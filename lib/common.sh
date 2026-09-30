#!/usr/bin/env bash
# Shared helpers for all provision/*.sh. Is sourced, not executed.
# Everything idempotent: check-before-create, check-before-install, check-before-set.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Overridable, so you can work against a test catalog without touching
# the real one:  CONFIG_DIR=/path/config provision/10-apps.sh
: "${CONFIG_DIR:=$REPO_ROOT/config}"
# Overridable like CONFIG_DIR: a private catalog wants its own binaries, its own
# pinned signers and its own SHA256SUMS, none of which belong in a repository
# that ships a template. This is the READ half - fetch.sh still writes into the
# repository's apks/, so a private inventory has to be fetched with CAT and the
# result moved, or fetch.sh needs the same treatment.
: "${APKS_DIR:=$REPO_ROOT/apks}"
STATE_DIR="$REPO_ROOT/.provision-state"
mkdir -p "$STATE_DIR"

: "${ADB:=adb}"
: "${ADB_SERIAL:=}"          # e.g. emulator-5554; empty = only device
: "${DRY_RUN:=0}"

# ---------- Logging ----------
_c() { [ -t 1 ] && printf '\033[%sm%s\033[0m' "$1" "$2" || printf '%s' "$2"; }
log()  { printf '%s %s\n' "$(_c '1;34' '::')" "$*"; }
ok()   { printf '%s %s\n' "$(_c '1;32' ' +')" "$*"; }
skip() { printf '%s %s\n' "$(_c '1;30' ' =')" "$*"; }
warn() { printf '%s %s\n' "$(_c '1;33' ' !')" "$*" >&2; }
die()  { printf '%s %s\n' "$(_c '1;31' ' x')" "$*" >&2; exit 1; }

# ---------- adb ----------
# adb_/ash  = mutating, only printed by DRY_RUN
# adb_ro/ash_ro = read-only, ALWAYS runs. A dry run that isn't allowed to read
# the current state can't say what would change - it would just feed the
# command text back into the checks and choke on its own output.
_adb_args() {
  _AA=()
  [ -n "$ADB_SERIAL" ] && _AA=(-s "$ADB_SERIAL")
  # return 0 is MANDATORY: without a serial the &&-construct returns 1, and a
  # bare _adb_args call in the script body then dies silently under set -e.
  # This never showed up in $(...) substitutions (errexit isn't inherited there).
  return 0
}
adb_() {
  _adb_args
  if [ "$DRY_RUN" = "1" ]; then
    printf '   [dry-run] adb %s %s\n' "${_AA[*]}" "$*"
    return 0
  fi
  # </dev/null is mandatory: 'adb shell' reads stdin and would otherwise
  # consume the input of the enclosing 'while read' loop - it would stop
  # after the first profile. Affects every adb call inside a read loop.
  "$ADB" "${_AA[@]}" "$@" </dev/null
}
adb_ro() { _adb_args; "$ADB" "${_AA[@]}" "$@" </dev/null; }
ash()    { adb_ shell "$@"; }
ash_ro() { adb_ro shell "$@"; }

require_device() {
  command -v "$ADB" >/dev/null || die "adb not found"
  local n
  n="$("$ADB" devices | awk 'NR>1 && $2=="device"' | wc -l)"
  [ "$n" -ge 1 ] || die "no adb device connected (is the emulator running? 'adb devices')"
  if [ -z "$ADB_SERIAL" ] && [ "$n" -gt 1 ]; then
    die "multiple devices connected - set ADB_SERIAL"
  fi
}

