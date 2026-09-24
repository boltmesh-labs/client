VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "v1.0.0")
GIT_COMMIT ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_TIME ?= $(shell date -u +'%Y-%m-%dT%H:%M:%SZ')

BUILD_DIR := bin
BINARY_AMD64 := boltmeshd-linux-amd64
BINARY_ARM64 := boltmeshd-linux-arm64
BINARY_WINDOWS_AMD64 := boltmeshd-windows-amd64.exe
BINARY_WINDOWS_ARM64 := boltmeshd-windows-arm64.exe
ENTRY_POINT := ./cmd/boltmeshd

LDFLAGS := -s -w \
    -X main.Version=$(VERSION) \
    -X main.GitCommit=$(GIT_COMMIT) \
    -X main.BuildTime=$(BUILD_TIME)

.PHONY: all build build-amd64 build-arm64 build-windows build-windows-amd64 build-windows-arm64 checksums clean test vet format lint lint-windows mod-tidy-check

all: clean format lint vet test build checksums

build: build-amd64 build-arm64 build-windows

build-amd64:
	@mkdir -p $(BUILD_DIR)
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
		-a -ldflags="$(LDFLAGS)" \
		-o $(BUILD_DIR)/$(BINARY_AMD64) $(ENTRY_POINT)
	@echo "Build complete: $(BUILD_DIR)/$(BINARY_AMD64)"

build-arm64:
	@mkdir -p $(BUILD_DIR)
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build \
		-a -ldflags="$(LDFLAGS)" \
		-o $(BUILD_DIR)/$(BINARY_ARM64) $(ENTRY_POINT)
	@echo "Build complete: $(BUILD_DIR)/$(BINARY_ARM64)"

build-windows: build-windows-amd64 build-windows-arm64

build-windows-amd64:
	@mkdir -p $(BUILD_DIR)
	CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build \
		-a -ldflags="$(LDFLAGS)" \
		-o $(BUILD_DIR)/$(BINARY_WINDOWS_AMD64) $(ENTRY_POINT)
	@echo "Build complete: $(BUILD_DIR)/$(BINARY_WINDOWS_AMD64)"

build-windows-arm64:
	@mkdir -p $(BUILD_DIR)
	CGO_ENABLED=0 GOOS=windows GOARCH=arm64 go build \
		-a -ldflags="$(LDFLAGS)" \
		-o $(BUILD_DIR)/$(BINARY_WINDOWS_ARM64) $(ENTRY_POINT)
	@echo "Build complete: $(BUILD_DIR)/$(BINARY_WINDOWS_ARM64)"

checksums: build
	@cd $(BUILD_DIR) && sha256sum $(BINARY_AMD64) $(BINARY_ARM64) $(BINARY_WINDOWS_AMD64) $(BINARY_WINDOWS_ARM64) > checksums.txt
	@echo "Checksums generated in $(BUILD_DIR)/checksums.txt"

test:
	go test ./... -v -count=1

vet:
	go vet ./...

format:
	go fmt ./...

lint:
	golangci-lint run ./...

lint-windows:
	GOOS=windows GOARCH=amd64 CGO_ENABLED=0 golangci-lint run ./...

mod-tidy-check:
	go mod tidy -diff

clean:
	rm -rf $(BUILD_DIR)
