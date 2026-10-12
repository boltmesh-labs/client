#!/usr/bin/env bash
#
# Measures the per-packet cost of the AmneziaWG engine against stock
# wireguard-go, on the host.
#
# Why this is not a straight A/B: the two engines we ship sit behind different
# Go runtimes. The stock libwg-go.so embeds go1.24.3 and
# golang.zx2c4.com/wireguard@v0.0.0-20250521234502-f333402bd9cb; our
# libawg-go.so embeds go1.27.2 and amneziawg-go/v3@v3.1.20260828. The Go
# runtime changed enough between them that a naive comparison measures mostly
# Go, not the fork. So the matrix crosses the engine with the toolchain:
# {stock, awg} x {go1.25.0, go1.27.2}, go1.25.0 being the lowest the AWG
# module's `go` directive allows. The shipped-exact stock cell is run as a
# reference, not as the comparison arm.
#
# Three instruments run in every cell, because no single one answers the
# question on its own:
#
#   BenchmarkEngineCPU / ...InMemory   whole-packet CPU, via getrusage. Honest
#       but blunt: the test TUN's channels and the goroutine hand-offs between
#       the two devices cost about a hundred times what the engine's own
#       per-packet work does, so this dilutes the difference rather than
#       resolving it. Read it as an upper bound.
#   BenchmarkTransportSeal / ...Open   the per-packet chacha20poly1305, which is
#       the engine's dominant per-packet cost and is shared code. Establishes
#       that the crypto itself did not move.
#   BenchmarkAWGHeaderProtection / BenchmarkAWGTypeScan   the fork's entire
#       per-packet addition over upstream, measured directly (tagged cells
#       only). This is the number the question is actually about.
#
# The whole-packet benchmarks come from the engines' own test files, so one op
# is a full encrypt/decrypt round trip: about twice what a single forwarded
# packet pays. The injected benchmarks are byte-identical across both engines,
# substituted only for the import path, so neither engine gets a friendlier
# loop.
#
# Usage:
#   tool/awg-bench/run.sh                     # the full matrix
#   COUNT=5 REPS=2 tool/awg-bench/run.sh      # fewer samples, two passes
#   PROFILE=awg-go127 tool/awg-bench/run.sh   # CPU profile one cell instead
#
# Env:
#   BENCHTIME  go test -benchtime for each cell    (default 0.5s)
#   COUNT      go test -count for each cell        (default 10)
#   REPS       passes over the matrix, interleaved (default 1)
#   PROFILE    a cell label to profile with pprof instead of benchmarking
#   KEEP       set to 1 to keep the work dir (its path is printed)
#   WORK_DIR   use this dir instead of a fresh mktemp -d
#
# Needs network the first time: two extra Go toolchains and one module
# revision are not in the local cache.
#
# Exit status is non-zero if any cell fails to build or run.
set -euo pipefail

benchtime="${BENCHTIME:-0.5s}"
count="${COUNT:-10}"
reps="${REPS:-1}"

# The one revision and one engine this repository ships, so the shipped cell
# cannot drift from what the APK contains.
wireguard_stock="v0.0.0-20250521234502-f333402bd9cb"
wireguard_new="v0.0.0-20260522210424-ecfc5a8d5446"
awg="v3.1.20260828"

wireguard_module="golang.zx2c4.com/wireguard"
awg_module="github.com/amnezia-vpn/amneziawg-go/v3"

# Pinned because this module has no semver tags, so `@latest` would move under
# us and change how the numbers are summarised.
benchstat_module="golang.org/x/perf/cmd/benchstat@v0.0.0-20261009192801-be2c69fb417e"

# Which benchmarks to run. BenchmarkLatency is deliberately absent: it
# allocates and stops a six-second timer per packet, so its per-op cost is
# harness overhead rather than engine cost.
bench_filter='Benchmark(EngineCPU|TransportSeal|TransportOpen|Throughput|AWG)'

