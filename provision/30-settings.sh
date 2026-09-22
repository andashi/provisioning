#!/usr/bin/env bash
# settings put per profile from config/settings.json.
# Namespaces: global (device-wide, only meaningful for user 0) | secure | system (per-user).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_device

SETTINGS_FILE="$CONFIG_DIR/settings.json"
[ -f "$SETTINGS_FILE" ] || die "config/settings.json missing"

apply_ns() {   # $1=uid $2=ns $3=json-object
  while read -r line; do
    [ -z "$line" ] && continue
    k="${line%%=*}"; v="${line#*=}"
    # The `|| cur=""` is not cosmetic. GrapheneOS refuses READ access to
    # protected settings with a SecurityException and adb exits 255 - and with
    # `set -euo pipefail` from lib/common.sh that status travels through the
    # pipe, lands on this assignment, and kills the whole step without printing
    # anything. One unreadable key used to take the entire settings run with it.
    # Unknown current value now simply means "try the write and report".
    cur="$(ash_ro settings --user "$1" get "$2" "$k" 2>/dev/null | tr -d '\r')" || cur=""
    if [ "$cur" = "$v" ]; then
      skip "$2/$k = $v"
    else
      ash settings --user "$1" put "$2" "$k" "$v" >/dev/null 2>&1 \
        && ok "$2/$k: ${cur:-<unset>} -> $v" \
        || warn "$2/$k could not be set (protected setting? then it is manual - MANUAL.md)"
    fi
  done < <(jq -r 'to_entries[]? | "\(.key)=\(.value)"' <<<"$3")
}

log "Global settings (user 0)"
apply_ns 0 global "$(jq -c '.global // {}' "$SETTINGS_FILE")"

# Notification forwarding is a secure setting in GrapheneOS, named after the
# censorship rather than the forwarding: send_censored_notifications_to_current_user.
# Found in the source (SendCensoredNotificationsToCurrentUserPreferenceController.java),
# not by guessing - a search for "forward" comes up empty. Only the username,
# app name, and time get forwarded, not the content. Controlled via the
# notification_forwarding field in profiles.json.
#
# MEASURED 2026-09-17, and the earlier claim that this step automates it was
# wrong: GrapheneOS treats the key as a PROTECTED setting. Both `settings get`
# and `settings put` are refused with
#   SecurityException: root is not allowed to access protected setting
# on every profile, adb root included. There is no adb path to it. The attempt
# below is kept because it costs nothing and a future Android may allow it, but
# it will warn, and the actual switch stays a manual step per profile
# (Settings -> Notifications). Do not re-advertise this as automated.
NOTIF_KEY=send_censored_notifications_to_current_user

while read -r key; do
  label="$(profile_label "$key")"
  uid="$(resolve_uid "$key")"
  [ -n "$uid" ] || continue
  printf '\n'; log "Profile $label (user $uid)"
  apply_ns "$uid" secure "$(jq -c --arg k "$key" '(.per_profile[$k].secure // {}) * (.all_profiles.secure // {})' "$SETTINGS_FILE")"
  apply_ns "$uid" system "$(jq -c --arg k "$key" '(.per_profile[$k].system // {}) * (.all_profiles.system // {})' "$SETTINGS_FILE")"

  fwd="$(profile_field "$key" notification_forwarding)"
  case "$fwd" in
    true)  apply_ns "$uid" secure "{\"$NOTIF_KEY\":1}" ;;
    false) apply_ns "$uid" secure "{\"$NOTIF_KEY\":0}" ;;
    *)     warn "$label: notification_forwarding missing in profiles.json - skipped" ;;
  esac
done < <(profile_keys)
