#!/usr/bin/env bash
# Cases for check-invariants.sh: the real catalog passes, and each rule fails
# on the smallest edit that breaks it. A rule without a case where it must fail
# is a guess about what it catches.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
# The cases start from the template with Azure taken out of Ops: the template
# itself breaks rule 1 there (a sandboxed-Play app in a zone declared
# play: none), which is a catalog decision still open, and each case here
# must test exactly one rule.
fresh() { cp profiles.json "$tmp/"; jq '(.apps[] | select(.id == "azure") | .profiles) -= ["ops"]' apps.json > "$tmp/apps.json"; }
t() {   # $1=name $2=expected fragment ("" = must pass)
  local out rc
  out="$(CONFIG_DIR="$tmp" ./check-invariants.sh 2>&1)"; rc=$?
  if [ -z "$2" ]; then
    if [ "$rc" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
    else printf '  FAIL  %s\n        expected a pass, got: %s\n' "$1" "$out"; fail=$((fail+1)); fi
  elif [ "$rc" != 0 ] && printf '%s' "$out" | grep -qF "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n        expected [%s], rc=%s, got: %s\n' "$1" "$2" "$rc" "$out"; fail=$((fail+1)); fi
}
edit() { jq "$2" "$tmp/$1" > "$tmp/$1.new" && mv "$tmp/$1.new" "$tmp/$1"; }

fresh; t "the template, without its one open violation, passes" ""

fresh; edit apps.json '(.apps[] | select(.source == "play-sandboxed") | .profiles) |= . + ["anon"]'
t "a Play app placed in Anon" "which has no Play"
fresh; edit apps.json '(.apps[] | select(.source == "play-sandboxed") | .profiles) |= . + ["home"]'
t "a Play app placed in Home" "is in home"
fresh; edit profiles.json '(.profiles[] | select(.key == "lab") | .play) = "none"'
t "a zone declared Play-free that holds Play apps" ""   # lab holds no Play app in the template
fresh; edit apps.json '(.apps[] | select(.source == "play-sandboxed") | .profiles) |= . + ["lab"]'
       edit profiles.json '(.profiles[] | select(.key == "lab") | .play) = "none"'
t "... and one that does" "is in lab"

fresh; edit profiles.json '(.profiles[] | select(.key == "ops") | .runtime) = "always"'
t "a second always-on zone" "more than one zone besides Home runs always: cloud, ops"
fresh; t "Home and its managed profile do not count" ""
fresh; edit profiles.json '(.profiles[] | select(.key == "cloud") | .runtime) = "on-demand"'
t "no always-on zone besides Home is fine" ""

fresh; edit apps.json '(.apps[] | select(.id == "heliboard") | .perms.grant) = ["android.permission.INTERNET"]'
t "net: false with an INTERNET grant" "HeliBoard is net: false and grants INTERNET"

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
