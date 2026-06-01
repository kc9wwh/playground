package main

import (
	"context"
	"errors"
	"strconv"
	"testing"
	"time"

	"github.com/osquery/osquery-go/plugin/table"
)

// sampleStatusOutput is the canonical fixture produced by `sentinelctl status`
// on a healthy macOS host. It must round-trip through parseSentinelctlStatus
// into populated columns.
const sampleStatusOutput = `Agent
   Version:                                25.3.4.8365
   ID:                                     d7f94b33-7f99-4c43-9c6b-1c6e0d01aabb
   Install Date:                           6/1/26, 10:09:51 AM
   Missing Authorizations
   ES Framework:                           started
   Agent Operational State:                enabled
   Remote Profiler:                        not running
   Agent Network Monitoring:               started
   Network Extension:                      running
   Network Extension Content Filter:       active
   Ready:                                  yes
   Protection:                             enabled
   Infected:                               no
   Network Quarantine:                     no
   Compatible OS:                          compatible
Command
   Authentication:                         enabled
Daemons
   Services
      Agent Helper:                        ready
      Agent UI:                            ready
      Cleaner:                             ready
      Control Service:                     ready
      Framework:                           ready
      Guard:                               ready
      Helper Service:                      ready
      Lib Hooks Service:                   not ready
      Lib Logs Service:                    not ready
      Shell:                               ready
   Integrity
      sentineld:                           ok
      sentineld_guard:                     ok
      sentineld_helper:                    ok
      sentineld_shell:                     not running
Launchd
   agent-helper:                           valid
   agent-ui:                               valid
   sentinel-extensions:                    valid
   sentineld:                              valid
   sentineld-guard:                        valid
   sentineld-helper:                       valid
   sentineld-shell:                        valid
Management
   Server:                                 https://euce1-109.sentinelone.net
   Site Key:                               site-key-abc-123
   Last Seen:                              6/1/26, 1:14:28 PM
   Connected:                              yes
`

// setRunSentinelctl swaps the global command runner for a mock and returns a
// cleanup func.
func setRunSentinelctl(t *testing.T, fn func(args []string) ([]byte, error)) func() {
	t.Helper()
	orig := runSentinelctl
	runSentinelctl = func(ctx context.Context, args ...string) ([]byte, error) {
		return fn(args)
	}
	return func() { runSentinelctl = orig }
}

func TestSentinelOneInfoColumns(t *testing.T) {
	cols := SentinelOneInfoColumns()
	if len(cols) != len(columnOrder) {
		t.Fatalf("expected %d columns, got %d", len(columnOrder), len(cols))
	}
	for i, c := range cols {
		if c.Name != columnOrder[i] {
			t.Errorf("column[%d]: got %q, want %q", i, c.Name, columnOrder[i])
		}
		if c.Type != table.ColumnTypeText {
			t.Errorf("column %s: expected TEXT, got %v", c.Name, c.Type)
		}
	}
}

