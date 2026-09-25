# BoltMesh Client — Development Setup

Fresh-machine setup for running the Flutter client from source. For release
packaging (Android AAB + keystore, Windows Inno Setup + Authenticode), CI
secrets and the test suite, see [README.md](README.md).

## Shared prereqs

- Flutter SDK 3.47.x stable (`flutter --version`).
- JDK 21 (Gradle 9.x rejects much newer JDKs).
- Git.
- A running backend (`podman-compose up -d` from the
  [`infra`](https://github.com/boltmesh-labs/infra) repo) plus a user account
  (`POST /v1/auth/register`).

## Windows

1. Install Visual Studio 2022 with the **Desktop development with C++**
   workload, then the Flutter SDK, and add it to `PATH`.
2. Configure Flutter and run the app:

    ```powershell
    flutter config --enable-windows-desktop
    flutter doctor

    git clone https://github.com/boltmesh-labs/client
    cd client
    flutter pub get
    flutter run -d windows
    ```

## Android

### 1. Install the SDK

The Android CLI installs the SDK components:

```bash
curl.exe -fsSL https://dl.google.com/android/cli/latest/windows_x86_64/install.cmd -o "%TEMP%\i.cmd" && "%TEMP%\i.cmd"

android sdk install "cmdline-tools;latest"
android sdk install "platforms;android-36"
android sdk install "build-tools;36.0.0"
android sdk install "system-images;android-36;google_apis;x86_64"
android sdk install "ndk;28.2.13676358"

android emulator create medium_phone
android emulator start medium_phone
```

### 2. Install JDK 21

[Oracle JDK 21 for Windows](https://download.oracle.com/java/21/latest/jdk-21_windows-x64_bin.exe).

### 3. Run through an SSH tunnel

The emulator runs on the Windows host; forward its adb port so a remote
(here: Linux) machine can run the app on it.

Host (Windows):

```dos
adb tcpip 5555
ssh -R 5555:127.0.0.1:5555 revolver1@192.168.1.112
```

Remote:

```bash
adb connect 127.0.0.1:5555
flutter run -d 127.0.0.1:5555
```

## macOS

macOS has the least automated setup of any target: the tunnel is a **Network
Extension**, which is a separate Xcode target plus a signing entitlement that
cannot be produced from this repository. Everything below is a one-time,
per-developer-Mac setup.

**Nothing in this section can be done on Linux or Windows** — the Network
Extension capability requires macOS with Xcode, and a provisioning profile
from an Apple Developer account that has been granted the Network Extension
entitlement for `packet-tunnel-provider`.

### 1. Prereqs

- macOS 12.0 or newer (the deployment target in
  `macos/Runner.xcodeproj`), Xcode 15+.
- Go on `PATH` (`brew install go`) — the extension links a Go-built static
  library, see step 4.
- An Apple Developer account with the **Network Extensions** capability.

### 2. Add the Packet Tunnel extension target

This is the part that is *not* in the repo. In Xcode
(`open macos/Runner.xcworkspace`):

1. **File ▸ New ▸ Target… ▸ Network Extension**, product name
   `boltmeshTunnel`, language **Swift**, provider type **Packet Tunnel
   Provider**. Set its bundle identifier to a prefix of the app's
   (`PRODUCT_BUNDLE_IDENTIFIER` in `macos/Runner/Configs/AppInfo.xcconfig`) —
   e.g. `com.boltmesh.boltmesh.tunnel`.
2. Give **both** the Runner target and the extension target the **Network
   Extensions** (Packet Tunnel) capability and the **App Groups** capability,
   and check the **same** group in both:
   `group.com.boltmesh.boltmesh`. That value is already declared in
   `macos/Runner/*.entitlements` and `ios/Runner/Runner.entitlements`; it
   must match the App Group in the provisioning profile or the connect fails.
3. Replace the generated `PacketTunnelProvider.swift` with the WireGuard
   implementation from the plugin's `ios_setup_readme.md` (it is
   reproduced in the `wireguard_flutter_plus` package under
   `~/.pub-cache/hosted/pub.dev/wireguard_flutter_plus-*/`).

### 3. Wire up the WireGuardKitGo bridge

The extension needs a Go static library (`libwg-go.a`) that is not vendored
here. Follow step 4 of the plugin's `ios_setup_readme.md` for macOS:

- vendor `WireGuardKitGo` from
  [`wireguard-apple`](https://github.com/aakashch0179/wireguard-apple) into
  the project;
- add an **External Build System** target running `/usr/bin/make` in
  `$(PROJECT_DIR)/WireGuardKitGo`, with *Pass build settings in environment*
  checked;
- make the extension depend on that target and link `out/libwg-go.a`.

### 4. Build and run

Both defines are required on Apple; the app fails fast with a named error if
either is missing (see `resolveAppGroup`/`resolveProviderBundleId` in
`lib/features/vpn/data/platform_info.dart`).

```bash
flutter config --enable-macos-desktop
flutter pub get

flutter run -d macos \
  --dart-define=VPN_PROVIDER_BUNDLE_ID=com.boltmesh.boltmesh.tunnel \
  --dart-define=VPN_APP_GROUP=group.com.boltmesh.boltmesh
```

Accept the system VPN consent prompt on first connect. OAuth uses the system
browser and returns over the registered `boltmesh://` custom scheme (declared
in `macos/Runner/Info.plist`) — unlike Windows/Linux, macOS does **not** use
the ephemeral loopback listener, because `flutter_web_auth_2` implements
macOS with `ASWebAuthenticationSession` and that path needs no listener.

Handshakes are **not** readable on Apple: there is no native reader, so the
health policy treats a null handshake as absence of evidence and heals only
from a degraded OS stage. See README "Handshake readers".

### 5. The privileged-helper alternative (optional, experimental)

macOS can also run the tunnel through the `boltmeshd` helper instead of a
Network Extension — the same privileged-daemon model as Linux and Windows. This
is what `boltmeshd`'s darwin backend implements: a launchd LaunchDaemon running
the WireGuard data plane in userspace over `utun` (macOS has no kernel
WireGuard, and `wgctrl` has no darwin backend).

It is **not wired up and not proven**. The helper builds and is vetted/linted
for darwin, but the Flutter client still routes macOS to the VPN plugin, and
nothing has run on a Mac. Treat it as a design in progress:

```bash
cd boltmeshd && make build-darwin   # cross-compiles; needs no Mac
```

See `boltmeshd/README.md` for the full design and its security properties.

## iOS

Same blockers as macOS, and a shorter list of things that can be done off a
Mac — everything here needs one.

1. **Prereqs**: macOS + Xcode, Go on `PATH`, and an Apple Developer account
   with the Network Extensions capability. A physical device is required; the
   iOS Simulator cannot host a Network Extension.
2. **Extension target**: in Xcode
   (`open ios/Runner.xcworkspace`), add a **Network Extension** target —
   product name `boltmeshTunnel`, language Swift, provider type **Packet Tunnel
   Provider** — with a bundle identifier that is a prefix of the app's. Follow
   steps 3–10 of the plugin's `ios_setup_readme.md` (in
   `~/.pub-cache/hosted/pub.dev/wireguard_flutter_plus-*/`) for the
   `WireGuardKitGo` bridge, the App Group capability, and the
   `PacketTunnelProvider.swift` implementation.
3. **Entitlements**: `ios/Runner/Runner.entitlements` already declares
   `packet-tunnel-provider` and the App Group `group.com.boltmesh.boltmesh`.
   The profile must include both.
4. **Run**:

    ```bash
    flutter run -d <device-id> \
      --dart-define=VPN_PROVIDER_BUNDLE_ID=com.boltmesh.boltmesh.tunnel \
      --dart-define=VPN_APP_GROUP=group.com.boltmesh.boltmesh
    ```

There is no helper path on iOS: the app sandbox forbids the privileged daemon
model Linux and Windows use.

## Linux (redhat)

### 1. Dependencies

```bash
sudo dnf install clang cmake ninja-build pkg-config gtk3-devel libX11-devel \
  libXi-devel libsecret-devel egl-utils glx-utils webkit2gtk4.1-devel go socat \
  wireguard-tools gh
```

`libX11-devel`/`libXi-devel` (Debian/Ubuntu `libx11-dev`/`libxi-dev`) are
required by the tray plugin the desktop build links; without them
`flutter build linux` fails in `pkg_check_modules`.

### 2. Flutter SDK

```bash
mkdir -p ~/develop
cd ~/develop
curl -O https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.5-stable.tar.xz
tar xf flutter_linux_3.47.5-stable.tar.xz

echo 'export PATH="$HOME/develop/flutter/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

flutter config --enable-linux-desktop
flutter doctor
```

### 3. Run

```bash
git clone https://github.com/boltmesh-labs/client
cd client
flutter pub get
flutter run -d linux
```

Tunnel actions go through the privileged `boltmeshd` helper; without it the
GUI launches but VPN operations fail with "helper socket unavailable".
[boltmeshd/README.md](boltmeshd/README.md).

## Next

[README.md](README.md) covers the run-time `--dart-define`s, platform notes,
release builds and code signing, and the test suite.
