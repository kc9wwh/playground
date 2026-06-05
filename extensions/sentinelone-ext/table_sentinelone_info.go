package main

import (
	"bufio"
	"context"
	"os/exec"
	"strconv"
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
		path = "sentinelctl"
	}

	cmd := exec.CommandContext(ctx, path, args...)
	return cmd.CombinedOutput()
}

// columnPathMap maps the flattened "section_subsection_key" path produced by
// parseSentinelctlStatus to the SQL column name exposed by the table.
var columnPathMap = map[string]string{
	// Agent section
	"agent_version":                          "agent_version",
	"agent_id":                               "agent_id",
	"agent_install_date":                     "install_date",
	"agent_es_framework":                     "es_framework",
	"agent_agent_operational_state":          "operational_state",
	"agent_remote_profiler":                  "remote_profiler",
	"agent_agent_network_monitoring":         "network_monitoring",
	"agent_network_extension":                "network_extension",
	"agent_network_extension_content_filter": "network_extension_content_filter",
	"agent_ready":                            "ready",
	"agent_protection":                       "protection",
	"agent_infected":                         "infected",
	"agent_network_quarantine":               "network_quarantine",
	"agent_compatible_os":                    "compatible_os",

	// Command section
	"command_authentication": "command_authentication",

	// Daemons -> Services
	"daemons_services_agent_helper":      "service_agent_helper",
	"daemons_services_agent_ui":          "service_agent_ui",
	"daemons_services_cleaner":           "service_cleaner",
	"daemons_services_control_service":   "service_control_service",
	"daemons_services_framework":         "service_framework",
	"daemons_services_guard":             "service_guard",
	"daemons_services_helper_service":    "service_helper_service",
	"daemons_services_lib_hooks_service": "service_lib_hooks_service",
	"daemons_services_lib_logs_service":  "service_lib_logs_service",
	"daemons_services_shell":             "service_shell",

	// Daemons -> Integrity
	"daemons_integrity_sentineld":        "integrity_sentineld",
	"daemons_integrity_sentineld_guard":  "integrity_sentineld_guard",
	"daemons_integrity_sentineld_helper": "integrity_sentineld_helper",
	"daemons_integrity_sentineld_shell":  "integrity_sentineld_shell",

	// Launchd section
	"launchd_agent_helper":        "launchd_agent_helper",
	"launchd_agent_ui":            "launchd_agent_ui",
	"launchd_sentinel_extensions": "launchd_sentinel_extensions",
	"launchd_sentineld":           "launchd_sentineld",
	"launchd_sentineld_guard":     "launchd_sentineld_guard",
	"launchd_sentineld_helper":    "launchd_sentineld_helper",
	"launchd_sentineld_shell":     "launchd_sentineld_shell",

	// Management section
	"management_server":    "management_server",
	"management_site_key":  "management_site_key",
	"management_last_seen": "management_last_seen",
	"management_connected": "management_connected",
}

// columnOrder is the canonical column order returned by SentinelOneInfoColumns.
// Keep in sync with the values of columnPathMap.
var columnOrder = []string{
	// Agent
	"agent_version",
	"agent_id",
	"install_date",
	"es_framework",
	"operational_state",
	"remote_profiler",
	"network_monitoring",
	"network_extension",
	"network_extension_content_filter",
	"ready",
	"protection",
	"infected",
	"network_quarantine",
	"compatible_os",
	// Command
	"command_authentication",
	// Daemons -> Services
	"service_agent_helper",
	"service_agent_ui",
	"service_cleaner",
	"service_control_service",
	"service_framework",
	"service_guard",
	"service_helper_service",
	"service_lib_hooks_service",
	"service_lib_logs_service",
	"service_shell",
	// Daemons -> Integrity
	"integrity_sentineld",
	"integrity_sentineld_guard",
	"integrity_sentineld_helper",
	"integrity_sentineld_shell",
	// Launchd
	"launchd_agent_helper",
	"launchd_agent_ui",
	"launchd_sentinel_extensions",
	"launchd_sentineld",
	"launchd_sentineld_guard",
	"launchd_sentineld_helper",
	"launchd_sentineld_shell",
	// Management
	"management_server",
	"management_site_key",
	"management_last_seen",
	"management_connected",
}

