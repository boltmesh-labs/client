# AmneziaWG vs stock wireguard-go: per-packet CPU cost

The Android client runs **every** rung on the AmneziaWG engine, so a
non-obfuscated `native` rung is served by `libawg-go.so` where it used to be
served by the stock plugin's `libwg-go.so`. That was a deliberate trade — one Go
runtime in the process instead of two, which is what fixed the owner-switch
segfault — and this directory measures what it costs.

The short version: on a plain, non-obfuscated config the fork adds about **70 ns
per forwarded packet**, against roughly **1.5 µs** of per-packet
chacha20poly1305, and it allocates nothing. See
[Results](#results).

## The confound this exists to control

The two engines we ship are not just different forks, they are different Go
runtimes, and a Go version moves this kind of benchmark more than a fork does:

| | engine | Go runtime | upstream revision |
| --- | --- | --- | --- |
| stock `libwg-go.so` | `golang.zx2c4.com/wireguard` | go1.24.3 | `v0.0.0-20250521234502-f333402bd9cb` |
| our `libawg-go.so` | `amneziawg-go/v3 v3.1.20260828` | go1.27.2 | -- |

Both values come from the Go build info embedded in the two shipped `.so` files
(`go version -m libwg-go.so`), not from a source tree. So a straight A/B measures
Go plus the fork together and cannot say which moved.

The matrix crosses the engine with the toolchain instead. `go1.25.0` is the
lowest common arm, because `amneziawg-go/v3`'s `go` directive is `1.25.0` and
upstream builds under anything newer; that is the arm where the fork is the only
difference.

## What runs

Six cells, each one a module copy built and benchmarked on its own:

| cell | engine | Go | role |
| --- | --- | --- | --- |
| `stock-go125` | upstream, stock revision | go1.25.0 | the fork comparison arm |
| `awg-go125` | AmneziaWG | go1.25.0 | the fork comparison arm |
| `stock-go127` | upstream, stock revision | go1.27.2 | the fork comparison arm |
| `awg-go127` | AmneziaWG | go1.27.2 | the fork comparison arm |
| `stock-newest-go127` | upstream, newest revision | go1.27.2 | upstream movement since we pinned |
| `stock-shipped` | upstream, stock revision | go1.24.3 | reproduces the shipped `libwg-go.so` |

Stock and AmneziaWG are listed adjacent, in pairs. That matters: an earlier run
ordered every stock cell before every AmneziaWG one and produced a
significant-looking 10% "regression" that the paired arm refuted. Cells are
interleaved across `REPS` passes for the same reason.

Within a cell, three instruments run, because no single one answers the question:

| benchmark | what it is | source |
| --- | --- | --- |
| `BenchmarkThroughput` | the engine's own upstream benchmark: a real two-device tunnel over loopback UDP | the module's `device_test.go` |
| `BenchmarkEngineCPU` / `...InMemory` | one packet across a two-device tunnel, reported as CPU time via `getrusage` | injected, see below |
| `BenchmarkTransportSeal` / `...Open` | one chacha20poly1305 seal/open of a full-size packet: the engine's dominant per-packet cost, and shared code | injected |
| `BenchmarkAWGHeaderProtection` / `BenchmarkAWGTypeScan` | the fork's two per-packet additions over upstream, measured directly | injected, tagged cells only |

The injected benchmarks live in `engine_cpu_test.go.tmpl` and
`obfuscation_cost_test.go.tmpl`. They are not Go files here because they cannot
build on their own; `run.sh` copies each into the module's `device` package as
`zz_*.go`, substituting `__ENGINE__` for that module's import path. Both engines
therefore run **byte-identical** benchmark code, differing only in which module
it is compiled against, and the second file is gated behind `-tags
boltmesh_awg`, which only the AmneziaWG cells get.

## Usage

```sh
tool/awg-bench/run.sh                     # the full matrix, ~10 minutes
COUNT=5 REPS=2 tool/awg-bench/run.sh      # fewer samples, two passes
PROFILE=awg-go127 tool/awg-bench/run.sh   # CPU-profile one cell instead

```

| env | default | meaning |
| --- | --- | --- |
| `BENCHTIME` | `0.5s` | `go test -benchtime` for every cell |
| `COUNT` | `10` | `go test -count` per pass |
| `REPS` | `1` | passes over the matrix, interleaved |
| `PROFILE` | -- | a cell label to profile with `pprof` instead of benchmarking |
| `KEEP` | `0` | keep the work dir and print its path |
| `WORK_DIR` | a fresh `mktemp -d` | reuse a directory instead of a temporary one |

Needs network the first time: two extra Go toolchains and one module revision
are not in the local cache, and `benchstat` is installed into the work dir if it
is not already on `PATH`. The exit status is non-zero if any cell fails to build
or run. Nothing here runs in CI: it needs a quiet, unloaded machine and its
numbers are not a gate.

## Results

An interleaved run -- three passes of five samples, so 15 samples per cell -- on
an Intel i7-10700K, `GOOS=linux GOARCH=amd64`. `~` means no significant
difference.

### The fork at equal Go

| benchmark | stock go1.27.2 | AmneziaWG go1.27.2 | delta |
| --- | --- | --- | --- |
| `Throughput` (wall) | 47.75 µs | 47.03 µs | `~` (p=0.325) |
| `EngineCPU` (CPU/packet) | 207.5 µs | 208.7 µs | `~` (p=0.653) |
| `EngineCPUInMemory` (CPU/packet) | 87.87 µs | 88.45 µs | `~` (p=0.653) |
| `TransportSeal` | 760.5 ns | 758.5 ns | `~` (p=0.713) |
| `TransportOpen` | 723.0 ns | 720.9 ns | `~` (p=0.486) |

The same comparison at go1.25.0 says the same thing: every metric `~`, smallest
p-value 0.087.

### What the fork actually adds

| | cost | how often |
| --- | --- | --- |
| `HeaderProtectionCipher` | 28.97 ns ± 1% | per sent and per received packet |
| `DeterminePacketTypeAndPadding` | 10.60 ns ± 1% | per received packet |
| **total, one forwarded packet** | **~69 ns** | 2 × 28.97 + 10.60 |

One forwarded packet pays that against about 760 ns of seal and 723 ns of open,
so the addition is roughly **4.6%** of the engine's per-packet crypto. It
allocates nothing: `TransportSeal`, `TransportOpen` and both differential
benchmarks all report `0 B/op`, `0 allocs/op`.

### The positive control

| comparison | `Throughput` |
| --- | --- |
| stock, go1.25.0 to go1.27.2 | **+5.00%** (p=0.000) |
| AmneziaWG, go1.25.0 to go1.27.2 | **+4.29%** (p=0.000) |
| upstream newest vs stock revision, both go1.27.2 | **-3.55%** (p=0.009) |
| stock vs AmneziaWG at equal Go | `~` |

Holding the engine fixed and moving only the toolchain shifts wall-clock
throughput by 4-5%. That is larger than the fork's own effect, which is the whole
reason this matrix exists. It also shows the instrument is not blind -- it
resolves a 4-5% difference -- so "no significant difference" for the fork is a
bound, not a shrug.

### What ships today

The stock revision on go1.24.3 against AmneziaWG on go1.27.2, conflated by
design: `Throughput` +2.88% (p=0.033), while per-packet CPU and the crypto stay
indistinguishable (p ≥ 0.25). That reads as the toolchain's effect on a
wall-clock benchmark rather than the fork's, since at equal Go the fork measures
as zero -- but the shipped pair is what it is, and it is the honest headline for
the native rung as it changes engines today.

## How to read this

- **The two engines' crypto is the same code.** `BenchmarkTransportSeal` and
  `...Open` should land within noise of each other and at identical `allocs/op`
  (zero). If they ever diverge, the fork changed the data plane and the premise
  of the fix is gone.
- **The fork's cost is what `AWGHeaderProtection` and `AWGTypeScan` report.**
  A plain config leaves the header-protection key zero, so `HeaderProtectionCipher`
  takes its cheap branch: one `RWMutex` read-lock and a zero-key check. It runs
  once per sent packet (`send.go`) and once per received one (`receive.go`), so a
  packet forwarded one way pays it twice. `DeterminePacketTypeAndPadding` is
  receive-only, and runs even with obfuscation off — it is what upstream does
  with a single byte load.
- **The whole-packet numbers are an upper bound, not the answer.** They are
  diluted by roughly two orders of magnitude; see below. Use them to rule out a
  gross regression, and read the differential numbers for the actual cost.

### Why the whole-packet instrument is blunt

A per-op wall or CPU figure for a packet crossing the test harness is dominated
by the harness. Profiling one cell (`PROFILE=awg-go127`) attributes it directly:

```text
      flat  flat%   sum%        cum   cum%
     1.16s 48.74% 48.74%      1.16s 48.74%  runtime.nanotime (inline)
     0.40s 16.81% 65.55%      0.40s 16.81%  runtime.futex
     0.36s 15.13% 80.67%      0.36s 15.13%  time.runtimeNow
     0.57s 23.95%                  ...      runtime.findRunnable
```

Half the samples are the runtime's own clock calls — the receive path asks
`time.Now()` per packet (`receive.go`) — and most of the rest is goroutine
hand-off, with the packet being passed between two devices over channels. That
overhead is around a hundred times the engine's per-packet work, so the engine
term cannot be resolved through it; the differential benchmarks exist precisely
because it cannot.

### Caveats

- **`GOOS=linux` is not `GOOS=android`.** The Android build selects
  `queueconstants_android.go`, which sets `PreallocatedBuffersPerPool = 4096`
  against the host's `0`. It is symmetric — both engines get the same — so the
  *difference* is unaffected, but absolute memory behaviour is not the phone's.
- **amd64 is not arm64.** `chacha20poly1305` uses NEON on a phone. Treat the
  ratio as the portable quantity and the absolute nanoseconds as indicative.
- **One op is a round trip.** The whole-packet benchmarks run both ends of the
  tunnel in one process, so one op is a full encrypt/decrypt, about twice what a
  single forwarded packet pays. The differential benchmarks are per call, not per
  round trip.
- **Plain configs only.** No obfuscation directive is set, which is the case in
  question. Turning obfuscation on moves the numbers by far more than anything
  measured here, and is not what an obfuscated rung's cost is about.

## Keeping it current

The revisions and the `benchstat` pin are at the top of `run.sh`. Bump them when
the app's engines move, and re-check the Go build info of the shipped `.so` files
rather than assuming:

```sh
unzip -p tunnel-*.aar jni/arm64-v8a/libwg-go.so | strings -n 5 |
  grep -aE '^dep|^go1\.'
```
