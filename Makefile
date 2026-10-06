# Developer entry points for the Flutter client.
#
# The reason this file exists: API_BASE_URL, WEBSITE_URL, TLS_PIN_SPKI_SHA256
# and the Apple defines are compile-time --dart-defines, and Flutter has no
# dotenv loader, so every command that needs them has to be handed .env by
# hand (--dart-define-from-file). These targets hand it over once.
#
# With no .env they pass nothing and the build takes the app's own default,
# http://localhost:8000/v1 -- the infra podman-compose stack -- which is what
# a fresh clone wants. `make env` says which defines are in play. Point at a
# different file with `make run ENV_FILE=staging.env`, or turn it off with
# `make run ENV_FILE=`.
#
# Release packaging never reads .env: distribute_options.yaml pins the
# production URL per fastforge job, so `make release` hands off to fastforge
# and inherits that.
#
# The check targets mirror the CI validation order documented in AGENTS.md
# ("Verification"); keep them in step with it.

ENV_FILE ?= .env
DEFINES := $(if $(wildcard $(ENV_FILE)),--dart-define-from-file=$(ENV_FILE),)
# Pass anything extra through: `make run EXTRA="-d chrome --web-port=8080"`.
EXTRA ?=
# strip, so an unset EXTRA leaves no trailing blank in the command.
FLAGS := $(strip $(DEFINES) $(EXTRA))

.DEFAULT_GOAL := help

.PHONY: help env run run-linux run-linux-debug run-web \
	build-linux build-linux-debug build-apk build-apk-release build-windows \
	release clean \
	deps generated analyze format format-check test coverage check \
	verify-native verify-windows e2e-linux-app suricata-wireguard

help: ## List these targets
	@grep -E '^[a-z][a-z0-9-]*:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

env: ## List the defines ENV_FILE supplies (keys only -- values are never printed)
	@if [ -f "$(ENV_FILE)" ]; then \
		echo "$(ENV_FILE) supplies:"; \
		sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "$(ENV_FILE)" | sed 's/^/  /'; \
	else \
		echo "$(ENV_FILE) not found: builds take the app default http://localhost:8000/v1"; \
	fi

# --- run ------------------------------------------------------------------

run: ## Run on the default device, with .env applied
	flutter run $(FLAGS)

run-linux: ## Run on the Linux desktop runner
	flutter run -d linux $(FLAGS)

run-linux-debug: ## Run the Linux desktop runner in debug mode
	flutter run -d linux --debug $(FLAGS)

run-web: ## Run in a browser
	flutter run -d web-server $(FLAGS)

# --- build ----------------------------------------------------------------

build-linux: ## Release build for Linux (refuses a cleartext API_BASE_URL)
	flutter build linux --release $(FLAGS)

build-linux-debug: ## Debug build for Linux
	flutter build linux --debug $(FLAGS)

build-apk: ## Debug APK -- the Android validation build, and what writes android/local.properties
	flutter build apk --debug $(FLAGS)

build-apk-release: ## Release APK
	flutter build apk --release $(FLAGS)

build-windows: ## Release build for Windows (x64 only)
	flutter build windows --release $(FLAGS)

release: ## Pack the production release (fastforge; pins its own URLs, ignores .env)
	fastforge release --name=production

clean: ## Drop build output and the Flutter tool's caches
	flutter clean

# --- checks ---------------------------------------------------------------
# Same commands, same order, as the `validate` job in .github/workflows/ci.yml.

deps: ## Resolve packages, failing rather than rewriting pubspec.lock
	flutter pub get --enforce-lockfile

generated: ## Fail if l10n/build_runner output differs from the committed tree
	bash tool/check_generated.sh

analyze: ## Static analysis, infos included
	flutter analyze --fatal-infos

format: ## Format lib/, test/ and integration_test/
	dart format lib test integration_test

format-check: ## Fail if lib/, test/ or integration_test/ is unformatted
	dart format --set-exit-if-changed lib test integration_test

test: ## Run the test suite
	flutter test $(EXTRA)

coverage: ## Run the suite under coverage and enforce the 80% floor
	flutter test --coverage
	bash tool/coverage_gate.sh 80

check: deps generated analyze format-check test coverage ## Everything `validate` runs

verify-native: ## Cross-compile the C++ pipe test and build the desktop Go modules
	bash tool/verify_native.sh

verify-windows: ## Full Windows validation -- Windows host only
	pwsh -File tool/verify_windows.ps1

# Not part of `check`: this one needs a live serving node, credentials in the
# environment, the installed helper and a display. See tool/e2e/README.md.
e2e-linux-app: ## Run the Linux desktop app end to end (live node; needs BOLTMESH_E2E_API_*)
	tool/e2e/run_linux_app.sh

# Also not part of `check`: needs root for Suricata, a live serving node and the
# e2e's requirements. See tool/suricata/README.md.
suricata-wireguard: ## Prove Suricata visibility of native/awg/stream (root; live node)
	tool/suricata/run.sh