# label|module|version|toolchain|build tags. The `go` directive gates which
# toolchain a module can be built with: AWG needs >= go1.25.0 and upstream is
# happy with go1.24.3, so go1.25.0 is the common arm that makes the fork
# comparison clean. Only the AWG cells get the tag that compiles the
# obfuscation-cost benchmarks.
#
# Stock and AWG are listed adjacent, in pairs, so that whatever the machine is
# doing drifts across the two arms of a comparison rather than sitting between
# them: an ordering that ran every stock cell and then every AWG one once
# produced a significant-looking 10% "regression" that the paired arm refuted.
cells=(
  "stock-go125|$wireguard_module|$wireguard_stock|go1.25.0|"
  "awg-go125|$awg_module|$awg|go1.25.0|boltmesh_awg"
  "stock-go127|$wireguard_module|$wireguard_stock|go1.27.2|"
  "awg-go127|$awg_module|$awg|go1.27.2|boltmesh_awg"
  "stock-newest-go127|$wireguard_module|$wireguard_new|go1.27.2|"
  "stock-shipped|$wireguard_module|$wireguard_stock|go1.24.3|"
)

here="$(cd "$(dirname "$0")" && pwd)"
templates=(engine_cpu_test.go.tmpl obfuscation_cost_test.go.tmpl)

work="${WORK_DIR:-}"
if [[ -z "$work" ]]; then
  work="$(mktemp -d "${TMPDIR:-/tmp}/awg-bench.XXXXXX")"
fi
out_dir="$work/out"
mkdir -p "$out_dir" "$work/mods"

