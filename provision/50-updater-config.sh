#!/usr/bin/env bash
# Hands each zone's updater its config (config/updater/<zone>.json, generated
# by config/gen-updater.sh) and proves it took:
#
#   content write --user <uid> --uri content://<updater>.ingest/updater.json
#   -> poll content://<updater>.state/diagnostics until configSha256 is the
#      sha256 of exactly this file and success is true
#   -> broadcast CHECK_NOW, so the zone compares itself with the lock now
#      instead of in up to six hours
#
# The same two-query contract as the launcher (45-launcher-config.sh): the
# write's exit code says nothing - `content write` exits 0 when the provider
# throws - so only the hash the updater reports for the file it loaded counts.
# A refused config says why in `error`, and the previous one stays in force.
#
# Nothing to do without an updater in the catalog (lib/updater.sh).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/updater.sh"
require_device

if [ -z "$UPDATER_PKG" ]; then
  skip "no app with role updater in the catalog - nothing to configure"
  exit 0
fi
: "${UPDATER_CFG_DIR:=$CONFIG_DIR/updater}"

FAILED=()
PENDING=()
problem() {   # $1=zone $2=reason
  if [ "$DRY_RUN" = "1" ]; then warn "$2"; else FAILED+=("$1|$2"); warn "$2"; fi
}

# What the host last saw a zone's updater load, per device: the sha256 of the
# file. Lets a stopped zone whose config did not change stay stopped.
record_file() { printf '%s/updater/%s/%s' "$STATE_DIR" "$(device_id)" "$1"; }

# 'content query' prints "Row: 0 json=<json>".
diagnostics() {   # $1=uid
  local out
  out="$(ash_ro content query --user "$1" --uri "content://$UPDATER_PKG.state/diagnostics" 2>/dev/null | tr -d '\r')" || return 1
  out="${out#Row: 0 json=}"
  jq -e . >/dev/null 2>&1 <<<"$out" || return 1
  printf '%s' "$out"
}

# One field of a diagnostics answer as text; empty for no answer at all. Not
# `// empty`: jq treats false as absent there, and success=false is the
# answer that matters most.
dfield() { jq -r "$1 | if . == null then empty else tostring end" <<<"${2:-null}" 2>/dev/null; }

# A provider is reachable a moment after the user starts, not at once; the
# same race the launcher step retries.
ingest_write() {   # $1=uid $2=file
  local attempt=0 out
  _adb_args
  while :; do
    out="$("$ADB" "${_AA[@]}" shell "content write --user $1 --uri content://$UPDATER_PKG.ingest/updater.json" < "$2" 2>&1 | tr -d '\r')" || out="${out:-content write failed}"
    [ -z "$out" ] && return 0
    case "$out" in
      *"Could not find provider"*|*"Unknown authority"*)
        attempt=$((attempt+1)); [ $attempt -ge 15 ] && { WRITE_OUT="$out"; return 1; }; sleep 2;;
      *) WRITE_OUT="$out"; return 1;;
    esac
  done
}

