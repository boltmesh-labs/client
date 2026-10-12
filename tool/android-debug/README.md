# Android native-crash debugging: the two Go runtimes

How the **AWG/stream → stock WireGuard owner switch on Android** was traced to a
SIGSEGV, and what actually causes it. The switch is the rung change back *into*
`native` — bringing a stock tunnel up after an obfuscated or stream rung has been
live.

This directory holds the two small tools the investigation needed, because the
usual ones do not work here (see [Why the usual tools fail](#why-the-usual-tools-fail)).

## Symptom

On the descent to `native`, after an `awg` or `stream` rung:

```text
I AmneziaWG/GoBackend: Bringing tunnel boltmesh0 DOWN
I WireGuard/GoBackend: Bringing tunnel boltmesh0 UP      <- the stock backend starts
D WireGuard/GoBackend: Requesting to start VpnService
D WireGuard/GoBackend: Go backend f333402                <- libwg-go's wgVersion()
I Zygote: Process NNNN exited due to signal 11 (Segmentation fault)
```

The app dies with no Dart exception, ~130 ms after the stock device starts, and
with **no tombstone** (see below). Reproduced on every run; the upward walk
(`native → awg → stream`) is fine.

## The two Go runtimes

The process links **two** Go `c-shared` libraries:

- `libwg-go.so` — the stock plugin's backend (`com.wireguard.android:tunnel`),
  constructed by the plugin's `onAttachedToEngine` when the engine attaches.
- `libawg-go.so` — BoltMesh's AWG host (`android/awg-native/`), loaded when the
  first obfuscated/stream rung starts.

## Root cause: two initialized Go runtimes in one process

Each Go runtime installs **process-global** state: its `SIGSEGV`/`SIGBUS`/`SIGURG`
handlers, its `sigaltstack`, its timers, its `pthread`/`%fs` TLS scheme. The
second runtime to initialize **replaces the first one's**, and the first runtime
keeps running as if it still owned them. So once both are live, the next thing
that exercises the stale half faults — here, the stock backend *starting its
device* after the AWG runtime is up:

- The crash carries **no tombstone**: a Go handler owns the signal, so bionic's
  `debuggerd` never runs.
- The faulting **stock** thread's RIP lands in **libawg-go.so's executable
  segment** — it is libawg's handler running over a signal from libwg's runtime,
  reading libwg's TLS as its own `g`.

This is not a symbol-binding problem, and it is not something thread confinement
can fix (the two runtimes are already on different threads). Two Go runtimes
simply cannot share a process.

### The symbol-preemption theory was disproven

The overlapping dynamic symbols are real — the two libraries export **46 of the
same** cgo runtime symbols (`crosscall1/2`, `_cgo_*`, `x_cgo_*`, `fatalf`,
`main.main`, `_cgo_yield`, `x_crosscall2_ptr`, …). It is tempting to blame them.
It was tested directly: `libawg-go.so` was rebuilt with a linker version script
exporting only its JNI entry points and its own `awg*` C API, leaving **zero**
cgo runtime symbols global (`llvm-readelf --dyn-syms` confirmed). The debug APK
was rebuilt, installed, and re-run — **the descent crashed identically**. Symbol
visibility is not the cause.

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
  (`0x1f3190`).
- `tid 9534` is the thread that ran the stock `WireGuard/GoBackend`; its last log
  is `Go backend f333402` — libwg's `wgVersion()` — immediately before the fault.
- `comm=DefaultDispatch` is a `Dispatchers.IO` worker.

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

### `xver` — probe the two libraries without the app

Loads both libraries and drives their version functions (and, for the `*turnon`
modes, a real TUN device) in different orders:

```sh
adb push build/android-debug/x86_64/xver /data/local/tmp/
adb push <libwg-go.so> /data/local/tmp/libwg-go.so
adb push <libawg-go.so> /data/local/tmp/libawg-go.so
# absolute paths: a bare name is not on the device's library search path
adb shell 'cd /data/local/tmp && ./xver /data/local/tmp/libwg-go.so \
  /data/local/tmp/libawg-go.so same-thread'
```

- `same-thread` — **one thread enters both runtimes**. Crashes 100% (fault addr
  `0x38` inside the second library's `cgocallback`, and *this* one does leave a
  tombstone). This is the inherent one-thread/two-runtime `%fs` conflict, which
  is why the Java side confines each runtime to its own thread; it is not the
  app's crash, and no symbol-visibility change touches it.
- `wg-first` / `awg-first` / `wg-again` / `awg-again` — leaf `*Version` calls in
  various orders; clean in every combination, which is exactly why the version
  script looked like a fix until the real app was run.
- `turnon` / `turnon-awg` — the intended deep repro. `wgTurnOn` will not stand a
  device up from a plain process on current images (`CreateUnmonitoredTUNFromFD:
  bad file descriptor`), so these modes do not reproduce; the app run is the
  decider.

## The fix: one Go runtime

Never load `libwg-go` on Android. Every rung — stock, obfuscated and stream —
runs on the in-process AWG engine, whose config parser accepts a stock wg-quick
config unchanged:

- `lib/features/vpn/data/tunnel_adapter.dart` — `AndroidTunnelAdapter` always
  takes the AWG path (`start`/`stop`/reads/`killGhost`/`requestConsent`), and
  never touches the plugin's backend.
- `android/build.gradle.kts` — the source overlay drops the plugin's
  attach-time `createBackend()` call, so the stock `GoBackend` is never built and
  `libwg-go.so` is never loaded.

`integration_test/app_e2e.dart` walks the ladder back down to `native`, so this
transition is exercised on every run — it is the regression test for the fix.
