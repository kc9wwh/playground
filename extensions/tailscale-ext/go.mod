module github.com/fleetdm/tailscale_status-ext

go 1.26

// osquery-go master requires Go 1.26+ (bumped 2026-03-06).
// Run `go mod tidy` after cloning to resolve transitive deps and generate
// go.sum. The pin below was verified working on 2026-04-15; if it drifts,
// replace with `go get github.com/osquery/osquery-go@latest`.
require github.com/osquery/osquery-go v0.0.0-20260306231408-a88c0766cd0d

require (
	github.com/Microsoft/go-winio v0.6.2 // indirect
	github.com/apache/thrift v0.20.0 // indirect
	github.com/go-logr/logr v1.2.4 // indirect
	github.com/go-logr/stdr v1.2.2 // indirect
	github.com/pkg/errors v0.8.0 // indirect
	go.opentelemetry.io/otel v1.16.0 // indirect
	go.opentelemetry.io/otel/metric v1.16.0 // indirect
	go.opentelemetry.io/otel/trace v1.16.0 // indirect
	golang.org/x/sys v0.25.0 // indirect
)
