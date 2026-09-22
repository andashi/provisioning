#!/usr/bin/env bash
# Brings profiles into their target runtime state: 'stopped' gets stopped (keys evicted).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_device

# Two passes: first stop everything that should be stopped, then start the
# always profiles. The other way around, starting would evict someone we
# still need.
log "Establishing target runtime states"
for _pass in stop start; do
while read -r key; do
  [ "$(profile_field "$key" create)" = "true" ] || continue
  label="$(profile_label "$key")"
  runtime="$(profile_field "$key" runtime)"
  uid="$(user_id_for "$label")"
  [ -n "$uid" ] || { warn "$label does not exist - skipped"; continue; }

  case "$runtime" in
    stopped|on-demand)
      [ "$_pass" = "stop" ] || continue
      if user_running "$label"; then
        ash am stop-user -w -f "$uid" >/dev/null
        ok "$label stopped (keys evicted, user $uid)"
      else
        skip "$label is already stopped"
      fi
      ;;
    always)
      [ "$_pass" = "start" ] || continue
      # Don't just skip: during provisioning, more profiles temporarily run than
      # GrapheneOS allows (3 incl. owner), and Android evicts by LRU. What
      # typically gets hit is Cloud - the profile that MUST run afterward
      # (a car key, a door lock, work push). The finalize step therefore has to establish
      # the target state, not assume it.
      if user_running_uid "$uid"; then
        skip "$label is running (target state)"
      else
        ash am start-user -w "$uid" >/dev/null \
          && ok "$label started - had been evicted during provisioning" \
          || warn "$label could not be started - target state NOT reached"
      fi
      ;;
  esac
done < <(profile_keys)
done
