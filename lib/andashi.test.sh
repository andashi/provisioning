#!/usr/bin/env bash
# Cases for the decisions in lib/andashi.sh: which steps a change needs, and
# what `apply` does with a zone whose launcher both sides may have touched.
# The expensive mistakes are the quiet ones - a change mapped to no step is a
# change that never reaches the phone, and a conflict read as a push is an
# edit on the phone overwritten without a word.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/andashi.sh"
pass=0; fail=0
t() {   # $1=name $2=got $3=expected
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s: expected "%s", got "%s"\n' "$1" "$3" "$2"; fail=$((fail+1)); fi
}
j() { tr '\n' ' ' | sed 's/ $//'; }

echo "steps for sections"
t "a launcher change is one step"          "$(steps_for_sections launcher | j)" "45-launcher-config"
t "a theme change: palette, then launcher" "$(steps_for_sections theme | j)"    "40-theming 45-launcher-config"
t "chain order, whatever the input order"  "$(steps_for_sections launcher settings | j)" "30-settings 45-launcher-config"
t "each step once"                         "$(steps_for_sections theme launcher | j)" "40-theming 45-launcher-config"
t "apps start zones, so finalize follows"  "$(steps_for_sections apps | j)" "10-apps 20-permissions 45-launcher-config 90-manual 99-finalize"
t "permissions start zones too"            "$(steps_for_sections permissions | j)" "20-permissions 99-finalize"
t "settings start nothing: no finalize"    "$(steps_for_sections settings | j)" "30-settings"
steps_for_sections themes >/dev/null 2>&1; t "an unknown section refuses" "$?" "1"

echo "changed sections"
old=$'profiles.json p1\napps.json a1\nsettings.json s1\ntheming.json t1\nfeatures.json f1\nwallpapers w1'
t "nothing changed"                   "$(changed_sections "$old" "$old" | j)" ""
t "theming.json: theme and launcher"  "$(changed_sections "$old" "${old/t1/t2}" | j)" "theme launcher"
t "new bytes under an old image name" "$(changed_sections "$old" "${old/w1/w2}" | j)" "launcher"
t "apps.json"                         "$(changed_sections "$old" "${old/a1/a2}" | j)" "apps permissions launcher manual"
t "profiles.json is everything"       "$(changed_sections "$old" "${old/p1/p2}" | j)" "profiles apps permissions settings vpn theme launcher manual"
t "never applied is everything"       "$(changed_sections "" "$old" | j)" "profiles apps permissions settings vpn theme launcher manual"
t "an input the record lacks counts"  "$(changed_sections "${old/$'\nwallpapers w1'/}" "$old" | j)" "launcher"

echo "reconcile"
t "nothing changed"                   "$(reconcile_plan a a a)" none
t "host changed"                      "$(reconcile_plan b a a)" push
t "device changed"                    "$(reconcile_plan a a c)" adopt
t "both changed"                      "$(reconcile_plan b a c)" conflict
t "both changed to the same thing"    "$(reconcile_plan b a b)" none
t "no record: nothing to protect"     "$(reconcile_plan b "" c)" first
t "device silent is not agreement"    "$(reconcile_plan a a "")" unknown

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
