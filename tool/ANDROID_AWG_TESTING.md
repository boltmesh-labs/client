# Android AmneziaWG and stream test notes

## Build and attach the emulator

The Android AWG JNI library is built from `android/awg-native` during each APK
build. Requirements: Flutter 3.47.x, JDK 21, Go 1.26, Android SDK/build-tools
36, and NDK `28.2.13676358`.

```bash
flutter build apk --debug --dart-define=API_BASE_URL=https://api.boltmesh.mooo.com/v1
adb connect 127.0.0.1:5555
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

For the remote emulator, forward its ADB port first. Accept the ADB host key
and Android's VPN consent prompt on the emulator when asked. Sign in through
the app, select the AWG test region (`test2` / US East 98), and connect.

Do not put staging API credentials in command-line arguments, local state files,
or committed files. If provisioning through an E2E script is needed, read
`BOLTMESH_E2E_API_USER` and `BOLTMESH_E2E_API_PASSWORD` from the environment.

## Positive checks

With the tunnel up:

```bash
adb shell toybox ping -c 3 -W 3 10.2.0.1
adb shell toybox ping -c 1 -W 5 boltmesh.mooo.com
adb shell dumpsys connectivity | grep -A1 'ni{VPN CONNECTED'
adb logcat -d | grep 'AmneziaWG/boltmesh0.*Received handshake response'
```

The DNS ping should resolve to `93.177.140.197`; `dumpsys connectivity`
should show `tun0`, the assigned `10.2.x.x/32`, and DNS `10.2.0.1`. The
AmneziaWG service log must show a handshake response, not only an active VPN
notification.

## Verified run and follow-up

- Android 16, x86_64 emulator over ADB TCP (`127.0.0.1:5555`), staging API
  `https://api.boltmesh.mooo.com/v1`.
- The final `CLOCK_BOOTTIME` overlay build connected to test2. The app showed
  `Connected · test2`; logcat recorded `Received handshake response`; ping was
  3/3 to `10.2.0.1`; and `boltmesh.mooo.com` resolved through tunnel DNS to
  `93.177.140.197` and replied. `dumpsys connectivity` showed `tun0`, address
  `10.2.130.125/32`, DNS `10.2.0.1`, and the VPN-owned full-tunnel routes. The
  Android status bar reported VPN on.
- At the start of this verification test2 was online with zero peers. The final
  live check is complete; no capacity recovery or device deregistration was
  performed.
- The release instrumentation XML reports 3/3 tests passed, and direct
  `adb shell am instrument -w -r ...` returns `OK (3 tests)`. On the remote TCP
  ADB emulator, Gradle's `connectedReleaseAndroidTest` still exits nonzero; this
  appears to be a UTP/remote-device result issue, not a failed test assertion.
  Recheck on the CI-local API 30/35 emulators when CI is next intentionally run;
  do not poll CI for this task.
- Android supports native → AWG → stream. Do not live-test a stock-format
  handshake against an AWG-only node: that would send a plaintext WireGuard
  handshake to it. The Android policy test instead verifies the AWG floor is
  chosen, and unsupported platforms refuse the region rather than falling back
  to stock.

## Inducing a stall

Reaching the demotion on a device needs the AWG handshake to stall while the
tunnel's own path stays up, which means breaking the emulator's UDP to the node.
The `google_apis` image is not capable of it: `ro.build.type` is `user`, `adb root`
is refused (`adbd cannot run as root in production builds`), there is no `su`, and
`iptables` reports `Permission denied (you must be root)`. The `tc` binary exists
at `/system/bin/tc` but is gated the same way, and `cmd netpolicy` only restricts
background UIDs — it cannot target UDP. Two ways out:

- Recreate the AVD on an `eng`/`userdebug` image, which gives root and netfilter.
- Block the node's WireGuard UDP port server-side while leaving TCP 443 up. That
  is a *more* faithful middlebox than emulator netfilter, since a real DPI blocks
  one protocol rather than the whole interface — but it affects every peer on that
  node, so it wants a dedicated test node.

## Stream rung

The stream rung runs the same `boltmesh/stream` bridge `boltmeshd` runs, inside
the AWG host's native library, and keeps its TLS socket off the tunnel with
`VpnService.protect` instead of a route. It is reached only after a confirmed
local stall demotes AWG → stream, so to exercise it on a device without inducing
a stall, temporarily pin the rung:

