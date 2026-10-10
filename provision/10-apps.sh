#!/usr/bin/env bash
# Installs apps per profile according to config/apps.json.
# Order: already there -> install-existing -> APK from apks/ -> MANUAL.md
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_device

MANUAL_QUEUE="$STATE_DIR/manual-installs.tsv"
# The queue is rebuilt for the zones this run covers and kept for the others.
# Truncating it whole was right while every run covered every zone; with ZONES
# a run for Lab alone would have left MANUAL.md knowing about Lab only.
if [ -n "${ZONES:-}" ] && [ -f "$MANUAL_QUEUE" ]; then
  _keep=" "
  while read -r _k; do _keep="$_keep$(profile_label "$_k") "; done < <(profile_keys)
  awk -F'\t' -v keep="$_keep" 'index(keep, " " $1 " ") == 0' "$MANUAL_QUEUE" > "$MANUAL_QUEUE.tmp"
  mv "$MANUAL_QUEUE.tmp" "$MANUAL_QUEUE"
else
  : > "$MANUAL_QUEUE"
fi

# What this chain installed into a zone, per device - the one list it may
# take things away from. A package the catalog stops naming for a zone is
# uninstalled there on the next run, because it is on this list; a package
# somebody installed by hand never is, because it is not. Before this list
# existed the chain only ever added: Tor Browser taken out of Home stayed in
# Home on every device provisioned before (8c44e45).
# Removals that did not happen. Every zone is still attempted; the step fails
# at the end, because a removal the catalog asked for and the phone refused
# is not done, and a run that says it is would be the proxy success this
# repository exists to avoid.
REMOVE_FAILED=()
installed_record() { printf '%s/installed/%s/%s' "$STATE_DIR" "$(device_id)" "$1"; }

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
  DECLARED=" "
  OWED=" "   # recorded packages the catalog dropped but that are still here

  # Android only lets a limited number of users run at the same time (measured
  # on emu64x: 3, owner included). Every start evicts the oldest one - so the
  # profiles started by 00-profiles.sh may well have been stopped again by
  # now. So start it here ourselves instead of relying on that. Installs into
  # a stopped user would otherwise fail.
  if ! user_running_uid "$uid"; then
    ash am start-user -w "$uid" >/dev/null && ok "$label started (had been evicted)" \
      || warn "$label could not be started - installs may fail"
  fi

  # Read the zone's apps with the reader's status checked. Through a process
  # substitution a failed jq would leave the list empty, DECLARED would name
  # nothing, and the removal below would uninstall everything this chain ever
  # put into the zone. An unreadable catalog stops the step instead.
  zone_apps="$(apps_for_profile "$key")" \
    || die "$label: could not read $CONFIG_DIR/apps.json - nothing installed or removed"

  while read -r app; do
    [ -n "$app" ] || continue
    pkg="$(jq -r '.pkg'   <<<"$app")"
    src="$(jq -r '.source'<<<"$app")"
    lbl="$(jq -r '.label' <<<"$app")"
    # has() instead of '// false' - consistent with the rest, even though it
    # would only come out right here by coincidence (false // false is also false).
    opt="$(jq -r 'if has("optional") then .optional else false end' <<<"$app")"
    st="$(jq -r '.pkg_status' <<<"$app")"

    # Feature gate: catalog entries with "feature" only if it's turned on.
    feat="$(jq -r 'if has("feature") then .feature else "" end' <<<"$app")"
    if [ -n "$feat" ] && ! feature_enabled "$feat"; then
      skip "$lbl (feature '$feat' is off)"; continue
    fi
    # Declared for this zone from here on - an optional app skipped for this
    # run is still declared, and must not be taken away for being skipped.
    DECLARED="$DECLARED$pkg "

    [ "${SKIP_OPTIONAL:-0}" = "1" ] && [ "$opt" = "true" ] && { skip "$lbl (optional, skipped)"; continue; }

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
  done <<<"$zone_apps"

  # ---- Take away what the catalog stopped naming ----------------------------
  # Only from the list of what this chain put here. `pm uninstall --user`
  # removes the app and its data from this zone and nowhere else. PRUNE=0
  # keeps them, for a run that should only add.
  #
  # Everything below reads the zone's packages ONCE, with the read's status
  # checked. pkg_installed_for_user answers "no" for a failed query as well as
  # for an absent package, and here "no" means "nothing to remove" and "drop
  # it from the record" - a flaky adb call would quietly turn an owed removal
  # into somebody's own app. An inventory that cannot be read skips all of it
  # and leaves the record as it was.
  rec="$(installed_record "$key")"
  if ! inv="$(ash_ro pm list packages --user "$uid" 2>/dev/null | tr -d '\r')" || [ -z "$inv" ]; then
    warn "$label: could not read its installed packages - removals and the install record are left for the next run"
    continue
  fi
  inv=" $(sed -n 's/^package://p' <<<"$inv" | tr '\n' ' ') "
  if [ -f "$rec" ]; then
    while read -r p; do
      [ -n "$p" ] || continue
      case "$DECLARED" in *" $p "*) continue;; esac
      case "$inv" in *" $p "*) ;; *) continue;; esac
      if [ "${PRUNE:-1}" = "0" ]; then
        warn "$p: no longer in the catalog for $label - kept (PRUNE=0)"
        OWED="$OWED$p "
      else
        ash pm uninstall --user "$uid" "$p" >/dev/null \
          && ok "$p removed - no longer in the catalog for $label" \
          || { warn "$p: could not be removed from $label"; REMOVE_FAILED+=("$label: $p"); OWED="$OWED$p "; }
      fi
    done < "$rec"
  fi

  # Somebody's own apps are theirs: named, never removed - unless a person asks
  # with PRUNE_UNDECLARED=1 (andashi apply --prune-undeclared), after `andashi
  # diff` has shown them.
  if ! third="$(ash_ro pm list packages -3 --user "$uid" 2>/dev/null | tr -d '\r' | sed -n 's/^package://p')"; then
    warn "$label: could not list its own apps - foreign apps not checked this run"
    third=""
  fi
  for p in $third; do
    case "$DECLARED$(zone_system_pkgs "$key")" in *" $p "*) continue;; esac
    grep -qxF "$p" "$rec" 2>/dev/null && continue    # handled above
    if [ "${PRUNE_UNDECLARED:-0}" = "1" ]; then
      ash pm uninstall --user "$uid" "$p" >/dev/null \
        && ok "$p removed - not in the catalog for $label (--prune-undeclared)" \
        || { warn "$p: could not be removed from $label"; REMOVE_FAILED+=("$label: $p"); }
    else
      warn "$p is installed in $label but not in the catalog - kept (andashi app add, or apply --prune-undeclared)"
    fi
  done

  # The record is what the catalog declares AND the zone now holds, plus what
  # is still owed. Read again after the removals, and rewritten only from a
  # read that worked.
  if [ "$DRY_RUN" != "1" ]; then
    if ! inv="$(ash_ro pm list packages --user "$uid" 2>/dev/null | tr -d '\r')" || [ -z "$inv" ]; then
      warn "$label: could not read its packages after the run - the install record is left as it was"
      continue
    fi
    inv=" $(sed -n 's/^package://p' <<<"$inv" | tr '\n' ' ') "
    mkdir -p "$(dirname "$rec")"
    : > "$rec.tmp"
    for p in $DECLARED; do case "$inv" in *" $p "*) printf '%s\n' "$p" >> "$rec.tmp";; esac; done
    # A removal that failed, or was held back with PRUNE=0, stays on the
    # record: it is still owed. Dropped from it, the next run would take the
    # package for somebody's own and keep it - the catalog's removal quietly
    # turned into a "kept" warning.
    for p in $OWED; do printf '%s\n' "$p" >> "$rec.tmp"; done
    mv "$rec.tmp" "$rec"
  fi
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

if [ "${#REMOVE_FAILED[@]}" -gt 0 ]; then
  printf '\n'
  warn "${#REMOVE_FAILED[@]} removal(s) the catalog asked for did not happen:"
  for e in "${REMOVE_FAILED[@]}"; do printf '     %s\n' "$e" >&2; done
  die "apps: removals failed - see above"
fi
