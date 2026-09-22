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

## Linux

### 1. Dependencies

```bash
sudo dnf install clang cmake ninja-build pkg-config gtk3-devel libsecret-devel \
  egl-utils glx-utils webkit2gtk4.1-devel go socat wireguard-tools gh
```

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