# ro.modversion does NOT work as a detection marker: the property is set by
# GrapheneOS device configs, but the generic emulator target leaves it
# empty. Verified on the emu64x build from 2026-09-14.
# Two markers are reliable instead:
#   1. preinstalled app.grapheneos.* packages
#   2. android.permission.INTERNET declared as DANGEROUS - on stock AOSP it's
#      'normal' and can't be revoked at all. 20-permissions.sh builds exactly on that.
require_graphene() {
  local t g pkgs prot
  t="$(ash_ro getprop ro.build.version.security_patch 2>/dev/null | tr -d '\r' || true)"
  g="$(ash_ro getprop ro.modversion 2>/dev/null | tr -d '\r' || true)"
  local _pl _dp
  _pl="$(ash_ro pm list packages 2>/dev/null | tr -d '\r')" || _pl=""
  pkgs="$(printf '%s' "$_pl" | grep -c '^package:app\.grapheneos\.' || true)"
  _dp="$(ash_ro dumpsys package permission android.permission.INTERNET 2>/dev/null | tr -d '\r')" || _dp=""
  prot="$(printf '%s' "$_dp" | grep -m1 -o 'prot=[a-z|]*' || true)"

  if [ "${pkgs:-0}" -gt 0 ] && [ "${prot#prot=}" != "${prot}" ] && case "$prot" in *dangerous*) true;; *) false;; esac; then
    ok "GrapheneOS detected: ${pkgs} app.grapheneos.* packages, INTERNET is revocable (${prot}), patch ${t:-?}${g:+, version $g}"
    return 0
  fi

  warn "No GrapheneOS detected: ${pkgs:-0} app.grapheneos.* packages, INTERNET ${prot:-unknown} (patch ${t:-?})"
  warn "Without revocable INTERNET there is no network toggle - 20-permissions.sh would be ineffective."
  [ "${ALLOW_NON_GRAPHENE:-0}" = "1" ] || die "Aborting. Override with ALLOW_NON_GRAPHENE=1."
}

# ---------- Profile / User ----------
# Returns the user id for a profile label, or empty.
user_id_for() {
  local label="$1"
  ash_ro pm list users 2>/dev/null | tr -d '\r' \
    | sed -n "s/.*UserInfo{\([0-9]\+\):${label}:.*/\1/p" | head -1
}

user_exists() { [ -n "$(user_id_for "$1")" ]; }

user_running() {
  local label="$1" out
  out="$(ash_ro pm list users 2>/dev/null | tr -d '\r')" || return 1
  printf '%s' "$out" | grep -q "UserInfo{[0-9]*:${label}:.*} running"
}

# Running check via user id instead of name. Needed for the owner: the
# system calls it "Owner", but the zone model calls it "Home" - a name
# search would never find it and would try to endlessly "start" it. user 0
# always runs.
user_running_uid() {
  [ "$1" = "0" ] && return 0
  local out
  out="$(ash_ro pm list users 2>/dev/null | tr -d '\r')" || return 1
  printf '%s' "$out" | grep -q "UserInfo{$1:.*} running"
}

# ---------- The host's record of a device ----------
# One directory per device under .provision-state, keyed by serial: a laptop
# that provisions two phones must not mix up what it agreed with each.
device_id() { printf '%s' "${ADB_SERIAL:-$("$ADB" get-serialno 2>/dev/null || echo unknown)}" | tr -c 'A-Za-z0-9_.-' '_'; }

# Changes a step could not deliver because the zone was stopped and NO_START
# asked it not to start one. One line per zone and section, removed by the
# step that finally delivers it. `andashi status` reads this; without it a
# skipped zone would be indistinguishable from a converged one.
pending_file() { printf '%s/pending/%s' "$STATE_DIR" "$(device_id)"; }
pending_add() {   # $1=zone $2=section
  [ "$DRY_RUN" = "1" ] && return 0
  local f; f="$(pending_file)"; mkdir -p "$(dirname "$f")"
  grep -qxF "$1 $2" "$f" 2>/dev/null || printf '%s %s\n' "$1" "$2" >> "$f"
}
pending_clear() {   # $1=zone $2=section
  [ "$DRY_RUN" = "1" ] && return 0
  local f; f="$(pending_file)"
  [ -f "$f" ] || return 0
  grep -vxF "$1 $2" "$f" > "$f.tmp" || true
  mv "$f.tmp" "$f"
}

# ---------- Catalog ----------
apps_for_profile() {   # $1 = profile key -> JSON lines
  jq -c --arg p "$1" '.apps[] | select(.profiles | index($p))' "$CONFIG_DIR/apps.json"
}

