# The stream transport's wire format and client bridge. Extracted from
# boltmeshd so the Android native module can carry the identical protocol; this
# module depends only on the standard library and has no build tags, so one
# build/vet/lint/test pass covers every consumer.
.PHONY: all test vet format lint mod-tidy-check

all: format lint vet test

test:
	go test ./... -v -count=1

vet:
	go vet ./...

format:
	go fmt ./...

lint:
	golangci-lint run ./...

mod-tidy-check:
	go mod tidy -diff