```bash
# lib/features/vpn/state/connection_controller.dart
-  ObfuscationRung _obfuscationRung = ObfuscationRung.native;
+  ObfuscationRung _obfuscationRung = ObfuscationRung.stream;  // revert after
flutter build apk --debug --dart-define=API_BASE_URL=https://api.boltmesh.mooo.com/v1
```

Connect to a region with a usable `stream` credential and enough capacity
(`test1` / US East 99 is stock; `test2` / US East 98 is obfuscated), then:

```bash
adb logcat -d | grep 'boltmesh0-stream'          # session established
adb logcat -d | grep 'Received handshake response'
adb shell dumpsys connectivity | grep -oE 'InterfaceName: tun0.*DnsAddresses: \[ [0-9./]+ \]'
```

The overlay gateway is per-region (`10.1.0.1` for test1, `10.2.0.1` for test2),
so ping the one `dumpsys` reports. Expect an early
`session unavailable: ... could not be protected from the VPN` line before the
VpnService registers the protector: the bridge fails closed until then and
retries, which is the intended behavior, not a failure. A successful run shows a
later `session established`, an inner `Received handshake response`, and tunnel
DNS resolution.

Verified on the final build: with the rung pinned, the app connected to test1
(stock inner config). Logcat showed
`stream: session established with <node>:443`, the inner WireGuard handshake
response, and `[BoltMesh] tunnel connected ... server=test1`. Ping to the
region's gateway `10.1.0.1` was 3/3; `boltmesh.mooo.com` resolved through the
tunnel to `93.177.140.197` and replied. The bridge booked one fail-closed dial
before the VpnService registered, then connected. The pin was reverted after the
run. A stream start no longer requires pinning: a confirmed local stall now steps
AWG → stream before it spends a server move. Reaching that on a device still
means inducing the stall, which needs a network break the emulator image can
make, so pinning remains the way to exercise the bridge without one.

Both inner formats are now proven. On the AWG region `test2`, with the rung
pinned the same way, logcat showed `UAPI: Updating h1 padding` … `Updating
header protection key` (the obfuscated inner config), `Received handshake
response`, and `Connected · test2`; `tun0` came up on test2's overlay
(`10.2.103.148/32`, DNS `10.2.0.1`), ping to `10.2.0.1` was 3/3, and
`boltmesh.mooo.com` resolved through the tunnel. So the stream carries a stock
*and* an obfuscated inner config.

Re-verified on the post-ladder-fix tree (Android 16 x86_64 emulator, rung
pinned, staging API). Auto-provision picked test1: the bridge logged
`stream: session established with 192.168.1.115:443`, the inner `Received
handshake response` arrived, `tun0` came up `10.1.97.0/32` with DNS
`10.1.0.1`, ping was 3/3, and `boltmesh.mooo.com` resolved to `93.177.140.197`.
Switching to test2 logged `UAPI: Updating h1 padding` … `header protection key`
then `stream: session established with 192.168.1.116:443` and an inner
`Received handshake response`, with `tun0` on `10.2.84.210/32` / DNS
`10.2.0.1`, ping 3/3, and the UI at `Connected · test2`. Note the bridge dialed
the node's *literal* address (resolved in Dart before the TUN exists) while SNI
stayed the hostname, as intended. The pin was reverted after the run; the tree
was clean apart from the `.gitignore` change. Note the emulator here was a
`user` build, so the demotion itself still could not be induced — this run
proves the bridge and both inner formats, not the ladder.

The node host is resolved in Dart before the native start and before the TUN
exists (`lib/features/vpn/data/stream_server_resolver_io.dart`), and the bridge
is handed a literal `address:port`; `server_name` stays the hostname for TLS
SNI/verification. Resolving inside the native start was tried first, but it put
a variable, potentially slow lookup inside the ten-second start budget, and on a
loaded emulator that could blow the budget while the native tunnel still came
up — the app showed `Error` with a live TUN. A literal address keeps the native
start fast and the two states consistent; the bridge rejects a hostname that
reaches it. After that change the same connect completed in about a second.
