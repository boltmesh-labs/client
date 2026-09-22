# AGENTS.md

BoltMesh VPN: Flutter WireGuard client app, Linux privileged helper (`linux/boltmeshd/`, Go, entry `cmd/boltmeshd/main.go`).

## Commands

- **Client** (Flutter ≥3.47): `flutter analyze` → `dart format --set-exit-if-changed lib test` → `flutter test`. CI (`.github/workflows/default.yml`) runs all three in the `validate` job on every push/PR, plus `validate-android`/`validate-windows` jobs (`flutter build apk --debug` / `flutter build windows --debug`) that compile the Android app and the native Windows runner; Android (`appbundle`+`apk`), Linux installers (deb+rpm) and the Windows Inno Setup installer (all via `fastforge release --name=production`; each host runs only its own jobs) build only on `v*` tags; the Android artifacts are signed with the upload keystore when the `ANDROID_KEYSTORE`/`ANDROID_KEYSTORE_PASSWORD` secrets are set (`build-android` fails on a tag without them instead of shipping a debug-signed build), and the Windows artifacts are Authenticode-signed when the `WINDOWS_CERTIFICATE`/`WINDOWS_CERTIFICATE_PASSWORD` secrets are set (see `README.md`). Single test: `flutter test test/features/vpn/data/wg_conf_test.dart` (test paths mirror `lib/`). API base defaults to production (`https://api.boltmesh.mooo.com/v1`); point at a local stack with `--dart-define=API_BASE_URL=http://localhost:8000/v1` (plus `VPN_PROVIDER_BUNDLE_ID=` for the iOS/macOS Network Extension, `VPN_PLATFORM=` to override the `platform` enum). Run android app with `flutter run -d 127.0.0.1:5555` (android emulator is running on windows host tunneled through port 5555)
- **boltmeshd** (from `linux/boltmeshd/`, Go 1.26): `make vet`, `make test` (`go test ./... -v -count=1`), `make build` (amd64+arm64), `make all`; `make lint` needs golangci-lint v2. CI's `default.yml` `validate-boltmeshd` job runs `gofmt`, golangci-lint, `deadcode` and `go test ./...` on every push/PR. It is the privileged Linux helper (root, systemd socket `/run/boltmesh/boltmeshd.sock`, group `boltmesh`); the Flutter app talks to it over UDS and never runs `sudo`/`wg`/`wg-quick`. The deb/rpm stage it into the bundle via `hooks.pre` in `distribute_options.yaml` and install it from `postinstall_scripts`.

## Conventions & gotchas

- **Pre-commit** (`.pre-commit-config.yaml`): gofmt+golangci-lint (boltmeshd), eslint, dart format + flutter analyze, prettier, markdownlint.
- Do not implement backward compatibility, there is no production servers yet.
- Try to not overengineer, keep it lean, guard only real edge cases, no redundant checks.
