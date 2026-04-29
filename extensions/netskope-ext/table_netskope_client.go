package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/osquery/osquery-go/plugin/table"
)

// NetskopeClientColumns describes the netskope table schema.
// All columns are exposed as TEXT — osquery handles coercion from the column
// type, and keeping a single Go type (string) simplifies the Generate path.
func NetskopeClientColumns() []table.ColumnDefinition {
	return []table.ColumnDefinition{
		table.TextColumn("client_version"),
		table.TextColumn("connection_state"),     // enabled | disabled | degraded | unknown
		table.TextColumn("tunnel_status"),        // up | down | unknown
		table.IntegerColumn("enabled"),           // 1 if fully enabled, 0 otherwise
		table.IntegerColumn("disabled_silently"), // 1 if process is up but nstdiag reports disabled/degraded
		table.IntegerColumn("process_running"),   // 1 if stAgentSvc / nsagent is alive
		table.TextColumn("steering_config"),
		table.TextColumn("tenant"),
		table.TextColumn("user_email"),
		table.TextColumn("last_config_update"),
		table.TextColumn("policy_version"),
		table.TextColumn("install_path"),
		table.TextColumn("error"),
	}
}

// nstdiagState captures the subset of nstdiag output we care about. nstdiag's
// exact output format varies by platform and version, so parsing is tolerant —
// missing fields are treated as "unknown" rather than fatal errors.
type nstdiagState struct {
	ClientVersion    string `json:"client_version"`
	ConnectionState  string `json:"connection_state"`
	TunnelStatus     string `json:"tunnel_status"`
	SteeringConfig   string `json:"steering_config"`
	Tenant           string `json:"tenant"`
	UserEmail        string `json:"user_email"`
	LastConfigUpdate string `json:"last_config_update"`
	PolicyVersion    string `json:"policy_version"`
}

// nsbrandingConfig is a partial schema for Netskope's nsbranding.json, which
// typically contains tenant and steering identifiers. Fields beyond these are
// ignored.
type nsbrandingConfig struct {
	Tenant         string `json:"tenantName"`
	SteeringConfig string `json:"steeringConfigName"`
	UserEmail      string `json:"userEmail"`
	PolicyVersion  string `json:"policyVersion"`
}

// The following function variables abstract every side-effect the table
// performs. Tests replace them with fixtures so coverage does not depend on
// Netskope being installed.
var (
	runNstdiag        = defaultRunNstdiag
	readBrandingFile  = defaultReadBrandingFile
	readConfigFile    = defaultReadConfigFile
	detectProcessUp   = defaultDetectProcessUp
	detectInstallPath = defaultDetectInstallPath
)

// NetskopeClientGenerate produces the single-row result set returned for each
// query. Graceful degradation is important: if Netskope is not installed we
// emit one row with error="not installed" and zero-valued columns. Returning
// an error from this function would cause osquery to log a plugin failure,
// which would mask the common "Netskope not deployed" case.
func NetskopeClientGenerate(ctx context.Context, qc table.QueryContext) ([]map[string]string, error) {
	row := map[string]string{
		"client_version":     "",
		"connection_state":   "unknown",
		"tunnel_status":      "unknown",
		"enabled":            "0",
		"disabled_silently":  "0",
		"process_running":    "0",
		"steering_config":    "",
		"tenant":             "",
		"user_email":         "",
		"last_config_update": "",
		"policy_version":     "",
		"install_path":       "",
		"error":              "",
	}

	installPath := detectInstallPath()
	if installPath == "" {
		row["error"] = "netskope client not installed"
		return []map[string]string{row}, nil
	}
	row["install_path"] = installPath

	if detectProcessUp() {
		row["process_running"] = "1"
	}

	// Pull config-file data first so we still have tenant/steering info even
	// if nstdiag fails.
	if branding, err := readBrandingFile(installPath); err == nil {
		if branding.Tenant != "" {
			row["tenant"] = branding.Tenant
		}
		if branding.SteeringConfig != "" {
			row["steering_config"] = branding.SteeringConfig
		}
		if branding.UserEmail != "" {
			row["user_email"] = branding.UserEmail
		}
		if branding.PolicyVersion != "" {
			row["policy_version"] = branding.PolicyVersion
		}
	}

	if mtime, err := readConfigFile(installPath); err == nil && !mtime.IsZero() {
		row["last_config_update"] = mtime.UTC().Format(time.RFC3339)
	}

	// Execute nstdiag for authoritative state. Missing/failed nstdiag does not
	// fail the row — we keep the config-file data and record the error.
	state, err := runNstdiag(ctx, installPath)
	if err != nil {
		if row["error"] == "" {
			row["error"] = "nstdiag failed: " + err.Error()
		}
		return []map[string]string{row}, nil
	}

	if state.ClientVersion != "" {
		row["client_version"] = state.ClientVersion
	}
	if state.ConnectionState != "" {
		row["connection_state"] = strings.ToLower(state.ConnectionState)
	}
	if state.TunnelStatus != "" {
		row["tunnel_status"] = strings.ToLower(state.TunnelStatus)
	}
	if state.SteeringConfig != "" {
		row["steering_config"] = state.SteeringConfig
	}
	if state.Tenant != "" {
		row["tenant"] = state.Tenant
	}
	if state.UserEmail != "" {
		row["user_email"] = state.UserEmail
	}
	if state.LastConfigUpdate != "" {
		row["last_config_update"] = state.LastConfigUpdate
	}
	if state.PolicyVersion != "" {
		row["policy_version"] = state.PolicyVersion
	}

	if row["connection_state"] == "enabled" && row["tunnel_status"] == "up" {
		row["enabled"] = "1"
	}

	// The silent-degradation case the customer cares about: the host-level
	// processes look healthy, but nstdiag reports the client is not fully up.
	if row["process_running"] == "1" && row["enabled"] == "0" {
		row["disabled_silently"] = "1"
	}

	return []map[string]string{row}, nil
}