configure_zone() {   # $1=zone
  local key="$1" label uid cfg want diag sha err i rec
  label="$(profile_label "$key")"
  cfg="$UPDATER_CFG_DIR/$key.json"
  [ -f "$cfg" ] || { problem "$key" "$label: $cfg missing - run config/gen-updater.sh"; return 1; }
  jq -e --arg p "$UPDATER_PKG" '.apps[] | select(.pkg == $p) | .profiles | index($k)' --arg k "$key" "$CONFIG_DIR/apps.json" >/dev/null \
    || { skip "$label: the catalog does not place the updater here"; return 0; }
  uid="$(resolve_uid "$key")"
  [ -n "$uid" ] || { problem "$key" "$label: profile does not exist - run 00-profiles.sh first"; return 1; }
  want="$(sha256sum "$cfg" | cut -d' ' -f1)"
  rec="$(record_file "$key")"

  printf '\n'
  log "$label (user $uid): $(basename "$cfg"), sha256 ${want:0:12}..."

  if ! user_running_uid "$uid"; then
    if [ "$(cat "$rec" 2>/dev/null)" = "$want" ]; then
      skip "$label: unchanged since the last push - not started"
      pending_clear "$key" updater
      return 0
    fi
    if [ "${NO_START:-0}" = "1" ]; then
      PENDING+=("$label"); pending_add "$key" updater
      warn "$label: stopped - the config stays pending here until $label runs (or apply --all)"
      return 0
    fi
    ash am start-user -w "$uid" >/dev/null \
      && ok "$label started (had been evicted)" \
      || { problem "$key" "$label could not be started"; return 1; }
  fi
  if [ "$DRY_RUN" != "1" ] && ! user_unlocked "$uid"; then
    problem "$key" "$label: profile locked - unlock it on the device, then run again"; return 1
  fi
  pkg_installed_for_user "$UPDATER_PKG" "$uid" \
    || { problem "$key" "$label: $UPDATER_PKG not installed (user $uid) - run 10-apps.sh first"; return 1; }

  if [ "$DRY_RUN" = "1" ]; then
    printf '   [dry-run] content write --user %s --uri content://%s.ingest/updater.json < %s\n' "$uid" "$UPDATER_PKG" "$cfg"
    return 0
  fi

  diag="$(diagnostics "$uid" || true)"
  if [ "$(dfield .configSha256 "$diag")" = "$want" ] && [ "$(dfield .success "$diag")" = true ]; then
    ok "$label: already holds this config"
  else
    ingest_write "$uid" "$cfg" \
      || { problem "$key" "$label: content write into $UPDATER_PKG.ingest failed: ${WRITE_OUT:-?}"; return 1; }
    sha=""; err=""
    for i in $(seq 1 20); do
      diag="$(diagnostics "$uid" || true)"
      sha="$(dfield .configSha256 "$diag")"
      if [ "$sha" = "$want" ]; then
        [ "$(dfield .success "$diag")" = true ] && break
        err="$(dfield .error "$diag")"; err="${err:-no reason given}"; break
      fi
      # A refusal leaves the previous config's hash in place and names the
      # error for the file it refused.
      [ "$(dfield .success "$diag")" = false ] && err="$(dfield .error "$diag")"
      [ -n "$err" ] && break
      sleep 1
    done
    if [ -n "$err" ]; then
      problem "$key" "$label: the updater refused the config: $err"; return 1
    fi
    [ "$sha" = "$want" ] \
      || { problem "$key" "$label: the updater reports config ${sha:-none}, not ${want:0:12}... - it did not load this file"; return 1; }
    ok "$label: config loaded (diagnostics sha256 match)"
  fi
  mkdir -p "$(dirname "$rec")"; printf '%s\n' "$want" > "$rec"
  pending_clear "$key" updater

  # Compare with the lock now. The broadcast enqueues a check and returns;
  # what it finds is `andashi status`'s to report, not this step's to wait for.
  ash am broadcast --user "$uid" -n "$UPDATER_PKG/$UPDATER_RECEIVER_CLASS" -a "$UPDATER_PKG.action.CHECK_NOW" >/dev/null 2>&1 \
    || warn "$label: CHECK_NOW could not be sent - the zone checks on its own schedule"
}

while read -r key; do
  [ -z "$key" ] && continue
  if [ "$(profile_field "$key" type)" = "managed" ]; then
    skip "$(profile_label "$key"): managed profile - no updater of its own"
    continue
  fi
  configure_zone "$key" || true
done < <(profile_keys)

printf '\n'
if [ "${#FAILED[@]}" -gt 0 ]; then
  warn "${#FAILED[@]} zone(s) did not take the updater config:"
  for e in "${FAILED[@]}"; do printf '     %-10s %s\n' "${e%%|*}" "${e#*|}" >&2; done
  die "updater config failed for ${#FAILED[@]} zone(s)"
fi
if [ "${#PENDING[@]}" -gt 0 ]; then
  warn "${#PENDING[@]} zone(s) stopped with a config waiting on this host: ${PENDING[*]}"
fi
[ "$DRY_RUN" = "1" ] || ok "every running zone's updater holds its config"
