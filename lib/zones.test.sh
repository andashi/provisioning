#!/usr/bin/env bash
# Cases for the zone selection in lib/common.sh (ZONES). The selection decides
# which zones every step touches, so its failure mode is the quiet one: a
# selection that comes out empty makes every step do nothing and end green.
# Each case sources common.sh in a fresh shell, the way a step does.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ADB="$here/../tests/fixtures/fake-adb" ADB_SERIAL=""
export FAKE_USERS='	UserInfo{0:Owner:4c13} running
	UserInfo{10:Work:1030} running
	UserInfo{11:Cloud:410} running
	UserInfo{12:Gadgets:410}
	UserInfo{13:Ops:410}
	UserInfo{14:Lab:410}
	UserInfo{15:Anon:410}'
pass=0; fail=0

# $1=name $2=ZONES $3=current user $4=expected keys, or "DIE" for a refusal
t() {
  local got rc
  got="$(ZONES="$2" FAKE_CURRENT_USER="$3" bash -c '
    source "'"$here"'/common.sh" 2>/dev/null
    profile_keys | tr "\n" " "' 2>/dev/null)"; rc=$?
  got="${got% }"
  if [ "$4" = "DIE" ]; then
    [ $rc -ne 0 ] && { printf '  ok    %s\n' "$1"; pass=$((pass+1)); return; }
    printf '  FAIL  %s: expected a refusal, got "%s"\n' "$1" "$got"; fail=$((fail+1)); return
  fi
  if [ $rc -eq 0 ] && [ "$got" = "$4" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s: expected "%s", got "%s" (rc %s)\n' "$1" "$4" "$got" "$rc"; fail=$((fail+1)); fi
}

t "unset means every zone"               ""            ""  "home work cloud gadgets ops lab anon"
t "one zone"                             "lab"         ""  "lab"
t "several, in catalog order"            "lab home"    ""  "home lab"
t "commas work too"                      "anon,cloud"  ""  "cloud anon"
t "current resolves a created zone"      "current"     14  "lab"
t "current resolves the owner to home"   "current"     0   "home"
t "current plus a named zone"            "current ops" 11  "cloud ops"
t "a typo refuses"                       "lap"         ""  DIE
t "current with no device answer refuses" "current"    ""  DIE
t "current on a user that is no zone refuses" "current" 42 DIE
t "only separators refuses"              ", ,"         ""  DIE

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
