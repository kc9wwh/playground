# netskope_client-ext — cross-compilation targets.
#
# All builds use CGO_ENABLED=0 so the produced binaries are static and have no
# libc dependency, which is required to run inside osqueryd's extension
# sandbox.

BINARY := netskope.ext
BUILD_DIR := build
GO := go
LDFLAGS := -s -w

.PHONY: all deps test build build-all clean
.PHONY: darwin-amd64 darwin-arm64 linux-amd64 linux-arm64 windows-amd64

all: test build-all

deps:
	$(GO) mod tidy

test:
	$(GO) test -race -count=1 ./...

build: darwin-arm64

build-all: darwin-amd64 darwin-arm64 linux-amd64 linux-arm64 windows-amd64

darwin-amd64:
	CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 $(GO) build -ldflags="$(LDFLAGS)" -o $(BUILD_DIR)/darwin-amd64/$(BINARY) .

darwin-arm64:
	CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 $(GO) build -ldflags="$(LDFLAGS)" -o $(BUILD_DIR)/darwin-arm64/$(BINARY) .

linux-amd64:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 $(GO) build -ldflags="$(LDFLAGS)" -o $(BUILD_DIR)/linux-amd64/$(BINARY) .

linux-arm64:
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 $(GO) build -ldflags="$(LDFLAGS)" -o $(BUILD_DIR)/linux-arm64/$(BINARY) .

windows-amd64:
	CGO_ENABLED=0 GOOS=windows GOARCH=amd64 $(GO) build -ldflags="$(LDFLAGS)" -o $(BUILD_DIR)/windows-amd64/$(BINARY).exe .

clean:
	rm -rf $(BUILD_DIR)
