# Android AmneziaWG test notes

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
- Android supports native → AWG; the stream rung remains unavailable on Android.
  Do not live-test a stock-format handshake against test2: that would send a
  plaintext WireGuard handshake to an AWG-only node. The Android policy test
  instead verifies the AWG floor is chosen, and unsupported platforms refuse
  the region rather than falling back to stock.
