#!/usr/bin/env bash
# Fails when generated code drifts from what is committed.
#
# `lib/l10n/gen/**`, `*.freezed.dart` and `*.g.dart` are excluded from
# analysis and generated on the developer's machine, so a stale file can
# otherwise ship green. Run from anywhere; the script cd's to `client/`.
#
# Only the generated files are compared, so a working tree with unrelated
# uncommitted edits still gets a clean signal. The installed build_runner
# reports `--delete-conflicting-outputs` as removed/ignored (outputs are
# always overwritten now), so it is omitted. The pre-commit
# `trailing-whitespace` hook strips the trailing whitespace build_runner
# emits; reproduce that before diffing so only real generator drift remains.
set -euo pipefail

cd "$(dirname "$0")/.."

flutter gen-l10n
dart run build_runner build

generated=()
while IFS= read -r file; do
  generated+=("$file")
done < <(
  {
    find lib/l10n/gen -type f -name '*.dart' 2>/dev/null || true
    find lib -type f \( -name '*.freezed.dart' -o -name '*.g.dart' \)
  } | sort -u
)

if [[ ${#generated[@]} -eq 0 ]]; then
  echo "no generated files found under lib/" >&2
  exit 1
fi

# `perl -pi` is used instead of `sed -i` for BSD/macOS portability.
perl -pi -e 's/[ \t]+$//' "${generated[@]}"
dart format "${generated[@]}" >/dev/null

dirty=$(git status --porcelain -- "${generated[@]}")
if [[ -n "$dirty" ]]; then
  echo "$dirty" >&2
  echo >&2
  echo "Generated code is stale. Regenerate it (client/tool/check_generated.sh)" >&2
  echo "and commit the result." >&2
  exit 1
fi

echo "Generated code is up to date."
