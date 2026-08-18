//go:build windows

package main

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

type winCtlCandidate struct {
	path        string
	dirName     string
	version     []int
	hasVersion  bool
}

// discoverWindowsSentinelctl locates SentinelCtl.exe under
// C:\Program Files\SentinelOne\. The agent installs into a versioned
// subdirectory (e.g. "Sentinel Agent 23.2.4.7"), so we enumerate candidates
// and pick the highest semantic version when possible.
func discoverWindowsSentinelctl() string {
	roots := []string{
		`C:\Program Files\SentinelOne`,
		`C:\Program Files (x86)\SentinelOne`,
	}
	var candidates []winCtlCandidate

	for _, root := range roots {
		entries, err := os.ReadDir(root)
		if err != nil {
			continue
		}
		// Gather subdirectories that look like Sentinel Agent installs.
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			nameLower := strings.ToLower(e.Name())
			if !strings.Contains(nameLower, "sentinel") || !strings.Contains(nameLower, "agent") {
				continue
			}
			name := e.Name()
			p := filepath.Join(root, name, "SentinelCtl.exe")
			if _, err := os.Stat(p); err == nil {
				ver, ok := parseDirVersion(name)
				candidates = append(candidates, winCtlCandidate{
					path:       p,
					dirName:    name,
					version:    ver,
					hasVersion: ok,
				})
			}
		}
	}

	if len(candidates) > 0 {
		sort.Slice(candidates, func(i, j int) bool {
			a, b := candidates[i], candidates[j]
			if a.hasVersion != b.hasVersion {
				return a.hasVersion
			}
			if a.hasVersion && b.hasVersion {
				if cmp := compareVersions(a.version, b.version); cmp != 0 {
					return cmp > 0
				}
			}
			return strings.ToLower(a.dirName) > strings.ToLower(b.dirName)
		})
		return candidates[0].path
	}

	for _, root := range roots {
		// Also check the root directory itself.
		p := filepath.Join(root, "SentinelCtl.exe")
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

func parseDirVersion(name string) ([]int, bool) {
	start := -1
	for i, r := range name {
		if r >= '0' && r <= '9' {
			start = i
			break
		}
	}
	if start < 0 {
		return nil, false
	}
	tail := name[start:]
	var b strings.Builder
	for _, r := range tail {
		if (r >= '0' && r <= '9') || r == '.' {
			b.WriteRune(r)
			continue
		}
		break
	}
	ver := strings.Trim(b.String(), ".")
	if ver == "" || !strings.Contains(ver, ".") {
		return nil, false
	}
	parts := strings.Split(ver, ".")
	out := make([]int, 0, len(parts))
	for _, p := range parts {
		if p == "" {
			return nil, false
		}
		n, err := strconv.Atoi(p)
		if err != nil {
			return nil, false
		}
		out = append(out, n)
	}
	return out, true
}

func compareVersions(a, b []int) int {
	n := len(a)
	if len(b) > n {
		n = len(b)
	}
	for i := 0; i < n; i++ {
		av := 0
		if i < len(a) {
			av = a[i]
		}
		bv := 0
		if i < len(b) {
			bv = b[i]
		}
		if av > bv {
			return 1
		}
		if av < bv {
			return -1
		}
	}
	return 0
}

func init() {
	cliPath = discoverWindowsSentinelctl()
}
