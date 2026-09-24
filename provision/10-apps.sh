#!/usr/bin/env bash
# Installs apps per profile according to config/apps.json.
# Order: already there -> install-existing -> APK from apks/ -> MANUAL.md
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_device

MANUAL_QUEUE="$STATE_DIR/manual-installs.tsv"
: > "$MANUAL_QUEUE"

# An APK is installed ONCE for the whole device - every user shares that code
# path - so the pinned version is enforced once per package, not once per
# profile. It has to happen before any "is it already there?" check: that
# question alone is what made a release_tag bump a no-op on every device that
# had been provisioned before. Measured 2026-09-21: bumping Andashi Home to
# v0.3.0 and running the full chain left all six zones on 0.2.1, green log.
declare -A _PIN_CHECKED=()
ensure_pinned_version() {   # $1=pkg $2=label
  local pkg="$1" lbl="$2" cur want apk
  [ -n "${_PIN_CHECKED[$pkg]:-}" ] && return 0
  _PIN_CHECKED[$pkg]=1

  # Not installed anywhere yet: the normal install path below handles it, and
  # apk_for_pkg() already honours release_tag there.
  pkg_installed_anywhere "$pkg" || return 0
  apk="$(apk_for_pkg "$pkg" || true)"
  # No local APK: Play/manual apps update through their own store.
  [ -n "$apk" ] || return 0

  cur="$(installed_version_code "$pkg" || true)"
  want="$(apk_version_code "$apk" || true)"
  if [ -z "$cur" ] || [ -z "$want" ]; then
    warn "$lbl: versions not comparable (device='${cur:-?}', $(basename "$apk")='${want:-?}') - pin NOT enforced"
    return 0
  fi
  [ "$cur" = "$want" ] && return 0

  # Say why this build is the target. Most apps carry no release_tag and simply
  # follow the newest APK the host has; calling that a pin sent people looking
  # for a pin in the catalog that was never there.
  local tag why
  tag="$(jq -r --arg p "$pkg" '[.apps[]|select(.pkg==$p)|.release_tag//empty][0] // empty' "$CONFIG_DIR/apps.json")"
  if [ -n "$tag" ]; then why="pinned by release_tag $tag"; else why="newest in the host inventory"; fi

  if [ "$cur" -gt "$want" ]; then
    # A rollback must be deliberate and loud. 'install -r' refuses a downgrade
    # without -d, and doing it silently would make the pin a lie in the other
    # direction - the device would keep a build the catalog does not name.
    warn "$lbl: device has $cur, target is $want ($(basename "$apk"), $why) - refusing to downgrade automatically"
    warn "$lbl: uninstall it first, or move release_tag to what should actually run"
    return 0
  fi

  log "$lbl: $cur -> $want ($why)"
  adb_ install -r "$apk" >/dev/null \
    && ok "$lbl upgraded to $want from $(basename "$apk")" \
    || warn "$lbl: upgrade to $want FAILED - device stays on $cur"
}

