package main

import (
	"context"
	"encoding/json"
	"errors"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/osquery/osquery-go/plugin/table"
)

// tailscaleStatus mirrors the subset of `tailscale status --json` output that
// we surface as columns. Only fields we actually read are declared — unknown
// keys are ignored by encoding/json, which keeps the extension resilient to
// schema additions in future Tailscale versions.
type tailscaleStatus struct {
	Version        string            `json:"Version"`
	BackendState   string            `json:"BackendState"`
	AuthURL        string            `json:"AuthURL"`
	TailscaleIPs   []string          `json:"TailscaleIPs"`
	Self           *tsPeer           `json:"Self"`
	MagicDNSSuffix string            `json:"MagicDNSSuffix"`
	CurrentTailnet *tsTailnet        `json:"CurrentTailnet"`
	Peer           map[string]tsPeer `json:"Peer"`
	User           map[string]tsUser `json:"User"`
	ExitNodeStatus *tsExitNode       `json:"ExitNodeStatus"`
}

type tsTailnet struct {
	Name            string `json:"Name"`
	MagicDNSSuffix  string `json:"MagicDNSSuffix"`
	MagicDNSEnabled bool   `json:"MagicDNSEnabled"`
}

type tsPeer struct {
	ID           string   `json:"ID"`
	PublicKey    string   `json:"PublicKey"`
	HostName     string   `json:"HostName"`
	DNSName      string   `json:"DNSName"`
	OS           string   `json:"OS"`
	UserID       int64    `json:"UserID"`
	TailscaleIPs []string `json:"TailscaleIPs"`
	Online       bool     `json:"Online"`
	ExitNode     bool     `json:"ExitNode"`
}

type tsUser struct {
	ID            int64  `json:"ID"`
	LoginName     string `json:"LoginName"`
	DisplayName   string `json:"DisplayName"`
	ProfilePicURL string `json:"ProfilePicURL"`
}

type tsExitNode struct {
	ID           string   `json:"ID"`
	Online       bool     `json:"Online"`
	TailscaleIPs []string `json:"TailscaleIPs"`
}

// tailscaleStatusFetcher is the indirection point for tests. Production code
// uses fetchTailscaleStatus; unit tests replace it with a mock that returns
// canned JSON or an error.
var tailscaleStatusFetcher = fetchTailscaleStatus

// TailscaleStatusColumns declares the schema the osquery extension exposes.
func TailscaleStatusColumns() []table.ColumnDefinition {
	return []table.ColumnDefinition{
		table.TextColumn("version"),
		table.TextColumn("backend_state"),
		table.TextColumn("auth_url"),
		table.TextColumn("tailnet_name"),
		table.TextColumn("magic_dns_suffix"),
		table.IntegerColumn("magic_dns_enabled"),
		table.TextColumn("self_hostname"),
		table.TextColumn("self_dns_name"),
		table.TextColumn("self_tailscale_ipv4"),
		table.TextColumn("self_tailscale_ipv6"),
		table.IntegerColumn("self_online"),
		table.TextColumn("user_login_name"),
		table.IntegerColumn("peer_count"),
		table.IntegerColumn("active_peer_count"),
		table.IntegerColumn("exit_node_in_use"),
		table.TextColumn("exit_node_hostname"),
	}
}

// TailscaleStatusGenerate is the row generator osquery calls for every query
// against tailscale_status. It always returns a single row when Tailscale is
// installed — even if the backend is Stopped or NeedsLogin — so that policies
// can distinguish "not installed" (zero rows) from "installed but broken"
// (one row with backend_state != "Running").
//
// When Tailscale is not installed or the CLI cannot be reached, we return an
// empty result set rather than an error. An error here would show up in
// osquery logs as a table failure and obscure the real signal.
func TailscaleStatusGenerate(ctx context.Context, _ table.QueryContext) ([]map[string]string, error) {
	raw, err := tailscaleStatusFetcher(ctx)
	if err != nil {
		// Not installed / not runnable — return empty rows, not an error.
		return []map[string]string{}, nil
	}

	var status tailscaleStatus
	if err := json.Unmarshal(raw, &status); err != nil {
		return []map[string]string{}, nil
	}

	row := buildRow(&status)
	return []map[string]string{row}, nil
}

