#!/usr/bin/env bash
# Cases for check-appwidgets.sh. A tripwire that has never been seen to fire is
# indistinguishable from no tripwire - and this one is meant to stay quiet for
# months, which is exactly the condition under which a broken check is never
# noticed.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
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

# Question 1 is answered by the script from the inventory, so it has the same
# three states a person would have had: a build new enough, one too old, and
# no build at all. An older launcher is the case that matters - it is what a
# release_tag pin produces - and it must say so rather than stay silent.
jq '.home.grid.layouts.phone.items[0].widget = "com.example.weather/.P"' \
  launcher/home.json > "$tmp/launcher/z.json"
mkdir -p "$tmp/apks/universal"

: > "$tmp/apks/universal/org.andashi.home-0.9.0.apk"
t2() {   # $1=name $2=expected fragment
  local out
  out="$(OUT_DIR="$tmp/launcher" APKS_DIR="$tmp/apks" ./check-appwidgets.sh 2>&1)"
  if printf '%s' "$out" | grep -qF "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n        expected [%s], got: %s\n' "$1" "$2" "$out"; fail=$((fail+1)); fi
}
t2 "an older launcher is named as too old" "is 0.9.0, older than 0.10.0"

: > "$tmp/apks/universal/org.andashi.home-0.10.0.apk"
t2 "a new enough launcher settles that half" "which carries"

rm -f "$tmp/apks/universal/"*.apk
t2 "no launcher at all is not silence" "UNKNOWN: no launcher APK"

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
