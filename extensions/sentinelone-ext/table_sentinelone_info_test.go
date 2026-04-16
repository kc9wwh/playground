package main

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/osquery/osquery-go/plugin/table"
)

// setRunSentinelctl swaps the global command runner for a mock and returns a
// cleanup func. The mock receives the args and returns scripted output.
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
	expected := []string{
		"agent_version",
		"agent_id",
		"status",
		"management_url",
		"site",
		"group",
		"last_communication",
		"self_protection",
		"network_status",
		"policy_mode",
		"db_version",
	}
	if len(cols) != len(expected) {
		t.Fatalf("expected %d columns, got %d", len(expected), len(cols))
	}
	colMap := map[string]table.ColumnType{}
	for _, c := range cols {
		colMap[c.Name] = c.Type
	}
	for _, name := range expected {
		typ, ok := colMap[name]
		if !ok {
			t.Errorf("missing expected column: %s", name)
			continue
		}
		if typ != table.ColumnTypeText {
			t.Errorf("column %s: expected TEXT, got %v", name, typ)
		}
	}
}

func TestSentinelOneInfoGenerate_HappyPath(t *testing.T) {
	cleanup := setRunSentinelctl(t, func(args []string) ([]byte, error) {
		switch strings.Join(args, " ") {
		case "version":
			return []byte("Agent version: 23.2.4.7\nDB Version: 1234\n"), nil
		case "agent_id":
			return []byte("Agent ID: d7f94b33-7f99-4c43-9c6b-1c6e0d01aabb\n"), nil
		case "status":
			return []byte(
				"Status: Loaded\n" +
					"Self Protection: On\n",
			), nil
		case "management status":
			return []byte(
				"Console URL: https://usea1-012.sentinelone.net\n" +
					"Site: Corp-Prod\n" +
					"Group: Servers-US\n" +
					"Last Communication: 2026-04-15 14:03:11\n" +
					"Network Status: Connected\n",
			), nil
		case "config show":
			return []byte("Agent Operational Mode: Protect\n"), nil
		}
		return nil, errors.New("unexpected args")
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
	wants := map[string]string{
		"agent_version":      "23.2.4.7",
		"agent_id":           "d7f94b33-7f99-4c43-9c6b-1c6e0d01aabb",
		"status":             "Loaded",
		"management_url":     "https://usea1-012.sentinelone.net",
		"site":               "Corp-Prod",
		"group":              "Servers-US",
		"last_communication": "2026-04-15 14:03:11",
		"self_protection":    "On",
		"network_status":     "Connected",
		"policy_mode":        "Protect",
		"db_version":         "1234",
	}
	for k, want := range wants {
		if got := row[k]; got != want {
			t.Errorf("row[%q] = %q, want %q", k, got, want)
		}
	}
}

func TestSentinelOneInfoGenerate_NotInstalled(t *testing.T) {
	cleanup := setRunSentinelctl(t, func(args []string) ([]byte, error) {
		// All sentinelctl invocations fail because the binary doesn't exist.
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

func TestSentinelOneInfoGenerate_PartialFailure(t *testing.T) {
	// version succeeds, everything else fails. We should still get a row
	// populated with whatever we could read.
	cleanup := setRunSentinelctl(t, func(args []string) ([]byte, error) {
		if strings.Join(args, " ") == "version" {
			return []byte("Agent version: 24.0.1.0\n"), nil
		}
		return nil, errors.New("boom")
	})
	defer cleanup()

	rows, err := SentinelOneInfoGenerate(context.Background(), table.QueryContext{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	if rows[0]["agent_version"] != "24.0.1.0" {
		t.Errorf("agent_version = %q, want 24.0.1.0", rows[0]["agent_version"])
	}
	if rows[0]["status"] != "" {
		t.Errorf("status expected empty when status subcommand failed, got %q", rows[0]["status"])
	}
}

func TestSentinelOneInfoGenerate_MalformedOutput(t *testing.T) {
	// version returns garbage that has no semver anywhere and no key:value.
	// The whole row should be considered empty -> zero rows.
	cleanup := setRunSentinelctl(t, func(args []string) ([]byte, error) {
		if strings.Join(args, " ") == "version" {
			return []byte("banana slug !@#$%\n"), nil
		}
		return nil, errors.New("boom")
	})
	defer cleanup()

	rows, err := SentinelOneInfoGenerate(context.Background(), table.QueryContext{})
	if err != nil {
		t.Fatalf("unexpected error for malformed output: %v", err)
	}
	if len(rows) != 0 {
		t.Errorf("expected 0 rows for unparseable output, got %d", len(rows))
	}
}

func TestSentinelOneInfoGenerate_FreeFormVersion(t *testing.T) {
	// Some sentinelctl builds print "Sentinel Version 23.4.1.0" with no
	// colon. extractSemver should still catch it.
	cleanup := setRunSentinelctl(t, func(args []string) ([]byte, error) {
		if strings.Join(args, " ") == "version" {
			return []byte("Sentinel Version 23.4.1.0\n"), nil
		}
		return nil, errors.New("boom")
	})
	defer cleanup()

	rows, err := SentinelOneInfoGenerate(context.Background(), table.QueryContext{})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	if rows[0]["agent_version"] != "23.4.1.0" {
		t.Errorf("agent_version = %q, want 23.4.1.0", rows[0]["agent_version"])
	}
}

func TestParseSentinelctl(t *testing.T) {
	in := "Console URL: https://example.net\n" +
		"  Site: Corp-Prod  \n" +
		"\n" +
		"NoColonLine\n" +
		"Key With: value:with:colons\n"
	got := parseSentinelctl(in)
	if got["console_url"] != "https://example.net" {
		t.Errorf("console_url = %q", got["console_url"])
	}
	if got["site"] != "Corp-Prod" {
		t.Errorf("site = %q", got["site"])
	}
	if got["key_with"] != "value:with:colons" {
		t.Errorf("key_with = %q", got["key_with"])
	}
	if _, ok := got["nocolonline"]; ok {
		t.Errorf("line without colon should not appear")
	}
}

func TestNormalizeKey(t *testing.T) {
	cases := map[string]string{
		"Console URL":              "console_url",
		"  Agent Version  ":        "agent_version",
		"Last Successful Connect.": "last_successful_connect",
		"DB-Version":               "db_version",
	}
	for in, want := range cases {
		if got := normalizeKey(in); got != want {
			t.Errorf("normalizeKey(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLooksLikeVersion(t *testing.T) {
	true_ := []string{"1.2.3", "23.2.4.7", "100.0.0"}
	false_ := []string{"", "abc", "1", "1.", "1.2.", "foo.bar.baz"}
	for _, s := range true_ {
		if !looksLikeVersion(s) {
			t.Errorf("%q should be version", s)
		}
	}
	for _, s := range false_ {
		if looksLikeVersion(s) {
			t.Errorf("%q should not be version", s)
		}
	}
}
