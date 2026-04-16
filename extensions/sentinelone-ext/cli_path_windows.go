//go:build windows

package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// discoverWindowsSentinelctl locates SentinelCtl.exe under
// C:\Program Files\SentinelOne\. The agent installs into a versioned
// subdirectory (e.g. "Sentinel Agent 23.2.4.7"), so we enumerate and pick
// the lexicographically highest one that contains the binary.
func discoverWindowsSentinelctl() string {
	roots := []string{
		`C:\Program Files\SentinelOne`,
		`C:\Program Files (x86)\SentinelOne`,
	}
	for _, root := range roots {
		entries, err := os.ReadDir(root)
		if err != nil {
			continue
		}
		// Gather subdirectories that look like Sentinel Agent installs.
		var candidates []string
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			if !strings.HasPrefix(strings.ToLower(e.Name()), "sentinel agent") {
				continue
			}
			candidates = append(candidates, e.Name())
		}
		sort.Sort(sort.Reverse(sort.StringSlice(candidates)))
		for _, name := range candidates {
			p := filepath.Join(root, name, "SentinelCtl.exe")
			if _, err := os.Stat(p); err == nil {
				return p
			}
		}
		// Also check the root directory itself.
		p := filepath.Join(root, "SentinelCtl.exe")
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return ""
}

func init() {
	cliPath = discoverWindowsSentinelctl()
}
