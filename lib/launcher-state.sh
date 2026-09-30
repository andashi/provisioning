#!/usr/bin/env bash
# What the host knows about a zone's launcher, and how it asks the device.
# Sourced by provision/45-launcher-config.sh and bin/andashi, so the push and
# the status report read the same records the same way; a second reading of
# them would be a second truth. Needs lib/common.sh and PKG.

# What the device reported the last time we agreed with it, per device and
# zone. Not a version counter: the launcher writes launcher.json itself once
# edit mode ships, and a counter would have to be maintained on both sides.
# The sha the launcher already publishes in its diagnostics is enough for a
# compare-and-swap on content.
sha_record() { printf '%s/launcher-sha/%s/%s' "$STATE_DIR" "$(device_id)" "$1"; }

# What we last agreed with a zone about. It used to be a bare sha; since
# andashi/home#226 the launcher also reports `sequence` and `storeId`, so the
# record carries all three as JSON. A file from before that is a bare sha and
# is read as one - rewriting the format must not invent agreement we never had.
#
# `wallpaper` is the sha256 of the image file this zone holds under its name,
# or "none" for a zone without one. The launcher sees a same-name file with new
# bytes on its own (WallpaperStore compares the file hash) - but only on a
# reload, and a push we skip is a reload that never happens. So the host has to
# know the bytes it last sent, and an empty argument keeps the value recorded
# before: a pull learns nothing about the image and must not forget it.
record_write() {   # $1=file $2=sha $3=sequence-or-empty $4=storeId-or-empty [$5=wallpaper sha|none]
  local wp="${5:-}"
  [ -n "$wp" ] || wp="$(record_field "$1" wallpaper 2>/dev/null || true)"
  mkdir -p "$(dirname "$1")"
  jq -n --arg sha "$2" --arg seq "$3" --arg store "$4" --arg wp "$wp" \
    '{sha: $sha, sequence: (if $seq == "" then null else ($seq|tonumber) end),
      storeId: (if $store == "" then null else $store end),
      wallpaper: (if $wp == "" then null else $wp end)}' > "$1.tmp" && mv "$1.tmp" "$1"
}
# Has the launcher saved a report since the one we agreed on? True only when
# all four values allow the question to be asked: both sides know their number,
# both name the SAME store, and the device's is higher. Anything else is "we
# cannot tell", which must not read as "nothing happened" - the fields are null
# on every build before andashi/home#226, and a different storeId is a new
# store rather than a number that went backwards.
#
# Deliberately `-gt` and never a difference of one: the numbers may have gaps,
# because a save that failed half way leaves one.
# Did somebody change the wallpaper on the device? The config carries an upload
# NAME, not a path - one segment, by the contract's own pattern - so the path in
# theming.json cannot come back through it and `--pull` leaves the wallpaper
# alone. That is right, and it left one case unnoticed: a name on the device
# that is not the basename of the path this zone is configured with means
# somebody changed it there, and the pull would silently keep our value.
#
# Both empty-ish cases are "cannot tell", not "fine": no name on the device is
# the wallpaper-pending-foreground state, and no path in the catalog means the
# zone never asked for one.
wallpaper_drifted() {   # $1=name on the device $2=configured path
  [ -n "$1" ] && [ -n "$2" ] || return 1
  [ "$1" != "${2##*/}" ]
}

# Is there anything to send? Decided from the host alone - what we are about to
# push against what we recorded after the last push that converged - so that a
# zone which is stopped does not have to be started to find out it needs
# nothing. "unchanged" needs BOTH the config and the wallpaper to match, and a
# record that predates the wallpaper field counts as changed once: nothing we
# know says which bytes the zone holds.
#
# This is the host half only. Whether the DEVICE still holds that state - an
# edit on the phone, a cleared app - is asked separately when the zone runs.
launcher_plan() {   # $1=want_sha $2=rec_sha $3=want_wallpaper(sha|none) $4=rec_wallpaper
  [ -n "$2" ] && [ "$1" = "$2" ] || { printf 'changed'; return 0; }
  [ -n "$4" ] && [ "$3" = "$4" ] || { printf 'changed'; return 0; }
  printf 'unchanged'
}

report_moved() {   # $1=dev_seq $2=dev_store $3=rec_seq $4=rec_store
  [ -n "$1" ] && [ -n "$3" ] && [ -n "$2" ] && [ "$2" = "$4" ] || return 1
  [ "$1" -gt "$3" ]
}

record_field() {   # $1=file $2=sha|sequence|storeId
  [ -f "$1" ] || return 1
  if jq -e . "$1" >/dev/null 2>&1; then
    jq -r --arg f "$2" '.[$f] // empty' "$1"
  elif [ "$2" = "sha" ]; then
    tr -d '[:space:]' < "$1"
  fi
}

# Queries the launcher state provider and prints the served JSON document.
# 'content query' prints "Row: 0 <col>=<json>" - strip everything up to the
# first '{' and let jq decide whether what remains is a document.
query_state() {   # $1=path (config|diagnostics) $2=uid
  local out json
  out="$(ash_ro content query --uri "content://$PKG.state/$1" --user "$2" 2>/dev/null | tr -d '\r')" || return 1
  case "$out" in
    *\{*) json="{${out#*\{}";;
    *)    return 1;;
  esac
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s' "$json"
}
