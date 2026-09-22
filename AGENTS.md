# AGENTS.md

BoltMesh VPN: Flutter WireGuard client (`lib/`) plus the privileged Linux/Windows helper (`boltmeshd/`, Go, entry `cmd/boltmeshd/main.go`). Backend contract lives in the [`backend`](https://github.com/boltmesh-labs/backend) repo (`app/vpn/`; `/vpn-devices`, `/vpn-regions` under `/v1`).

## Commands

Client (Flutter ≥3.47), from the repo root, in CI order:

```sh
flutter pub get
bash tool/check_generated.sh        # regenerate l10n + build_runner, fail on drift
flutter analyze --fatal-infos
dart format --set-exit-if-changed lib test
flutter test --coverage
bash tool/coverage_gate.sh 80       # floor on hand-written lines only
```

- Single test: `flutter test test/features/vpn/data/wg_conf_test.dart` (test paths mirror `lib/`).
- Run against a local backend: `flutter run --dart-define=API_BASE_URL=http://localhost:8000/v1`. API base defaults to production `https://api.boltmesh.mooo.com/v1`; release builds refuse `http://`.
- Android emulator is tunneled to `127.0.0.1:5555`: `flutter run -d 127.0.0.1:5555`.

boltmeshd (from `boltmeshd/`, Go 1.26; builds Linux amd64/arm64 + Windows amd64/arm64):

```sh
make vet && make test   # go test ./... -v -count=1
make build              # Linux + Windows binaries into bin/
make all                # clean + format + lint + vet + test + build + checksums
```

`make lint` needs golangci-lint v2. CI's `validate-boltmeshd` job runs `gofmt`, golangci-lint (Linux and `GOOS=windows`), `deadcode`, `GOOS=windows` build/vet and `go test ./...` on every push/PR; `validate-windows` also runs the Windows-tagged tests on a Windows runner.

The Windows backend is build-tagged (`*_windows.go`), so `go test` on Linux covers shared + Linux code only. Cross-check Windows with `GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go vet ./...` before pushing.

## Gotchas

- **Generated code is committed but excluded from analysis** (`lib/l10n/gen/**`, `*.freezed.dart`, `*.g.dart`). After editing `.arb` files or freezed/json models, run `bash tool/check_generated.sh` (does `flutter gen-l10n` + `dart run build_runner build`) and commit the result — CI fails on drift. Never hand-edit those files.
- **The analyzer is strict**: `strict-casts`, `strict-raw-types`, `strict-inference`, plus the extra lints in `analysis_options.yaml` (`unawaited_futures`, `prefer_relative_imports`, `directives_ordering`, `avoid_print`, `prefer_single_quotes`, …). Pre-commit runs plain `flutter analyze`; CI adds `--fatal-infos`.
- **Tests are deterministic**: timer behaviour uses `package:fake_async` (`async.elapse`), never real sleeps. `dart_test.yaml` sets a 60s timeout and deliberately no `retry` — flakiness must be fixed, not masked. Shared doubles live in `test/support/fakes.dart`; state suites layer fixtures on `test/support/vpn_harness.dart`, `typedef`-aliasing the fakes and subclassing only the delta.
- **`ConnectionController` public methods (`connect`, `switchServer`, `pollStatusOnce`, …) must stay instance methods, never extension members** — `flutter_riverpod` exposes the class and Dart resolves extensions statically, so a test/preview override would be silently bypassed. Implementations live in the `conn_*.dart` part files; those cannot touch Riverpod's `@protected` `ref`/`state` and must go through the class accessors (`snap`, `_api`, `_tunnel`, `_networkMonitor`, …).
- **The app is unprivileged**: it never runs `sudo`/`wg`/`wg-quick` and never starts an elevated Windows service. Linux and Windows both delegate to `boltmeshd` (newline-delimited JSON `ping`/`status`/`up`/`down`) — over `/run/boltmesh/boltmeshd.sock` (group `boltmesh`) on Linux and `\\.\pipe\boltmesh\boltmeshd` on Windows. On Windows the daemon owns the `boltmesh0` tunnel service and the app's runner only proxies the pipe (`windows/runner/helper_pipe.cpp`, since `dart:io` has no named-pipe client). Apple handshake reads are still a placeholder, and a null read never heals.
- `flutter create --org com.boltmesh --project-name boltmesh .` only fills in missing `android/ ios/ macos/ windows/ linux/` shells — it never overwrites `lib/`.
- **Release**: the git tag is the source of truth; CI runs `dart run tool/set_release_version.dart` before every build job. The checked-in `version: 0.1.0+1` is a dev placeholder. Tagged release jobs (`build-android`/`build-linux`/`build-windows`) run only on `v*` and fail rather than ship unsigned artifacts. Signing, secrets and packaging details are in `README.md`.
- No backward compatibility: there are no production servers yet. Keep it lean; guard only real edge cases.

## Layout & conventions

- `lib/`: `main.dart`; `app/` (auth gate + nav/lifecycle shell); `core/` (dio, env, errors, ip, locale, log, mutex, theme, TLS pinning); `features/auth/{data,state,ui}`; `features/vpn/{data,domain,state,ui}`; `previews/`.
- `test/` mirrors `lib/`; app-level suites (`widget_test.dart`, `regions_refresh_test.dart`) stay at the `test/` root.
- Pre-commit (`.pre-commit-config.yaml`): gofmt + golangci-lint (boltmeshd), generated-code check, dart format + flutter analyze, prettier, markdownlint.
- Deeper docs: `README.md` (platform notes, release builds, backend flows, handshake readers), `SETUP.md` (fresh-machine setup), `boltmeshd/README.md` (socket/pipe protocol + security model).
