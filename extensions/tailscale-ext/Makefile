# Cross-compile the tailscale osquery extension for macOS, Linux, and Windows.
#
# osquery extensions must be statically built (CGO_ENABLED=0) so they run
# inside the orbit/osqueryd process on customer endpoints without depending
# on host libc versions.

BINARY := tailscale.ext
BUILD_DIR := build

GO := go
GOFLAGS := -trimpath
LDFLAGS := -s -w

.PHONY: all test clean sign macos macos-arm64 macos-amd64 linux-amd64 linux-arm64 windows-amd64

all: macos linux-amd64 linux-arm64 windows-amd64 sign

test:
	$(GO) test -race -v ./...

clean:
	rm -rf $(BUILD_DIR)

# macOS universal: build amd64 and arm64, then lipo-merge when on macOS.
macos: macos-amd64 macos-arm64
	@if command -v lipo >/dev/null 2>&1; then \
		mkdir -p $(BUILD_DIR)/darwin-universal; \
		lipo -create -output $(BUILD_DIR)/darwin-universal/$(BINARY) \
			$(BUILD_DIR)/darwin-amd64/$(BINARY) \
			$(BUILD_DIR)/darwin-arm64/$(BINARY); \
		echo "Built universal binary: $(BUILD_DIR)/darwin-universal/$(BINARY)"; \
	else \
		echo "lipo not available; per-arch macOS binaries in $(BUILD_DIR)/darwin-*"; \
	fi

macos-amd64:
	mkdir -p $(BUILD_DIR)/darwin-amd64
	CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 $(GO) build $(GOFLAGS) -ldflags="$(LDFLAGS)" \
		-o $(BUILD_DIR)/darwin-amd64/$(BINARY) .

macos-arm64:
	mkdir -p $(BUILD_DIR)/darwin-arm64
	CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 $(GO) build $(GOFLAGS) -ldflags="$(LDFLAGS)" \
		-o $(BUILD_DIR)/darwin-arm64/$(BINARY) .

linux-amd64:
	mkdir -p $(BUILD_DIR)/linux-amd64
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 $(GO) build $(GOFLAGS) -ldflags="$(LDFLAGS)" \
		-o $(BUILD_DIR)/linux-amd64/$(BINARY) .

linux-arm64:
	mkdir -p $(BUILD_DIR)/linux-arm64
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 $(GO) build $(GOFLAGS) -ldflags="$(LDFLAGS)" \
		-o $(BUILD_DIR)/linux-arm64/$(BINARY) .

windows-amd64:
	mkdir -p $(BUILD_DIR)/windows-amd64
	CGO_ENABLED=0 GOOS=windows GOARCH=amd64 $(GO) build $(GOFLAGS) -ldflags="$(LDFLAGS)" \
		-o $(BUILD_DIR)/windows-amd64/$(BINARY).exe .

# Set root:wheel ownership and 755 mode required by osquery's extension loader.
# Must run as root (or via sudo make sign).
sign:
	sudo chown -R root:wheel $(BUILD_DIR)
	sudo chmod -R 755 $(BUILD_DIR)
