// Package main implements a standalone osquery extension that exposes the
// netskope_client table. It is designed to be loaded by osqueryd via the
// extensions.load mechanism used by Fleet's orbit agent.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	osquery "github.com/osquery/osquery-go"
	"github.com/osquery/osquery-go/plugin/table"
)

const (
	serverName     = "com.fleetdm.netskope_ext"
	defaultTimeout = 10 * time.Second
)

func main() {
	socket := flag.String("socket", "", "Path to the osqueryd extensions socket")
	timeout := flag.Int("timeout", 3, "Seconds to wait for autoloaded extensions")
	interval := flag.Int("interval", 3, "Seconds delay between connectivity checks")
	_ = flag.Bool("verbose", false, "Enable verbose informational messages")
	flag.Parse()

	if *socket == "" {
		log.Fatalf("missing required --socket flag")
	}

	server, err := osquery.NewExtensionManagerServer(
		serverName,
		*socket,
		osquery.ServerTimeout(time.Duration(*timeout)*time.Second),
		osquery.ServerPingInterval(time.Duration(*interval)*time.Second),
	)
	if err != nil {
		log.Fatalf("creating extension manager server: %v", err)
	}

	server.RegisterPlugin(table.NewPlugin(
		"netskope_client",
		NetskopeClientColumns(),
		func(ctx context.Context, qc table.QueryContext) ([]map[string]string, error) {
			return NetskopeClientGenerate(ctx, qc)
		},
	))

	if err := server.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "extension server exited: %v\n", err)
		os.Exit(1)
	}
}
