# BoltMesh Client

WireGuard VPN client. Backend contract lives in the
[`backend`](https://github.com/boltmesh-labs/backend) repo (`app/vpn/`; user
routes `/vpn-devices`, `/vpn-regions` under `/v1`).

## Prereqs

Setting up a fresh machine (per-OS toolchains, emulator, `boltmeshd` dev
loop): see [SETUP.md](SETUP.md).

- Flutter SDK ≥ 3.47 (`flutter --version`).
- Running backend (`podman-compose up -d` from the
  [`infra`](https://github.com/boltmesh-labs/infra) repo) + a user account
  (`POST /v1/auth/register`, then log in from the app's login screen).

## First-time platform scaffolding

`lib/` + `pubspec.yaml` are checked in; native shells are generated once:

```sh
flutter create --org com.boltmesh --project-name boltmesh .
flutter pub get
```

`flutter create .` only fills in missing `android/ ios/ macos/ windows/ linux/`
folders and never overwrites `lib/`.

## Run

```sh
# API_BASE_URL defaults to https://api.boltmesh.mooo.com/v1 (production);
# point it at the local stack with:
flutter run --dart-define=API_BASE_URL=http://localhost:8000/v1
# iOS/macOS Network Extension target id:
# --dart-define=VPN_PROVIDER_BUNDLE_ID=com.boltmesh.app.WGExtension
# optional public-key (SPKI) pin(s): comma-separated base64 SHA-256 of the
# server cert's SubjectPublicKeyInfo (survives cert renewal while the key is
# reused; compute with `openssl x509 -pubkey -noout | openssl pkey -pubin
# -outform DER | openssl dgst -sha256 -binary | base64`):
# --dart-define=TLS_PIN_SPKI_SHA256=pin[,pin...]
# release builds refuse http:// API URLs (debug/profile allow localhost)
# physical phone on LAN: replace localhost with your machine IP
# optional platform label override: --dart-define=VPN_PLATFORM=android
```

Then: log in (username or email + password, or Continue with
Google/GitHub) → Connect tab → toggle.
Regions tab → Quick Connect (auto lowest-load) or per-server switch.

## Project layout

```text
lib/
├── main.dart              # main() + BoltMeshApp
├── previews.dart          # barrel re-exporting previews/*
├── l10n/                  # app_en/app_de.arb + generated gen/**
├── app/                   # root_shell (auth gate), authed_shell (nav + lifecycle)
├── core/                  # dio_client, env, errors, ip, locale, log, mutex,
│                          #   storage_options, theme
├── features/
│   ├── auth/{data,state,ui}/   # auth_api/models, session_store, auth_session
│   └── vpn/
│       ├── data/          # wg_conf, platform_info, probes, api, stores, tunnel IO
│       ├── domain/        # region/diagnosis/failover/tunnel policies
│       ├── state/         # connection_controller + conn_* parts, polling, resume
│       └── ui/            # home, regions, settings
└── previews/              # harness, fixtures, login, home, regions, settings
```

`test/` mirrors `lib/`: `core/`, `features/auth/{data,state}/` and
`features/vpn/{data,domain,state}/`. App-level suites (`widget_test.dart`,
`regions_refresh_test.dart`) stay at the `test/` root, and shared doubles live
in `test/support/fakes.dart`.

## Platform notes (after `flutter create`)

- **Android**: supports **API 24 (Android 7.0 Nougat) and newer**, and
  builds against **compile/target SDK 36 (Android 16)**. The floor is pinned
  in `android/app/build.gradle.kts` (`minSdk = 24`: Flutter 3.47's default,
  above `wireguard_flutter_plus`'s own `minSdkVersion 21`) so the documented
  minimum cannot drift with the Flutter SDK.
  `wireguard_flutter_plus` needs the `VpnService` permission
  (`android/app/src/main/AndroidManifest.xml`):
  `<uses-permission android:name="android.permission.INTERNET" />`,
  plus the `VpnService` `BIND_VPN_SERVICE` service entry from the
  package README. Accept the system VPN consent dialog on first connect.
- **Android foreground service**: the plugin's
  `VpnForegroundService` keeps the tunnel's foreground notification alive
  while connected. Behavior is API-level dependent:

  | API | Android | Foreground-service behavior |
  | --- | --- | --- |
  | 24 | 7.0 | Minimum supported. `VpnService` runs; no typed foreground service exists yet. |
  | 28 | 9 | `FOREGROUND_SERVICE` permission required to start the keep-alive service (normal permission, declared in the manifest). |
  | 29 | 10 | `foregroundServiceType="connectedDevice"` supported; the plugin's service declares it. |
  | 33 | 13 | `POST_NOTIFICATIONS` is a runtime permission: without the grant the notification is hidden, but the service keeps running. |
  | 34 | 14 | Typed foreground services are mandatory: `FOREGROUND_SERVICE_CONNECTED_DEVICE` (declared) plus the `connectedDevice` type, or `startForeground` throws. |

  The service is declared with `android:stopWithTask="false"`, so a task
  swipe leaves it running (see the background-healing bullet below).
  Doze/app-standby and OEM battery managers may defer the service; the
  WireGuard tunnel itself is in-kernel and keeps passing traffic regardless.
- **Android background healing**: the app runs on a process-cached
  `FlutterEngine` (`MainActivity.provideFlutterEngine`,
  `shouldDestroyEngineWithHost = false`), so swiping the task away destroys
  the Activity but not the Dart isolate. Together with the plugin's
  `VpnForegroundService` (`android:stopWithTask="false"`), the background
  health tick (30s while the app is hidden) and the heal → failover ladder
  keep running while the app is "killed". The app's native channels live in `TunnelHost` (process scope) so
  a detached Activity's `cleanUpFlutterEngine` cannot cancel them. A true
  process death (force-stop / OOM) still cold-starts via
  `reconcileColdStart`.
- **iOS/macOS**: enable the NetworkExtension capability
  (Packet Tunnel Provider) in Xcode for the Runner target
  (`ios/Runner/Runner.entitlements` already declares it, but the
  extension target + a provisioning profile with the entitlement are
  still created in Xcode, not in this repo).
- **Windows**: hands all privileged work to the `boltmeshd` helper
  (`boltmeshd/`, installed as a LocalSystem service by the Inno Setup `.exe`).
  The plugin still bundles Wintun, `wireguard_svc.exe` and `wireguard.dll`,
  but the GUI no longer calls it and no longer requests elevation: the daemon
  creates/starts the `boltmesh0` tunnel service and answers stage, handshake,
  peer and counters over the named pipe `\\.\pipe\boltmesh\boltmeshd`. OAuth
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
  Persistent helper failures land in `/var/log/boltmesh/boltmeshd.log`
  (JSON lines); see `boltmeshd/README.md`.
  OAuth uses the same ephemeral loopback listener as Windows
  (`http://127.0.0.1:{port}/callback`) opened in the system browser, so the
  browser must be able to reach `API_BASE_URL` — the packaged deb/rpm pins
  production via `distribute_options.yaml`.
  `linux/assets/boltmesh.png` is maintained by hand (RGBA, transparent
  corners — `flutter_launcher_icons` has no Linux target); keep it a
  512×512 RGBA copy of the app icon or the deb/rpm launcher shows black
  corners.

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
hook if the plugin ships a fixed release. CI (`default.yml` `build-android`
job, on tags) runs this same `flutter build appbundle --release`; the
remaining KGP warning (`flutter_web_auth_2`, `wireguard_flutter_plus`
apply their own Kotlin plugin) is upstream's to fix and doesn't fail
the build.

## Windows release build

Prereqs: Visual Studio 2022 with the "Desktop development with C++" workload,
[Inno Setup 6](https://jrsoftware.org/isinfo.php) (the `iscc` compiler;
fastforge resolves `%ProgramFiles(x86)%\Inno Setup 6` or `INNO_SETUP_PATH`),
and Go 1.26 (to build `boltmeshd.exe`; the `windows-exe` pre hook does this).

```powershell
flutter config --enable-windows-desktop
dart pub global activate fastforge
# then add %LOCALAPPDATA%\Pub\Cache\bin to PATH (once)
fastforge release --name=production
# dist/<version>/boltmesh-<version>-windows-setup.exe
```

The Windows package is an Inno Setup `.exe`, not MSIX. The pre-packing hook
`windows/packaging/stage_boltmeshd.ps1` builds `boltmeshd.exe` into the
bundle, so the installer ships the helper next to `boltmesh.exe` (and the
plugin-bundled `wireguard_svc.exe`/`wireguard.dll`), then
`windows/packaging/exe/boltmesh.iss` installs and starts the helper service
and removes it on uninstall. The GUI no longer requests elevation: the app
CMake drops the plugin's `requireAdministrator` link flag, and the privileged
work lives in the helper. The installer itself is per-machine into
`%ProgramFiles%\BoltMesh` and still runs elevated. Config:
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
it signs `boltmesh.exe` and `boltmeshd.exe` between the Flutter build and
Inno packing, then the installer after packing, timestamped via RFC 3161
(default `http://timestamp.digicert.com`, override
`WINDOWS_TIMESTAMP_URL`). Signing the app exe and the helper as well as the
setup exe means the signature covers everything the installer later launches.

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

## Flows (backend truth)

- Auth: `POST /auth/login` (form: `grant_type=password`, `username`,
  `password`, always-persistent `remember_me=true`) → access JWT (15 min)
  - `refresh_token` HttpOnly cookie, both in secure storage. The session
  persists until Log Out or server-side revocation (no Remember me
  option). OAuth (Google/GitHub buttons): system browser opens
  `GET /auth/{provider}?platform=native` (desktop adds a `native_callback`
  loopback address and listens on it; mobile uses the `boltmesh://`
  custom scheme), provider consent redirects back with the single-use
  code (`boltmesh://auth/callback?code=...`, scheme registered in
  `AndroidManifest.xml` + iOS/macOS `Info.plist`; override with
  `--dart-define=OAUTH_CALLBACK_SCHEME=...`), the app exchanges the
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
  already-connected → re-read `config`.
- Switch: fresh keypair + `POST .../switch` with **exactly one** of
  `region_id`/`server_id`. Auto = lowest-`active_peers` region from
  `GET /vpn-regions` (cached 60s), then switch with its `region_id`.
- Disconnect: graceful `stopVpn()` (3s budget, one automated hard-kill
  retry on timeout with no user input) then `POST .../disconnect` (no body,
  idempotent, works with lapsed subscription).
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
  foreground, 30s hidden) reads the OS stage, the WireGuard handshake and a
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
  reachable out-of-band) from suppressing the ladder forever; a merely-late
  rekey is well inside the ceiling, and a live echo still wins. On platforms
  with no handshake reader (Apple) detection stays degraded-stage dependent:
  a null read is absence of evidence and never heals on its own.
- Echo shortcut: the in-tunnel DNS echo is read only when it can change a
  decision — once the handshake is older than 45s, on a degraded stage, or
  when the handshake is unknown — so a healthy peer sends no probe datagram
  at all (it was one UDP echo per tick, ~6/min foreground). Three
  consecutive *performed-dead* echoes (never null) then shorten the
  observed-handshake window to 30s: the data path is confirmed dead ~30s
  after probing starts, so a death early in a rekey cycle is caught in
  ~45-75s foreground (~1.5-2min hidden) instead of waiting out the full 150s;
  deaths after the gate are unaffected. A handshake inside the 25s keepalive
  still wins, and the run resets on any skipped/alive/unknown echo, a
  successful status poll, or a tunnel restart.
- Diagnostic probes run only once a stall is suspected and are read-only —
  they never consume heal/move budgets: physical link → in-tunnel echo →
  control-plane probe. A *performed* dead echo, or a hard-stale handshake,
  with a reachable control plane fast-tracks straight to a server move,
  stopping the proven-dead tunnel before discovery. Every post-heal
  escalation is likewise path-dead: a stall that survived a same-server
  restart stops the tunnel before discovery (the region fetch and switch
  POST travel direct) instead of probing a path already known bad. Otherwise
  the ladder is cheap-restart-first (a null echo with only a reachable
  control plane stays on the local ladder — absence of evidence is not
  death); the in-tunnel probes that remain on the recovery path use a short
  3s budget, while manual switch/rotate keep the 10s one.
- Ladder & budgets: offline restart on the cached config (zero API calls) →
  after one same-server restart, the next corroborated stall moves servers
  (same region first, then global lowest-load; an explicit pin errors out
  instead of roaming). At most 3 moves per outage window, then two trailing
  same-server restarts, after which recovery is surfaced as an actionable
  error instead of restarting a proven-dead config forever. A successful
  status poll ends the outage and restores the budget only when the handshake
  is fresh: an out-of-band poll success while the WireGuard path stays dead
  (WG UDP blocked) does not reset the ladder, so it still escalates. A 429
  holds the ladder until its window reopens. A 5s post-(re)connect status
  check (re-armed after every restart) arms corroboration early, so a hard
  kill escalates in ~15s rather than a full poll interval. There is no
  same-server config-refresh rung: a reboot-rotated server key is picked up
  by a server move or a manual reconnect.
- Byte counters are display-only (Home card) and never drive heals.
- OS link transitions are watched (`NetworkMonitor.linkChanges`): losing
  the link raises the no-network banner at once, and a returning link runs
  the same resume catch-up (backend-free health tick, then a status poll
  only when the snapshot is stale) immediately instead of waiting out the
  tick.

## Handshake readers (`com.boltmesh/handshake` → `getLastHandshake`)

`wireguard_flutter_plus` exposes only byte counters, so the app reads
handshakes through its own channel (the plugin is never forked). Contract:
`getLastHandshake` returns epoch seconds (double) of the last completed
handshake, or null when unknown (null never heals — only the
degraded-stage path acts). Dart side: `lib/features/vpn/data/` —
`tunnel_adapter.dart`, whose `handshakeReaderSupported` gates the
never-handshook branch (Apple is still a placeholder, so its null reads
never count).

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
- **iOS/macOS**: app side sends `sendProviderMessage("getHandshake")`
  over the `NETunnelProviderSession` (same pattern the plugin uses for
  `getStats`); the Packet Tunnel extension (Xcode target, created per the
  Platform notes above) answers with the WireGuardKit peer handshake
  epoch. Until both halves land, Apple reads are unknown.

## Tests

```sh
flutter test
# Coverage (report-only unless the floor is passed):
flutter test --coverage && bash tool/coverage_gate.sh 80

# The rest of what CI enforces locally:
flutter analyze --fatal-infos
dart format --set-exit-if-changed lib test
bash tool/check_generated.sh
# Native-platform contracts (systemd units + staged Linux payload, the
# Android manifest the background tunnel needs, the Windows helper channel):
bash tool/verify_native.sh
```

`tool/check_generated.sh` regenerates `flutter gen-l10n` + `build_runner`
output and fails on drift: those files are excluded from analysis, so a stale
one would otherwise ship green. `tool/coverage_gate.sh` enforces a floor
(currently 80%) on hand-written lines only — generated code is excluded.
`tool/verify_native.sh` covers checks the Dart suite cannot reach (see the
`validate-native` CI job). Timer behaviour is tested with `package:fake_async`
(`async.elapse`), never real sleeps, so the suite is deterministic and fast.

The Windows named-pipe transport is covered by a Flutter-free C++ test
(`windows/runner/tests/helper_pipe_io_test.cpp`, built as
`helper_pipe_io_tests` and run by the `validate-windows` job); Android is
additionally checked by `./gradlew :app:lintDebug` in `validate-android`.

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
