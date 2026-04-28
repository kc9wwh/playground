package main

import (
	"context"
	"errors"
	"testing"

	"github.com/osquery/osquery-go/plugin/table"
)

// sampleStatusJSON is trimmed but realistic output from `tailscale status
// --json` on a machine that is connected to a tailnet and using an exit node.
const sampleStatusJSON = `{
  "Version": "1.78.1-t4a8a2f33b-g3d7a2c4e",
  "BackendState": "Running",
  "AuthURL": "",
  "TailscaleIPs": ["100.64.0.5", "fd7a:115c:a1e0::5"],
  "MagicDNSSuffix": "tail1234.ts.net",
  "CurrentTailnet": {
    "Name": "acme.com",
    "MagicDNSSuffix": "tail1234.ts.net",
    "MagicDNSEnabled": true
  },
  "Self": {
    "ID": "nABC123",
    "PublicKey": "nodekey:abc",
    "HostName": "josh-laptop",
    "DNSName": "josh-laptop.tail1234.ts.net.",
    "OS": "macOS",
    "UserID": 42,
    "TailscaleIPs": ["100.64.0.5", "fd7a:115c:a1e0::5"],
    "Online": true,
    "ExitNode": false
  },
  "User": {
    "42": {
      "ID": 42,
      "LoginName": "josh@acme.com",
      "DisplayName": "Josh"
    }
  },
  "Peer": {
    "nodekey:peer1": {
      "ID": "nPEER1",
      "HostName": "exit-node-sfo",
      "DNSName": "exit-node-sfo.tail1234.ts.net.",
      "TailscaleIPs": ["100.64.0.9"],
      "Online": true,
      "ExitNode": true
    },
    "nodekey:peer2": {
      "ID": "nPEER2",
      "HostName": "build-box",
      "TailscaleIPs": ["100.64.0.11"],
      "Online": true
    },
    "nodekey:peer3": {
      "ID": "nPEER3",
      "HostName": "old-laptop",
      "TailscaleIPs": ["100.64.0.22"],
      "Online": false
    }
  },
  "ExitNodeStatus": {
    "ID": "nPEER1",
    "Online": true,
    "TailscaleIPs": ["100.64.0.9"]
  }
}`

func TestColumnsSchema(t *testing.T) {
	cols := TailscaleStatusColumns()

	expected := map[string]table.ColumnType{
		"version":             table.ColumnTypeText,
		"backend_state":       table.ColumnTypeText,
		"auth_url":            table.ColumnTypeText,
		"tailnet_name":        table.ColumnTypeText,
		"magic_dns_suffix":    table.ColumnTypeText,
		"magic_dns_enabled":   table.ColumnTypeInteger,
		"self_hostname":       table.ColumnTypeText,
		"self_dns_name":       table.ColumnTypeText,
		"self_tailscale_ipv4": table.ColumnTypeText,
		"self_tailscale_ipv6": table.ColumnTypeText,
		"self_online":         table.ColumnTypeInteger,
		"user_login_name":     table.ColumnTypeText,
		"peer_count":          table.ColumnTypeInteger,
		"active_peer_count":   table.ColumnTypeInteger,
		"exit_node_in_use":    table.ColumnTypeInteger,
		"exit_node_hostname":  table.ColumnTypeText,
	}

	if len(cols) != len(expected) {
		t.Fatalf("column count mismatch: got %d, want %d", len(cols), len(expected))
	}
	for _, col := range cols {
		want, ok := expected[col.Name]
		if !ok {
			t.Errorf("unexpected column: %s", col.Name)
			continue
		}
		if col.Type != want {
			t.Errorf("column %s: got type %v, want %v", col.Name, col.Type, want)
		}
	}
}

