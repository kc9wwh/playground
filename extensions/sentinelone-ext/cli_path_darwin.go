//go:build darwin

package main

import "os"

// candidatePaths is the ordered list of places sentinelctl commonly lives on
// macOS. The first readable path wins.
var candidatePaths = []string{
	"/usr/local/bin/sentinelctl",
	"/Library/Sentinel/sentinel-agent.bundle/Contents/MacOS/sentinelctl",
	"/Applications/SentinelOne.app/Contents/MacOS/sentinelctl",
}

func init() {
	for _, p := range candidatePaths {
		if _, err := os.Stat(p); err == nil {
			cliPath = p
			return
		}
	}
	// Leave cliPath empty; exec will fall back to looking on $PATH.
}
