#!/usr/bin/env bash
# Checks package names in the catalog against the real APKs in apks/ (aapt2).
# Without an argument: report only. With --fix: corrects config/apps.json.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

FIX=0; [ "${1:-}" = "--fix" ] && FIX=1
command -v aapt2 >/dev/null || die "aapt2 missing (pacman -S android-sdk-build-tools or check PATH)"

shopt -s nullglob
# Flat legacy inventory + ABI subdirectories (see apks/README.md)
apks=("$APKS_DIR"/*.apk "$APKS_DIR"/universal/*.apk "$APKS_DIR"/arm64-v8a/*.apk "$APKS_DIR"/x86_64/*.apk)
[ ${#apks[@]} -gt 0 ] || die "no APKs in apks/ - download first (see apks/README.md)"

log "Checking ${#apks[@]} APK(s) against the catalog"
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT

for apk in "${apks[@]}"; do
  pkg="$(aapt2 dump packagename "$apk" 2>/dev/null | tr -d '\r')"
  [ -n "$pkg" ] || { warn "$(basename "$apk"): package name not readable"; continue; }
  ver="$(aapt2 dump badging "$apk" 2>/dev/null | sed -n "s/.*versionName='\([^']*\)'.*/\1/p" | head -1)"

  if jq -e --arg p "$pkg" '.apps[]|select(.pkg==$p)' "$CONFIG_DIR/apps.json" >/dev/null; then
    st="$(jq -r --arg p "$pkg" '.apps[]|select(.pkg==$p)|.pkg_status' "$CONFIG_DIR/apps.json")"
    if [ "$st" = "unverified" ]; then
      ok "$pkg ($ver) confirmed -> pkg_status: verified"
      printf '%s\n' "$pkg" >> "$tmp"
    else
      skip "$pkg ($ver) already verified"
    fi
  else
    warn "$(basename "$apk"): package '$pkg' is in NO catalog entry"
  fi
done

if [ -s "$tmp" ] && [ "$FIX" = "1" ]; then
  while read -r pkg; do
    jq --arg p "$pkg" '(.apps[]|select(.pkg==$p)|.pkg_status) = "verified"' \
      "$CONFIG_DIR/apps.json" > "$CONFIG_DIR/apps.json.tmp" && mv "$CONFIG_DIR/apps.json.tmp" "$CONFIG_DIR/apps.json"
  done < "$tmp"
  ok "config/apps.json updated"
elif [ -s "$tmp" ]; then
  log "run with --fix to write"
fi

printf '\n'
log "Still unverified (package name only guessed, check BEFORE the run):"
jq -r '.apps[]|select(.pkg_status=="unverified")|"   \(.label)  ->  \(.pkg)"' "$CONFIG_DIR/apps.json"

# ---- Favorites from theming.json against the catalog -----------------------
# Catches statically what otherwise only shows up as a warning after ~140s
# of runtime: a favorite whose app gets installed in a different profile.
if [ -f "$CONFIG_DIR/theming.json" ]; then
  printf '\n'
  log "Favorites (config/theming.json) against the catalog:"
  jq -r '.per_profile | to_entries[] | .key as $z | (.value.favorites // [])[] | "\($z)|\(.)"' \
    "$CONFIG_DIR/theming.json" |
  while IFS='|' read -r zone fav; do
    hit="$(jq -r --arg f "$fav" '
      ([.apps[] | select(.label == $f or .id == $f)]) as $e
      | (if ($e|length) == 1 then $e
         else [.apps[] | select(.label | ascii_downcase | contains($f|ascii_downcase))] end) as $m
      | if ($m|length) == 1 then "\($m[0].pkg)|\($m[0].profiles|join(","))|\($m[0].source)" else empty end' \
      "$CONFIG_DIR/apps.json")"
    if [ -z "$hit" ]; then
      skip "$zone/$fav: not in the catalog (system app like Phone or Vanadium?)"
      continue
    fi
    pkg="${hit%%|*}"; rest="${hit#*|}"; zones="${rest%%|*}"; src="${rest##*|}"
    case ",$zones," in
      *",$zone,"*)
        # Assigned to the zone is not the same as installed there. Anything the
        # pipeline cannot fetch an APK for lands in MANUAL.md, so the favorite
        # is a promise the run cannot keep until someone installs it by hand -
        # the launcher then shows an empty dock slot for it until that happens.
        case "$src" in
          obtainium|fdroid|local) ok "$zone/$fav -> $pkg" ;;
          *) warn "$zone/$fav: '$pkg' is source=$src - installed by hand (MANUAL.md), so this favorite stays unpinned until then" ;;
        esac ;;
      *)           warn "$zone/$fav: '$pkg' gets installed in [$zones], not in '$zone'" ;;
    esac
  done
fi

# ---- perms.grant against what the APKs actually declare --------------------
# The runtime cannot catch this. 'pm grant' exits 0 for a permission the
# package does not request, grants nothing, and the only trace is
# "isn't requested by package" in logcat - which is why 20-permissions.sh now
# reads the state back. Statically it costs nothing, because the APK is right
# here. This is the check that would have caught READ_CALENDAR still sitting in
# the catalog after Andashi Home 0.3.0 dropped calendar search (2026-09-21).
#
# No device is involved here, so apk_for_pkg() is not usable - it asks the
# device for its ABI. Same preference order, just resolved offline.
apk_for_pkg_offline() {   # $1=pkg
  local pkg="$1" d f tag
  tag="$(jq -r --arg p "$pkg" '[.apps[]|select(.pkg==$p)|.release_tag//empty][0] // empty' "$CONFIG_DIR/apps.json")"
  tag="${tag#v}"
  if [ -n "$tag" ]; then
    for d in universal arm64-v8a x86_64 ""; do
      [ -f "$APKS_DIR/${d:+$d/}${pkg}-${tag}.apk" ] \
        && { printf '%s' "$APKS_DIR/${d:+$d/}${pkg}-${tag}.apk"; return 0; }
    done
  fi
  f="$(ls -1 "$APKS_DIR"/*/"${pkg}-"*.apk "$APKS_DIR/${pkg}-"*.apk 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "$f" ] && { printf '%s' "$f"; return 0; }
  return 1
}

printf '\n'
log "perms.grant (config/apps.json) against the APK manifests:"
while IFS='|' read -r lbl pkg perm; do
  [ -z "$pkg" ] && continue
  apk="$(apk_for_pkg_offline "$pkg" || true)"
  if [ -z "$apk" ]; then
    skip "$lbl/$perm: no APK in apks/ - cannot check (source is not a fetched one?)"
    continue
  fi
  # No 'grep -q' in a pipeline here (see common.sh on pipefail/SIGPIPE):
  # collect the list first, then match it in bash.
  decl="$(aapt2 dump permissions "$apk" 2>/dev/null | sed -n "s/^uses-permission: name='\([^']*\)'.*/\1/p")"
  case $'\n'"$decl"$'\n' in
    *$'\n'"$perm"$'\n'*) ok "$lbl: $perm declared by $(basename "$apk")" ;;
    *) warn "$lbl: perms.grant asks for $perm, but $(basename "$apk") does not declare it - the grant would silently do nothing" ;;
  esac
done < <(jq -r '.apps[] | select(.perms.grant) | . as $a | .perms.grant[] | "\($a.label)|\($a.pkg)|\(.)"' \
           "$CONFIG_DIR/apps.json")