// defaultDetectInstallPath returns the platform-specific install directory for
// the Netskope client, or "" if it is not present.
func defaultDetectInstallPath() string {
	candidates := installPathCandidates()
	for _, c := range candidates {
		if st, err := os.Stat(c); err == nil && st.IsDir() {
			return c
		}
	}
	return ""
}

func installPathCandidates() []string {
	switch runtime.GOOS {
	case "darwin":
		return []string{"/Library/Application Support/Netskope/STAgent"}
	case "windows":
		return []string{
			`C:\Program Files (x86)\Netskope\STAgent`,
			`C:\Program Files\Netskope\STAgent`,
		}
	case "linux":
		return []string{
			"/opt/netskope/stagent",
			"/opt/Netskope/STAgent",
		}
	}
	return nil
}

func nstdiagBinaryName() string {
	if runtime.GOOS == "windows" {
		return "nstdiag.exe"
	}
	return "nstdiag"
}

// defaultRunNstdiag executes nstdiag with the JSON status flag and parses the
// result. The exact flag varies slightly by Netskope release; this function
// tries the most common invocation first and falls back to plain-text parsing
// if JSON is unavailable.
func defaultRunNstdiag(ctx context.Context, installPath string) (nstdiagState, error) {
	bin := filepath.Join(installPath, nstdiagBinaryName())
	if _, err := os.Stat(bin); err != nil {
		return nstdiagState{}, errors.New("nstdiag not found at " + bin)
	}

	cctx, cancel := context.WithTimeout(ctx, defaultTimeout)
	defer cancel()

	// Preferred: JSON status output (supported by recent Netskope releases).
	out, err := exec.CommandContext(cctx, bin, "-s", "-j").Output()
	if err == nil && len(out) > 0 {
		if s, perr := parseNstdiagJSON(out); perr == nil {
			return s, nil
		}
	}

	// Fallback: plain-text status output.
	cctx2, cancel2 := context.WithTimeout(ctx, defaultTimeout)
	defer cancel2()
	out, err = exec.CommandContext(cctx2, bin, "-s").Output()
	if err != nil {
		return nstdiagState{}, err
	}
	return parseNstdiagText(out), nil
}

func parseNstdiagJSON(b []byte) (nstdiagState, error) {
	var s nstdiagState
	if err := json.Unmarshal(b, &s); err != nil {
		return nstdiagState{}, err
	}
	return s, nil
}

// parseNstdiagText handles the "Key: Value" style output that older nstdiag
// releases emit. It is intentionally tolerant of unexpected fields.
func parseNstdiagText(b []byte) nstdiagState {
	var s nstdiagState
	for _, line := range strings.Split(string(b), "\n") {
		idx := strings.Index(line, ":")
		if idx == -1 {
			continue
		}
		key := strings.TrimSpace(strings.ToLower(line[:idx]))
		val := strings.TrimSpace(line[idx+1:])
		switch key {
		case "client version", "version":
			s.ClientVersion = val
		case "connection state", "state":
			s.ConnectionState = val
		case "tunnel status", "tunnel":
			s.TunnelStatus = val
		case "steering config", "steering configuration":
			s.SteeringConfig = val
		case "tenant", "tenant name":
			s.Tenant = val
		case "user", "user email", "email":
			s.UserEmail = val
		case "last config update", "last update":
			s.LastConfigUpdate = val
		case "policy version":
			s.PolicyVersion = val
		}
	}
	return s
}

// defaultReadBrandingFile reads and parses nsbranding.json from the install
// directory. Missing file or malformed JSON returns an error — the caller is
// expected to downgrade this to a non-fatal condition.
func defaultReadBrandingFile(installPath string) (nsbrandingConfig, error) {
	path := filepath.Join(installPath, "nsbranding.json")
	b, err := os.ReadFile(path)
	if err != nil {
		return nsbrandingConfig{}, err
	}
	var c nsbrandingConfig
	if err := json.Unmarshal(b, &c); err != nil {
		return nsbrandingConfig{}, err
	}
	return c, nil
}

// defaultReadConfigFile returns the modification time of nsconfig.json, which
// Netskope rewrites on every policy pull. This is a useful proxy for "when did
// this client last sync with the tenant" when the config JSON does not
// expose a timestamp field directly.
func defaultReadConfigFile(installPath string) (time.Time, error) {
	path := filepath.Join(installPath, "nsconfig.json")
	st, err := os.Stat(path)
	if err != nil {
		return time.Time{}, err
	}
	return st.ModTime(), nil
}

// defaultDetectProcessUp reports whether the Netskope agent process is running.
// Shelling out to the platform process tool keeps the extension free of cgo
// and platform-specific deps.
func defaultDetectProcessUp() bool {
	ctx, cancel := context.WithTimeout(context.Background(), defaultTimeout)
	defer cancel()

	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.CommandContext(ctx, "tasklist", "/FI", "IMAGENAME eq stAgentSvc.exe")
	default:
		cmd = exec.CommandContext(ctx, "pgrep", "-f", "stAgent|nsagent")
	}
	out, err := cmd.Output()
	if err != nil {
		return false
	}
	s := strings.ToLower(string(out))
	if runtime.GOOS == "windows" {
		return strings.Contains(s, "stagentsvc.exe")
	}
	return strings.TrimSpace(s) != ""
}
