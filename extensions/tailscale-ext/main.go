// Package main is the entry point for the tailscale osquery extension.
//
// The extension registers a single table, `tailscale_status`, which exposes
// the local Tailscale client state (backend state, tailnet, MagicDNS,
// self IPs, peer counts, exit node) by shelling out to `tailscale status
// --json` on the host.
package main

import (
	"flag"
	"log"
	"os"
	"time"

	osquery "github.com/osquery/osquery-go"
	"github.com/osquery/osquery-go/plugin/table"
)

func main() {
	socket := flag.String("socket", "", "Path to the osqueryd extensions socket")
	timeout := flag.Int("timeout", 3, "Seconds to wait for autoloaded extensions")
	interval := flag.Int("interval", 3, "Seconds delay between connectivity checks")
	_ = flag.Bool("verbose", false, "Enable verbose informational messages")
	flag.Parse()

	if *socket == "" {
		log.Fatalf("Missing required --socket argument")
	}

	serverTimeout := osquery.ServerTimeout(time.Duration(*timeout) * time.Second)
	serverPingInterval := osquery.ServerPingInterval(time.Duration(*interval) * time.Second)

	server, err := osquery.NewExtensionManagerServer(
		"com.fleetdm.tailscale_ext",
		*socket,
		serverTimeout,
		serverPingInterval,
	)
	if err != nil {
		log.Fatalf("Error creating extension: %s\n", err)
	}

	server.RegisterPlugin(table.NewPlugin(
		"tailscale_status",
		TailscaleStatusColumns(),
		TailscaleStatusGenerate,
	))

	if err := server.Run(); err != nil {
		log.Println("Extension server exited with error:", err)
		os.Exit(1)
	}
}
