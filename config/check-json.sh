#!/usr/bin/env bash
# Every file named on the command line must parse as JSON.
#
# This was a loop in the Makefile:
#
#     for f in config/*.json; do jq -e . $f >/dev/null && echo "ok: $f"; done
#
# A shell `for` loop exits with its LAST iteration's status, so a broken file
# anywhere but at the end was checked, found broken, and reported green. It is
# a script now so that a case can watch it fail; a loop inside a recipe cannot
# be tested without running the whole recipe.
#
# `jq empty` rather than `jq -e .`: with -e, jq takes its exit status from the
# last value it printed, so a file whose entire content is `false` or `null` -
# valid JSON, both of them - is reported as unparseable. Whether such a file is
# a sensible config is check-schema.sh's question, not this one's.
set -uo pipefail

if [ "$#" -eq 0 ]; then
  echo "check-json: no files given - a glob that matched nothing is not a pass" >&2
  exit 2
fi

failed=0
for f in "$@"; do
  if [ ! -f "$f" ]; then
    # An unexpanded glob arrives here as a literal path. Reading that as
    # "nothing to check" is how a moved directory passes.
    printf 'MISSING: %s\n' "$f" >&2
    failed=1
    continue
  fi
  if [ ! -s "$f" ]; then
    # jq reads an empty file as zero documents and exits 0. Zero documents is
    # not a config, and a truncated write is exactly how one gets here.
    printf 'INVALID: %s\n  empty file\n' "$f" >&2
    failed=1
    continue
  fi
  if err="$(jq empty "$f" 2>&1)"; then
    printf 'ok: %s\n' "$f"
  else
    printf 'INVALID: %s\n%s\n' "$f" "$err" >&2
    failed=1
  fi
done

exit "$failed"
