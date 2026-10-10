# BoltMesh Client

WireGuard VPN client. Backend contract lives in the
[`backend`](https://github.com/boltmesh-labs/backend) repo (`app/vpn/`; user
routes `/vpn-devices`, `/vpn-regions` under `/v1`).

## Documentation

This README is the entry point; the deeper docs live alongside it:

- [SETUP.md](SETUP.md) — fresh-machine setup per OS (toolchains, emulator,
  `boltmeshd` dev loop).
- [DEPLOYMENT.md](DEPLOYMENT.md) — release versions, CI pipeline, artifacts
  and signing.
- [CONTRIBUTING.md](CONTRIBUTING.md) — contribution flow, local hooks, style,
  test locations.
- [SECURITY.md](SECURITY.md) — vulnerability reporting, privilege model,
  transport security.
- [`boltmeshd/README.md`](boltmeshd/README.md) — helper socket/pipe protocol
  and security model.
- [AGENTS.md](AGENTS.md) — conventions for automated contributors.

## Contents

- [Prereqs](#prereqs)
- [Run](#run)
- [Project layout](#project-layout)
- [Platform status](#platform-status)
- [Platform notes](#platform-notes)
- [Release versioning](#release-versioning)
- [Android release build](#android-release-build)
- [Windows release build](#windows-release-build)
- [Flows](#flows)
- [Handshake readers](#handshake-readers)
- [Tests](#tests)

## Prereqs

Setting up a fresh machine (per-OS toolchains, emulator, `boltmeshd` dev
loop): see [SETUP.md](SETUP.md).

- Flutter SDK 3.47.x (`flutter --version`).
- Running backend (`podman-compose up -d` from the
  [`infra`](https://github.com/boltmesh-labs/infra) repo) + a user account
  (`POST /v1/auth/register`, then log in from the app's login screen).

## Run

The API URL is a compile-time constant, and it defaults to the local
`podman-compose` stack from the [`infra`](https://github.com/boltmesh-labs/infra)
repo (`http://localhost:8000/v1`) — so a fresh clone runs against localhost
with no configuration. To build against another API, put it in `.env` and
hand that file to Flutter:

```sh
cp .env.example .env          # then edit API_BASE_URL
flutter run --dart-define-from-file=.env
```

`--dart-define-from-file` is Flutter's own flag: every entry in `.env` becomes
a compile-time define, so it works for `run`, `build`, and anything else. Plain
`flutter run` and the IDE's run buttons still work — they just pass no file and
get the localhost default. `.env` is gitignored; `.env.example` is the
committed template.

The root `Makefile` wraps this so the flag is applied once and stays out of
the command: `make run` is `flutter run --dart-define-from-file=.env`, and
`make build-linux` / `make build-apk` do the same for builds. `make help` lists
every target. With no `.env` present it passes no file, so a fresh clone keeps
the localhost default; `make env` prints which defines the file supplies (keys
only, never values). Point it elsewhere with `make run ENV_FILE=staging.env`,
or turn it off with `make run ENV_FILE=`.

Every entry is a compile-time `--dart-define`, and `.env` is the preferred
place for all of them. Besides `API_BASE_URL`, these are understood:

- `WEBSITE_URL` — the public site where accounts are created. The login
  screen's "Create account" button opens it in the system browser and prints
  the URL underneath; unset hides that row entirely.
- `VPN_PROVIDER_BUNDLE_ID` and `VPN_APP_GROUP` — the iOS/macOS Network
  Extension target id and the App Group shared by the app and that extension.
  Both are required on Apple; the app fails fast naming whichever is missing
  (see [SETUP.md "macOS"](SETUP.md#macos)).
- `TLS_PIN_SPKI_SHA256` — optional comma-separated base64 SHA-256 public-key
  (SPKI) pin(s) of the server certificate, which survive cert renewal while
  the key is reused. Compute with `openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64`.
- `VPN_PLATFORM` — optional platform-label override for diagnostics (for
  example `android`).

Two behaviors are worth calling out: release builds refuse `http://` API URLs
(debug/profile allow localhost), so a release build with no `API_BASE_URL`
fails fast instead of shipping cleartext; and to run on a physical phone over
a LAN, replace `localhost` with your machine's IP.

Release packaging does not read `.env`: `distribute_options.yaml` pins the
production URL per job, so CI needs no `.env` of its own. `make release` hands
off to fastforge and inherits that pinning.

Then: log in (username or email + password, or Continue with
Google/GitHub) → Connect tab → toggle.
Regions tab → Quick Connect (auto lowest-load) or per-server switch.
No account yet? The login screen's "Create account" button opens
`WEBSITE_URL` in the system browser.

## Project layout

```text
lib/
├── main.dart              # main() + BoltMeshApp
├── previews.dart          # barrel re-exporting previews/*
├── l10n/                  # app_en/app_de.arb + generated gen/**
├── app/                   # root_shell (auth gate), authed_shell (nav +
│                          #   lifecycle), desktop_tray (close-to-tray)
├── core/                  # dio_client, env, errors, ip, locale, log, mutex,
│                          #   storage_options, theme, clock, tls_pinning,
│                          #   x509_spki, desktop/ (tray)
├── features/
│   ├── auth/{data,state,ui}/   # auth_api/models, session_store, auth_session
│   └── vpn/
│       ├── data/          # wg_conf, platform_info, probes, api, stores, tunnel IO
│       ├── domain/        # region/diagnosis/failover/tunnel policies
│       ├── state/         # connection_controller + conn_* parts, polling, resume
│       └── ui/            # home, regions, settings
└── previews/              # harness, fixtures, login, home, regions, settings
```

`test/` mirrors `lib/`, including `test/app/` and the `ui/` trees
(`features/auth/ui/`, `features/vpn/ui/`). Cross-cutting suites
(`widget_test.dart`, `regions_refresh_test.dart`) stay at the `test/` root;
shared doubles live in `test/support/fakes.dart` (state suites layer fixtures
on `test/support/vpn_harness.dart`).

## Platform status

Where each target actually stands. "Shipping" means the tunnel works and CI
validates the platform; "blocked" names what is missing rather than implying
progress that has not been made.

| Target | Tunnel | Privileged helper | CI | State |
| --- | --- | --- | --- | --- |
| **Android** | stock plugin + in-process AWG/stream (`VpnService`) | not needed | build, lint, minified bridge + API 30/35 instrumentation | **AWG and stream emulator proofs passed** |
| **Linux** | kernel (`wg-quick` + `wgctrl`) | `boltmeshd` (systemd) | build + `verify_native.sh` | **shipping** |
| **Windows** | stock WireGuard service + in-process AWG | `boltmeshd` (LocalSystem) | build, C++ pipe test, Go tests | **shipping** (AWG + stream ladder verified on hardware) |
| **macOS** | Network Extension, *or* the helper | `boltmeshd` (launchd) — written, not wired up, untested | cross-compile, `vet`, lint | **blocked on Apple hardware** |
| **iOS** | Network Extension only | not possible (sandbox) | none | **blocked on Apple hardware** |

### What blocks iOS and macOS

Both are blocked on the same thing, which **cannot be produced from this
repository** and cannot be worked around in code:

1. **A Packet Tunnel extension target.** On Apple the tunnel is not the app; it
   is a separate Xcode target that must be authored in Xcode. `ios/` and
   `macos/` contain only the app target.
2. **`WireGuardKitGo`.** The extension links a Go static library built from
   [`wireguard-apple`](https://github.com/aakashch0179/wireguard-apple). It is a
   third-party fork and is not vendored here.
3. **A provisioning profile** carrying the Network Extension entitlement,
   granted per-team by Apple. Requires a paid Apple Developer account.
4. **A Mac to run any of it on.** Everything above needs macOS with Xcode.
   Cross-compiling the Go helper for `darwin` works from Linux; the tunnel it
   drives, the extension, and the app itself do not.

### Apple work that *is* done

Not everything was blocked, and the parts that were not are landed and tested:

- The app-side **entitlements** are declared for both platforms —
  `networkextension`/`packet-tunnel-provider` and the App Group. macOS had
  neither, so its app target could never have hosted a Packet Tunnel provider.
- The **App Group is plumbed through** (`VPN_APP_GROUP`, resolved next to
  `VPN_PROVIDER_BUNDLE_ID`). It was silently never passed to the plugin, which
  fell back to `group.orbanvpn.wireguard` — a group in no provisioning
  profile, so a connect failed inside the extension with an opaque error.
  `bash tool/verify_native.sh` now asserts the entitlements on every run.
- The **macOS OAuth path is correct** and deliberately differs from Windows and
  Linux: it returns over the registered `boltmesh://` custom scheme via
  `ASWebAuthenticationSession`, with no loopback listener.
- **`boltmeshd` has a macOS backend** (see `boltmeshd/README.md`): a launchd
  LaunchDaemon running the WireGuard data plane in userspace over `utun`, since
  macOS has no kernel WireGuard and `wgctrl` has no darwin backend. It
  cross-compiles for `darwin/amd64` and `darwin/arm64`, is vetted and linted
  with `GOOS=darwin` in CI, and shares its platform-independent UAPI
  translation with the other backends. **It has never been run on a Mac.**

### Known macOS gaps

- The **client does not talk to the macOS helper yet.** `lib/features/vpn/data/`
  still routes macOS to the VPN plugin, not to `boltmeshd`. The helper side is
  written; the Dart side and the `.pkg` packaging are not.
- The macOS backend installs a **full-tunnel default route only**. Per-peer
  `AllowedIPs` split-tunneling is unimplemented there, unlike Linux.
- `macos/Runner.xcodeproj` has two targets (`Runner`, `RunnerTests`). Adding the
  extension is a manual Xcode step every developer repeats.
- **No Apple CI job, no release job, and no notarization.** `flutter build
  macos` is never run anywhere, and `DEPLOYMENT.md` lists no Apple artifact.

## Platform notes

- **Android**: supports **API 30 (Android 11) and newer**, and builds against
  **compile/target SDK 36 (Android 16)**. The floor is pinned in
  `android/app/build.gradle.kts` (`minSdk = 30`) so the documented minimum
  cannot drift with the Flutter SDK. `wireguard_flutter_plus` needs the
  `VpnService` permission (`android/app/src/main/AndroidManifest.xml`):
  `<uses-permission android:name="android.permission.INTERNET" />`, plus the
  `VpnService` `BIND_VPN_SERVICE` service entry from the package README.
  Accept the system VPN consent dialog on first connect.
- **Android foreground service**: the plugin's
  `VpnForegroundService` keeps the tunnel's foreground notification alive
  while connected. The Android build overlays a reviewed service implementation
  from `android/patches/wireguard_flutter_plus/` (the upstream 1.0.7 service
  is sticky and starts its notification from `onCreate()`): BoltMesh only
  enters the foreground after an explicit `START` request, returns
  `START_NOT_STICKY`, and ignores a null restart intent. A notification tap
  opens `MainActivity`. Behavior is API-level dependent:

  | API | Android | Foreground-service behavior |
  | --- | --- | --- |
  | 30 | 11 | Minimum supported. `VpnService` runs; the `FOREGROUND_SERVICE` permission and typed `connectedDevice` service are available. |
  | 33 | 13 | `POST_NOTIFICATIONS` is a runtime permission: without the grant the notification is hidden, but the service keeps running. |
  | 34 | 14 | Typed foreground services are mandatory: `FOREGROUND_SERVICE_CONNECTED_DEVICE` (declared) plus the `connectedDevice` type, or `startForeground` throws. |

  The service is declared with `android:stopWithTask="false"`, so a task
  swipe leaves it running (see the background-healing bullet below). It is not
  sticky across process death: the overlay stops a null restart before it can
  create or update a notification.
  Doze/app-standby and OEM battery managers may defer the service; the
  WireGuard tunnel itself is in-kernel and keeps passing traffic regardless.
- **Android background healing**: the app runs on a process-cached
  `FlutterEngine` (`MainActivity.provideFlutterEngine`,
  `shouldDestroyEngineWithHost = false`), so swiping the task away destroys
  the Activity but not the Dart isolate. Together with the plugin's
  `VpnForegroundService` (`android:stopWithTask="false"`), the background
  health tick (15s while the app is hidden) and the heal → failover ladder
  keep running while the app is "killed". The app's native channels live in
  `TunnelHost` (process scope) so a detached Activity's `cleanUpFlutterEngine`
  cannot cancel them. A true process death (force-stop / OOM) no longer
  resurrects the keep-alive service; the next app launch cold-starts and runs
  `reconcileColdStart`.
- **Android minified bridge**: `TunnelHost` reflects a small, explicit set of
  plugin/backend fields. `android/app/proguard-rules.pro` keeps those field
  names for R8; Flutter's generated plugin rules may still obfuscate the
  owner classes, while production accesses them through `javaClass`. PR CI
  builds a minified release APK and runs the
  `MinifiedTunnelBridgeTest` instrumentation smoke test, so a plugin update
  cannot silently turn handshake, active-peer, or ghost-kill reads into
  unknown/empty results again.
- **iOS/macOS**: the tunnel is a **Network Extension**, so the app itself is
  only half of it. The `networkextension` (Packet Tunnel) and App Group
  entitlements are declared in `ios/Runner/Runner.entitlements` and
  `macos/Runner/{DebugProfile,Release}.entitlements`, but the **extension
  target**, its `WireGuardKitGo` bridge and a provisioning profile carrying
  the entitlement are created in Xcode and are **not** in this repo — see
  [SETUP.md "macOS"](SETUP.md#macos) for the full one-time setup. Both Apple
  platforms need `--dart-define=VPN_PROVIDER_BUNDLE_ID=<ext id>` and
  `--dart-define=VPN_APP_GROUP=group.<id>`; the app fails fast naming the
  missing one rather than letting the plugin fall back to a group no profile
  contains. Unlike Windows/Linux, macOS OAuth returns over the registered
  `boltmesh://` custom scheme (no loopback listener — `flutter_web_auth_2`
  implements macOS with `ASWebAuthenticationSession`).
  A **privileged-helper path also exists for macOS** (`boltmeshd`'s darwin
  backend, a launchd LaunchDaemon), which would remove the Network Extension
  dependency entirely and match Linux/Windows. It cross-compiles and is vetted
  and linted in CI, but the client does not use it yet and it has never run on
  a Mac — see `boltmeshd/README.md` and Platform status.
- **Windows**: hands all privileged work to the `boltmeshd` helper
  (`boltmeshd/`, installed as a LocalSystem service by the Inno Setup `.exe`).
  The plugin still bundles Wintun, `wireguard_svc.exe` and `wireguard.dll`,
  but the GUI no longer calls it and no longer requests elevation: the daemon
  creates/starts the `boltmesh0` tunnel service and answers stage, handshake,
  peer and counters over the named pipe `\\.\pipe\boltmesh\boltmeshd`. The GUI
  authenticates the server before sending a request: the connected pipe's
  server process must be the process the SCM reports for the `boltmeshd`
  service, so an unprivileged process that pre-created the pipe name cannot
  receive the WireGuard config. OAuth
  opens the system browser and returns to an ephemeral loopback listener
  (`http://127.0.0.1:{port}/callback`). Never test a full-tunnel against a
  `localhost`-forwarded API (`API_BASE_URL=http://localhost:8000/v1` over a
  VSCode SSH forward dies with the tunnel — use a LAN/direct URL or run the
  backend on the Windows host). If stranded with no network: use Disconnect
  (it tears the tunnel down locally even when the server is unreachable),
  then `ncpa.cpl` → physical adapter Properties → re-check
  `Internet Protocol Version 4/6` → `route print -4` (no stale `0.0.0.0`
  via `boltmesh0`). Reboot only as a last resort. Privileged-helper failures
  are persisted as JSON lines at `%ProgramData%\BoltMesh\logs\boltmeshd.log`
  (SYSTEM/Administrators only); see `boltmeshd/README.md`. Packaging: see
  [Windows release build](#windows-release-build) (Inno Setup `.exe`).
- **Linux**: hands all privileged work to the `boltmeshd` helper
  (`boltmeshd/`, installed by the deb/rpm, socket-activated, `boltmesh`
  group). The app itself holds no privilege and never runs
  `sudo`/`wg`/`wg-quick`; the daemon needs `wireguard-tools` for `wg-quick`.
  The package enrolls the validated installing account or a unique active
  graphical user when possible; when no trustworthy hint exists or multiple
  users are active, explicitly run
  `sudo /usr/libexec/boltmesh/boltmesh-enroll-user --uid "$(id -u USER)"`.
  Stopping or uninstalling the package tears down the managed interface,
  routes, and resolver state before removing the helper. Persistent helper
  failures land in
  `/var/log/boltmesh/boltmeshd.log` (JSON lines); see
  [`boltmeshd/README.md`](boltmeshd/README.md).
  OAuth uses the same ephemeral loopback listener as Windows
  (`http://127.0.0.1:{port}/callback`) opened in the system browser, so the
  browser must be able to reach `API_BASE_URL` — the packaged deb/rpm pins
  production via `distribute_options.yaml`.
  `linux/assets/boltmesh.png` is maintained by hand (RGBA, transparent
  corners — `flutter_launcher_icons` has no Linux target); keep it a
  512×512 RGBA copy of the app icon or the deb/rpm launcher shows black
  corners.
- **Desktop close-to-tray (Windows/macOS/Linux)**: the window's close button
  hides the window instead of quitting, and the tray/menu-bar icon restores
  it (see `lib/app/desktop_tray.dart` and `lib/core/desktop/`). The menu has a
  Show/Hide toggle, Connect/Disconnect while signed in, and an explicit
  **Quit**; the helper and any live tunnel keep running while hidden, exactly
  as they do on Android. On Linux the icon is a StatusNotifierItem, so it
  needs a panel that hosts them (KDE Plasma and most desktops do; GNOME only
  with the AppIndicator extension, which Ubuntu ships). The Linux build links
  X11/Xi through that plugin, so `flutter build linux` needs the X11/Xi dev
  headers (see [SETUP.md](SETUP.md)). If the tray cannot be
  shown — or on mobile, web and under `flutter test` — close-to-quit is left
  untouched, so a window is never hidden with no way back. On Linux, startup
  and close handling verify that a StatusNotifier host is registered on the
  session bus; Fedora GNOME users need to enable the AppIndicator and
  KStatusNotifierItem Support extension themselves.

## Release versioning

The git tag is the release source of truth. CI derives the `vX.Y.Z` tag into
`pubspec.yaml`'s `version:` (via `tool/set_release_version.dart`, build number
from `GITHUB_RUN_NUMBER`) before every build job, because both the Android
`versionName` and the fastforge package names/versions are read from pubspec.
The checked-in `version: 0.1.0+1` is a dev placeholder and is not meaningful
for tagged artifacts.

The release job also emits supply-chain metadata for every tagged build:
SHA-256 checksums, CycloneDX/SPDX SBOMs, keyless cosign signatures for the Linux
packages, and Sigstore provenance/SBOM attestations (raw bundles included). See
[DEPLOYMENT.md](DEPLOYMENT.md#3-artifacts-and-signing) for what ships and how to
verify it.

## Android release build

Prereqs: JDK 21 (Gradle 9.x cannot run on much newer JDKs — e.g. Java 27
fails with `Unsupported class file major version`) + Android SDK with
platform 36 and build-tools 36:

```sh
sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0"
export ANDROID_HOME=$HOME/android-sdk JAVA_HOME=<path-to-jdk-21>
flutter build appbundle --release
# build/app/outputs/bundle/release/app-release.aab
```

The release is signed with the upload key when `android/key.properties`
exists, and falls back to the debug key otherwise (so `flutter run --release`
works without a keystore). Create both once:

```sh
keytool -genkeypair -v -keystore android/app/upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
cat > android/key.properties <<'EOF'
storeFile=upload-keystore.jks
storePassword=<store password>
keyAlias=upload
keyPassword=<key password>
EOF
```

`storeFile` resolves against the app module, and both files are gitignored
(`android/.gitignore`). CI reads these repo secrets (Settings → Secrets and
variables → Actions):

- `ANDROID_KEYSTORE` — base64 of the `.jks`, unwrapped:
  `base64 -w0 android/app/upload-keystore.jks` (`base64 -i` on macOS).
- `ANDROID_KEYSTORE_PASSWORD` — the keystore password.
- `ANDROID_KEY_PASSWORD` — the key password (defaults to the store password).
- `ANDROID_KEY_ALIAS` — optional, defaults to `upload`.

The `build-android` job fails on a tag when `ANDROID_KEYSTORE` is unset rather
than publish a debug-signed artifact; local builds keep the debug fallback.
Set `REQUIRE_RELEASE_SIGNING=true` (env var, or `-P requireReleaseSigning=true`
to Gradle) to make any build fail instead of silently falling back.

`wireguard_flutter_plus:1.0.7` hardcodes `compileSdkVersion 31` while its
transitive AndroidX deps require >= 34, so `android/build.gradle.kts` bumps
stale plugin modules to 36 (the `flutter.compileSdkVersion` default on
Flutter 3.47) via a `gradle.beforeProject` hook — it must run before AGP's
own afterEvaluate hook or AGP rejects the write as "too late". Delete the
hook if the plugin ships a fixed release. CI (`release.yml` `build-android`
job, on tags) runs this same `flutter build appbundle --release`; the
remaining KGP warning (`flutter_web_auth_2`, `wireguard_flutter_plus`
apply their own Kotlin plugin) is upstream's to fix and doesn't fail
the build.

## Windows release build

Prereqs: Visual Studio 2022 with the "Desktop development with C++" workload,
[Inno Setup 7](https://jrsoftware.org/isdl.php) (the `iscc` compiler; use the
64-bit edition, which installs to `C:\Program Files\Inno Setup 7`), and Go 1.27
(to build `boltmeshd.exe`; the `windows-exe` pre hook does this).

**Inno Setup 7 needs `INNO_SETUP_PATH`.** `flutter_app_packager` resolves
`ISCC.exe` as `INNO_SETUP_PATH`, then the hardcoded
`C:\Program Files (x86)\Inno Setup 6`, then `iscc` on `PATH`. It knows nothing
about Inno 7, so without the variable it falls through to a bare `iscc` that is
not on `PATH` and only fails once it tries to pack the installer:

```powershell
$env:INNO_SETUP_PATH = 'C:\Program Files\Inno Setup 7'
```

**Stop the helper service before packaging.** The staging hook builds
`boltmeshd.exe` into the bundle, and Windows will not let a running image be
overwritten. If the `boltmeshd` service is running from that same bundle
directory — which is what a dev loop usually leaves behind — the hook now fails
loudly instead of quietly packing the *previous* helper:

```powershell
sc stop boltmeshd
```

**`sh` has to be on `PATH`.** fastforge runs *every* packaging hook through
`sh -c`, on Windows too (`flutter_app_packager._runHooks`), so the `windows-exe`
pre/post hooks cannot run without it. CI gets it from Git for Windows, which
installs `sh.exe` under `bin\` and `usr\bin\` but adds neither to `PATH` — so a
plain developer shell fails with `'sh' is not recognized` part-way into
`fastforge release`. Put Git's `bin` on `PATH` for the session:

```powershell
$env:PATH = "C:\Program Files\Git\bin;$env:PATH"
```

Chocolatey publishes no 7.x package, so `choco install innosetup` still yields
6.x. Install 7 from the [downloads page][inno] or with
`winget install --id JRSoftware.InnoSetup.7`. The `build-windows` job pins
7.1.0 by SHA-256 and checks the vendor's Authenticode signature before running
it.

[inno]: https://jrsoftware.org/isdl.php

```powershell
flutter config --enable-windows-desktop
dart pub global activate fastforge
# then add %LOCALAPPDATA%\Pub\Cache\bin to PATH (once)
fastforge release --name=production
# dist/<version>/boltmesh-<version>-windows-setup.exe
```

To check the Windows build and its privileged helper without packaging
anything, run `pwsh -File tool/verify_windows.ps1` (see [Tests](#tests)); it is
the script the `validate-windows` CI job runs.

The Windows package is an Inno Setup `.exe`, not MSIX. The pre-packing hook
`windows/packaging/stage_boltmeshd.ps1` builds `boltmeshd.exe` into the
bundle, so the installer ships the helper next to `boltmesh.exe` (and the
plugin-bundled `wireguard_svc.exe`/`wireguard.dll`). It also stages the
vendored `wintun.dll` the obfuscated AmneziaWG data plane needs: nothing
embeds that driver, and the helper reads a hash-verified copy from beside
itself and pins it into System32 before loading it, so a bundle without it
fails every obfuscated connect at runtime while stock connects keep working.
`bash tool/verify_native.sh` asserts both that the vendored file still matches
the Go hash pin and that the hook still stages it, because no test sees an
installed bundle. Then
`windows/packaging/exe/boltmesh.iss` installs and starts the helper service;
uninstall quiesces the daemon, removes the tunnel service and private-key
config, and then removes the helper service. The Flutter-free
`helper_pipe_io_tests` target is `EXCLUDE_FROM_ALL` so it is never built into
that bundle (fastforge copies the runner output directory verbatim into the
installer); the `validate-windows` job builds it by name. If the helper binary
is missing (a damaged or partially removed install), the uninstaller fails
closed: it probes for the `boltmeshd`/`boltmesh0` services and the private-key
config and aborts when any survives, instead of completing with privileged
state left behind. The GUI no longer requests
elevation: the app
CMake drops the plugin's `requireAdministrator` link flag, and the privileged
work lives in the helper. The installer itself is per-machine into
`%ProgramFiles%\BoltMesh` and still runs elevated; the destination is fixed
(the directory page is disabled and a `/DIR` override outside the protected
Program Files tree aborts setup), so the LocalSystem helper and tunnel services
cannot load their binaries from a user-writable directory. Config:
`windows/packaging/exe/make_config.yaml`.
`fastforge release --name=production` also lists the Linux jobs but skips
those unsupported on the host, so the same command works from either OS.

The package is **x64-only**: `wireguard_flutter_plus` bundles only amd64
`tunnel.dll`/`wireguard.dll`, so the staging hook rejects an arm64 bundle and
the installer is pinned to Inno's `x64compatible`. An x64 install still runs
on Windows on ARM under emulation. The helper's `make build-windows-arm64`
target remains a standalone artifact and is not part of this package.

### Code signing (Authenticode)

`windows/packaging/sign.ps1` runs as the `windows-exe` job's pre/post hooks:
it signs every executable in the freshly built bundle (the app, the
`boltmeshd` helper, and the plugin-bundled `wireguard_svc.exe`) between the
Flutter build and Inno packing, then signs the installer after packing,
timestamped via RFC 3161 (default `http://timestamp.digicert.com`, override
`WINDOWS_TIMESTAMP_URL`). Signing every bundled executable as well as the setup
exe means the signature covers everything the installer later launches — the
LocalSystem helper runs `wireguard_svc.exe` from `{app}`, so it is signed too.

CI reads a base64 `.pfx` from two repo secrets (Settings → Secrets and
variables → Actions):

- `WINDOWS_CERTIFICATE` — base64 of the `.pfx`:
  `[Convert]::ToBase64String([IO.File]::ReadAllBytes('cert.pfx'))` on one line.
- `WINDOWS_CERTIFICATE_PASSWORD` — the `.pfx` password.

The `build-windows` job runs only on tags and fails when
`WINDOWS_CERTIFICATE` is unset rather than publish an unsigned installer,
mirroring `build-android`'s keystore gate; a secret that is set but unusable
also fails the release. Local `fastforge` builds still skip signing with a
warning when `WINDOWS_CERTIFICATE_PATH` is unset. To sign locally, either set
`WINDOWS_CERTIFICATE_PATH` + `WINDOWS_CERTIFICATE_PASSWORD` or pass them
explicitly:

```powershell
pwsh -File windows/packaging/sign.ps1 `
  -Path build/windows/x64/runner/Release/boltmesh.exe `
  -CertificatePath cert.pfx -CertificatePassword hunter2
```

Certificates are never committed (`*.pfx`/`*.p12` are gitignored). An
exportable OV certificate works but only builds SmartScreen reputation over
time; EV (immediate reputation) ships on a hardware token or cloud HSM and
cannot be exported to a `.pfx`, so for those swap the `signtool sign` line for
the provider's tool/action — [Azure Trusted Signing](https://learn.microsoft.com/azure/trusted-signing/)
(`azure/trusted-signing-action`), DigiCert KeyLocker or SSL.com eSigner. The
rest of the pipeline (which files, when, verify) is unchanged.

## Flows

- Auth: `POST /auth/login` (form: `grant_type=password`, `username`,
  `password`, always-persistent `remember_me=true`) → access JWT (15 min)
  - `refresh_token` HttpOnly cookie, both in secure storage. The session
  persists until Log Out or server-side revocation (no Remember me
  option). OAuth (Google/GitHub buttons): system browser opens
  `GET /auth/{provider}?platform=native` (desktop adds a `native_callback`
  loopback address and listens on it; mobile uses the `boltmesh://`
  custom scheme), provider consent redirects back with the single-use
  code (`boltmesh://auth/callback?code=...`, scheme registered in
  `AndroidManifest.xml` + iOS/macOS `Info.plist`), the app exchanges the
  single-use code at `POST /auth/native/exchange` and resolves the display
  name via `GET /users`. Closing the browser/tab cancels silently.
  Access renews proactively
  before expiry plus once per 401 (single-flight shared retry); revoked
  sessions return to the login gate. `POST /auth/logout` revokes;
  Settings shows the signed-in user with Log out.

- Provision once: fresh X25519 keypair → `POST /vpn-devices`
  `{name, platform(enum), public_key, [region_id|server_id]}` with a
  persisted `Idempotency-Key` UUID. Private key stays in secure storage.
- Connect: `GET /vpn-devices/{id}/config` (bound) else fresh keypair +
  `POST .../connect` (neither target = global auto-pick). 409
  already-connected → re-read `config`. `config` and every bind response
  echo the active peer's `client_public_key`; when it differs from the stored
  keypair (a lost bind response, or a rolled-back store), the client rotates
  in place to a fresh key before dialing instead of starting a tunnel the
  server can never handshake.
- Switch: fresh keypair + `POST .../switch` with **exactly one** of
  `region_id`/`server_id`. Auto = lowest-`active_peers` region from
  `GET /vpn-regions` (cached 60s), then switch with its `region_id`.
- Disconnect: graceful `stopVpn()` (3s budget, one automated hard-kill
  retry on timeout with no user input) then `POST .../disconnect` (no body,
  idempotent, works with lapsed subscription). On Linux/Windows the helper
  transport forwards each call's operation/cancellation deadline; closing
  the transport cancels the daemon request, and a retry waits for the
  original tunnel operation instead of racing its lock.
- Rotate: `POST /vpn-devices/{id}/rotate-keys` with a fresh public key
  (same server + IP, tunnel restarts on the new config). Automatic every
  24h of connected time (counted in status polls).
- Status: `GET /vpn-devices/{id}/status` polled every 60s while connected
  (never faster — session-budgeted rate limit). `suspended` auto-disconnects
  (lapsed subscription / disabled device); 404 forgets the device so the
  next connect reprovisions.
- Conf mirrors `build_wireguard_conf_string`: host-prefix Address
  (`/32` IPv4, `/128` IPv6), bracketed IPv6 endpoint `host:port`,
  `AllowedIPs 0.0.0.0/0, ::/0`, keepalive 25.
- Self-recovery (auto-heal): a local, backend-free health tick (10s
  foreground, 15s hidden) reads the OS stage, the WireGuard handshake and a
  `/32`-pinned in-tunnel DNS echo (`wg_dns`). A **stall** is a supported
  reader's stale handshake (`isHandshakeStale`: observed >150s ≈ one 120s
  keepalive-triggered rekey + 30s margin; "no handshake yet" >30s after the
  start; an unsupported reader's null never counts) or a degraded OS stage,
  corroborated by backend unreachability — ≥1 failed status poll or no
  successful poll in 15s (never-polled counts as quiet). A live in-tunnel
  echo suppresses healing entirely, and a recently proven-reachable backend
  never lets a stale handshake act on its own — with one deliberate
  exception: past the **hard ceiling** (180s ≈ 1.5 rekey cycles), or when a
  supported reader reports no handshake for 60s after a (re)start, the
  handshake drives recovery *without* corroboration. That keeps a filtered
  network (WireGuard UDP blocked/zero-rated while the HTTPS API stays
  reachable by another route) from suppressing the ladder forever; a merely-late
  rekey is well inside the ceiling, and a live echo still wins. On platforms
  with no handshake reader (Apple) detection stays degraded-stage dependent:
  a null read is absence of evidence and never heals on its own.
- Echo shortcut: the in-tunnel DNS echo is read only when it can change a
  decision — once the handshake is older than 30s, on a degraded stage, or
  when the handshake is unknown — so a healthy peer sends no probe datagram
  at all (it was one UDP echo per tick, ~6/min foreground). Two consecutive
  *performed-dead* echoes (never null) then shorten the observed-handshake
  window to 30s: the data path is confirmed dead ~40s after the last
  handshake foreground (~45s hidden) instead of waiting out the full 150s;
  deaths after the gate are unaffected. A handshake inside the 25s keepalive
  still wins, and the run resets on any skipped/alive/unknown echo, a
  successful status poll while the handshake is fresh (or on a platform with
  no reader), or a tunnel restart. A *transition* into a degraded
  OS stage also kicks an immediate health tick (coalesced through the tick's
  single-flight guard) instead of waiting out the cadence, so a stall the OS
  already reported is corroborated on the first tick.
- Diagnostic probes run only once a stall is suspected and are read-only —
  they never consume heal/move budgets: physical link → in-tunnel echo →
  control-plane probe. The control-plane probe uses its own client but still
  follows OS routing, so while a tunnel is up it may travel through the very
  path that is dead; it is therefore only consulted for *ambiguous* evidence.
  Positive local path-death evidence — two *performed-dead* echoes, a
  hard-stale handshake, or a backend `server-status` "node not online"
  verdict — fast-tracks straight to a server move, stopping the proven-dead
  tunnel first so region discovery and the switch POST travel direct. Every
  post-heal escalation is likewise path-dead: a stall that survived a
  same-server restart stops the tunnel before discovery instead of probing a
  path already known bad. Otherwise the ladder is cheap-restart-first (a
  single dead echo, or a null echo with only a reachable control plane,
  stays on the local ladder — absence of evidence is not death); the
  in-tunnel probes that remain on the recovery path use a short 3s budget,
  while manual switch/rotate keep the 10s one.
- Ladder & budgets: offline restart on the cached config (zero API calls) →
  after one same-server restart, the next corroborated stall moves servers
  (same region first, then global lowest-load; an explicit pin only biases
  that order — if its region is dead or gone, the move roams and the pin
  drops back to Auto). At most 3 moves per outage window, then two trailing
  same-server restarts, after which recovery is surfaced as an actionable
  error instead of restarting a proven-dead config forever. A successful
  status poll ends the outage and restores the budget only when the handshake
  is fresh: a poll that answers over another route while the WireGuard path
  stays dead does not reset the ladder, so it still escalates. A 429
  holds the ladder until its window reopens. A 5s post-(re)connect status
  check (re-armed after every restart) arms corroboration early, so a hard
  kill escalates in ~15s rather than a full poll interval. There is no
  same-server config-refresh rung: a reboot-rotated server key is picked up
  by a server move or a manual reconnect.
- Transport ladder: where it *starts* is the serving node's own floor, and a path
  the health policy confirmed dead *locally* is rebuilt one rung lower per heal, so
  an unobstructed network pays nothing. The server states which rungs it serves
  rather than the client deriving them from which optional fields are set — see
  *Transport list* below. `native` (platform WireGuard) → `awg` (in-process
  AmneziaWG, Linux, Windows, and Android) → `stream` (the tunnel's datagrams inside
  a TLS session to the node, Linux, Windows, and Android).
  - The floor rule, stated exactly: **the floor is the cheapest rung the server
    advertises that this platform can run.** Not "the cheapest rung this platform
    can run" — that is the derivation this replaced, and with every server
    serving both formats it floored Apple to `awg` and made the product unusable
    there. Scoped to the *advertised list*, a dual-format server floors every
    platform to `native`, because `native` is in the list and every platform can
    run it. A server serving only `awg` and `stream` floors an Apple device to
    `stream`, which is the only thing it can start there.
  - The floor is re-derived on every start, so a server move follows the new
    node's advertised list and never keeps a rung the new node does not serve. A
    move onto a node that *does* advertise the sticky rung keeps it, so a roam is
    not charged for the walk again.
  - A rung is selected only when the node advertises it, this platform can run it,
    and (for `stream`) the data plane advertises the `stream-transport` token — the
    `boltmeshd` daemon advertises it only on builds whose `up` would honour the
    spec, and the Android adapter advertises it for its in-process native bridge,
    so an older helper keeps the rung off the ladder instead of selecting a rung
    guaranteed to be refused. An entry the client cannot assemble — an `awg` entry
    with no address on the obfuscated overlay, a `stream` entry whose credential
    fails the daemon's own size checks — counts as not advertised, because a
    conf this build cannot build is indistinguishable on-device from a blocked
    network.
  - `_applyRung` refuses exactly one case now: a payload with no rung this build
    can start at all, where any start would be a guess at what the node runs. It
    is no longer the path a platform without an obfuscated data plane takes, since
    such a node advertises `native` and is started on it.
  - Each rung has its own node port *and its own overlay address*. A server serving
    the `awg` rung runs two devices on one host, and they cannot share a network:
    both hold every peer's route, so the kernel would keep one and the other
    device's replies would leave on a link holding no session for that peer. So the
    dial payload carries `awg_assigned_ip`/`awg_dns` beside `assigned_ip`/`wg_dns`,
    both null on a server that does not offer the rung, and the conf claims
    whichever pair the rung points at. Getting this wrong is not a cosmetic
    mistake — a conf aimed at the wrong port puts a handshake on the wire at a
    device that cannot read it, and one claiming the wrong address handshakes and
    then blackholes every packet; both read to the health ladder as a blocked
    network rather than a wrong setting.
  - The two lower rungs have different platform reach. The **stream** transport
  is a bridge plus a way to keep the bridge's own egress off the tunnel it
  carries. The bridge is the same `boltmesh/stream` code everywhere; what
  differs is the bypass. On Linux and Windows it is a `/32` through the physical
  interface installed *before* the tunnel's own routes exist — on Linux ahead of
  `wg-quick` (and repeated in each table `wg-quick`'s fwmark policy rules
  select), on Windows ahead of the tunnel service (where the longest-prefix
  match wins outright, so one route is enough). Android has no route to pin:
  `VpnService.protect` exempts the bridge's TLS socket from the tunnel, so the
  rung reaches every server there, and the bridge runs on the host's VpnService. The
  **AWG** data
  plane runs in-process on Linux and Windows, and through Android's VpnService
  TUN. Windows cannot use its stock kernel service for AWG because that service
  has no concept of the obfuscation directives. The desktop adapters are Linux
  `/dev/net/tun` and Windows Wintun; Android uses the official AWG Android
  backend with the same pinned AmneziaWG Go engine. The wire format is shared;
  platform adapters and route/resolver setup differ. Two
  platform details are worth knowing because they are invisible from the client:
  the Wintun DLL is copied to System32 and pinned by content hash before the
  device loads it (the upstream binding resolves it by bare name, and the daemon
  runs as LocalSystem), and the tunnel route is installed with `INFINITE_LIFETIME`
  because a zero lifetime is an expiry of *now* — the route appears installed and
  the stack routes around it.
  The two gates are independent by design. The `stream` gate does *not* require
  the obfuscated data plane — the node's bridge injects into its stock device, so
  a stream session carries stock datagrams whatever else the node serves — which
  is what makes the stream rung the widest-reaching one. A platform with neither
  gate, macOS today, still reaches every server on `native`, and reaches a node
  serving only `awg` and `stream` on `stream`. Region selection no longer filters
  on format at all: every server advertises `native`, so every region is dialable
  everywhere and a per-region filter could only ever exclude regions that would
  have worked. Demotion rides the existing heal (no new timer or state, and the
  heal budget is the ladder's whole walk) and is sticky across connects — a
  reconnect preserves a demotion but never causes one. The one exception is deliberate:
  after `rungPromotionHealthyFor` (24h) of positively healthy traffic the tick
  may probe a single cheaper rung, because a blocked transport is usually
  temporary (a captive portal, a hotel network, one blocked port) and a process
  that demoted once would otherwise pay the expensive rung for the rest of its
  life. The last working rung stays armed as the rollback target until the
  candidate proves live — a fresh handshake or a live gateway echo — and reverts
  within `rungPromotionProbeTimeout` (45s), so a probe costs one controlled
  restart and one stale connection at worst.
  One rung at a time — a start runs on a single rung. The **stream** rung's inner
  format is *always* stock, whatever else the node serves: its bridge injects
  into the stock device, so a session's datagrams have to be readable there. A
  conf carrying the AWG directives inside the TLS session would reach a device
  that does not speak them. Only the `awg` rung builds an obfuscated conf, and
  only against the address on the obfuscated overlay.
  The rung step is the next entry in the advertised list, not the next value in a
  fixed cost order: a node serving stock and stream demotes straight to stream,
  and one whose `awg` entry this platform cannot run skips it. That also makes the
  promotion probe structurally non-trivial — every entry carries the port and
  payload its own rung needs, so a rung below can never build the identical conf
  the rung above just proved dead.
  The rung step comes *before* the server move, because Layer 1 cannot tell a
  blocked transport from a dead node: a middlebox dropping this rung's traffic
  is indistinguishable from a powered-off server at the echo and the handshake.
  `serverDown` is the backend-attributed verdict that the node itself is gone,
  so that skips the ladder and moves straight on; anything else takes the
  cheap local retry first. Where the server serves no lower rung there is
  nothing to step to, so a heal would only rebuild the same config on the same
  rung and the old move-first escalation is kept unchanged. One step is gated
  on reachability: a demotion that would land on `stream` first probes that
  rung's TLS port over TCP after the heal's tunnel stop (direct network — a
  probe issued while the tunnel still routes traffic would travel the dead
  path it is meant to judge), and an unreachable port skips the restart and
  moves servers instead. An unknown probe fails open onto the demote, and a
  spent move budget keeps the restart.
  A rung step is licensed by *local* path-death evidence, not by the control
  plane: a performed-dead echo run, a hard-stale handshake, or a handshake that
  never completed past `firstHandshakeGrace` (30s). The control-plane probe is
  deliberately not required, because in a full tunnel it is routed through the
  very rung under test — a blocked transport kills the probe too — so requiring
  it left the ladder unable to walk exactly when it exists for. Evidence is
  graded by the cost of the action it buys. A handshake that never completed at
  all is real local evidence, because a peer that never answered six WireGuard
  handshake retries is not idle, and that licenses the cheap rung step at 30s.
  The same evidence does *not* license an uncorroborated server move: a
  fast-track move stops the tunnel and spends the move budget without asking
  anyone, so it waits for `hardFirstHandshakeCeiling` (45s), which measures from
  the tunnel's start and is deliberately independent of how many times the
  tunnel has been restarted. Only a bare single dead echo still needs the
  control plane to answer before it acts. That distinction is the whole of the
  ladder's ordering, and it lives in one pure decision
  (`domain/ladder_policy.dart`) with the evidence table in
  `test/features/vpn/domain/ladder_policy_test.dart`.
  The heal budget is two restarts per incident (`maxHealsPerIncident`), one rung
  per restart, so a node serving `native`, `awg` and `stream` is walked to the
  bottom of its own list inside a single incident: a middlebox that fingerprints
  WireGuard takes stock and obfuscated together while leaving an ordinary TLS
  session alone, so stopping after one step would move servers on exactly the
  network where the rung that would have worked was never tried. Once the budget
  is spent the same confirmed-dead evidence escalates to the server move, and a
  stall no rung fixes falls through to the existing escalation (move, then the
  surfaced recovery error), never a new failure mode. It is the *walk* that is
  bounded, not the retries — a node with one rung below gets exactly one step,
  and a heal with nothing below spends itself on the current rung as before.
  After the move budget is spent the trailing budget (`maxHealsAfterMoveBudget`)
  takes over at one restart: with nowhere to move, the second rung is no longer
  a cheap alternative to a move but just another restart of a path already proven
  dead. The rung is sticky across the reconnects that reset the budget, so a
  server offering both AWG and stream stays on stream once it has stepped down —
  a reconnect preserves a demotion but never causes one, and a roam onto a node
  that also serves the sticky rung keeps it rather than paying for the walk
  again.
  - Bypass-route lifetime. The pinned routes outlive the daemon that installed
    them, so the set is recorded beside the config and written *before* each
    install — a crash in between would otherwise leak a `/32` nothing accounts
    for, while the reverse order would only strand a record naming a route that
    was never installed. A restarted daemon sweeps from that record rather than
    from memory. This matters because a stranded `/32` is not a cosmetic
    leftover: it exempts one destination from the tunnel on every connect
    afterwards. The record holds routes only, never the PSK.
  - What the stream rung actually is. Not a second VPN and not a plain TCP
    wrapper: it is the *same* WireGuard tunnel with its UDP datagrams carried
    inside a TLS 1.3 session to the node — length-prefixed frames over TLS,
    nothing else — so a network that blocks or fingerprints WireGuard's own UDP
    sees one ordinary HTTPS connection instead of a tunnel. Four consequences
    follow.
    - The tunnel is still WireGuard end to end. The conf is a normal one with a
      loopback peer endpoint, so every local signal the health ladder reads —
      handshake, in-tunnel gateway echo, byte counters — behaves exactly as on
      the rungs above. Only the transport underneath changed, which is also why
      a rung change is just a different conf plus a transport spec, never a
      different recovery path.
    - It is the most expensive rung, and its cost is structural rather than
      merely slower: a TLS session and a persistent TCP connection per tunnel,
      head-of-line blocking across it, and a session drop that stalls the tunnel
      until the bridge reconnects with backoff (for as long as the tunnel
      lives). That is why it is last on the ladder, and why AWG remains the
      primary defence — this is the rung for networks where that defence did not
      work.
    - The client does not assemble the bridge itself, which is why selecting the
      rung needs more than a credential: a data plane that can run it — the
      privileged helper in-process on Linux and Windows, the host's VpnService on
      Android — the `stream-transport` capability token that data
      plane advertises, and a usable credential. On the desktop the daemon owns
      the bridge for the tunnel's lifetime because it owns the tunnel's
      lifecycle, and is the only party that can keep the bridge's own egress out
      of the tunnel it carries.
    - The bridge injects into the node's **stock** tunnel device, so the inner
      format is always stock WireGuard whatever else that node serves, and the
      conf claims the stock overlay's address and resolver. This is what makes the
      rung the most widely available one: a platform with no obfuscated data plane
      (macOS) can still use it against a node serving it, and a conf carrying the
      AWG directives inside the session would reach a device that does not speak
      them.
    - The node is pinned, not discovered: a certificate SPKI pin plus a
      per-device PSK (below), so there is no CA chain to trust and no second
      protocol to speak. It is also deliberately not an anti-probing
      construction — the node presents its own certificate, so an active prober
      sees a real TLS server that does not complete the handshake without the
      key.

    Wire format, the two-way authentication and the routing rules that keep the
    bridge out of its own tunnel: `boltmeshd/README.md` → *Stream transport*.
    Platform reach and the bypass-route mechanics: the sibling bullet above.
  - Transport list. `config` and every bind response carry an ordered `transports`
    array — one entry per rung this node serves this device on, cheapest first,
    each carrying that rung's own port and the payload it needs:

    ```json
    "transports": [
      { "rung": "native", "port": 51820 },
      { "rung": "awg", "port": 51821, "params": { "jc": 3, "h1": [115, 120] } },
      {
        "rung": "stream",
        "port": 443,
        "credential": {
          "server": "vpn.example.net:443",
          "server_name": "vpn.example.net",
          "spki_sha256": ["<base64 sha256 of the node's leaf SPKI>"],
          "psk": "<base64, 32 bytes>",
          "client_id": "<base64, 16 bytes>"
        }
      }
    ]
    ```

    This replaced three independently-present fields (`obfuscation`, `stream`, a
    nullable `awg_port`) that a client could only read by *deriving* which rungs
    existed from which of them were set — a private encoding of the same fact, and
    one that had to be kept in step with the withholding rules on the control
    plane's side. Order is the cost order, so "the next rung down" is the next
    entry and a client walks the list instead of reconstructing a ladder it has to
    agree with the server about separately. Absence is the single meaning of "not
    served": a rung the control plane withheld and a rung the server never had are
    the same thing to the client, which is exactly right, because on-device a
    conf that cannot be built is indistinguishable from a blocked network. The
    schema refuses an entry whose payload does not match its rung, so a credential
    can never ride the `awg` entry and a `stream` entry can never be emitted
    without one.

    `native` always leads, because every node runs a stock device. That is what
    makes the floor rule a lookup rather than a guess, and what makes every region
    dialable on every platform.

    The `stream` entry's `credential` is per-device — the PSK authenticates one
    tunnel endpoint to one node — so `transports` stays on the dial payload and
    *not* on the region list, which every client of a region fetches.
  - Stream credential. `server` is where to dial — the node's `endpoint`, or its
    public IP when it has none — while `server_name` is what the handshake claims.
    They are usually the same string, because the SNI is the node's `endpoint` too,
    but they have different requirements and the difference is load-bearing: a dial
    target only has to *resolve*, so an address is fine, while RFC 6066's SNI
    extension carries a *hostname*, so a client sends no SNI at all for an IP
    literal — a passively observable tell no browser produces. So a node with no DNS
    endpoint gets no stream rung rather than an SNI-less one, and the control plane
    withholds the whole entry instead of serving a credential whose SNI cannot be
    sent. The SNI is never resolved by the node, so it needs no DNS of its own.

    Every field is size-validated client-side against the same values the
    daemon enforces, so a malformed credential is never turned into a
    transport — `isUsable` is the only gate, and a failing entry is simply not an
    offer. On this rung the client allocates
    two free loopback ports per start: the peer's `Endpoint` is rewritten to
    the bridge's listen address, and the conf pins `ListenPort` to the port the
    bridge delivers to (an interface left at `0` takes an ephemeral port
    nothing can guess). The spec rides the helper's `up`; the PSK never reaches
    a log, and the loopback bind is what keeps the privileged daemon from
    relaying for anyone.
- Byte counters are display-only (Home card) and never drive heals.
- OS link transitions are watched (`NetworkMonitor.linkChanges`): losing
  the link raises the no-network banner at once, and a returning link runs
  the same resume catch-up (backend-free health tick, then a status poll
  only when the snapshot is stale) immediately instead of waiting out the
  tick.

## Handshake readers

`wireguard_flutter_plus` exposes only byte counters, so the app reads
handshakes through its own channel, `com.boltmesh/handshake` →
`getLastHandshake` (the plugin is never forked). Contract:
`getLastHandshake` returns epoch seconds (double) of the last completed
handshake, or null when unknown (null never heals — only the
degraded-stage path acts). Dart side: `lib/features/vpn/data/` —
`tunnel_adapter.dart`, whose `handshakeReaderSupported` gates the
never-handshook branch. Every `isHandshakeStale` call site must pass it: the
default is `true`, which reads a permanent null as "never handshook" and tears
down a live tunnel on exactly the platforms that have no reader.

- **Linux and Windows**: work today via the privileged `boltmeshd` helper
  (`boltmeshd/`). On Linux it reads the peer handshake with `wgctrl` and
  answers over its Unix socket; on Windows it reads `WireGuardGetConfiguration`
  from the plugin-bundled `wireguard.dll` on adapter `boltmesh0` and answers
  over its named pipe. Both convert the newest peer to unix seconds
  (`(ft - 116444736000000000) / 10000000` on Windows) and resolve
  `getActivePeer`/`killGhost` from the same status/`down` path. The app itself
  never runs `wg` or the SCM; see `helper_tunnel_adapter.dart`.
- **Android**: works today. `MainActivity.kt` reaches the plugin's
  `GoBackend` reflectively (`futureBackend` + `tunnel`, no fork) and
  returns the newest peer `latestHandshakeEpochMillis / 1000`; any failure
  resolves as null (unknown). It deliberately does *not* read the plugin's
  private `config` field: the plugin never re-assigns it on `connect` (and
  clears it on every `disconnect`), so after any reconnect it is null even
  though the tunnel is live. The config needed for ghost-kill/active-peer is
  resolved from the plugin's own `vpn_prefs/last_used_config` instead.
- **Windows**: works today through the helper (see above); the GUI-side
  `runner/helper_pipe.cpp` only shuttles the JSON exchange over the named pipe
  (Dart has no Windows named-pipe client) and the daemon owns the reads.
- **iOS/macOS**: **not implemented; reads are unknown.** The app side would
  send `sendProviderMessage("getHandshake")` over the `NETunnelProviderSession`
  (the pattern the plugin uses for `getStats`) and the Packet Tunnel extension
  would answer with the WireGuardKit peer handshake epoch. Neither half is
  written, and the extension target does not exist (see Platform status).
- **macOS, via the helper instead**: `boltmeshd`'s darwin backend reads the
  peer table over the same UAPI `get=1` exchange it configures the device
  with, so the handshake needs no extension-side code — but the client does not
  use the macOS helper yet, so this is not wired up. A null handshake on Apple
  is absence of evidence and never heals on its own; only a degraded OS stage
  acts. See the reader-support gate in `lib/features/vpn/state/`.

## Tests

```sh
# The root Makefile wraps these: `make check` runs the CI order end to end,
# and `make test`, `make coverage`, `make analyze`, `make generated`,
# `make format-check`, `make verify-native` cover them one at a time.
flutter test
# Coverage (report-only unless the floor is passed):
flutter test --coverage && bash tool/coverage_gate.sh 80

# The rest of what CI enforces locally:
flutter analyze --fatal-infos
dart format --set-exit-if-changed lib test
bash tool/check_generated.sh
# Native-platform contracts (systemd units + staged Linux payload, the
# Android manifest the background tunnel needs, the Windows helper channel and
# a mingw-w64 cross-compile of the Windows runner C++ test):
bash tool/verify_native.sh
# The Windows half, which only a Windows host can run (native runner build, the
# named-pipe transport test, the Windows-tagged boltmeshd tests, and the
# packaging staging hook). Same script the validate-windows CI job runs:
pwsh -File tool/verify_windows.ps1
# Minified-release Android bridge and API 30 connect smoke tests (with an emulator running):
(cd android && ./gradlew :app:connectedReleaseAndroidTest)
```

The Go helper has its own gates (`boltmeshd/`), including the two that keep the
build-tagged backends from rotting invisibly on a Linux host:

```sh
cd boltmeshd
go test ./...          # host-platform suite
make lint-darwin       # golangci-lint with GOOS=darwin
make test-darwin       # go vet: type-checks the darwin files AND their tests
make build-darwin      # cross-compiles darwin/amd64 + darwin/arm64
```

`make lint`, `lint-windows` and `lint-darwin` (and their pre-commit hooks) need
**golangci-lint v2** — the v1 line is EOL and cannot target Go 1.27. Install it
with `go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.14.0`
(matching the version the `validate-boltmeshd` job pins); a different v2 release
can report differently from CI.

`make test-darwin` type-checks the darwin-tagged tests but cannot **run** them:
they need a macOS host with a `utun` interface and root. There is no Apple CI
runner, so the macOS data plane has no executed test.

`tool/check_generated.sh` regenerates `flutter gen-l10n` + `build_runner`
output and fails on drift: those files are excluded from analysis, so a stale
one would otherwise ship green. `tool/coverage_gate.sh` enforces a floor
(currently 80%) on hand-written lines only — generated code is excluded.
`tool/verify_native.sh` covers checks the Dart suite cannot reach (see the
`validate-native` CI job). Timer behaviour is tested with `package:fake_async`
(`async.elapse`), never real sleeps, so the suite is deterministic and fast.

The Windows named-pipe transport is covered by a Flutter-free C++ test
(`windows/runner/tests/helper_pipe_io_test.cpp`, built as the
`EXCLUDE_FROM_ALL` `helper_pipe_io_tests` target and run by the
`validate-windows` job, which builds it by name so it never enters the
installer bundle);
`tool/verify_native.sh` also cross-compiles that test with mingw-w64 on Linux,
so a Windows-only C++ break fails the `validate-native` job too. It is not
executed on Linux — the test drives overlapped named-pipe I/O, which Wine
emulates incompletely. Android is
additionally checked by `./gradlew :app:lintDebug` and the minified-release
`MinifiedTunnelBridgeTest` plus API 30 `WireGuardConnectSmokeTest`
instrumentation tests in `validate-android`. The Android CI matrix runs the
release smoke tests on API 30 and 35.

Apple is the one platform with no executed test of any kind — no emulator, no
simulator, no runner. What CI does instead is compile and analyse: the
`validate-boltmeshd` job cross-compiles the helper for `darwin/amd64` and
`darwin/arm64` and runs `golangci-lint` with `GOOS=darwin`, and
`verify_native.sh` asserts the Apple entitlements. The platform-independent
UAPI translation the macOS backend depends on *is* unit-tested on Linux. See
Platform status.

Test paths mirror `lib/` (e.g. `flutter test
test/features/vpn/data/wg_conf_test.dart`). Shared doubles live in
`test/support/fakes.dart` (`FakeTunnel`, `FakeDeviceStore`, `FakeKeys`, plus
the gateway/control/network probe fakes), and the state suites layer their
common fixtures on `test/support/vpn_harness.dart` (the recording Dio, the
`dialJson`/status payloads, the backend-error factories, the fixed probe
doubles). Files alias the stateless doubles with `typedef` and declare only
the delta they need as a subclass, so call sites stay uniform:

```dart
class FakeTunnel extends support.FakeTunnel {
  FakeTunnel(List<String> events)
    : super(events: events, stageValue: VpnStage.disconnected);
}
```

Two invariants keep that working:

- The controller's public methods (`connect`, `switchServer`, `rotateKeys`,
  `pollStatusOnce`, …) stay **instance methods** on `ConnectionController`,
  never extension members: `flutter_riverpod` exposes the class and Dart
  resolves extensions statically, so an override in a test/preview subclass
  would be silently bypassed. Each one delegates to its implementation in the
  `conn_*.dart` part files under `lib/features/vpn/state/` (`provision`,
  `connect`, `lifecycle`, `poll`, `health`, `tunnel`, `stage`, `coldstart`,
  `transport`, `switch`, `recovery`); `resume_coordinator.dart` owns
  startup/resume orchestration and `cold_restore_watch.dart` the cold-restore
  value object.
- Those part-file extensions cannot touch Riverpod's `@protected` `ref`/`state`
  directly (the analyzer rejects it) — they go through the class-level
  accessors (`snap`, `_api`, `_device`, `_tunnel`, `_networkMonitor`, …).
