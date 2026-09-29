#!/usr/bin/env bash
# Cases for report_moved() in lib/launcher-state.sh: the condition
# that decides whether the launcher saved something since we last agreed with
# a zone. Every device we run today answers null for both fields, so the
# interesting half of this function cannot be reached on a device yet - which
# is exactly why it has cases.
set -uo pipefail
eval "$(sed -n '/^report_moved()/,/^}/p' "$(dirname "${BASH_SOURCE[0]}")/launcher-state.sh")"
pass=0; fail=0
t() {   # $1=name $2..$5=dev_seq dev_store rec_seq rec_store $6=yes|no
  local want="$6" got=no
  report_moved "$2" "$3" "$4" "$5" && got=yes
  if [ "$got" = "$want" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s: expected %s, got %s\n' "$1" "$want" "$got"; fail=$((fail+1)); fi
}

t "a higher number in the same store"     9  s1  8  s1  yes
t "a gap in the numbering still counts"   40 s1  8  s1  yes
t "the same number"                       8  s1  8  s1  no
t "an older build answers null"           "" ""  8  s1  no
t "we have no number yet"                 9  s1  "" ""  no
t "a new store is not a comparison"       1  s2  8  s1  no
t "a store we never recorded"             9  s1  8  ""  no
t "a device without a store id"           9  ""  8  s1  no
t "lower, which means a new store or a bug, is not our call" 3 s1 8 s1 no

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