# Profiles with a "feature" field disappear from the list as long as the
# feature is off. Previously every step iterated over the work profile and
# it only worked out because resolve_uid returns empty for a missing
# profile - that depends on the profile not existing, not on the feature
# being off.
profile_keys() {
  local _k _feat
  while read -r _k; do
    _feat="$(profile_field "$_k" feature)"
    feature_enabled "$_feat" || continue
    zone_selected "$_k" || continue
    printf '%s\n' "$_k"
  done < <(jq -r '.profiles[].key' "$CONFIG_DIR/profiles.json")
}

# ---------- Zone selection ----------
# ZONES narrows every step to some zones: `ZONES="lab home"`, commas work too.
# Unset means all of them, which is what provisioning has always done. It is
# the difference between a run that costs two minutes and one that costs two
# seconds, because a step that walks all six zones also STARTS all six, and
# Android runs three: each start evicts somebody, and the next step starts them
# again (measured 2026-09-30 on the Fold emulator: 106 s for a run in which
# nothing had changed, most of it starting evicted zones).
#
# `current` is the zone in the foreground - the only one whose screen you can
# see, which is why the edit-and-look loop defaults to it.
#
# An unknown name is an error, not an empty selection: a typo would otherwise
# select nothing, every step would do nothing, and the run would end green.
ZONES_RESOLVED=""
zones_resolve() {
  [ -n "$ZONES_RESOLVED" ] && return 0
  local z all out="" cur uid k
  all=" $(jq -r '.profiles[].key' "$CONFIG_DIR/profiles.json" | tr '\n' ' ')"
  for z in ${ZONES//,/ }; do
    if [ "$z" = "current" ]; then
      cur="$(ash_ro am get-current-user 2>/dev/null | tr -d '\r' || true)"
      [ -n "$cur" ] || die "ZONES=current: could not ask the device which user is in the foreground"
      z=""
      for k in $all; do
        # A managed profile shares its parent's screen and is never "current".
        [ "$(profile_field "$k" type)" = "managed" ] && continue
        uid="$(resolve_uid "$k")"
        [ "$uid" = "$cur" ] && { z="$k"; break; }
      done
      [ -n "$z" ] || die "ZONES=current: user $cur in the foreground is not a zone of $CONFIG_DIR/profiles.json"
    fi
    case "$all " in *" $z "*) ;; *) die "ZONES: '$z' is not a zone (known:$all)";; esac
    out="$out $z"
  done
  [ -n "$out" ] || die "ZONES is set but names no zone"
  ZONES_RESOLVED="$out "
}
zone_selected() {   # $1 = profile key
  [ -z "${ZONES:-}" ] && return 0
  [ -n "$ZONES_RESOLVED" ] || die "zone_selected: ZONES was never resolved"
  case "$ZONES_RESOLVED" in *" $1 "*) return 0;; *) return 1;; esac
}

# Screen aspect class, same idea as device_abi: ask the device instead of
# guessing. GrapheneOS runs on everything from a 1080x2424 phone (w/h 0.45) to
# a folded-open inner screen near 1:1, and a wallpaper is centre-cropped to
# fill - a phone-shaped image loses 46% of its height on the fold. The midpoint
# 0.75 separates the two classes cleanly; nothing real sits near it.
device_aspect_class() {
  local sz w h
  sz="$(ash_ro wm size 2>/dev/null | tr -d '\r' | sed -n 's/.*: *\([0-9]*x[0-9]*\).*/\1/p' | tail -1)"
  [ -n "$sz" ] || { printf 'tall'; return 0; }
  w="${sz%x*}"; h="${sz#*x}"
  [ "$w" -gt 0 ] && [ "$h" -gt 0 ] 2>/dev/null || { printf 'tall'; return 0; }
  # w/h < 0.75 -> tall; integer arithmetic, no bc dependency
  if [ $(( w * 100 / h )) -lt 75 ]; then printf 'tall'; else printf 'square'; fi
}

