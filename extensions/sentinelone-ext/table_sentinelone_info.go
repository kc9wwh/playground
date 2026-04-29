package main

import (
	"bufio"
	"context"
	"os/exec"
	"strings"
	"time"

	"github.com/osquery/osquery-go/plugin/table"
)

// execTimeout is the maximum time to wait for a single sentinelctl invocation.
const execTimeout = 15 * time.Second

// cliPath is the path to the sentinelctl binary on the current platform. It is
// populated by an init() in one of the platform-specific cli_path_*.go files
// and can be overridden at runtime for tests.
var cliPath = ""

// runSentinelctl executes `sentinelctl <args...>` and returns the combined
// stdout/stderr output. It is a variable so tests can inject mock data.
var runSentinelctl = func(ctx context.Context, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, execTimeout)
	defer cancel()

	path := cliPath
	if path == "" {
		// If platform init did not discover a path, give exec a chance via PATH.
		path = "sentinelctl"
	}

	cmd := exec.CommandContext(ctx, path, args...)
	return cmd.CombinedOutput()
}

// SentinelOneInfoColumns returns the schema for the sentinelone table.
func SentinelOneInfoColumns() []table.ColumnDefinition {
	return []table.ColumnDefinition{
		table.TextColumn("agent_version"),
		table.TextColumn("agent_id"),
		table.TextColumn("status"),
		table.TextColumn("management_url"),
		table.TextColumn("site"),
		table.TextColumn("group"),
		table.TextColumn("last_communication"),
		table.TextColumn("self_protection"),
		table.TextColumn("network_status"),
		table.TextColumn("policy_mode"),
		table.TextColumn("db_version"),
	}
}

// SentinelOneInfoGenerate returns a single row describing the local
// SentinelOne agent, or an empty result set if the agent is not installed.
func SentinelOneInfoGenerate(
	ctx context.Context,
	queryContext table.QueryContext,
) ([]map[string]string, error) {
	row := map[string]string{
		"agent_version":      "",
		"agent_id":           "",
		"status":             "",
		"management_url":     "",
		"site":               "",
		"group":              "",
		"last_communication": "",
		"self_protection":    "",
		"network_status":     "",
		"policy_mode":        "",
		"db_version":         "",
	}

	// First probe: `version`. If this fails, sentinelctl is not installed and
	// we return an empty result set (not an error) per the skill's graceful
	// degradation rule.
	versionOut, err := runSentinelctl(ctx, "version")
	if err != nil {
		return []map[string]string{}, nil
	}
	parsed := parseSentinelctl(string(versionOut))
	// Version output typically contains "Agent version" or "Sentinel version".
	row["agent_version"] = firstNonEmpty(
		parsed["agent_version"],
		parsed["sentinel_version"],
		parsed["version"],
		extractSemver(string(versionOut)),
	)
	if row["db_version"] == "" {
		row["db_version"] = firstNonEmpty(parsed["db_version"], parsed["signatures_version"])
	}

	// Agent ID.
	if out, err := runSentinelctl(ctx, "agent_id"); err == nil {
		parsed := parseSentinelctl(string(out))
		row["agent_id"] = firstNonEmpty(
			parsed["agent_id"],
			parsed["uuid"],
			strings.TrimSpace(stripTrailingNewlines(string(out))),
		)
	}

	// Status (loaded / running / disabled).
	if out, err := runSentinelctl(ctx, "status"); err == nil {
		parsed := parseSentinelctl(string(out))
		row["status"] = firstNonEmpty(
			parsed["status"],
			parsed["agent_status"],
			parsed["state"],
			summarizeStatus(string(out)),
		)
		row["self_protection"] = firstNonEmpty(
			row["self_protection"],
			parsed["self_protection"],
			parsed["anti_tampering"],
		)
	}

	// Management status (console URL, site, group, last check-in).
	if out, err := runSentinelctl(ctx, "management", "status"); err == nil {
		parsed := parseSentinelctl(string(out))
		row["management_url"] = firstNonEmpty(
			parsed["console_url"],
			parsed["management_url"],
			parsed["mgmt_url"],
			parsed["mgmt_server"],
			parsed["server"],
		)
		row["site"] = firstNonEmpty(parsed["site"], parsed["site_name"])
		row["group"] = firstNonEmpty(parsed["group"], parsed["group_name"])
		row["last_communication"] = firstNonEmpty(
			parsed["last_communication"],
			parsed["last_active"],
			parsed["last_successful_connection"],
			parsed["last_heartbeat"],
		)
		if row["network_status"] == "" {
			row["network_status"] = firstNonEmpty(
				parsed["network_status"],
				parsed["connectivity"],
			)
		}
	}

	// Policy mode (detect vs. protect).
	if out, err := runSentinelctl(ctx, "config", "show"); err == nil {
		parsed := parseSentinelctl(string(out))
		row["policy_mode"] = firstNonEmpty(
			parsed["policy_mode"],
			parsed["agent_operational_mode"],
			parsed["operational_mode"],
			parsed["mode"],
		)
	}

	// If absolutely nothing came back, treat as "not installed" rather than
	// returning a row full of empty strings.
	if allEmpty(row) {
		return []map[string]string{}, nil
	}

	return []map[string]string{row}, nil
}