log "Installing apps"
while read -r key; do
  label="$(profile_label "$key")"
  uid="$(resolve_uid "$key")"
  [ -n "$uid" ] || { warn "Profile $label does not exist - run 00-profiles.sh first"; continue; }

  printf '\n'
  log "Profile $label (user $uid)"

  # Android only lets a limited number of users run at the same time (measured
  # on emu64x: 3, owner included). Every start evicts the oldest one - so the
  # profiles started by 00-profiles.sh may well have been stopped again by
  # now. So start it here ourselves instead of relying on that. Installs into
  # a stopped user would otherwise fail.
  if ! user_running_uid "$uid"; then
    ash am start-user -w "$uid" >/dev/null && ok "$label started (had been evicted)" \
      || warn "$label could not be started - installs may fail"
  fi

  while read -r app; do
    id="$(jq -r '.id'     <<<"$app")"
    pkg="$(jq -r '.pkg'   <<<"$app")"
    src="$(jq -r '.source'<<<"$app")"
    lbl="$(jq -r '.label' <<<"$app")"
    # has() instead of '// false' - consistent with the rest, even though it
    # would only come out right here by coincidence (false // false is also false).
    opt="$(jq -r 'if has("optional") then .optional else false end' <<<"$app")"
    st="$(jq -r '.pkg_status' <<<"$app")"

    [ "${SKIP_OPTIONAL:-0}" = "1" ] && [ "$opt" = "true" ] && { skip "$lbl (optional, skipped)"; continue; }

    # Feature gate: catalog entries with "feature" only if it's turned on.
    feat="$(jq -r 'if has("feature") then .feature else "" end' <<<"$app")"
    if [ -n "$feat" ] && ! feature_enabled "$feat"; then
      skip "$lbl (feature '$feat' is off)"; continue
    fi

    if [ "$st" = "unverified" ]; then
      warn "$lbl: package name '$pkg' is UNVERIFIED - use 05-verify-catalog.sh"
    fi

    # Enforce the pin before deciding anything about this profile: the upgrade
    # is global, so it must not depend on which zone happens to come first.
    ensure_pinned_version "$pkg" "$lbl"

    if pkg_installed_for_user "$pkg" "$uid"; then
      skip "$lbl ($pkg)"
      continue
    fi

    if pkg_installed_anywhere "$pkg"; then
      ash pm install-existing --user "$uid" "$pkg" >/dev/null \
        && ok "$lbl via install-existing" \
        || { warn "$lbl: install-existing failed"; printf '%s\t%s\t%s\t%s\n' "$label" "$lbl" "$pkg" "$src" >> "$MANUAL_QUEUE"; }
      continue
    fi

    apk="$(apk_for_pkg "$pkg" || true)"
    if [ -n "$apk" ]; then
      adb_ install --user "$uid" -r "$apk" >/dev/null \
        && ok "$lbl from $(basename "$apk")" \
        || { warn "$lbl: install failed"; printf '%s\t%s\t%s\t%s\n' "$label" "$lbl" "$pkg" "$src" >> "$MANUAL_QUEUE"; }
      continue
    fi

    # No APK available: Play/store apps are manual by design.
    skip "$lbl -> MANUAL.md (source: $src)"
    printf '%s\t%s\t%s\t%s\n' "$label" "$lbl" "$pkg" "$src" >> "$MANUAL_QUEUE"
  done < <(apps_for_profile "$key")
done < <(profile_keys)

printf '\n'
n="$(wc -l < "$MANUAL_QUEUE")"
log "$n app(s) need manual steps -> land in MANUAL.md"

# ---- What the device actually runs, not what we meant to install -----------
# ensure_pinned_version drives the upgrade; this asserts the outcome by asking
# the device. Kept separate on purpose: a check that re-reads what the same
# function just decided would only ever agree with itself. Everything the
# chain does downstream - the launcher config contract above all - assumes a
# specific build, and until now nothing ever compared that assumption to
# reality.
# Every app with a local APK, not only the pinned ones. Four zones (Cloud,
# Gadgets, Lab, Anon) carry no app store, so for everything the host fetches,
# THIS chain is the update mechanism - and "is any zone running something older
# than what the host has?" has to be answerable in one place. Silent on a
# match, so the answer stays readable; a pinned version is named explicitly,
# because that one is a deliberate choice rather than just the newest file.
printf '\n'
log "Versions against the local APK inventory:"
_match=0; _drift=0
while IFS='|' read -r lbl pkg tag; do
  [ -z "$pkg" ] && continue
  pkg_installed_anywhere "$pkg" || continue
  apk="$(apk_for_pkg "$pkg" || true)"
  [ -n "$apk" ] || continue          # Play/manual apps update through their own store
  cur="$(installed_version_code "$pkg" || true)"
  want="$(apk_version_code "$apk" || true)"
  if [ -n "$cur" ] && [ "$cur" = "$want" ]; then
    _match=$((_match+1))
    [ -n "$tag" ] && ok "$lbl: $cur ($tag)"
  else
    _drift=$((_drift+1))
    warn "$lbl: device runs ${cur:-?}, host has ${want:-?} ($(basename "$apk"))"
  fi
done < <(jq -r '.apps[]|"\(.label)|\(.pkg)|\(.release_tag // "")"' "$CONFIG_DIR/apps.json")
if [ "$_drift" = 0 ]; then
  ok "$_match app(s) match the APK inventory on the host"
else
  warn "$_drift app(s) differ from the host inventory - 'make update' brings them forward"
fi
