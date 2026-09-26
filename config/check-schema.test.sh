#!/usr/bin/env bash
# Cases for check-schema.sh. A checker's correct answer and its broken answer
# look the same from outside - both are silence - so the only thing that finds
# a checker which has stopped working is a case where it must fail.
#
# This one proved the point while it was being written: the first version used
# `$sch.additionalProperties // true`, jq treats false as empty, every closed
# object read as open, and the unknown-key check - the whole reason the script
# exists - passed a config carrying home.dock without a word.
set -uo pipefail
cd "$(dirname "$0")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/launcher"
pass=0; fail=0

t() {   # $1=name $2=expected fragment ("" = must pass)
  local out rc
  out="$(OUT_DIR="$tmp/launcher" ./check-schema.sh 2>&1)"; rc=$?
  if [ -z "$2" ]; then
    if [ "$rc" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
    else printf '  FAIL  %s\n        expected a pass, got: %s\n' "$1" "$out"; fail=$((fail+1)); fi
  else
    if [ "$rc" != 0 ] && printf '%s' "$out" | grep -qF "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
    else printf '  FAIL  %s\n        expected [%s], rc=%s, got: %s\n' "$1" "$2" "$rc" "$out"; fail=$((fail+1)); fi
  fi
}

cp launcher/home.json "$tmp/launcher/z.json"
t "the real configs pass" ""

jq '.home.dock = {"enabled": true}' launcher/home.json > "$tmp/launcher/z.json"
t "a key the contract removed" ".home.dock: not a key of this contract"

jq '.appearance.glass.contrast = "extreme"' launcher/home.json > "$tmp/launcher/z.json"
t "a value outside its enum" '.appearance.glass.contrast: "extreme" is not one of'

jq '.home.grid.columns = "four"' launcher/home.json > "$tmp/launcher/z.json"
t "a value of the wrong type" ".home.grid.columns: expected integer, got string"

jq '.icons.pack = 7' launcher/home.json > "$tmp/launcher/z.json"
t "a string key given a number" ".icons.pack: 7 matches none of the accepted forms"

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
