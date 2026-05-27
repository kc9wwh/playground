package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/osquery/osquery-go/plugin/table"
)

func emptyQueryContext() table.QueryContext {
	return table.QueryContext{Constraints: map[string]table.ConstraintList{}}
}

type stubConfig struct {
	installPath string
	nstdiag     map[string]string
	nstdiagErr  error
}

// withStubs swaps all side-effecting function variables for fakes and restores
// them when the test exits.
func withStubs(t *testing.T, stubs stubConfig) {
	t.Helper()
	origInstall := detectInstallPath
	origNstdiag := runNstdiag
	t.Cleanup(func() {
		detectInstallPath = origInstall
		runNstdiag = origNstdiag
	})
	detectInstallPath = func() string { return stubs.installPath }
	runNstdiag = func(context.Context, string) (map[string]string, error) {
		return stubs.nstdiag, stubs.nstdiagErr
	}
}

func TestColumns(t *testing.T) {
	cols := NetskopeClientColumns()
	want := map[string]bool{
		"orgname":          true,
		"tenant_url":       true,
		"addonhost":        true,
		"addoncheckerhost": true,
		"gateway":          true,
		"gateway_ip":       true,
		"config":           true,
		"steering_config":  true,
		"email":            true,
		"peruser_config":   true,
		"tunnel_status":    true,
		"client_status":    true,
		"dynamic_steering": true,
		"onpremdetection":  true,
		"explicit_proxy":   true,
		"tunnel_protocol":  true,
		"sni_enable":       true,
		"traffic_mode":     true,
		"client_version":   true,
		"install_path":     true,
		"error":            true,
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
}

func TestGenerate_HealthyAgent(t *testing.T) {
	withStubs(t, stubConfig{
		installPath: "/Library/Application Support/Netskope/STAgent",
		nstdiag: map[string]string{
			"client_version":   "117.1.0.1234",
			"client_status":    "enable",
			"tunnel_status":    "NSTUNNEL_CONNECTED",
			"orgname":          "CompanyName",
			"tenant_url":       "companyname.goskope.com",
			"steering_config":  "Default tenant config",
			"email":            "alice@acme.example",
			"addonhost":        "addon-companyname.goskope.com",
			"addoncheckerhost": "achecker-companyname.goskope.com",
			"gateway":          "gateway-xyz.goskope.com",
			"gateway_ip":       "000.111.222.333",
			"config":           "Pop Pinning Client Configuration",
			"peruser_config":   "FALSE",
			"dynamic_steering": "FALSE",
			"onpremdetection":  "Not Configured",
			"explicit_proxy":   "FALSE",
			"tunnel_protocol":  "TLS",
			"sni_enable":       "FALSE",
			"traffic_mode":     "All Traffic",
		},
	})

	rows, err := NetskopeClientGenerate(context.Background(), emptyQueryContext())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	r := rows[0]
	if r["client_status"] != "enable" {
		t.Errorf("expected client_status=enable, got %q", r["client_status"])
	}
	if r["tunnel_status"] != "NSTUNNEL_CONNECTED" {
		t.Errorf("expected tunnel_status=NSTUNNEL_CONNECTED, got %q", r["tunnel_status"])
	}
	if r["client_version"] != "117.1.0.1234" {
		t.Errorf("unexpected client_version: %q", r["client_version"])
	}
	if r["orgname"] != "CompanyName" {
		t.Errorf("unexpected orgname: %q", r["orgname"])
	}
	if r["tenant_url"] != "companyname.goskope.com" {
		t.Errorf("unexpected tenant_url: %q", r["tenant_url"])
	}
	if r["email"] != "alice@acme.example" {
		t.Errorf("unexpected email: %q", r["email"])
	}
	if r["error"] != "" {
		t.Errorf("expected no error, got %q", r["error"])
	}
}

func TestGenerate_NstdiagFailure(t *testing.T) {
	withStubs(t, stubConfig{
		installPath: "/opt/netskope/stagent",
		nstdiagErr:  errors.New("permission denied"),
	})

	rows, err := NetskopeClientGenerate(context.Background(), emptyQueryContext())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	r := rows[0]
	if r["error"] == "" {
		t.Error("expected nstdiag error to be surfaced in error column")
	}
}

func TestParseNstdiagText(t *testing.T) {
	input := []byte(`Orgname:: CompanyName.
Tenant URL :: CompanyName.goskope.com.
AddonHost:: addon-companyname.goskope.com.
AddonCheckerHost:: achecker-companyname.goskope.com.
Gateway:: gateway-xyz.goskope.com.
Gateway IP:: 000.111.222.333.
Config:: Pop Pinning Client Configuration.
Steering Config:: Default tenant config.
Email:: alice@acme.example.
Peruser config:: FALSE.
Tunnel status:: NSTUNNEL_CONNECTED.
Client status:: enable.
Dynamic Steering:: FALSE.
OnPremDetection:: Not Configured.
Explicit Proxy:: false.
Tunnel Protocol:: TLS.
SNI Enable:: FALSE.
Traffic Mode:: All Traffic.
Client version:: 117.1.0.1234.
`)
	s := parseNstdiagText(input)
	checks := map[string]string{
		"client_version":   "117.1.0.1234",
		"client_status":    "enable",
		"tunnel_status":    "NSTUNNEL_CONNECTED",
		"orgname":          "CompanyName",
		"tenant_url":       "CompanyName.goskope.com",
		"steering_config":  "Default tenant config",
		"email":            "alice@acme.example",
		"addonhost":        "addon-companyname.goskope.com",
		"addoncheckerhost": "achecker-companyname.goskope.com",
		"gateway":          "gateway-xyz.goskope.com",
		"gateway_ip":       "000.111.222.333",
		"config":           "Pop Pinning Client Configuration",
		"peruser_config":   "FALSE",
		"dynamic_steering": "FALSE",
		"onpremdetection":  "Not Configured",
		"explicit_proxy":   "FALSE",
		"tunnel_protocol":  "TLS",
		"sni_enable":       "FALSE",
		"traffic_mode":     "All Traffic",
	}
	for col, want := range checks {
		if got := s[col]; got != want {
			t.Errorf("column %q: got %q, want %q", col, got, want)
		}
	}
}

func TestParseNstdiagText_UnknownFieldsIgnored(t *testing.T) {
	input := []byte(`Client version:: 117.1.0.1234.
Unrelated Field:: noise.
`)
	s := parseNstdiagText(input)
	if s["client_version"] != "117.1.0.1234" {
		t.Errorf("unexpected client_version: %q", s["client_version"])
	}
	if _, ok := s["unrelated_field"]; ok {
		t.Error("unexpected key for unrecognized field")
	}
}

func TestParseNstdiagText_Empty(t *testing.T) {
	s := parseNstdiagText(nil)
	if len(s) != 0 {
		t.Errorf("expected empty map for empty input, got %+v", s)
	}
}

type fakeFileInfo struct {
	isDir bool
}

func (f fakeFileInfo) Name() string       { return "" }
func (f fakeFileInfo) Size() int64        { return 0 }
func (f fakeFileInfo) Mode() os.FileMode  { return 0 }
func (f fakeFileInfo) ModTime() time.Time { return time.Time{} }
func (f fakeFileInfo) IsDir() bool        { return f.isDir }
func (f fakeFileInfo) Sys() any           { return nil }

func TestFindInstallPath_PrefersCandidateWithBinary(t *testing.T) {
	// Build paths with filepath.Join + nsdiagBinaryName() so the test matches
	// what findInstallPath computes under any runtime.GOOS (forward slashes on
	// unix, "nsdiag" vs "nsdiag.exe").
	dir1 := filepath.Join("Program Files", "Netskope", "STAgent")
	dir2 := filepath.Join("Program Files (x86)", "Netskope", "STAgent")
	bin1 := filepath.Join(dir1, nsdiagBinaryName())

	candidates := []string{dir1, dir2}
	paths := map[string]fakeFileInfo{
		dir1: {isDir: true},
		bin1: {isDir: false},
		dir2: {isDir: true},
	}

	got := findInstallPath(candidates, func(path string) (os.FileInfo, error) {
		if info, ok := paths[path]; ok {
			return info, nil
		}
		return nil, os.ErrNotExist
	})

	if got != dir1 {
		t.Fatalf("expected install path %q, got %q", dir1, got)
	}
}

func TestFindInstallPath_FallsBackToExistingDirectory(t *testing.T) {
	dir := filepath.Join("Program Files", "Netskope", "STAgent")
	candidates := []string{dir}
	paths := map[string]fakeFileInfo{
		dir: {isDir: true},
	}

	got := findInstallPath(candidates, func(path string) (os.FileInfo, error) {
		if info, ok := paths[path]; ok {
			return info, nil
		}
		return nil, os.ErrNotExist
	})

	if got != dir {
		t.Fatalf("expected fallback install path %q, got %q", dir, got)
	}
}
