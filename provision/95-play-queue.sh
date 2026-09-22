#!/usr/bin/env bash
# Walks the sandboxed-Play installs of a zone, one Play page at a time.
#
#   provision/95-play-queue.sh               every zone that has Play apps left
#   provision/95-play-queue.sh cloud work    only these zones
#   DRY_RUN=1 provision/95-play-queue.sh     print what it would open
#
# NOT part of run.sh, and it never will be: this step waits for a human. Play
# needs an account and taps, which is exactly why those apps are manual by
# design (docs/decisions/0008-some-things-stay-manual.md). What provisioning
# CAN do is remove the navigation - it knows the package name and the profile,
# so it sends the store straight to the right page in the right profile. The
# person taps "Install" and presses Enter; they never type a search term and
# never pick the wrong profile.
#
# The zone has to be in the FOREGROUND for that, so this switches users while
# it works and returns to Home at the end. Nothing else here writes to the
# device.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_device

PLAY_PKG="com.android.vending"

# Zones to walk: arguments, otherwise every configured one. Managed profiles
# are included on purpose - the work profile is where Teams and Intune live.
if [ "$#" -gt 0 ]; then
  KEYS=("$@")
else
  mapfile -t KEYS < <(profile_keys)
fi

total_open=0      # pages actually opened (or, in a dry run, that would be)
total_done=0     # already installed - why this list shrinks every run
total_blocked=0  # zones that cannot be walked yet, because Play is not there

for key in "${KEYS[@]}"; do
  [ -z "$key" ] && continue
  label="$(profile_label "$key")"
  [ -n "$label" ] || { warn "unknown zone '$key' - skipped"; continue; }
  uid="$(resolve_uid "$key")"
  [ -n "$uid" ] || { warn "$label does not exist - run 00-profiles.sh first"; continue; }

  # Which Play apps does this zone still need? Feature-gated entries whose
  # feature is off were never meant to be here, and anything already installed
  # is why this list gets shorter every run instead of staying the same length.
  pending=()
  while read -r app; do
    [ -z "$app" ] && continue
    [ "$(jq -r '.source' <<<"$app")" = "play-sandboxed" ] || continue
    feat="$(jq -r 'if has("feature") then .feature else "" end' <<<"$app")"
    [ -n "$feat" ] && ! feature_enabled "$feat" && continue
    pkg="$(jq -r '.pkg' <<<"$app")"
    if pkg_installed_for_user "$pkg" "$uid"; then
      total_done=$((total_done + 1)); continue
    fi
    pending+=("$(jq -r '.label' <<<"$app")|$pkg")
  done < <(apps_for_profile "$key")

  [ "${#pending[@]}" -eq 0 ] && { skip "$label: nothing left to install from Play"; continue; }

  printf '\n'
  log "$label (user $uid): ${#pending[@]} app(s) from Play"

  if [ "$DRY_RUN" = "1" ]; then
    total_open=$((total_open + ${#pending[@]}))
    for entry in "${pending[@]}"; do
      printf '   [dry-run] am start --user %s -a android.intent.action.VIEW -d market://details?id=%s\n' \
        "$uid" "${entry#*|}"
    done
    continue
  fi

  # Without Play in the profile a market:// link resolves to nothing and the
  # screen just stays where it is - which looks like the script did nothing.
  # Say it instead, and point at the step that comes first.
  if ! pkg_installed_for_user "$PLAY_PKG" "$uid"; then
    warn "$label: sandboxed Play is not installed in this profile"
    warn "$label: install it from the GrapheneOS app store first (MANUAL.md, \"Sandboxed Play Services\")"
    total_blocked=$((total_blocked + ${#pending[@]}))
    continue
  fi

  ash am switch-user "$uid" >/dev/null || { warn "$label: could not switch to this profile"; continue; }
  # The switch is not instant; a store started too early opens in the profile
  # we just left - the exact mistake this step exists to prevent.
  for _i in $(seq 1 30); do
    [ "$(ash_ro am get-current-user 2>/dev/null | tr -d '\r')" = "$uid" ] && break
    sleep 1
  done
  if [ "$(ash_ro am get-current-user 2>/dev/null | tr -d '\r')" != "$uid" ]; then
    warn "$label: profile did not come to the foreground within 30 s - skipped"
    continue
  fi

  i=0
  for entry in "${pending[@]}"; do
    i=$((i + 1))
    lbl="${entry%%|*}"; pkg="${entry#*|}"
    printf '  %2d/%d  %-28s %s\n' "$i" "${#pending[@]}" "$lbl" "$pkg"
    if ash am start --user "$uid" -a android.intent.action.VIEW -d "market://details?id=$pkg" >/dev/null 2>&1; then
      total_open=$((total_open + 1))
    else
      warn "$lbl: Play did not open for $pkg"
    fi
    # Reading from the terminal, not from stdin: the loop's stdin belongs to
    # the app list, and consuming it here would end the walk after one entry.
    read -r -p "        installed? [Enter] next, [q] quit this zone " answer </dev/tty || answer=q
    case "$answer" in
      q|Q) warn "$label: stopped at $i of ${#pending[@]}"; break ;;
      *)   : ;;
    esac
  done
done

printf '\n'
ash am switch-user 0 >/dev/null 2>&1 || warn "could not switch back to Home - do it by hand"

if [ "$total_blocked" -gt 0 ]; then
  warn "$total_blocked app(s) in zones without sandboxed Play - install Play there, then run this again"
fi
if [ "$total_open" -eq 0 ] && [ "$total_blocked" -eq 0 ]; then
  ok "No Play installs left ($total_done already installed)"
else
  [ "$total_open" -gt 0 ] && log "$total_open Play page(s) opened, $total_done were already installed"
  log "Run 90-manual.sh afterwards so MANUAL.md reflects what is actually left."
fi
