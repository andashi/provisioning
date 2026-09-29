#!/usr/bin/env bash
# Cases for wallpaper_drifted() in provision/45-launcher-config.sh. The pull
# deliberately does not carry the wallpaper back - the config holds an upload
# name, not a path - so this is the one thing it can still say about it.
set -uo pipefail
eval "$(sed -n '/^wallpaper_drifted()/,/^}/p' "$(dirname "${BASH_SOURCE[0]}")/../provision/45-launcher-config.sh")"
pass=0; fail=0
t() {   # $1=name $2=device $3=path $4=yes|no
  local got=no
  wallpaper_drifted "$2" "$3" && got=yes
  if [ "$got" = "$4" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s: expected %s, got %s\n' "$1" "$4" "$got"; fail=$((fail+1)); fi
}

t "the name we asked for"            "home.jpg"  "themes/synthwave/{aspect}/home.jpg"  no
t "somebody chose another image"     "cats.jpg"  "themes/synthwave/{aspect}/home.jpg"  yes
t "no wallpaper on the device yet"   ""          "themes/synthwave/{aspect}/home.jpg"  no
t "the zone never asked for one"     "cats.jpg"  ""                                    no
t "neither side has anything"        ""          ""                                    no
t "a path without a directory"       "home.jpg"  "home.jpg"                            no
t "same basename, other theme"       "home.jpg"  "themes/mauritius/{aspect}/home.jpg"  no

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
