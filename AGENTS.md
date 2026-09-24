# AGENTS.md

BoltMesh is a Flutter WireGuard client (`lib/`, root `pubspec.yaml`) plus a privileged Go helper (`boltmeshd/`, entry `boltmeshd/cmd/boltmeshd/main.go`). The backend contract is in the separate [`backend`](https://github.com/boltmesh-labs/backend) repository (`app/vpn/`; `/vpn-devices` and `/vpn-regions` under `/v1`).

## Toolchain and entry points

- Use Flutter 3.47.x stable (Dart `^3.13.0`) and Go 1.26. Android builds use JDK 21 plus Android platform/build-tools 36; Windows native/release builds need Visual Studio 2022 C++ and Inno Setup 6.
- `lib/main.dart` is the composition root; `lib/app/root_shell.dart` is the auth gate, and `lib/features/vpn/state/connection_controller.dart` orchestrates provisioning, connect/switch, polling, and recovery through its `conn_*.dart` part files.
- The Flutter app is unprivileged: Linux uses `/run/boltmesh/boltmeshd.sock`; Windows uses `\\.\pipe\boltmesh\boltmeshd`. `boltmeshd` owns `wg-quick`/WireGuard service work and privileged reads; never add `sudo`, `wg`, `wg-quick`, or GUI elevation to the app.

## Verification

### Flutter client (repository root)

Run the CI validation order when changing Dart code:

```sh
flutter pub get
bash tool/check_generated.sh
flutter analyze --fatal-infos
dart format --set-exit-if-changed lib test
flutter test --coverage
bash tool/coverage_gate.sh 80
bash tool/verify_native.sh
```

- Run one test with `flutter test test/features/vpn/data/wg_conf_test.dart`; test paths mirror `lib/`.
- For a local backend, run `podman-compose up -d` from the `infra` repository, then use `flutter run --dart-define=API_BASE_URL=http://localhost:8000/v1`. The default API is production HTTPS; release builds reject `http://`.
- Android validation is `flutter build apk --debug` followed by `(cd android && ./gradlew :app:lintDebug)`; the build must run first so Gradle has `android/local.properties`.
- Windows native validation (`flutter build windows --debug` and the named-pipe C++ test) must run on Windows; the helper’s Windows-tagged Go tests also run only on the Windows CI runner.

### `boltmeshd` (run from `boltmeshd/`)

```sh
make lint                 # Linux/shared files
make lint-windows         # GOOS=windows amd64 lint
make mod-tidy-check       # go mod tidy -diff, read-only
make vet
make test                 # go test ./... -v -count=1
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build ./...
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go vet ./...
make build                # Linux + Windows helper binaries in ignored bin/
```

`make all` is a broad build/check target but does not replace `make lint-windows` or Windows-tagged tests. `bin/` is ignored; do not commit helper binaries.

## High-risk conventions

- Generated Dart is committed but excluded from analysis: `lib/l10n/gen/**`, `**/*.freezed.dart`, and `**/*.g.dart`. Never hand-edit it; after changing `.arb` files or freezed/JSON models run `bash tool/check_generated.sh` and commit the regenerated output.
- `analysis_options.yaml` also excludes native platform directories, so Dart analysis does not replace Android/Windows builds. Keep its strict casts/raw types/inference and custom lints intact.
- Tests are deterministic: use `package:fake_async` and `async.elapse`, never real sleeps; `dart_test.yaml` has a 60-second timeout and no retries. Shared doubles live in `test/support/fakes.dart`; state suites build on `test/support/vpn_harness.dart` and subclass only their delta.
- Keep public `ConnectionController` methods (`connect`, `switchServer`, `rotateKeys`, `pollStatusOnce`, …) as instance methods, never extension members. The `conn_*.dart` extensions cannot access Riverpod’s protected `ref`/`state`; use the class accessors instead.
- Do not treat a null Apple handshake as proof of failure: unsupported/null reads never heal, and only the health-policy path may act on degraded state. Byte counters are display-only.
- The Windows client is x64-only because `wireguard_flutter_plus` supplies amd64 tunnel/WireGuard DLLs. `windows/packaging/stage_boltmeshd.ps1` rejects arm64 bundles and the Inno config pins `x64compatible`; the standalone arm64 helper target is not an app package.
- Close-to-tray code is in `lib/app/desktop_tray.dart` over `lib/core/desktop/`; it is desktop-only and disabled under `flutter test`. Add tray menu strings through the `.arb` localization files, then regenerate.
- Releases are driven by `v*` tags. `tool/set_release_version.dart` rewrites the checked-in dev version before tagged builds; signing/artifact details are in `DEPLOYMENT.md`. `flutter create .` only fills missing native shells and must not overwrite `lib/`.
- Dependabot groups minor/patch updates by `pub`, Gradle, Go modules, and GitHub Actions; major updates remain separate so generated-code and platform checks are reviewable.

## Layout and local checks

- `lib/`: `app/` (auth/navigation/lifecycle), `core/` (HTTP, environment, errors, locale, logging, mutex, theme, storage), `features/auth/{data,state,ui}`, `features/vpn/{data,domain,state,ui}`, and `previews/`.
- `test/` mirrors `lib/`; app-level suites such as `widget_test.dart` and `regions_refresh_test.dart` stay at the test root.
- `.pre-commit-config.yaml` runs shellcheck, Go formatting/linting/tests/module checks for Linux and Windows, generated-code and Flutter lockfile checks, Dart formatting/analyze, actionlint, gitleaks, and repository hygiene hooks. Formatting hooks may modify files; inspect the diff.
- See `README.md` for runtime flags, platform behavior, backend flows, and handshake readers; `SETUP.md` for fresh-machine prerequisites; `boltmeshd/README.md` for the socket/pipe protocol and security model; `DEPLOYMENT.md` for releases.

There are no production servers yet: avoid backward-compatibility layers and add defensive behavior only for real edge cases.
