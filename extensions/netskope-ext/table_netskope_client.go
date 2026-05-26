package main

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/osquery/osquery-go/plugin/table"
)

// nstdiagColumnNames lists all columns exposed by the netskope table. Each
// column maps directly to a field from `nsdiag -f` output, converted to
// lowercase with underscores. The "install_path" and "error" columns are
// added for operational diagnostics.
var nstdiagColumnNames = []string{
	"orgname",
	"tenant_url",
	"addonhost",
	"addoncheckerhost",
	"gateway",
	"gateway_ip",
	"config",
	"steering_config",
	"email",
	"peruser_config",
	"tunnel_status",
	"client_status",
	"dynamic_steering",
	"onpremdetection",
	"explicit_proxy",
	"tunnel_protocol",
	"sni_enable",
	"traffic_mode",
	"client_version",
	"install_path",
	"error",
}

// NetskopeClientColumns describes the netskope table schema.
func NetskopeClientColumns() []table.ColumnDefinition {
	cols := make([]table.ColumnDefinition, len(nstdiagColumnNames))
	for i, name := range nstdiagColumnNames {
		cols[i] = table.TextColumn(name)
	}
	return cols
}

// nstdiagKeyToColumn maps the lowercase form of each nsdiag -f field name to
// the corresponding osquery column name.
var nstdiagKeyToColumn = map[string]string{
	"orgname":          "orgname",
	"tenant url":       "tenant_url",
	"addonhost":        "addonhost",
	"addoncheckerhost": "addoncheckerhost",
	"gateway":          "gateway",
	"gateway ip":       "gateway_ip",
	"config":           "config",
	"steering config":  "steering_config",
	"email":            "email",
	"peruser config":   "peruser_config",
	"tunnel status":    "tunnel_status",
	"client status":    "client_status",
	"dynamic steering": "dynamic_steering",
	"onpremdetection":  "onpremdetection",
	"explicit proxy":   "explicit_proxy",
	"tunnel protocol":  "tunnel_protocol",
	"sni enable":       "sni_enable",
	"traffic mode":     "traffic_mode",
	"client version":   "client_version",
}

var (
	runNstdiag        = defaultRunNstdiag
	detectInstallPath = defaultDetectInstallPath
)

// NetskopeClientGenerate produces the single-row result set returned for each
// query. If Netskope is not installed, it returns one row with
// error="netskope client not installed" rather than a plugin failure.
func NetskopeClientGenerate(ctx context.Context, qc table.QueryContext) ([]map[string]string, error) {
	row := make(map[string]string, len(nstdiagColumnNames))
	for _, col := range nstdiagColumnNames {
		row[col] = ""
	}

	installPath := detectInstallPath()
	if installPath == "" {
		row["error"] = "netskope client not installed"
		return []map[string]string{row}, nil
	}
	row["install_path"] = installPath

	parsed, err := runNstdiag(ctx, installPath)
	if err != nil {
		row["error"] = "nstdiag failed: " + err.Error()
		return []map[string]string{row}, nil
	}

	for col, val := range parsed {
		row[col] = val
	}

	return []map[string]string{row}, nil
}

// defaultDetectInstallPath returns the platform-specific install directory for
// the Netskope client, or "" if it is not present.
func defaultDetectInstallPath() string {
	return findInstallPath(installPathCandidates(), os.Stat)
}

func installPathCandidates() []string {
	switch runtime.GOOS {
	case "darwin":
		return []string{"/Library/Application Support/Netskope/STAgent"}
	case "windows":
		return []string{
			`C:\Program Files\Netskope\STAgent`,
			`C:\Program Files (x86)\Netskope\STAgent`,
		}
	case "linux":
		return []string{
			"/opt/netskope/stagent",
			"/opt/Netskope/STAgent",
		}
	}
	return nil
}

func findInstallPath(candidates []string, stat func(string) (os.FileInfo, error)) string {
	for _, candidate := range candidates {
		bin := filepath.Join(candidate, nsdiagBinaryName())
		if st, err := stat(bin); err == nil && !st.IsDir() {
			return candidate
		}
	}

	for _, candidate := range candidates {
		if st, err := stat(candidate); err == nil && st.IsDir() {
			return candidate
		}
	}

	return ""
}

func nsdiagBinaryName() string {
	if runtime.GOOS == "windows" {
		return "nsdiag.exe"
	}
	return "nsdiag"
}

// defaultRunNstdiag executes nsdiag -f to collect Netskope client state and
// parses the "Key:: Value." output into a column-name-keyed map.
func defaultRunNstdiag(ctx context.Context, installPath string) (map[string]string, error) {
	bin := filepath.Join(installPath, nsdiagBinaryName())
	if _, err := os.Stat(bin); err != nil {
		return nil, errors.New("nsdiag not found at " + bin)
	}

	cctx, cancel := context.WithTimeout(ctx, defaultTimeout)
	defer cancel()

	out, err := exec.CommandContext(cctx, bin, "-f").Output()
	if err != nil {
		return nil, err
	}
	return parseNstdiagText(out), nil
}

// parseNstdiagText handles the "Key:: Value." style output produced by
// nsdiag -f. Literal boolean values are normalized to uppercase TRUE/FALSE to
// keep output consistent across fields.
func parseNstdiagText(b []byte) map[string]string {
	result := make(map[string]string)
	for _, line := range strings.Split(string(b), "\n") {
		idx := strings.Index(line, "::")
		if idx == -1 {
			continue
		}
		key := strings.TrimSpace(strings.ToLower(line[:idx]))
		val := strings.TrimSpace(line[idx+2:])
		// nsdiag appends a trailing period to every value.
		val = strings.TrimSuffix(val, ".")
		val = strings.TrimSpace(val)
		val = normalizeNstdiagValue(val)
		if col, ok := nstdiagKeyToColumn[key]; ok {
			result[col] = val
		}
	}
	return result
}

func normalizeNstdiagValue(val string) string {
	if parsed, err := strconv.ParseBool(val); err == nil {
		if parsed {
			return "TRUE"
		}
		return "FALSE"
	}
	return val
}