// SentinelOneInfoColumns returns the schema for the sentinelone table.
func SentinelOneInfoColumns() []table.ColumnDefinition {
	cols := make([]table.ColumnDefinition, 0, len(columnOrder))
	for _, name := range columnOrder {
		cols = append(cols, table.TextColumn(name))
	}
	return cols
}

// SentinelOneInfoGenerate returns a single row describing the local
// SentinelOne agent, or an empty result set if the agent is not installed or
// `sentinelctl status` produced no parseable fields.
func SentinelOneInfoGenerate(
	ctx context.Context,
	queryContext table.QueryContext,
) ([]map[string]string, error) {
	row := make(map[string]string, len(columnOrder))
	for _, name := range columnOrder {
		row[name] = ""
	}

	out, err := runSentinelctl(ctx, "status")
	if err != nil {
		return []map[string]string{}, nil
	}

	parsed := parseSentinelctlStatus(string(out))
	populated := false
	for path, val := range parsed {
		col, ok := columnPathMap[path]
		if !ok {
			continue
		}
		row[col] = val
		populated = true
	}

	// Normalize timestamp columns to Unix epoch seconds. If parsing fails the
	// column is cleared so SQL numeric comparisons (e.g. WHERE install_date <
	// 1700000000) aren't broken by mixed-format values.
	for _, col := range epochColumns {
		if v := row[col]; v != "" {
			if epoch, ok := toUnixEpoch(v); ok {
				row[col] = epoch
			} else {
				row[col] = ""
			}
		}
	}

	if !populated {
		return []map[string]string{}, nil
	}
	return []map[string]string{row}, nil
}

// epochColumns lists the columns whose values are timestamps and should be
// emitted as Unix epoch seconds (as a decimal string).
var epochColumns = []string{
	"install_date",
	"management_last_seen",
}

// timeLayouts is the ordered list of layouts toUnixEpoch tries against a raw
// value. The first match wins. sentinelctl on macOS emits "6/1/26, 10:09:51 AM"
// (a locale-influenced short form); additional layouts cover common variants
// observed on other platforms.
var timeLayouts = []string{
	"1/2/06, 3:04:05 PM",
	"1/2/2006, 3:04:05 PM",
	"1/2/06 3:04:05 PM",
	"1/2/2006 3:04:05 PM",
	"2006-01-02 15:04:05",
	"2006-01-02T15:04:05Z07:00",
	time.RFC3339,
}

// toUnixEpoch parses s with each layout in timeLayouts and, on success,
// returns the parsed time as Unix epoch seconds (decimal string) and true.
// Times without an explicit zone are interpreted in the host's local zone.
//
// If none of the strict layouts match, a manual fallback parser is tried
// that recognises the locale-style "M/D/YY[YY][,] H:MM[:SS] [AM|PM]" form
// emitted by macOS sentinelctl, tolerating extra whitespace, missing comma
// and missing seconds.
func toUnixEpoch(s string) (string, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "", false
	}
	for _, layout := range timeLayouts {
		if t, err := time.ParseInLocation(layout, s, time.Local); err == nil {
			return strconv.FormatInt(t.Unix(), 10), true
		}
	}
	if t, ok := parseLocaleShortDateTime(s); ok {
		return strconv.FormatInt(t.Unix(), 10), true
	}
	return "", false
}

