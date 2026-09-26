#!/usr/bin/env bash
# Cases for lib/readback-compare.jq, the one claim this chain makes about a
# device: that what the file said is what the launcher does. `make check` runs
# it, because the logic was wrong twice on 2026-09-26 - once comparing whole
# sections, which broke on every release that added a key, and once walking
# into arrays, which reported one swallowed favorite as three mismatches.
#
# The expectations are exact strings on purpose. A case asserting "contains
# home.favorites" passes either way and is how the second bug hid.
set -uo pipefail
J="$(dirname "${BASH_SOURCE[0]}")/readback-compare.jq"
pass=0; fail=0
t() { # $1=name $2=want $3=eff $4=expected
  local got
  got="$(jq -n --argjson eff "$3" --slurpfile want <(printf '%s' "$2") -r -f "$J" 2>&1)" || got="JQ FAILED: $got"
  if [ "$got" = "$4" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n        expected [%s]\n        got      [%s]\n' "$1" "$4" "$got"; fail=$((fail+1)); fi
}

WROTE='{"schemaVersion":2,"icons":{"themed":true,"enforceThemed":true,"pack":"app.lawnchair.lawnicons"},"home":{"favorites":[{"packageName":"a.b"}],"widgets":{"enabled":true}},"search":{"contacts":true}}'
# what a launcher two releases from now serves: everything above, plus keys we never wrote
SERVES='{"schemaVersion":2,"icons":{"themed":true,"enforceThemed":true,"pack":"app.lawnchair.lawnicons","size":48,"adaptify":false,"badges":{"notifications":true,"shortcuts":true,"suspendedApps":true}},"home":{"favorites":[{"packageName":"a.b","profile":"personal"}],"widgets":{"enabled":true},"searchBar":{"fixed":false},"lockRotation":false},"search":{"contacts":true,"reversed":false,"labels":true},"appearance":{"systemBars":{"status":"auto"}}}'

t "keys added to every section"              "$WROTE" "$SERVES" ""
t "a written value flipped"                "$WROTE" "$(jq -c '.icons.themed=false' <<<"$SERVES")" "icons.themed"
t "a written key not served"               "$WROTE" "$(jq -c 'del(.icons.pack)' <<<"$SERVES")" "icons.pack"
t "a whole section missing"                "$WROTE" "$(jq -c 'del(.icons)' <<<"$SERVES")" "icons.themed, icons.enforceThemed, icons.pack"
t "a favorite swallowed"                   "$WROTE" "$(jq -c '.home.favorites=[]' <<<"$SERVES")" "home.favorites"
t "a search key flipped"                   "$WROTE" "$(jq -c '.search.contacts=false' <<<"$SERVES")" "search.contacts"
t "false served as true"                   '{"icons":{"themed":false}}' '{"icons":{"themed":true,"size":48}}' "icons.themed"

# the launcher completes geometry; we declare structure. canon absorbs that.
GRID='{"schemaVersion":2,"home":{"grid":{"columns":4,"locked":false,"layouts":{"phone":{"items":[{"id":"favorites","widget":"favorites"}]}}}}}'
GRID_DEV='{"schemaVersion":2,"home":{"grid":{"columns":4,"locked":false,"labels":true,"layouts":{"phone":{"items":[{"id":"favorites","widget":"favorites","x":0,"y":5,"w":4,"h":1,"borderless":false,"background":true,"themeColors":true}]}}}}}'
t "geometry completed by the device"       "$GRID" "$GRID_DEV" ""
t "a grid item gone"                       "$GRID" "$(jq -c '.home.grid.layouts.phone.items=[]' <<<"$GRID_DEV")" "home.grid.layouts.phone.items"
t "locked flipped"                         "$GRID" "$(jq -c '.home.grid.locked=true' <<<"$GRID_DEV")" "home.grid.locked"
t "v1 written, v2 served"                  '{"schemaVersion":2,"home":{"dock":{"favorites":["a.b"]}}}' '{"schemaVersion":2,"home":{"favorites":[{"packageName":"a.b","profile":"personal"}]}}' ""

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = "0" ]
