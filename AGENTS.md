# AGENTS.md

BoltMesh is a Flutter WireGuard client (`lib/`, root `pubspec.yaml`) plus a privileged Go helper (`boltmeshd/`, entry `boltmeshd/cmd/boltmeshd/main.go`). The backend contract is in the separate [`backend`](https://github.com/boltmesh-labs/backend) repository (`app/vpn/`; `/vpn-devices` and `/vpn-regions` under `/v1`).

## Toolchain and entry points

- Use Flutter 3.47.x stable (Dart `^3.13.0`) and Go 1.27. Android builds use JDK 21 plus Android platform/build-tools 36; Windows native/release builds need Visual Studio 2022 C++ and Inno Setup 7 (the 64-bit edition, at `C:\Program Files\Inno Setup 7`).
- `lib/main.dart` is the composition root; `lib/app/root_shell.dart` is the auth gate, and `lib/features/vpn/state/connection_controller.dart` orchestrates provisioning, connect/switch, polling, and recovery through its `conn_*.dart` part files.
- The Flutter app is unprivileged: Linux uses `/run/boltmesh/boltmeshd.sock`; Windows uses `\\.\pipe\boltmesh\boltmeshd`. `boltmeshd` owns `wg-quick`/WireGuard service work and privileged reads; never add `sudo`, `wg`, `wg-quick`, or GUI elevation to the app.

## Verification

CI does not run the per-commit validation. `.github/workflows/ci.yml` runs only
`dependency-review` (PRs) and `security` (gitleaks + Trivy); every check below is
a manual gate to run before pushing. On a tag, `release.yml` reuses that same
security scan and nothing else. The toolchains these checks need (Flutter SDK, Go
build cache, Gradle, the Android NDK) populated gigabytes of Actions storage,
which is why they are local only.

### Flutter client (repository root)

Run this order when changing Dart code:

```sh
flutter pub get --enforce-lockfile
bash tool/check_generated.sh
pwsh -File tool/verify_windows.ps1   # Windows host only
flutter analyze --fatal-infos
dart format --set-exit-if-changed lib test integration_test
flutter test --coverage
bash tool/verify_native.sh
```

- The root `Makefile` wraps the commands above rather than replacing them: `make check` runs the Flutter half in the same order (`deps`, `generated`, `analyze`, `format-check`, `test`, `coverage`), `make verify-native` / `make verify-windows` map to the two scripts, and the run/build targets apply `--dart-define-from-file=$(ENV_FILE)` when that file exists and pass nothing when it does not. `make help` lists them; `make env` prints the keys `.env` supplies, never the values.
- Run one test with `flutter test test/features/vpn/data/wg_conf_test.dart`; test paths mirror `lib/`.
- `integration_test/` is formatted and analyzed but never run by `flutter test`: it holds the device-run GUI end-to-end, which needs a live serving node, real credentials in the environment, and the installed `boltmeshd` helper. `app_e2e.dart` runs on both desktop platforms behind one `_Host` seam; run it with `tool/e2e/run_linux_app.sh` (sudo `tool/e2e/install_boltmeshd.sh` first) or `tool/e2e/run_windows_app.ps1` (elevated `tool/e2e/install_boltmeshd.ps1` first); see `tool/e2e/README.md`.
- For a local backend, run `podman-compose up -d` from the `infra` repository; that is already the default API (`http://localhost:8000/v1`), so a fresh clone runs against localhost unconfigured. For any other API, copy `.env.example` to `.env` (gitignored) and pass it to Flutter with `--dart-define-from-file=.env` on `run|build`, or let `make run` / `make build-*` apply it; plain `flutter` and the IDE still work but pass no file and get the localhost default. Release builds reject `http://`, and `distribute_options.yaml` pins the production URL per job, so CI reads no `.env`.
- Android validation is `flutter build apk --debug --config-only` followed by `(cd android && ./gradlew :app:lintDebug)`; the config step must run first so Gradle has `android/local.properties`. Run that by hand when touching Android; the minified release variants are built only on a tag, by `release.yml`'s `build-android`.
- The Gradle wrapper (`android/gradlew`, `android/gradlew.bat`, `android/gradle/wrapper/gradle-wrapper.jar`) is committed, unlike the Flutter template, so any job or fresh clone can run Gradle before a `flutter build`. Those files are the Flutter SDK's `gradle_wrapper` artifact byte-for-byte; never hand-edit them. `android/local.properties` stays ignored, and anything that invokes Gradle without `flutter build` must write it, which is why the manual Android check starts with `--config-only`.
- Windows native validation must run on Windows: `tool/verify_windows.ps1` is the single entry point (native runner build, the `helper_pipe_io_tests` named-pipe C++ test, the Windows-tagged `boltmeshd` Go tests, and the `stage_boltmeshd.ps1` staging hook). It is the manual Windows check, so there are no CI job steps to keep in sync. `tool/verify_native.sh` additionally cross-compiles the C++ test with mingw-w64 on Linux (compile-only — Wine does not emulate its overlapped named-pipe I/O faithfully). `cmake` is often absent from a developer `PATH` on Windows, so the script falls back to the copy Visual Studio ships.

### `boltmeshd` (run from `boltmeshd/`)

```sh
make lint                 # Linux/shared files
make lint-windows         # GOOS=windows amd64 lint
make lint-darwin          # GOOS=darwin arm64 lint
make mod-tidy-check       # go mod tidy -diff, read-only
make vet
make test                 # go test ./... -v -count=1
make test-darwin          # GOOS=darwin go vet: type-checks darwin files and tests
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build ./...
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go vet ./...
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build ./...
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go vet ./...
GOOS=darwin GOARCH=amd64 CGO_ENABLED=0 go build ./...
go run golang.org/x/tools/cmd/deadcode@v0.50.0 -test ./...   # no output expected
make build                # Linux + Windows helper binaries in ignored bin/
```

`make all` is a broad build/check target but does not replace `make lint-windows` or Windows-tagged tests. `bin/` is ignored; do not commit helper binaries.

The stream transport's wire format and bridge live in the top-level `stream/` module (`boltmesh/stream`), imported by both `boltmeshd` and `android/awg-native` through a local `replace`. It is standard-library only and build-tag free; a change there runs its own suite (`make -C stream test`), and because `boltmeshd` imports it, keep `boltmeshd`'s build and tests green too.

`android/awg-native` is the third Go module and is cgo, which changes what can be checked where: it includes `<jni.h>` and `<android/log.h>`, so `go vet` and `golangci-lint` need the NDK toolchain and cannot run on a plain Linux runner. `make -C android/awg-native check` (gofmt, `go mod tidy -diff`, then vet + lint over all four ABIs) is the gate, run manually; it delegates to `python3 tool/build_awg_android.py --check`, which shares its NDK wiring with the APK build so the two cannot drift. `tool/install_android_ndk.sh` installs that NDK for the release build (`release.yml`) and for this local check, and sets `ANDROID_NDK_HOME`, without which the check resolves the host's own default NDK instead. The pre-commit hooks cover only the toolchain-free parts. An APK build compiling this module is **not** a gate — it says nothing about vet, lint, or formatting.

`tool/build_awg_android.py` has two modes: the default cross-builds the four ABIs for the APK, and `--check` gates the module. Both share `resolve_ndk`/`toolchain_for`/`abi_env`, so a check cannot pass on a toolchain the shipped build does not use, and `android/awg-native/Makefile` exposes them as `check`, `format`, `mod-tidy-check`. Note that `bash tool/verify_native.sh` is *not* this module's gate — it covers the C++ pipe test and the desktop Go modules.

## High-risk conventions

- Generated Dart is committed but excluded from analysis: `lib/l10n/gen/**`, `**/*.freezed.dart`, and `**/*.g.dart`. Never hand-edit it; after changing `.arb` files or freezed/JSON models run `bash tool/check_generated.sh` and commit the regenerated output. The `check-generated` pre-commit hook runs that script on any commit touching `lib/**.dart`, `*.arb`, `l10n.yaml` or `pubspec.*`, and `make generated` is the same gate — so a stale generator drops the commit, and when `pre-commit install` was never run only the manual gate catches it.
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
- `.pre-commit-config.yaml` runs shellcheck, Go formatting/linting/tests/module checks for Linux and Windows, generated-code and Flutter lockfile checks, Dart formatting/analyze, actionlint, gitleaks, and repository hygiene hooks. Formatting hooks may modify files; inspect the diff. The prettier and markdownlint hooks are version-pinned (markdown runs through `markdownlint-cli2`, which bundles the engine, so pinning that version pins both), and their rules are frozen in `.prettierrc.json` and `.markdownlint.json`, because these hooks are meant to be run with `--all-files`: an unpinned release would reformat every covered file at once. Since CI no longer runs them, that check is local — a config change will only show up when you next run the hooks across the tree. Prettier is configured identically in every boltmesh repo: `.prettierrc.json` is byte-for-byte the same file in all five, `.prettierignore` opens with the same vendored/generated block, and the version is pinned. Because the file is shared, changing an option value reformats every repo at once, so land such a change as its own commit across all five rather than in one. In the repos other than `frontend`, markdown is markdownlint's job rather than prettier's, so a bare `prettier --write .` will still want to rewrap the `.md` files: use the hook, not a whole-tree write. Bump those two pins by hand — Dependabot has no `npm` ecosystem here and does not parse versions out of `.pre-commit-config.yaml` — and land the resulting reformat in its own commit. Both hooks here are `language: node` with their versions pinned in `additional_dependencies`, so pre-commit installs each tree once into `~/.cache/pre-commit` rather than an `npx` entry re-resolving ~80 packages into an uncached `~/.npm/_npx` on every run — a truncated extraction there fails the hook before it reads a file. In `frontend`, prettier is the exception and stays an `npx` entry resolving the local devDependency, because that repo's prettier is gated by the locked `npm run format:check` and a second, hook-only install would let the two drift. The hooks are the local gate; CI runs only `security` (gitleaks over the full commit history with `fetch-depth: 0`, then Trivy) and `dependency-review`, so nothing re-checks the hooks remotely. The "Verification" section above covers the Flutter, Dart, Go and Gradle commands, actionlint, and `shellcheck -x` over `*.sh` as manual checks. Local-only: the hygiene guards, Prettier and markdownlint. Adding a hook to `.pre-commit-config.yaml` therefore needs no CI change.
- See `README.md` for runtime flags, platform behavior, backend flows, and handshake readers; `SETUP.md` for fresh-machine prerequisites; `boltmeshd/README.md` for the socket/pipe protocol and security model; `DEPLOYMENT.md` for releases.
- Other boltmesh repos live in parent directory (backend, frontend, agent, client, infra)

There are no production servers yet: avoid backward-compatibility layers and add defensive behavior only for real edge cases.
