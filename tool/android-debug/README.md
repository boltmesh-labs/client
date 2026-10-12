# Android native-crash debugging: the two Go runtimes

How the **AWG/stream → stock WireGuard owner switch on Android** was traced to a
SIGSEGV, and what actually causes it. The switch is the rung change back *into*
`native` — hand Android's single `VpnService` from the in-process AWG host
(`libawg-go.so`) back to the stock plugin (`libwg-go.so`).

This directory holds the two small tools the investigation needed, because the
usual ones do not work here (see [Why the usual tools fail](#why-the-usual-tools-fail)).

## Symptom

On the descent to `native`, after an `awg` or `stream` rung:

```text
I WireGuard/GoBackend: Bringing tunnel boltmesh0 UP
D WireGuard/GoBackend: Requesting to start VpnService
D WireGuard/GoBackend: Go backend f333402          <- libwg-go's wgVersion()
I Zygote: Process NNNN exited due to signal 11 (Segmentation fault)
```

The app dies with no Dart exception. Reproduced on every run; the upward walk
(`native → awg → stream`) is fine.

## The two Go runtimes

The process links **two** Go `c-shared` libraries:

- `libwg-go.so` — the stock plugin's backend (`com.wireguard.android:tunnel`),
  loaded on a `Dispatchers.IO` worker when the plugin creates its `GoBackend`.
- `libawg-go.so` — BoltMesh's AWG host (`android/awg-native/`), loaded on the
  private `BoltMeshAwg` thread when the first obfuscated/stream rung starts.

## Root cause: symbol preemption

The two libraries export **45 of the same global symbols**, and they are the
whole cgo runtime surface:

```text
crosscall1  crosscall2  _cgo_topofstack  _cgo_sys_thread_start
_cgo_wait_runtime_init_done  _cgo_get_context_function  _cgo_panic  _cgo_yield
x_cgo_init  x_cgo_inittls  x_cgo_mmap  x_cgo_munmap  x_cgo_getstackbound
x_cgo_callers  x_cgo_notify_runtime_init_done  x_cgo_bindm  x_cgo_setenv
fatalf  main.main  ...
```

Both are loaded with global visibility in the app's linker namespace, so the
later-loaded **`libawg-go` preempts `libwg-go`'s own references**. When the stock
backend calls into libwg-go, its cgo/runtime callbacks land in **libawg-go's**
copy — code that reads libawg's runtime state, which was never set up on that
thread — and the process faults.

This is not a per-thread "a thread that entered one runtime must never enter the
other" problem (the model in `TunnelHost.kt`): the crashing thread never touched
libawg-go. The two libraries share one symbol namespace, so control crosses
between them without any Java thread doing so. That is why confining every
libawg-go entry point to a private thread (`TunnelHost.runOnAwgThread`,
`AndroidAwgHost.checkAwgThread`) does not fix it.

## Evidence

A ptrace sniffer (`ptrace_catch.c`) attached to every thread of the live app and
logged the one fatal fault (the others were ART's benign `SIGBUS`):

```text
FAULT#7 tid=9534 comm=DefaultDispatch sig=11 (SIGSEGV)
  ... rip in the base.apk executable mapping at apk offset 0x3428000  liboff=0x64f6a
END leader killed by signal 11 after 7 fault(s)
```

- The mapping is **libawg-go.so's executable segment**: its size (`~3.03 MB`)
  matches libawg's `R E` segment (`0x2e5d70`); libwg's is only `~2.04 MB`
  (`0x1f3190`). The apk offset lands in libawg's range, not libwg's.
- `tid 9534` is the thread that **loaded `libwg-go.so`** and ran the stock
  `WireGuard/GoBackend`; its last log is `Go backend f333402` — libwg's
  `wgVersion()` — immediately before the fault.
- `comm=DefaultDispatch` is a `Dispatchers.IO` worker: a thread that had never
  entered libawg-go.

The symbol overlap above is what lets that happen.

## Why the usual tools fail

- **No tombstone.** Every Go runtime installs its own `SIGSEGV` handler, so
  bionic's `debuggerd` never runs. `/data/tombstones` stays empty and logcat has
  no `DEBUG` dump — on a `user` build *and* on a `userdebug` build.
- **`lldb` over the NDK's remote-android platform hangs** on `continue` in this
  setup (the app is left ptrace-stopped). `ptrace_catch.c` does the one thing
  that is needed here, without symbol loading or a remote stub.

## Requirements

- A **userdebug/eng** emulator image (`ro.debuggable=1`) so `adb root` works.
  Set it up as in `SETUP.md`. Run `adb root` first.
- The Android NDK (the repo pins `28.2.13676358`).

## Tools

### `ptrace_catch` — find the faulting thread and library

Attaches to every thread, forwards signals, and logs each fatal-class signal with
the faulting tid, thread name, RIP, RSP and the `/proc/<pid>/maps` entry that
contains RIP. The last `FAULT#` before `END` is the crash.

```sh
tool/android-debug/build.sh x86_64
adb push build/android-debug/x86_64/ptrace_catch /data/local/tmp/
adb shell chmod 755 /data/local/tmp/ptrace_catch
# start it once the app pid exists (before the crash):
adb shell /data/local/tmp/ptrace_catch "$(adb shell pidof com.boltmesh.boltmesh)"
```

### `xver` — reproduce the conflict without a VPN

Loads both libraries and calls each one's version function, in one of three
orders:

```sh
adb push build/android-debug/x86_64/xver /data/local/tmp/
adb push <libwg-go.so> /data/local/tmp/libwg-go.so
adb push <libawg-go.so> /data/local/tmp/libawg-go.so
adb shell 'cd /data/local/tmp && ./xver libwg-go.so libawg-go.so same-thread'
```

- `same-thread` — load+use libwg, then libawg **on the same thread**. Crashes
  100% (fault addr `0x38` inside libawg's `cgocallback`), which is the pre-fix
  `native → awg` signature.
- `wg-first` / `awg-first` — load and use each on its **own** thread. Clean in
  both orders; only calling into the *other* runtime's deeper cgo path (as the
  app does) trips it.

The prebuilt `lib*.so` pair is in the debug APK, or extract them with:

```sh
unzip -o build/app/outputs/flutter-apk/app-debug.apk 'lib/<abi>/*.so' -d /tmp/apklibs
```

## Fix options

- **One runtime (guaranteed).** Never enter `libwg-go` on Android: run the
  native rung through the in-process AWG engine (it parses stock configs
  unchanged) and stop the stock plugin from constructing its `GoBackend`, so
  `libwg-go` is never loaded.
- **Stop the preemption (small, needs validation).** Make `libawg-go` stop
  exporting the overlapping cgo symbols (a linker version script localizing
  `crosscall*`, `_cgo_*`, `x_cgo_*`, `fatalf`, `main.main`; keep only the `awg*`
  JNI exports global) so `libwg-go` binds its own — wired through
  `tool/build_awg_android.py`. Or load `libawg-go` with `RTLD_LOCAL` so it never
  enters the global scope.

`integration_test/app_e2e.dart` walks the ladder back down to `native` so this
transition is exercised on every run; it is the regression test for either fix.
