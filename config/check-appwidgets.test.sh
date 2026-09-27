#!/usr/bin/env bash
# Cases for check-appwidgets.sh. A tripwire that has never been seen to fire is
# indistinguishable from no tripwire - and this one is meant to stay quiet for
# months, which is exactly the condition under which a broken check is never
# noticed.
set -uo pipefail
cd "$(dirname "$0")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/launcher"
pass=0; fail=0

t() {   # $1=name $2=expected fragment ("" = must pass)
  local out rc
  out="$(OUT_DIR="$tmp/launcher" ./check-appwidgets.sh 2>&1)"; rc=$?
  if [ -z "$2" ]; then
    if [ "$rc" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
    else printf '  FAIL  %s\n        expected a pass, got: %s\n' "$1" "$out"; fail=$((fail+1)); fi
  else
    if [ "$rc" != 0 ] && printf '%s' "$out" | grep -qF "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
    else printf '  FAIL  %s\n        expected [%s], rc=%s, got: %s\n' "$1" "$2" "$rc" "$out"; fail=$((fail+1)); fi
  fi
}

cp launcher/home.json "$tmp/launcher/z.json"
t "the built-in favorites widget" ""

jq '.home.grid.layouts.phone.items[0].widget = "com.example.weather/.WidgetProvider"' \
  launcher/home.json > "$tmp/launcher/z.json"
t "a provider on the phone layout" "z: com.example.weather/.WidgetProvider"

jq '.home.grid.layouts.fold.items[0].widget = "com.example.clock/.Big"' \
  launcher/home.json > "$tmp/launcher/z.json"
t "a provider on the fold layout only" "z: com.example.clock/.Big"

jq '.home.grid.layouts.phone.items = []' launcher/home.json > "$tmp/launcher/z.json"
t "a zone with no items at all" ""

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
