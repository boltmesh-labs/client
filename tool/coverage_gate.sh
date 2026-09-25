#!/usr/bin/env bash
# Enforces a minimum line-coverage floor from Flutter's lcov output.
#
# Generated code (l10n/build_runner) is excluded because it is excluded from
# analysis and never unit-tested by design. Usage:
#
#   tool/coverage_gate.sh [min-percent]   # default 80
set -euo pipefail

cd "$(dirname "$0")/.."

min="${1:-80}"
lcov="coverage/lcov.info"
if [[ ! -f "$lcov" ]]; then
  echo "coverage file not found: $lcov (run 'flutter test --coverage')" >&2
  exit 1
fi

# lcov `SF:` paths are absolute and use the host separator, so the generated
# markers are matched against both forms: a Windows/macOS developer would
# otherwise get a different (inflated) percentage than CI on the same tree.
read -r lf lh < <(
  awk -F: '
    function is_generated(p) {
      gsub(/\\/, "/", p)
      return (p ~ /lib\/l10n\/gen\// || p ~ /\.(g|freezed)\.dart$/)
    }
    /^SF:/{ skip = is_generated($0) }
    /^LF:/{ if (!skip) lf += $2 }
    /^LH:/{ if (!skip) lh += $2 }
    END { printf "%d %d\n", lf, lh }
  ' "$lcov"
)

if [[ "$lf" -eq 0 ]]; then
  echo "no instrumented lines in $lcov" >&2
  exit 1
fi

pct=$(awk -v lh="$lh" -v lf="$lf" 'BEGIN { printf "%.2f", 100 * lh / lf }')
echo "Line coverage (excluding generated code): ${pct}% (${lh}/${lf}), floor ${min}%"

awk -v pct="$pct" -v min="$min" 'BEGIN { exit (pct + 0 >= min + 0) ? 0 : 1 }' || {
  echo "::error::line coverage ${pct}% is below the ${min}% floor" >&2
  exit 1
}
