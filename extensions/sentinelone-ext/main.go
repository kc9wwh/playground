package main

import (
	"flag"
	"log"
	"os"
	"time"

	"github.com/osquery/osquery-go"
	"github.com/osquery/osquery-go/plugin/table"
)

// version is set at build time via ldflags.
var version = "dev"

var (
	flSocketPath = flag.String("socket", "", "Path to osquery extension socket")
	flTimeout    = flag.Int("timeout", 3, "Seconds to wait for autoloaded extensions")
	flInterval   = flag.Int("interval", 3, "Seconds delay between connectivity checks")
	flVerbose    = flag.Bool("verbose", false, "Enable verbose logging")
)

func main() {
	flag.Parse()

	if *flSocketPath == "" {
		log.Fatalf("Usage: %s --socket SOCKET_PATH", os.Args[0])
	}

	if *flVerbose {
		log.Printf("sentinelone.ext %s starting (socket=%s)", version, *flSocketPath)
	}

	server, err := osquery.NewExtensionManagerServer(
		"com.fleetdm.sentinelone_ext",
		*flSocketPath,
		osquery.ServerTimeout(time.Duration(*flTimeout)*time.Second),
		osquery.ServerPingInterval(time.Duration(*flInterval)*time.Second),
	)
	if err != nil {
		log.Fatalf("Error creating extension: %s\n", err)
	}

	server.RegisterPlugin(table.NewPlugin(
		"sentinelone_info",
		SentinelOneInfoColumns(),
		SentinelOneInfoGenerate,
	))

	if err := server.Run(); err != nil {
		log.Fatalln(err)
	}
}
