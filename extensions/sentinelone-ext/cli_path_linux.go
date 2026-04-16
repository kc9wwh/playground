//go:build linux

package main

import "os"

// candidatePaths is the ordered list of places sentinelctl commonly lives on
// Linux. The first readable path wins.
var candidatePaths = []string{
	"/opt/sentinelone/bin/sentinelctl",
	"/usr/local/bin/sentinelctl",
	"/usr/bin/sentinelctl",
}

func init() {
	for _, p := range candidatePaths {
		if _, err := os.Stat(p); err == nil {
			cliPath = p
			return
		}
	}
}
