BINARY_NAME := sentinelone.ext
VERSION := 0.1.0
BUILD_DIR := build

GO := go
GOFLAGS := -trimpath
LDFLAGS := -s -w -X main.version=$(VERSION)

.PHONY: all clean test vet build sign macos macos-amd64 macos-arm64 linux-amd64 linux-arm64 windows-amd64

all: test build sign

test:
	$(GO) test -v -race ./...

vet:
	$(GO) vet ./...

build: macos linux-amd64 linux-arm64 windows-amd64

# macOS universal: build amd64 and arm64, then lipo-merge when on macOS.
macos: macos-amd64 macos-arm64
	@if command -v lipo >/dev/null 2>&1; then \
		mkdir -p $(BUILD_DIR)/darwin-universal; \
		lipo -create -output $(BUILD_DIR)/darwin-universal/$(BINARY_NAME) \
			$(BUILD_DIR)/darwin-amd64/$(BINARY_NAME) \
			$(BUILD_DIR)/darwin-arm64/$(BINARY_NAME); \
		echo "Built universal binary: $(BUILD_DIR)/darwin-universal/$(BINARY_NAME)"; \
	else \
		echo "lipo not available; per-arch macOS binaries in $(BUILD_DIR)/darwin-*"; \
	fi

macos-amd64:
	mkdir -p $(BUILD_DIR)/darwin-amd64
	CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 $(GO) build $(GOFLAGS) -ldflags="$(LDFLAGS)" \
		-o $(BUILD_DIR)/darwin-amd64/$(BINARY_NAME) .

macos-arm64:
	mkdir -p $(BUILD_DIR)/darwin-arm64
	CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 $(GO) build $(GOFLAGS) -ldflags="$(LDFLAGS)" \
		-o $(BUILD_DIR)/darwin-arm64/$(BINARY_NAME) .

linux-amd64:
	mkdir -p $(BUILD_DIR)/linux-amd64
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 $(GO) build $(GOFLAGS) -ldflags="$(LDFLAGS)" \
		-o $(BUILD_DIR)/linux-amd64/$(BINARY_NAME) .

linux-arm64:
	mkdir -p $(BUILD_DIR)/linux-arm64
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 $(GO) build $(GOFLAGS) -ldflags="$(LDFLAGS)" \
		-o $(BUILD_DIR)/linux-arm64/$(BINARY_NAME) .

windows-amd64:
	mkdir -p $(BUILD_DIR)/windows-amd64
	CGO_ENABLED=0 GOOS=windows GOARCH=amd64 $(GO) build $(GOFLAGS) -ldflags="$(LDFLAGS)" \
		-o $(BUILD_DIR)/windows-amd64/$(BINARY_NAME).exe .

# Set root:wheel ownership and 755 mode required by osquery's extension loader.
# Must run as root (or via sudo make sign).
sign:
	sudo chown -R root:wheel $(BUILD_DIR)
	sudo chmod -R 755 $(BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR)
