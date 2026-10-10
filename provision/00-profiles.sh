#!/usr/bin/env bash
# Creates the secondary profiles and brings them into the desired runtime state.
# Home = Owner (user 0) is never created.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/updater.sh"

require_device
require_graphene

log "Reconciling profiles from config/profiles.json"

while read -r key; do
  label="$(profile_label "$key")"
  create="$(profile_field "$key" create)"
  runtime="$(profile_field "$key" runtime)"

  if [ "$create" != "true" ]; then
    skip "$label (Owner, user 0) - not created"
    continue
  fi

  # Feature gate: only create profiles with "feature" if it's turned on.
  feat="$(profile_field "$key" feature)"
  if [ -n "$feat" ] && ! feature_enabled "$feat"; then
    skip "$label (feature '$feat' is off)"; continue
  fi

  if user_exists "$label"; then
    uid="$(user_id_for "$label")"
    skip "$label already exists (user $uid)"
  elif [ "$DRY_RUN" = "1" ]; then
    # In a dry run there is no real user id - the call is only shown.
    # Without this branch, evaluating the output here would fail.
    ash pm create-user "$label" >/dev/null
    uid=""
    ok "$label would be created"
  else
    # type=managed -> work profile under a parent profile instead of its own
    # secondary user. Only work profiles allow cross-profile contact
    # resolution; the framework branches on isManagedProfile.
    ptype="$(profile_field "$key" type)"
    if [ "$ptype" = "managed" ]; then
      parent="$(profile_field "$key" parent)"
      puid="$(resolve_uid "$parent")"
      [ -n "$puid" ] || die "$label: parent profile '$parent' does not exist"
      out="$(ash pm create-user --profileOf "$puid" --user-type android.os.usertype.profile.MANAGED "$label" | tr -d '\r')"
    else
      out="$(ash pm create-user "$label" | tr -d '\r')"
    fi
    uid="$(printf '%s' "$out" | sed -n 's/.*id \([0-9]\+\).*/\1/p')"
    [ -n "$uid" ] || die "create-user for $label failed: $out"
    ok "$label created (user $uid)"

    # A work profile needs a profile owner. Shelter is a local, open-source
    # stand-in for an MDM solution - it doesn't manage anything, it just
    # exists so the profile is allowed to exist. Intune can't take on this
    # role on GrapheneOS (os-issue-tracker#1938: Company Portal can't find
    # the Play Store).
    po="$(profile_field "$key" profile_owner)"
    if [ -n "$po" ]; then
      popkg="${po%%/*}"
      # The owner app must already exist in the PARENT profile before it can be
      # pushed into the new one - and on a genuinely fresh device it does not,
      # because 10-apps.sh runs AFTER this step. `pm install-existing` then
      # failed, and since it was the last command of the || chain the whole line
      # returned non-zero: `set -e` ended the run right here, with 2>&1 having
      # swallowed the reason. The first clean-room run died silently at profile
      # two for exactly this. A missing owner is now an expected, reported
      # condition that costs the work profile, not the run.
      # run.sh has 00-profiles BEFORE 10-apps, so on a fresh device the owner
      # simply is not there yet. Reporting that and carrying on (below) keeps the
      # run alive but still leaves the work profile ownerless, which is not a
      # working work profile. So fetch the one APK we need from the catalog right
      # here - it is a single package and apk_for_pkg already knows where it
      # lives. The step stops depending on an ordering it cannot control.
      if ! pkg_installed_for_user "$popkg" 0; then
        po_apk="$(apk_for_pkg "$popkg" || true)"
        if [ -n "$po_apk" ]; then
          # The first app this chain installs on a fresh device, so the
          # updater goes on first, to be named as its installer (lib/updater.sh).
          ensure_updater_device
          po_args=()
          updater_manages "$(jq -r --arg p "$popkg" '[.apps[] | select(.pkg == $p) | .source][0] // ""' "$CONFIG_DIR/apps.json")" \
            && po_args=("${INSTALLER_ARGS[@]}")
          adb_ install "${po_args[@]}" --user 0 -r "$po_apk" >/dev/null 2>&1 \
            && ok "$label: profile owner $popkg installed from $(basename "$po_apk")" \
            || warn "$label: could not install $popkg from $(basename "$po_apk")"
        fi
      fi
      if pkg_installed_for_user "$popkg" 0; then
        pkg_installed_for_user "$popkg" "$uid" \
          || ash pm install-existing --user "$uid" "$popkg" >/dev/null 2>&1 \
          || true
        ash dpm set-profile-owner --user "$uid" "$po" >/dev/null 2>&1 \
          && ok "$label: profile owner set ($popkg)" \
          || warn "$label: profile owner could not be set ($popkg)"
      else
        warn "$label: $popkg is not in Home yet, so the work profile gets no owner."
        warn "  Install it first (10-apps.sh), then run this step again - continuing."
      fi
    fi
  fi

  # Establish runtime state
  if [ -z "$uid" ]; then
    skip "$label: runtime state '$runtime' is not set in a dry run"
    continue
  fi

  case "$runtime" in
    always|on-demand)
      # The profile must be running for provisioning - installs need a running user.
      if user_running "$label"; then
        skip "$label already running"
      else
        ash am start-user -w "$uid" >/dev/null
        ok "$label started (user $uid)"
      fi
      ;;
    stopped)
      # Start it on the first run anyway - 99-finalize stops it again.
      if ! user_running "$label"; then
        ash am start-user -w "$uid" >/dev/null
        ok "$label temporarily started for provisioning (user $uid)"
      fi
      ;;
  esac
done < <(profile_keys)

log "Current state:"
ash_ro pm list users | tr -d '\r' | sed 's/^/   /'