func TestSentinelOneInfoGenerate_HappyPath(t *testing.T) {
	cleanup := setRunSentinelctl(t, func(args []string) ([]byte, error) {
		if len(args) != 1 || args[0] != "status" {
			return nil, errors.New("unexpected args")
		}
		return []byte(sampleStatusOutput), nil
	})
	defer cleanup()

	rows, err := SentinelOneInfoGenerate(context.Background(), table.QueryContext{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	row := rows[0]

	// Install Date / Last Seen are converted to Unix epoch seconds in the
	// host's local time zone. Compute the expected values via the same
	// parsing path so the test is location-independent.
	installEpoch := mustEpoch(t, "1/2/06, 3:04:05 PM", "6/1/26, 10:09:51 AM")
	lastSeenEpoch := mustEpoch(t, "1/2/06, 3:04:05 PM", "6/1/26, 1:14:28 PM")

	wants := map[string]string{
		// Agent
		"agent_version":                    "25.3.4.8365",
		"agent_id":                         "d7f94b33-7f99-4c43-9c6b-1c6e0d01aabb",
		"install_date":                     installEpoch,
		"es_framework":                     "started",
		"operational_state":                "enabled",
		"remote_profiler":                  "not running",
		"network_monitoring":               "started",
		"network_extension":                "running",
		"network_extension_content_filter": "active",
		"ready":                            "yes",
		"protection":                       "enabled",
		"infected":                         "no",
		"network_quarantine":               "no",
		"compatible_os":                    "compatible",
		// Command
		"command_authentication": "enabled",
		// Daemons -> Services
		"service_agent_helper":      "ready",
		"service_agent_ui":          "ready",
		"service_cleaner":           "ready",
		"service_control_service":   "ready",
		"service_framework":         "ready",
		"service_guard":             "ready",
		"service_helper_service":    "ready",
		"service_lib_hooks_service": "not ready",
		"service_lib_logs_service":  "not ready",
		"service_shell":             "ready",
		// Daemons -> Integrity
		"integrity_sentineld":        "ok",
		"integrity_sentineld_guard":  "ok",
		"integrity_sentineld_helper": "ok",
		"integrity_sentineld_shell":  "not running",
		// Launchd
		"launchd_agent_helper":        "valid",
		"launchd_agent_ui":            "valid",
		"launchd_sentinel_extensions": "valid",
		"launchd_sentineld":           "valid",
		"launchd_sentineld_guard":     "valid",
		"launchd_sentineld_helper":    "valid",
		"launchd_sentineld_shell":     "valid",
		// Management
		"management_server":    "https://euce1-109.sentinelone.net",
		"management_site_key":  "site-key-abc-123",
		"management_last_seen": lastSeenEpoch,
		"management_connected": "yes",
	}
	for k, want := range wants {
		if got := row[k]; got != want {
			t.Errorf("row[%q] = %q, want %q", k, got, want)
		}
	}

	// Every declared column must be present in the row (even if empty).
	for _, name := range columnOrder {
		if _, ok := row[name]; !ok {
			t.Errorf("row missing declared column %q", name)
		}
	}
}

func TestSentinelOneInfoGenerate_NotInstalled(t *testing.T) {
	cleanup := setRunSentinelctl(t, func(args []string) ([]byte, error) {
		return nil, errors.New(`exec: "sentinelctl": executable file not found`)
	})
	defer cleanup()

	rows, err := SentinelOneInfoGenerate(context.Background(), table.QueryContext{})
	if err != nil {
		t.Fatalf("expected nil error when product missing, got %v", err)
	}
	if len(rows) != 0 {
		t.Errorf("expected 0 rows when product missing, got %d", len(rows))
	}
}

func TestSentinelOneInfoGenerate_UnparseableOutput(t *testing.T) {
	cleanup := setRunSentinelctl(t, func(args []string) ([]byte, error) {
		return []byte("banana slug !@#$%\n"), nil
	})
	defer cleanup()

	rows, err := SentinelOneInfoGenerate(context.Background(), table.QueryContext{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(rows) != 0 {
		t.Errorf("expected 0 rows for unparseable output, got %d", len(rows))
	}
}

func TestSentinelOneInfoGenerate_PartialOutput(t *testing.T) {
	// Only the Management section is present; everything else missing.
	cleanup := setRunSentinelctl(t, func(args []string) ([]byte, error) {
		return []byte(
			"Management\n" +
				"   Server:    https://example.net\n" +
				"   Connected: yes\n",
		), nil
	})
	defer cleanup()

	rows, err := SentinelOneInfoGenerate(context.Background(), table.QueryContext{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	if rows[0]["management_server"] != "https://example.net" {
		t.Errorf("management_server = %q", rows[0]["management_server"])
	}
	if rows[0]["management_connected"] != "yes" {
		t.Errorf("management_connected = %q", rows[0]["management_connected"])
	}
	if rows[0]["agent_version"] != "" {
		t.Errorf("agent_version expected empty, got %q", rows[0]["agent_version"])
	}
}

func TestParseSentinelctlStatus_NestedSections(t *testing.T) {
	got := parseSentinelctlStatus(sampleStatusOutput)

	cases := map[string]string{
		"agent_version":                          "25.3.4.8365",
		"agent_id":                               "d7f94b33-7f99-4c43-9c6b-1c6e0d01aabb",
		"agent_agent_operational_state":          "enabled",
		"agent_network_extension_content_filter": "active",
		"command_authentication":                 "enabled",
		"daemons_services_agent_helper":          "ready",
		"daemons_services_lib_hooks_service":     "not ready",
		"daemons_integrity_sentineld_shell":      "not running",
		"launchd_sentineld_guard":                "valid",
		"management_server":                      "https://euce1-109.sentinelone.net",
		"management_connected":                   "yes",
	}
	for k, want := range cases {
		if g := got[k]; g != want {
			t.Errorf("path %q = %q, want %q", k, g, want)
		}
	}

	// The bare "Missing Authorizations" section header has no leaves and must
	// not appear as a value.
	if _, ok := got["agent_missing_authorizations"]; ok {
		t.Errorf("unexpected key for headerless section")
	}
}

func TestParseSentinelctlStatus_ValueWithColons(t *testing.T) {
	in := "Management\n   Server: https://host:8443/path\n   Last Seen: 6/1/26, 1:14:28 PM\n"
	got := parseSentinelctlStatus(in)
	if got["management_server"] != "https://host:8443/path" {
		t.Errorf("management_server = %q", got["management_server"])
	}
	if got["management_last_seen"] != "6/1/26, 1:14:28 PM" {
		t.Errorf("management_last_seen = %q", got["management_last_seen"])
	}
}

func TestNormalizeKey(t *testing.T) {
	cases := map[string]string{
		"Console URL":              "console_url",
		"  Agent Version  ":        "agent_version",
		"Last Successful Connect.": "last_successful_connect",
		"DB-Version":               "db_version",
		"agent-helper":             "agent_helper",
		"sentineld_guard":          "sentineld_guard",
	}
	for in, want := range cases {
		if got := normalizeKey(in); got != want {
			t.Errorf("normalizeKey(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLeadingSpaces(t *testing.T) {
	cases := map[string]int{
		"":         0,
		"x":        0,
		"  x":      2,
		"      x":  6,
		"\tx":      1,
		"   ":      3,
	}
	for in, want := range cases {
		if got := leadingSpaces(in); got != want {
			t.Errorf("leadingSpaces(%q) = %d, want %d", in, got, want)
		}
	}
}

// mustEpoch parses value with layout in the local time zone and returns the
// Unix epoch seconds as a decimal string, matching toUnixEpoch's output.
func mustEpoch(t *testing.T, layout, value string) string {
	t.Helper()
	tm, err := time.ParseInLocation(layout, value, time.Local)
	if err != nil {
		t.Fatalf("mustEpoch: parse %q with %q: %v", value, layout, err)
	}
	return strconv.FormatInt(tm.Unix(), 10)
}

func TestToUnixEpoch(t *testing.T) {
	// Round-trip the canonical sentinelctl macOS short form.
	want := mustEpoch(t, "1/2/06, 3:04:05 PM", "6/1/26, 10:09:51 AM")
	if got, ok := toUnixEpoch("6/1/26, 10:09:51 AM"); !ok || got != want {
		t.Errorf("toUnixEpoch macOS short form: got (%q,%v), want (%q,true)", got, ok, want)
	}

	// Alternate layouts that should also parse.
	if _, ok := toUnixEpoch("2026-06-01 13:14:28"); !ok {
		t.Errorf("toUnixEpoch ISO-ish: expected ok")
	}
	if _, ok := toUnixEpoch("2026-06-01T13:14:28Z"); !ok {
		t.Errorf("toUnixEpoch RFC3339: expected ok")
	}

	// Unparseable -> false.
	if got, ok := toUnixEpoch("never"); ok {
		t.Errorf("toUnixEpoch garbage: got (%q,true), want false", got)
	}
	if got, ok := toUnixEpoch(""); ok {
		t.Errorf("toUnixEpoch empty: got (%q,true), want false", got)
	}
}

func TestToUnixEpoch_TolerantFallback(t *testing.T) {
	want := mustEpoch(t, "1/2/06, 3:04:05 PM", "6/1/26, 10:09:51 AM")

	// Same logical timestamp expressed with whitespace / separator variants
	// that the strict layouts won't match but the manual fallback should.
	variants := []string{
		"6/1/26  10:09:51 AM",       // double space, no comma
		"6/1/26,\t10:09:51 AM",      // tab after comma
		"6/1/26, 10:09:51\u00a0AM",  // NBSP before AM
		"06/01/2026, 10:09:51 AM",   // zero-padded, four-digit year
		"6/1/26 10:09:51 am",        // lowercase am
	}
	for _, v := range variants {
		got, ok := toUnixEpoch(v)
		if !ok {
			t.Errorf("toUnixEpoch(%q) failed", v)
			continue
		}
		if got != want {
			t.Errorf("toUnixEpoch(%q) = %q, want %q", v, got, want)
		}
	}

	// PM hour with no seconds.
	wantPM := mustEpoch(t, "1/2/06, 3:04 PM", "6/1/26, 1:46 PM")
	if got, ok := toUnixEpoch("6/1/26, 1:46 PM"); !ok || got != wantPM {
		t.Errorf("toUnixEpoch PM no seconds: got (%q,%v), want (%q,true)", got, ok, wantPM)
	}
}
