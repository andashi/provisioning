#!/usr/bin/env bash
# Orchestrates the complete run. Idempotent - repeatable any number of times.
#   DRY_RUN=1 provision/run.sh        # only show what would happen
#   ADB_SERIAL=emulator-5554 ...      # with multiple devices
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# The launcher is configured by file (45-launcher-config: push + reload +
# read-back). There is no UI-driven step in the chain any more - Andashi Home
# is the only supported launcher precisely so that there never has to be one.
STEPS=(00-profiles 10-apps 20-permissions 30-settings 35-vpn 40-theming 45-launcher-config 50-updater-config 90-manual 99-finalize)
[ "${SKIP_FINALIZE:-0}" = "1" ] && STEPS=("${STEPS[@]/99-finalize}")

start="$(date +%s)"
for s in "${STEPS[@]}"; do
  [ -z "$s" ] && continue
  # Steps are allowed to be temporarily missing (e.g. 35-vpn is being created
  # in a parallel session).
  [ -f "$REPO_ROOT/provision/$s.sh" ] || { warn "$s.sh missing - skipped"; continue; }
  printf '\n%s\n' "$(_c '1;35' "===== $s =====")"
  "$REPO_ROOT/provision/$s.sh"
done
printf '\n'
# Every step went through (each one exits non-zero on failure, and this script
# stops there), so this is what the host has now applied to each zone.
# `andashi apply` starts from it and touches only what changes afterwards.
source "$REPO_ROOT/lib/andashi.sh"
while read -r _z; do record_applied "$_z"; done < <(profile_keys)
ok "Done in $(( $(date +%s) - start ))s. Now work through MANUAL.md."
