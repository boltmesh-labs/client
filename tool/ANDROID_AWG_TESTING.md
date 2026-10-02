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

## Current run and follow-up

- Android 16, x86_64 emulator over ADB TCP (`127.0.0.1:5555`), staging API
  `https://api.boltmesh.mooo.com/v1`.
- The pre-suspend-overlay build connected to test2; the Go backend logged a
  handshake response. Ping was 3/3 to `10.2.0.1`; DNS resolved
  `boltmesh.mooo.com` to `93.177.140.197`. The active service was
  `org.amnezia.awg.backend.GoBackend$VpnService`, confirming the AWG path rather
  than the stock plugin.
- The final build now overlays Go timers to `CLOCK_BOOTTIME` and no longer opens
  an unused UAPI socket. It builds for all four Android ABIs and has passed the
  minified parser/JNI smoke tests, but the live tunnel has not yet been repeated
  on that exact build. At the time of this note, test2 reports `error` and the
  app shows no capacity; the node-agent is active and test2's rootfs is read-only.
  Restore test2 capacity/online status before repeating the live test.
- The release instrumentation XML reports 3/3 tests passed, and direct
  `adb shell am instrument -w -r ...` returns `OK (3 tests)`. On the remote TCP
  ADB emulator, Gradle's `connectedReleaseAndroidTest` still exits nonzero; this
  appears to be a UTP/remote-device result issue, not a failed test assertion.
  Recheck on the CI-local API 30/35 emulators when CI is next intentionally run;
  do not poll CI for this task.
- Android supports native → AWG; the stream rung remains unavailable on Android.
  A like-for-like Android negative test (stock inner format against test2)
  remains to be added after test2 is healthy again.
