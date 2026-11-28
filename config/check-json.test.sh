#!/usr/bin/env bash
# Cases for check-json.sh.
#
# The script replaces a loop that validated every file and reported only the
# last one's verdict, so the case that matters is a broken file in the MIDDLE:
# it is the one the old loop answered wrongly, and it is indistinguishable
# from a working check unless somebody writes it down.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0

t() {   # $1=name $2=expected fragment ("" = must pass); rest: arguments
  local name="$1" want="$2"; shift 2
  local out rc
  out="$(./check-json.sh "$@" 2>&1)"; rc=$?
  if [ -z "$want" ]; then
    if [ "$rc" = 0 ]; then printf '  ok    %s\n' "$name"; pass=$((pass+1))
    else printf '  FAIL  %s\n        expected a pass, rc=%s, got: %s\n' "$name" "$rc" "$out"; fail=$((fail+1)); fi
  else
    if [ "$rc" != 0 ] && printf '%s' "$out" | grep -qF "$want"; then printf '  ok    %s\n' "$name"; pass=$((pass+1))
    else printf '  FAIL  %s\n        expected [%s], rc=%s, got: %s\n' "$name" "$want" "$rc" "$out"; fail=$((fail+1)); fi
  fi
}

printf '{"a": 1}\n' > "$tmp/1.json"
printf '{"b": 2}\n' > "$tmp/2.json"
printf '{"c": 3}\n' > "$tmp/3.json"
printf '{"d": \n'   > "$tmp/broken.json"

t "the files this repository ships" "" ./*.json ../config/*.json
t "three valid files" "" "$tmp/1.json" "$tmp/2.json" "$tmp/3.json"

# The defect. Before the fix the loop's status was the last file's, so this
# combination - broken in the middle, valid at the end - exited 0.
t "broken in the middle" "INVALID: $tmp/broken.json" "$tmp/1.json" "$tmp/broken.json" "$tmp/3.json"

# Control: the old loop refused this one too, so it passes in both states. It
# is here to show the fix did not trade one position for another.
t "broken at the end" "INVALID: $tmp/broken.json" "$tmp/1.json" "$tmp/2.json" "$tmp/broken.json"
t "broken at the front" "INVALID: $tmp/broken.json" "$tmp/broken.json" "$tmp/2.json" "$tmp/3.json"

# A failure must not read as a pass. An empty argument list is what a glob
# that matched nothing leaves behind, and an unexpanded glob arrives as a
# literal path - both of them are "I could not look", not "nothing is wrong".
t "no files at all" "no files given"
t "a path that does not exist" "MISSING: $tmp/nope.json" "$tmp/nope.json"
t "an unexpanded glob" "MISSING: $tmp/none-of-these-*.json" "$tmp"/none-of-these-*.json

# Valid JSON that is not an object. `jq -e .` exits 1 on these, which would
# report a parseable file as broken; whether a config may be `false` is
# check-schema.sh's question.
printf 'false\n' > "$tmp/false.json"
printf 'null\n'  > "$tmp/null.json"
t "a file that is just false" "" "$tmp/false.json"
t "a file that is just null"  "" "$tmp/null.json"

# An empty file parses as nothing at all, which is not a JSON document.
: > "$tmp/empty.json"
t "an empty file" "INVALID: $tmp/empty.json" "$tmp/empty.json"

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
