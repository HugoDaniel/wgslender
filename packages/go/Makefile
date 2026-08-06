# wgslender Go package — local gates only.
#
# This repo has no CI by design, so `make check` is the gate: it must pass
# before every commit. The opt-in targets (lint, fuzz, bench) are for when you
# are working on the thing they measure, not for every change.

GO ?= go

# Fuzzing runs one target in one package at a time (`go test -fuzz` refuses a
# multi-package pattern, and a pattern matching two targets in one). The
# targets, and where they live:
#
#	FuzzMinify     ./wgslender          (default)
#	FuzzEveryCall  ./wgslender
#	FuzzDecode     ./internal/wasmabi
FUZZPKG  ?= ./wgslender
FUZZTIME ?= 30s
FUZZ     ?= FuzzMinify

.PHONY: check fmt vet build test lint fuzz bench

## check: the mandatory pre-commit gate.
check: fmt vet build test

## fmt: report unformatted files without rewriting them, so the gate is a
## question ("is this clean?") rather than an action with a side effect.
fmt:
	@unformatted="$$(gofmt -l .)"; \
	if [ -n "$$unformatted" ]; then \
		echo "not gofmt-clean:"; \
		echo "$$unformatted"; \
		echo "run: gofmt -w ."; \
		exit 1; \
	fi

## vet: stdlib static analysis.
vet:
	$(GO) vet ./...

## build: every package compiles.
build:
	$(GO) build ./...

## test: -race is not optional here; the package hands a pool of
## single-threaded wasm instances to arbitrarily many goroutines and the
## detector is what keeps that honest. -count=1 defeats the test cache.
test:
	$(GO) test -race -count=1 ./...

## lint: opt-in, and hard-fails when golangci-lint is missing — a check that
## did not run has not passed.
lint:
	@command -v golangci-lint >/dev/null 2>&1 || { \
		echo "golangci-lint is not installed."; \
		echo "install: https://golangci-lint.run/welcome/install/"; \
		exit 1; \
	}
	golangci-lint run

## fuzz: opt-in. Override FUZZ/FUZZPKG/FUZZTIME to aim it.
fuzz:
	$(GO) test -run '^$$' -fuzz '^$(FUZZ)$$' -fuzztime $(FUZZTIME) $(FUZZPKG)

## bench: opt-in. -count=6 is what benchstat wants to see, and -cpu 1,8 is what
## makes the pool's whole reason for existing visible: the parallel rows are
## flat at 1 and should be several times faster at 8.
##
##	make bench > new.txt && benchstat old.txt new.txt
bench:
	$(GO) test -run '^$$' -bench . -benchmem -count=6 -cpu 1,8 ./...