cleanup() {
  if [[ "${KEEP:-0}" == 1 ]]; then
    printf 'kept work dir: %s\n' "$work" >&2
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT

modcache="$(go env GOMODCACHE)"

fetch_module() {
  local module="$1" version="$2"
  if [[ -d "$modcache/$module@$version" ]]; then
    return 0
  fi
  printf 'fetching %s@%s\n' "$module" "$version" >&2
  (cd "$work" && go mod download "$module@$version")
}

# The module cache is read-only, and a module's own test files are not
# importable, so each cell gets a writable copy to run `go test` in. The
# injected benchmarks are templated so a single source is used for both
# engines, differing only in the import path.
prepare_module() {
  local label="$1" module="$2" version="$3" src dst template name
  src="$modcache/$module@$version"
  if [[ ! -d "$src" ]]; then
    printf 'module cache has no %s@%s\n' "$module" "$version" >&2
    exit 1
  fi
  dst="$work/mods/$label"
  rm -rf "$dst"
  mkdir -p "$dst"
  cp -R "$src/." "$dst/"
  chmod -R u+w "$dst"
  for template in "${templates[@]}"; do
    name="zz_${template%.tmpl}"
    sed "s|__ENGINE__|$module|" "$here/$template" >"$dst/device/$name"
  done
  printf '%s\n' "$dst"
}

benchstat_bin=""
ensure_benchstat() {
  if command -v benchstat >/dev/null 2>&1; then
    benchstat_bin="$(command -v benchstat)"
    return 0
  fi
  benchstat_bin="$work/bin/benchstat"
  if [[ ! -x "$benchstat_bin" ]]; then
    printf 'installing benchstat\n' >&2
    mkdir -p "$work/bin"
    (cd "$work" && GOBIN="$work/bin" go install "$benchstat_module")
  fi
}

go_test_args() {
  local gotool="$1" tags="$2"
  printf '%s\n' -run '^$' -bench "$bench_filter" -benchtime="$benchtime" -benchmem
  if [[ -n "$tags" ]]; then
    printf '%s\n' -tags "$tags"
  fi
}

# Profiles one cell instead of benching the matrix; -cpuprofile cannot be
# combined with -count > 1.
profile_cell() {
  local want="$1" cell label module version gotool tags dir args
  for cell in "${cells[@]}"; do
    IFS='|' read -r label module version gotool tags <<<"$cell"
    if [[ -z "$label" || -z "$module" || -z "$version" || -z "$gotool" ]]; then
      printf 'malformed cell: %s\n' "$cell" >&2
      exit 1
    fi
    [[ "$label" == "$want" ]] || continue
    fetch_module "$module" "$version"
    dir="$(prepare_module "$label" "$module" "$version")"
    printf 'profiling %s (GOTOOLCHAIN=%s)\n' "$label" "$gotool" >&2
    mapfile -t args < <(go_test_args "$gotool" "$tags")
    (
      cd "$dir"
      GOTOOLCHAIN="$gotool" go test "${args[@]}" -count=1 \
        -cpuprofile="$out_dir/$label.prof" ./device
    ) 2>&1 | tee "$out_dir/$label.txt"
    go tool pprof -top -nodecount=25 "$out_dir/$label.prof"
    return 0
  done
  printf 'no cell named %s\n' "$want" >&2
  exit 1
}

bench_cell() {
  local gotool="$1" tags="$2" dir="$3" args
  mapfile -t args < <(go_test_args "$gotool" "$tags")
  (
    cd "$dir"
    GOTOOLCHAIN="$gotool" go test "${args[@]}" -count="$count" ./device
  )
}

compare() {
  local baseline="$1" candidate="$2"
  printf '\n'
  "$benchstat_bin" "$out_dir/$baseline.bench" "$out_dir/$candidate.bench" ||
    printf 'benchstat could not compare %s and %s; raw output is in the work dir\n' \
      "$baseline" "$candidate"
}

section() {
  printf '\n== %s ==\n' "$1"
}

if [[ -n "${PROFILE:-}" ]]; then
  profile_cell "$PROFILE"
  exit 0
fi

declare -A dirs=()
for cell in "${cells[@]}"; do
  IFS='|' read -r label module version gotool tags <<<"$cell"
  if [[ -z "$label" || -z "$module" || -z "$version" || -z "$gotool" ]]; then
    printf 'malformed cell: %s\n' "$cell" >&2
    exit 1
  fi
  fetch_module "$module" "$version"
  dirs["$label"]="$(prepare_module "$label" "$module" "$version")"
  : >"$out_dir/$label.txt"
done

# Cells are interleaved across passes so a drifting clock or a warming machine
# hits both arms equally.
for ((rep = 1; rep <= reps; rep++)); do
  for cell in "${cells[@]}"; do
    IFS='|' read -r label module version gotool tags <<<"$cell"
    printf 'bench %s (GOTOOLCHAIN=%s) pass %d/%d\n' \
      "$label" "$gotool" "$rep" "$reps" >&2
    if ! bench_cell "$gotool" "$tags" "${dirs[$label]}" >>"$out_dir/$label.txt" 2>&1; then
      printf '::error::cell %s failed; output follows\n' "$label" >&2
      cat "$out_dir/$label.txt" >&2
      exit 1
    fi
  done
done

ensure_benchstat

# benchstat pairs files by their `pkg:` line, and the two engines are different
# packages by definition, so comparing the raw output silently degrades to a
# one-sided table instead of a diff. Drop that header for the comparison; the
# untouched `go test` output stays in the work dir.
for cell in "${cells[@]}"; do
  IFS='|' read -r label _ <<<"$cell"
  grep -E '^(goos|goarch):|^Benchmark' "$out_dir/$label.txt" >"$out_dir/$label.bench"
done

# Each comparison prints every benchmark both cells ran, so a comparison with an
# AWG cell carries the fork's own additions as one-sided rows: those have no
# stock counterpart to diff against, they are the absolute cost being claimed.

section 'Fork cost at equal Go (go1.27.2) -- the headline'
compare stock-go127 awg-go127

section 'Fork cost at the older common Go (go1.25.0)'
compare stock-go125 awg-go125

section 'Go effect on the stock engine (same code, go1.25.0 -> go1.27.2)'
compare stock-go125 stock-go127

section 'Go effect on the AWG engine (same code, go1.25.0 -> go1.27.2)'
compare awg-go125 awg-go127

section 'What ships today (stock+go1.24.3 vs awg+go1.27.2; conflated by design)'
compare stock-shipped awg-go127

section 'Newest upstream vs the stock revision (both go1.27.2)'
compare stock-go127 stock-newest-go127