# A started user is not necessarily a usable one. With a PIN set, a user comes
# up RUNNING_LOCKED: its credential-encrypted storage stays sealed, so none of
# its apps can run - no content provider, no activity. Settings writes still
# work, which is why a locked profile gets its palette but not its wallpaper.
user_unlocked() {   # $1 = uid
  case "$(ash_ro am get-started-user-state "$1" 2>/dev/null | tr -d '\r')" in
    *UNLOCKED*) return 0;;
    *)          return 1;;
  esac
}

# ---------- Features ----------
# A feature is an architecture decision, not an app. Catalog entries with a
# "feature" field are skipped as long as the feature is off. Unknown feature
# names are an error, not "off": a typo in the catalog would otherwise
# silently never install the app.
FEATURES_FILE="$CONFIG_DIR/features.json"

feature_enabled() {   # $1 = feature key; empty/no field => always active
  local key="$1" val
  [ -z "$key" ] || [ "$key" = "null" ] && return 0
  [ -f "$FEATURES_FILE" ] || { warn "features.json missing - '$key' counts as OFF"; return 1; }
  val="$(jq -r --arg k "$key" 'if .features|has($k) then .features[$k].enabled else "MISSING" end' "$FEATURES_FILE")"
  case "$val" in
    true)    return 0;;
    false)   return 1;;
    MISSING) die "Catalog references unknown feature '$key' - typo in apps.json or entry missing in features.json";;
    *)       die "Feature '$key': 'enabled' is neither true nor false (is '$val')";;
  esac
}

feature_field() { jq -r --arg k "$1" --arg f "$2" '.features[$k][$f] // empty' "$FEATURES_FILE" 2>/dev/null; }
feature_keys()  { jq -r '.features|keys[]' "$FEATURES_FILE" 2>/dev/null; }
# WARNING: '.[$f] // empty' would be wrong - jq's // operator treats not
# only null but also FALSE as empty. For "create": false nothing would come
# back, and Home (the owner) would fall through the label search, which
# never finds it, because user 0 is called "Owner" in the system. So check
# via has() instead.
profile_field() { jq -r --arg k "$1" --arg f "$2" '.profiles[]|select(.key==$k)|if has($f) then .[$f] else empty end' "$CONFIG_DIR/profiles.json"; }
profile_label() { profile_field "$1" label; }

# Field of config/theming.json for a profile. per_profile WINS over
# all_profiles here (unlike settings.json). Same has() rule as above: a
# value of false must come back as "false", not as nothing.
theme_field() {   # $1=profile-key $2=field
  jq -r --arg k "$1" --arg f "$2" \
    '((.all_profiles // {}) * (.per_profile[$k] // {})) | if has($f) then .[$f] else empty end' \
    "$CONFIG_DIR/theming.json"
}

# Resolves a profile key to the user id. For profiles with create=false the
# id is fixed in profiles.json (Home = Owner = 0); a search via the label
# would come up empty there, because the owner is called "Owner" in the
# system, not "Home".
resolve_uid() {
  local key="$1"
  if [ "$(profile_field "$key" create)" = "false" ]; then
    profile_field "$key" user_id
  else
    user_id_for "$(profile_label "$key")"
  fi
}

# ---------- Packages ----------
# WARNING: no 'grep -q'/'grep -m1' in a pipeline while pipefail is active.
# Both exit on the first match, the upstream process dies from SIGPIPE
# (141), and pipefail turns that into a failure - a MATCH then reads as
# "not found". And it's a race: short output works fine, long output
# doesn't. So collect first, then check.
pkg_installed_for_user() {   # $1=pkg $2=uid
  local out
  out="$(ash_ro pm list packages --user "$2" 2>/dev/null | tr -d '\r')" || return 1
  case $'\n'"$out"$'\n' in *$'\n'"package:$1"$'\n'*) return 0;; *) return 1;; esac
}

# ABI of the connected device, determined once and cached (one adb call per
# app would otherwise be noticeable). APK_ABI overrides it manually.
_DEV_ABI=""
device_abi() {
  if [ -z "$_DEV_ABI" ]; then
    _DEV_ABI="$(ash_ro getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
    [ -z "$_DEV_ABI" ] && _DEV_ABI="arm64-v8a"
  fi
  printf '%s' "$_DEV_ABI"
}