func buildRow(status *tailscaleStatus) map[string]string {
	row := map[string]string{
		"version":             status.Version,
		"backend_state":       status.BackendState,
		"auth_url":            status.AuthURL,
		"tailnet_name":        "",
		"magic_dns_suffix":    status.MagicDNSSuffix,
		"magic_dns_enabled":   "0",
		"self_hostname":       "",
		"self_dns_name":       "",
		"self_tailscale_ipv4": "",
		"self_tailscale_ipv6": "",
		"self_online":         "0",
		"user_login_name":     "",
		"peer_count":          "0",
		"active_peer_count":   "0",
		"exit_node_in_use":    "0",
		"exit_node_hostname":  "",
	}

	if status.CurrentTailnet != nil {
		row["tailnet_name"] = status.CurrentTailnet.Name
		if status.CurrentTailnet.MagicDNSSuffix != "" {
			row["magic_dns_suffix"] = status.CurrentTailnet.MagicDNSSuffix
		}
		row["magic_dns_enabled"] = boolToStr(status.CurrentTailnet.MagicDNSEnabled)
	}

	if status.Self != nil {
		row["self_hostname"] = status.Self.HostName
		row["self_dns_name"] = strings.TrimSuffix(status.Self.DNSName, ".")
		row["self_online"] = boolToStr(status.Self.Online)

		ipv4, ipv6 := splitIPs(status.Self.TailscaleIPs)
		row["self_tailscale_ipv4"] = ipv4
		row["self_tailscale_ipv6"] = ipv6

		if u, ok := status.User[strconv.FormatInt(status.Self.UserID, 10)]; ok {
			row["user_login_name"] = u.LoginName
		}
	}

	row["peer_count"] = strconv.Itoa(len(status.Peer))
	active := 0
	for _, p := range status.Peer {
		if p.Online {
			active++
		}
	}
	row["active_peer_count"] = strconv.Itoa(active)

	if status.ExitNodeStatus != nil && status.ExitNodeStatus.Online {
		row["exit_node_in_use"] = "1"
		// Look up the exit node peer to resolve its hostname.
		for _, p := range status.Peer {
			if p.ID == status.ExitNodeStatus.ID {
				row["exit_node_hostname"] = p.HostName
				break
			}
		}
	}

	return row
}

// fetchTailscaleStatus shells out to `tailscale status --json` with a
// hard timeout. Callers should treat any error as "Tailscale unavailable".
func fetchTailscaleStatus(ctx context.Context) ([]byte, error) {
	cmdCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	bin, err := findTailscaleBinary()
	if err != nil {
		return nil, err
	}

	cmd := exec.CommandContext(cmdCtx, bin, "status", "--json")
	out, err := cmd.Output()
	if err != nil {
		return nil, err
	}
	return out, nil
}

// findTailscaleBinary returns the path to the tailscale CLI on this host.
// It looks in well-known install locations before falling back to PATH,
// because macOS GUI installs place the binary inside the .app bundle and
// orbit/osqueryd does not always inherit a PATH that includes it.
func findTailscaleBinary() (string, error) {
	candidates := tailscaleCandidatePaths()
	for _, p := range candidates {
		if p == "" {
			continue
		}
		if _, err := exec.LookPath(p); err == nil {
			return p, nil
		}
	}
	if p, err := exec.LookPath("tailscale"); err == nil {
		return p, nil
	}
	return "", errors.New("tailscale CLI not found")
}

func tailscaleCandidatePaths() []string {
	switch runtime.GOOS {
	case "darwin":
		return []string{
			"/Applications/Tailscale.app/Contents/MacOS/Tailscale",
			"/usr/local/bin/tailscale",
			"/opt/homebrew/bin/tailscale",
		}
	case "linux":
		return []string{
			"/usr/bin/tailscale",
			"/usr/local/bin/tailscale",
		}
	case "windows":
		return []string{
			`C:\Program Files\Tailscale\tailscale.exe`,
			`C:\Program Files (x86)\Tailscale\tailscale.exe`,
		}
	}
	return nil
}

func splitIPs(ips []string) (string, string) {
	var ipv4, ipv6 string
	for _, ip := range ips {
		if strings.Contains(ip, ":") {
			if ipv6 == "" {
				ipv6 = ip
			}
		} else {
			if ipv4 == "" {
				ipv4 = ip
			}
		}
	}
	return ipv4, ipv6
}

func boolToStr(b bool) string {
	if b {
		return "1"
	}
	return "0"
}