// parseLocaleShortDateTime is a tolerant manual parser for the macOS
// sentinelctl "M/D/YY[YY][,] H:MM[:SS] [AM|PM]" timestamp format. It
// tokenises on slashes, colons and any run of whitespace/comma, so it
// accepts non-breaking spaces and irregular padding that defeat the strict
// time.Parse layouts.
//
// LIMITATION: The parser assumes US-style M/D/Y field order. On hosts whose
// locale emits D/M/Y, dates where day > 12 will fail the month range check
// (atoiRange 1–12) and the epoch column will be cleared rather than silently
// storing an incorrect timestamp. Auto-detection between M/D and D/M is not
// feasible when day <= 12, so we document rather than guess.
func parseLocaleShortDateTime(s string) (time.Time, bool) {
	// Split on anything that isn't a digit or a letter.
	fields := strings.FieldsFunc(s, func(r rune) bool {
		return !(r >= '0' && r <= '9' || r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z')
	})
	// Expect: month, day, year, hour, minute, [second,] [am|pm]
	if len(fields) < 5 {
		return time.Time{}, false
	}
	month, ok1 := atoiRange(fields[0], 1, 12)
	day, ok2 := atoiRange(fields[1], 1, 31)
	year, ok3 := atoi(fields[2])
	if !ok1 || !ok2 || !ok3 {
		return time.Time{}, false
	}
	if year < 100 {
		year += 2000
	}
	hour, ok4 := atoiRange(fields[3], 0, 23)
	minute, ok5 := atoiRange(fields[4], 0, 59)
	if !ok4 || !ok5 {
		return time.Time{}, false
	}
	second := 0
	idx := 5
	if idx < len(fields) {
		if sec, ok := atoiRange(fields[idx], 0, 60); ok {
			second = sec
			idx++
		}
	}
	if idx < len(fields) {
		marker := strings.ToUpper(fields[idx])
		switch marker {
		case "AM":
			if hour == 12 {
				hour = 0
			}
		case "PM":
			if hour < 12 {
				hour += 12
			}
		}
	}
	if hour > 23 {
		return time.Time{}, false
	}
	return time.Date(year, time.Month(month), day, hour, minute, second, 0, time.Local), true
}

// atoi parses s as a non-negative decimal integer.
func atoi(s string) (int, bool) {
	if s == "" {
		return 0, false
	}
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 {
		return 0, false
	}
	return n, true
}

// atoiRange parses s and returns the value if it falls within [lo, hi].
func atoiRange(s string, lo, hi int) (int, bool) {
	n, ok := atoi(s)
	if !ok || n < lo || n > hi {
		return 0, false
	}
	return n, true
}

// parseSentinelctlStatus parses the hierarchical, indentation-structured
// output of `sentinelctl status` and returns a flat map keyed by the
// underscore-joined section path. Top-level section names become the first
// path component, nested sub-section names are appended, and the final leaf
// component is the normalized key.
//
// Lines without a colon (e.g. "Daemons", "Services", "Missing Authorizations")
// are treated as section headers at their indentation level.
func parseSentinelctlStatus(out string) map[string]string {
	type frame struct {
		indent int
		name   string
	}
	var stack []frame

	result := map[string]string{}
	scanner := bufio.NewScanner(strings.NewReader(out))
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for scanner.Scan() {
		raw := strings.TrimRight(scanner.Text(), "\r\n")
		if strings.TrimSpace(raw) == "" {
			continue
		}
		indent := leadingSpaces(raw)
		trimmed := strings.TrimLeft(raw, " \t")

		// Pop any frames at or deeper than this indent.
		for len(stack) > 0 && stack[len(stack)-1].indent >= indent {
			stack = stack[:len(stack)-1]
		}

		idx := strings.Index(trimmed, ":")
		if idx <= 0 {
			// No colon -> section header at this indent.
			name := normalizeKey(trimmed)
			if name != "" {
				stack = append(stack, frame{indent: indent, name: name})
			}
			continue
		}

		key := normalizeKey(trimmed[:idx])
		val := strings.TrimSpace(trimmed[idx+1:])
		if key == "" {
			continue
		}
		if val == "" {
			stack = append(stack, frame{indent: indent, name: key})
			continue
		}

		parts := make([]string, 0, len(stack)+1)
		for _, f := range stack {
			parts = append(parts, f.name)
		}
		parts = append(parts, key)
		path := strings.Join(parts, "_")
		if _, exists := result[path]; !exists {
			result[path] = val
		}
	}
	return result
}

// leadingSpaces counts leading ASCII spaces / tabs on a line.
func leadingSpaces(s string) int {
	n := 0
	for _, r := range s {
		if r != ' ' && r != '\t' {
			break
		}
		n++
	}
	return n
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
	return strings.Trim(b.String(), "_")
}