# Finds the APK for a package name. Searches the device-ABI directory
# first, then universal/. That way the same inventory serves both the Fold
# (arm64-v8a) and the emulator (x86_64), without duplicating the 15
# architecture-neutral APKs - only the four ABI-specific ones exist twice.
#
# The hyphen in the glob is MANDATORY: fetch.sh names files as
# <package>-<version>.apk, and without the separator a package name that is
# the prefix of another one ("org.andashi.home" vs "org.andashi.home.debug",
# or historically "app.lawnchair" vs "app.lawnchair.lawnicons") would match
# the other one's file. The result would be the wrong file under the right
# label, and the log reports success.
# Picks the APK to install: the ABI directory of the device first, then
# universal, then the flat legacy inventory.
# Within a directory the HIGHEST version wins - except when the catalog pins a
# release_tag. That pin is what "a release we ship deliberately" means, and it
# used to apply only to the download: fetch.sh would get the pinned version
# while this function installed whatever higher version was still lying around,
# so a rollback after a regression silently did not happen.
apk_for_pkg() {
  local pkg="$1" d f tag=""
  tag="$(jq -r --arg p "$pkg" '[.apps[]|select(.pkg==$p)|.release_tag//empty][0] // empty' "$CONFIG_DIR/apps.json" 2>/dev/null)"
  tag="${tag#v}"
  for d in "${APK_ABI:-$(device_abi)}" universal ""; do
    if [ -n "$tag" ] && [ -f "$APKS_DIR/${d:+$d/}${pkg}-${tag}.apk" ]; then
      printf '%s' "$APKS_DIR/${d:+$d/}${pkg}-${tag}.apk"; return 0
    fi
    f="$(ls -1 "$APKS_DIR/${d:+$d/}${pkg}-"*.apk 2>/dev/null | sort -V | tail -1 || true)"
    [ -n "$f" ] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# versionCode of the package as INSTALLED - device-global, because an APK is
# installed once for the whole device and every user shares that code path.
# Empty/1 when the package is not installed.
# Parsed in bash, not with 'head -1': a pipeline that exits early kills the
# upstream with SIGPIPE and pipefail turns that into a failure (see the
# warning above pkg_installed_for_user).
installed_version_code() {   # $1=pkg
  local out line
  out="$(ash_ro dumpsys package "$1" 2>/dev/null | tr -d '\r')" || return 1
  while IFS= read -r line; do
    case "$line" in
      *versionCode=*) line="${line#*versionCode=}"; printf '%s' "${line%% *}"; return 0;;
    esac
  done <<<"$out"
  return 1
}

# versionCode an APK file declares. Same parsing rule as above.
apk_version_code() {   # $1=apk
  local out line
  command -v aapt2 >/dev/null || return 1
  out="$(aapt2 dump badging "$1" 2>/dev/null)" || return 1
  while IFS= read -r line; do
    case "$line" in
      package:*versionCode=\'*)
        line="${line#*versionCode=\'}"; printf '%s' "${line%%\'*}"; return 0;;
    esac
  done <<<"$out"
  return 1
}

all_user_ids() { ash_ro pm list users 2>/dev/null | tr -d '\r' | sed -n 's/.*UserInfo{\([0-9]\+\):.*/\1/p'; }

pkg_installed_anywhere() {   # $1=pkg
  local u
  while read -r u; do
    pkg_installed_for_user "$1" "$u" && return 0
  done < <(all_user_ids)
  return 1
}

# Resolved here, while the script is still in its own shell. Every step reads
# profile_keys through a process substitution, and a `die` in there ends only
# that subshell: the loop would see no zones, do nothing and report success -
# exactly the empty selection the check exists to refuse. Resolving `current`
# asks the device, so a script sourcing this with ZONES set needs one.
if [ -n "${ZONES:-}" ]; then zones_resolve; fi

