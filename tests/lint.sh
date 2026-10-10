#!/usr/bin/env bash
# Static checks over everything that runs here: `bash -n` and ShellCheck over
# every tracked bash script, actionlint over the workflows.
#
#   tests/lint.sh             all three; fails on any finding
#   tests/lint.sh --list      the scripts it checks, one per line
#
# A script is found by its first line, not by its name: bin/pr-gate,
# bin/andashi and the commit-msg hook carry no .sh, and the CI step that
# looked for *.sh never checked them. A tool that is missing is a failure,
# not a skip - a lint that passes because it did not run is the defect this
# repository exists to avoid. CI installs pinned versions
# (.github/workflows/verify-apks.yml); locally, put them on PATH.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

scripts() {
  git ls-files -z | while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    IFS= read -r first < "$f" 2>/dev/null || continue
    case "$first" in
      '#!'*bash*|'#!/bin/sh'*|'#!/usr/bin/env sh'*) printf '%s\n' "$f";;
    esac
  done
}

[ "${1:-}" = --list ] && { scripts; exit 0; }

mapfile -t files < <(scripts)
[ "${#files[@]}" -gt 0 ] || { echo "lint: found no scripts - refusing to report a clean run" >&2; exit 1; }
fail=0

for f in "${files[@]}"; do bash -n "$f" || { echo "syntax error: $f" >&2; fail=1; }; done
echo "bash -n: ${#files[@]} scripts"

if command -v shellcheck >/dev/null; then
  shellcheck -S warning "${files[@]}" || fail=1
  echo "shellcheck $(shellcheck --version | sed -n 's/^version: //p'): ${#files[@]} scripts"
else
  echo "lint: shellcheck is not installed" >&2; fail=1
fi

if command -v actionlint >/dev/null; then
  actionlint || fail=1
  echo "actionlint $(actionlint --version | head -1): $(ls .github/workflows/*.yml | wc -l) workflows"
else
  echo "lint: actionlint is not installed" >&2; fail=1
fi

exit "$fail"