// parseSentinelctl turns sentinelctl's "Key: Value" text output into a map of
// normalized lower-snake-case keys to trimmed values. Lines without a colon
// are ignored. Indented / continuation lines are ignored.
func parseSentinelctl(out string) map[string]string {
	result := map[string]string{}
	scanner := bufio.NewScanner(strings.NewReader(out))
	// Allow for long lines (e.g. certificate fingerprints).
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		idx := strings.Index(line, ":")
		if idx <= 0 || idx == len(line)-1 {
			continue
		}
		key := normalizeKey(line[:idx])
		val := strings.TrimSpace(line[idx+1:])
		if key == "" || val == "" {
			continue
		}
		// First occurrence wins so that nested sections don't overwrite the
		// top-level value.
		if _, ok := result[key]; !ok {
			result[key] = val
		}
	}
	return result
}

// normalizeKey lowercases and snake-cases a sentinelctl field label.
// "Console URL" -> "console_url", "Agent Version" -> "agent_version".
func normalizeKey(s string) string {
	s = strings.TrimSpace(s)
	var b strings.Builder
	prevSep := false
	for _, r := range s {
		switch {
		case r >= 'A' && r <= 'Z':
			b.WriteRune(r + ('a' - 'A'))
			prevSep = false
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
			prevSep = false
		default:
			if !prevSep && b.Len() > 0 {
				b.WriteRune('_')
				prevSep = true
			}
		}
	}
	// Trim any trailing separator.
	out := b.String()
	return strings.Trim(out, "_")
}

// firstNonEmpty returns the first non-empty string in the argument list.
func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		v = strings.TrimSpace(v)
		if v != "" {
			return v
		}
	}
	return ""
}

// stripTrailingNewlines removes trailing CR/LF characters.
func stripTrailingNewlines(s string) string {
	return strings.TrimRight(s, "\r\n")
}

// extractSemver pulls the first x.y.z[.w] token out of a string, useful when
// sentinelctl version prints free-form text instead of key:value.
func extractSemver(s string) string {
	fields := strings.FieldsFunc(s, func(r rune) bool {
		return r == ' ' || r == '\t' || r == '\n' || r == '\r' || r == ','
	})
	for _, f := range fields {
		if looksLikeVersion(f) {
			return strings.Trim(f, ".")
		}
	}
	return ""
}

func looksLikeVersion(s string) bool {
	if s == "" || s[0] == '.' || s[len(s)-1] == '.' {
		return false
	}
	dots := 0
	for _, r := range s {
		if r == '.' {
			dots++
			continue
		}
		if r < '0' || r > '9' {
			return false
		}
	}
	return dots >= 1 && dots <= 3 && len(s) >= 3
}

// summarizeStatus compresses multi-line status output into a one-line summary
// when we can't find a clearly labeled field.
func summarizeStatus(out string) string {
	out = strings.TrimSpace(out)
	if out == "" {
		return ""
	}
	// Collapse to first non-empty line.
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			return line
		}
	}
	return ""
}

// allEmpty reports whether every value in the row is empty.
func allEmpty(row map[string]string) bool {
	for _, v := range row {
		if strings.TrimSpace(v) != "" {
			return false
		}
	}
	return true
}
