package main

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/osquery/osquery-go/plugin/table"
)

func emptyQueryContext() table.QueryContext {
	return table.QueryContext{Constraints: map[string]table.ConstraintList{}}
}

type stubConfig struct {
	installPath string
	processUp   bool
	branding    nsbrandingConfig
	brandingErr error
	configMtime time.Time
	configErr   error
	nstdiag     nstdiagState
	nstdiagErr  error
}

// withStubs swaps all side-effecting function variables for fakes and restores
// them when the test exits.
func withStubs(t *testing.T, stubs stubConfig) {
	t.Helper()
	origInstall := detectInstallPath
	origProcess := detectProcessUp
	origBranding := readBrandingFile
	origConfig := readConfigFile
	origNstdiag := runNstdiag
	t.Cleanup(func() {
		detectInstallPath = origInstall
		detectProcessUp = origProcess
		readBrandingFile = origBranding
		readConfigFile = origConfig
		runNstdiag = origNstdiag
	})
	detectInstallPath = func() string { return stubs.installPath }
	detectProcessUp = func() bool { return stubs.processUp }
	readBrandingFile = func(string) (nsbrandingConfig, error) { return stubs.branding, stubs.brandingErr }
	readConfigFile = func(string) (time.Time, error) { return stubs.configMtime, stubs.configErr }
	runNstdiag = func(context.Context, string) (nstdiagState, error) { return stubs.nstdiag, stubs.nstdiagErr }
}

func TestColumns(t *testing.T) {
	cols := NetskopeClientColumns()
	// Spot-check presence of the columns the customer specifically asked for —
	// silent-degradation detection is the whole point of this extension.
	want := map[string]bool{
		"client_version":     true,
		"connection_state":   true,
		"tunnel_status":      true,
		"enabled":            true,
		"disabled_silently":  true,
		"process_running":    true,
		"steering_config":    true,
		"tenant":             true,
		"user_email":         true,
		"last_config_update": true,
		"policy_version":     true,
		"install_path":       true,
		"error":              true,
	}
	got := map[string]bool{}
	for _, c := range cols {
		got[c.Name] = true
	}
	for k := range want {
		if !got[k] {
			t.Errorf("missing column %q in schema", k)
		}
	}
	if len(cols) != len(want) {
		t.Errorf("unexpected column count: got %d want %d", len(cols), len(want))
	}
}

