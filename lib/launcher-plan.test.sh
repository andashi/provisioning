#!/usr/bin/env bash
# Cases for launcher_plan() in lib/launcher-state.sh: whether a zone
# needs a push at all, decided from the host alone. Its dangerous answer is
# "unchanged" - that one makes the loop skip a zone without starting it, so a
# wrong "unchanged" is a change that never arrives and a run that says so in
# green. Every case that must NOT skip is here for that reason.
set -uo pipefail
eval "$(sed -n '/^launcher_plan()/,/^}/p' "$(dirname "${BASH_SOURCE[0]}")/launcher-state.sh")"
pass=0; fail=0
t() {   # $1=name $2..$5=want_sha rec_sha want_wp rec_wp $6=expected
  local got; got="$(launcher_plan "$2" "$3" "$4" "$5")"
  if [ "$got" = "$6" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s: expected %s, got %s\n' "$1" "$6" "$got"; fail=$((fail+1)); fi
}

t "same config, same wallpaper"                 a1 a1 w1   w1   unchanged
t "same config, no wallpaper on either side"    a1 a1 none none unchanged
t "the config changed"                          a2 a1 w1   w1   changed
t "the wallpaper bytes changed under one name"  a1 a1 w2   w1   changed
t "a wallpaper added"                           a1 a1 w1   none changed
t "the wallpaper removed"                       a1 a1 none w1   changed
t "never pushed: no record at all"              a1 "" w1   ""   changed
t "a record from before the wallpaper field"    a1 a1 w1   ""   changed
t "an empty hash is never agreement"            "" "" none none changed

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