func TestGenerateHappyPath(t *testing.T) {
	restore := withFetcher(func(context.Context) ([]byte, error) {
		return []byte(sampleStatusJSON), nil
	})
	defer restore()

	rows, err := TailscaleStatusGenerate(context.Background(), table.QueryContext{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	row := rows[0]

	checks := map[string]string{
		"version":             "1.78.1-t4a8a2f33b-g3d7a2c4e",
		"backend_state":       "Running",
		"tailnet_name":        "acme.com",
		"magic_dns_suffix":    "tail1234.ts.net",
		"magic_dns_enabled":   "1",
		"self_hostname":       "josh-laptop",
		"self_dns_name":       "josh-laptop.tail1234.ts.net",
		"self_tailscale_ipv4": "100.64.0.5",
		"self_tailscale_ipv6": "fd7a:115c:a1e0::5",
		"self_online":         "1",
		"user_login_name":     "josh@acme.com",
		"peer_count":          "3",
		"active_peer_count":   "2",
		"exit_node_in_use":    "1",
		"exit_node_hostname":  "exit-node-sfo",
	}
	for col, want := range checks {
		if got := row[col]; got != want {
			t.Errorf("%s: got %q, want %q", col, got, want)
		}
	}
}

func TestGenerateNotInstalled(t *testing.T) {
	restore := withFetcher(func(context.Context) ([]byte, error) {
		return nil, errors.New("tailscale CLI not found")
	})
	defer restore()

	rows, err := TailscaleStatusGenerate(context.Background(), table.QueryContext{})
	if err != nil {
		t.Fatalf("expected nil error when CLI missing, got %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("expected 0 rows when Tailscale missing, got %d", len(rows))
	}
}

func TestGenerateMalformedJSON(t *testing.T) {
	restore := withFetcher(func(context.Context) ([]byte, error) {
		return []byte("this is not json"), nil
	})
	defer restore()

	rows, err := TailscaleStatusGenerate(context.Background(), table.QueryContext{})
	if err != nil {
		t.Fatalf("expected nil error on malformed JSON, got %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("expected 0 rows on malformed JSON, got %d", len(rows))
	}
}

func TestGenerateStoppedBackend(t *testing.T) {
	// Tailscale installed but not logged in.
	const stoppedJSON = `{
      "Version": "1.78.1",
      "BackendState": "NeedsLogin",
      "AuthURL": "https://login.tailscale.com/a/abc123",
      "TailscaleIPs": [],
      "Peer": {},
      "User": {}
    }`
	restore := withFetcher(func(context.Context) ([]byte, error) {
		return []byte(stoppedJSON), nil
	})
	defer restore()

	rows, err := TailscaleStatusGenerate(context.Background(), table.QueryContext{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row for installed-but-not-logged-in, got %d", len(rows))
	}
	row := rows[0]
	if row["backend_state"] != "NeedsLogin" {
		t.Errorf("backend_state: got %q, want NeedsLogin", row["backend_state"])
	}
	if row["auth_url"] != "https://login.tailscale.com/a/abc123" {
		t.Errorf("auth_url: got %q", row["auth_url"])
	}
	if row["peer_count"] != "0" {
		t.Errorf("peer_count: got %q, want 0", row["peer_count"])
	}
	if row["self_online"] != "0" {
		t.Errorf("self_online: got %q, want 0 (nil Self)", row["self_online"])
	}
	if row["exit_node_in_use"] != "0" {
		t.Errorf("exit_node_in_use: got %q, want 0", row["exit_node_in_use"])
	}
}

func TestSplitIPs(t *testing.T) {
	cases := []struct {
		name string
		in   []string
		v4   string
		v6   string
	}{
		{"empty", nil, "", ""},
		{"v4 only", []string{"100.64.0.5"}, "100.64.0.5", ""},
		{"v6 only", []string{"fd7a::5"}, "", "fd7a::5"},
		{"both", []string{"100.64.0.5", "fd7a::5"}, "100.64.0.5", "fd7a::5"},
		{"v6 first", []string{"fd7a::5", "100.64.0.5"}, "100.64.0.5", "fd7a::5"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			v4, v6 := splitIPs(tc.in)
			if v4 != tc.v4 || v6 != tc.v6 {
				t.Errorf("got (%q,%q), want (%q,%q)", v4, v6, tc.v4, tc.v6)
			}
		})
	}
}

// withFetcher swaps the package-level fetcher for a test-supplied one and
// returns a cleanup function that restores the original.
func withFetcher(f func(context.Context) ([]byte, error)) func() {
	orig := tailscaleStatusFetcher
	tailscaleStatusFetcher = f
	return func() { tailscaleStatusFetcher = orig }
}
