# The Android AmneziaWG JNI module.
#
# cgo, and that changes what can be checked where: `format` and
# `mod-tidy-check` need only the Go toolchain, but `go vet` and golangci-lint
# need the Android NDK because this package includes <jni.h> and
# <android/log.h> — on a plain Linux runner it cannot even be parsed. Those go
# through tool/build_awg_android.py, which owns the same toolchain wiring the
# APK build uses, so the check cannot drift from the build it guards.
#
# `check` therefore needs the pinned NDK discoverable (ANDROID_HOME, or
# ANDROID_NDK_HOME) plus golangci-lint v2 on PATH. CI runs it; the local
# pre-commit hooks cover only the toolchain-free parts.
.PHONY: all format mod-tidy-check check

all: check

format:
	gofmt -w .

mod-tidy-check:
	go mod tidy -diff

check:
	python3 ../../tool/build_awg_android.py --check
