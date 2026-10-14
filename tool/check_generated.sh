#!/usr/bin/env bash
# Fails when generated code drifts from what is committed.
#
# `lib/l10n/gen/**`, `*.freezed.dart` and `*.g.dart` are excluded from
# analysis and generated on the developer's machine, so a stale file can
# otherwise ship green.
#
# Only the generated files are compared, so a working tree with unrelated
# uncommitted edits still gets a clean signal. The comparison is against the
# index, not HEAD: during a commit the regenerated files are already staged,
# and staged changes to those very files are expected. Drift is a mismatch
# between the regenerated working tree and the index (plus untracked
# generated files). On a clean CI checkout index == HEAD, so the guard is
# unchanged there. The installed build_runner reports
# `--delete-conflicting-outputs` as removed/ignored (outputs are always
# overwritten now), so it is omitted. The pre-commit `trailing-whitespace`
# hook strips the trailing whitespace build_runner emits; reproduce that
# before diffing so only real generator drift remains.
set -euo pipefail

cd "$(dirname "$0")/.."

flutter gen-l10n
dart run build_runner build

# l10n.yaml owns where `flutter gen-l10n` writes, and the check has to look
# there or it silently stops noticing those files: a `find` over a hardcoded
# path that no longer exists matches nothing, and the drift would ship. Read
# the setting instead, and fail loudly if the directory it names is not there
# after `flutter gen-l10n` above. build_runner output (freezed, json_serializable)
# is always under `lib/`, so that `find` stays hardcoded.
l10n_out="$(sed -n 's/^output-dir:[[:space:]]*//p' l10n.yaml | head -n1)"
l10n_out="${l10n_out:-lib/l10n/gen}"
if [[ ! -d "$l10n_out" ]]; then
  echo "l10n output directory '$l10n_out' (l10n.yaml output-dir) not found" >&2
  exit 1
fi

generated=()
while IFS= read -r file; do
  generated+=("$file")
done < <(
  {
    find "$l10n_out" -type f -name '*.dart'
    find lib -type f \( -name '*.freezed.dart' -o -name '*.g.dart' \)
  } | sort -u
)

if [[ ${#generated[@]} -eq 0 ]]; then
  echo "no generated files found (l10n output and build_runner output)" >&2
  exit 1
fi

# `perl -pi` is used instead of `sed -i` for BSD/macOS portability.
perl -pi -e 's/[ \t]+$//' "${generated[@]}"
dart format "${generated[@]}" >/dev/null

# Compare the regenerated working tree against the index, not HEAD: staged
# changes to the very files being committed are expected, only a mismatch
# between the regenerated output and the staged content is drift. Untracked
# generated files (never `git add`ed) are drift too.
dirty=$(
  {
    git diff --name-only -- "${generated[@]}"
    git ls-files --others --exclude-standard -- "${generated[@]}"
  } | sort -u
)
if [[ -n "$dirty" ]]; then
  echo "$dirty" >&2
  echo >&2
  echo "Generated code is stale. Regenerate it (tool/check_generated.sh)" >&2
  echo "and commit the result." >&2
  exit 1
fi

echo "Generated code is up to date."