func TestGenerate_NotInstalled(t *testing.T) {
	withStubs(t, stubConfig{installPath: ""})

	rows, err := NetskopeClientGenerate(context.Background(), emptyQueryContext())
	if err != nil {
		t.Fatalf("Generate returned error: %v (expected graceful degradation)", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	if rows[0]["error"] != "netskope client not installed" {
		t.Errorf("unexpected error column: %q", rows[0]["error"])
	}
	if rows[0]["enabled"] != "0" {
		t.Errorf("expected enabled=0, got %q", rows[0]["enabled"])
	}
}

func TestGenerate_HealthyAgent(t *testing.T) {
	configMtime := time.Date(2026, 4, 14, 15, 30, 0, 0, time.UTC)
	withStubs(t, stubConfig{
		installPath: "/Library/Application Support/Netskope/STAgent",
		processUp:   true,
		branding: nsbrandingConfig{
			Tenant:         "acme-corp",
			SteeringConfig: "default-steering",
			UserEmail:      "alice@acme.example",
			PolicyVersion:  "42",
		},
		configMtime: configMtime,
		nstdiag: nstdiagState{
			ClientVersion:   "117.1.0.1234",
			ConnectionState: "Enabled",
			TunnelStatus:    "UP",
		},
	})

	rows, err := NetskopeClientGenerate(context.Background(), emptyQueryContext())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	r := rows[0]
	if r["enabled"] != "1" {
		t.Errorf("expected enabled=1, got %q", r["enabled"])
	}
	if r["disabled_silently"] != "0" {
		t.Errorf("expected disabled_silently=0, got %q", r["disabled_silently"])
	}
	if r["connection_state"] != "enabled" {
		t.Errorf("expected connection_state=enabled, got %q", r["connection_state"])
	}
	if r["tunnel_status"] != "up" {
		t.Errorf("expected tunnel_status=up, got %q", r["tunnel_status"])
	}
	if r["client_version"] != "117.1.0.1234" {
		t.Errorf("unexpected client_version: %q", r["client_version"])
	}
	if r["tenant"] != "acme-corp" {
		t.Errorf("unexpected tenant: %q", r["tenant"])
	}
	if r["last_config_update"] != configMtime.Format(time.RFC3339) {
		t.Errorf("unexpected last_config_update: %q", r["last_config_update"])
	}
	if r["error"] != "" {
		t.Errorf("expected no error, got %q", r["error"])
	}
}

// TestGenerate_SilentDegradation is the critical case from issue #43629: the
// process looks healthy but nstdiag reports the client is not fully up.
func TestGenerate_SilentDegradation(t *testing.T) {
	withStubs(t, stubConfig{
		installPath: "/Library/Application Support/Netskope/STAgent",
		processUp:   true,
		nstdiag: nstdiagState{
			ClientVersion:   "117.1.0.1234",
			ConnectionState: "disabled",
			TunnelStatus:    "down",
		},
	})

	rows, err := NetskopeClientGenerate(context.Background(), emptyQueryContext())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	r := rows[0]
	if r["disabled_silently"] != "1" {
		t.Errorf("expected disabled_silently=1 (process up, tunnel down), got %q", r["disabled_silently"])
	}
	if r["enabled"] != "0" {
		t.Errorf("expected enabled=0, got %q", r["enabled"])
	}
	if r["process_running"] != "1" {
		t.Errorf("expected process_running=1, got %q", r["process_running"])
	}
}

func TestGenerate_NstdiagFailure_StillReportsConfig(t *testing.T) {
	withStubs(t, stubConfig{
		installPath: "/opt/netskope/stagent",
		processUp:   true,
		branding:    nsbrandingConfig{Tenant: "acme-corp", SteeringConfig: "default-steering"},
		nstdiagErr:  errors.New("permission denied"),
	})

	rows, err := NetskopeClientGenerate(context.Background(), emptyQueryContext())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	r := rows[0]
	if r["tenant"] != "acme-corp" {
		t.Errorf("expected tenant to be populated from branding file even when nstdiag fails, got %q", r["tenant"])
	}
	if r["error"] == "" {
		t.Error("expected nstdiag error to be surfaced in error column")
	}
	if r["connection_state"] != "unknown" {
		t.Errorf("expected connection_state=unknown when nstdiag fails, got %q", r["connection_state"])
	}
}

func TestParseNstdiagText(t *testing.T) {
	input := []byte(`Client Version: 117.1.0.1234
Connection State: Enabled
Tunnel Status: up
Tenant: acme-corp
Steering Config: default-steering
User: alice@acme.example
Policy Version: 42
Unrelated Field: noise
`)
	s := parseNstdiagText(input)
	if s.ClientVersion != "117.1.0.1234" {
		t.Errorf("unexpected ClientVersion: %q", s.ClientVersion)
	}
	if s.ConnectionState != "Enabled" {
		t.Errorf("unexpected ConnectionState: %q", s.ConnectionState)
	}
	if s.Tenant != "acme-corp" {
		t.Errorf("unexpected Tenant: %q", s.Tenant)
	}
	if s.PolicyVersion != "42" {
		t.Errorf("unexpected PolicyVersion: %q", s.PolicyVersion)
	}
}

func TestParseNstdiagJSON(t *testing.T) {
	input := []byte(`{
		"client_version": "117.1.0.1234",
		"connection_state": "enabled",
		"tunnel_status": "up",
		"tenant": "acme-corp",
		"steering_config": "default-steering"
	}`)
	s, err := parseNstdiagJSON(input)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if s.ClientVersion != "117.1.0.1234" || s.Tenant != "acme-corp" {
		t.Errorf("unexpected parsed state: %+v", s)
	}
}

func TestParseNstdiagJSON_Malformed(t *testing.T) {
	if _, err := parseNstdiagJSON([]byte("not json")); err == nil {
		t.Error("expected error on malformed JSON")
	}
}

func TestParseNstdiagText_Empty(t *testing.T) {
	s := parseNstdiagText(nil)
	if s.ClientVersion != "" || s.ConnectionState != "" {
		t.Errorf("expected zero value for empty input, got %+v", s)
	}
}
