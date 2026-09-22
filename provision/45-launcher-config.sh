#!/usr/bin/env bash
# Pushes the generated launcher config (config/launcher/<profile>.json, see
# config/gen-launcher.sh) into every non-managed profile and lets the
# launcher converge to it. The only supported launcher is Andashi Home
# (config: true in theming.json); the former UI-automation step for launchers
# without a config interface is gone, together with those launchers.
#
# Flow per profile (Kvaesitso fork ADR 0002/0003, services/config module):
#   content write launcher.json into the launcher's ingest provider of that
#   user -> broadcast RELOAD_CONFIG -> poll diagnostics until configSha256
#   matches the written file -> query /config and verify the effective state
#   semantically against the written file.
#
# Transport: `content write --user <uid> --uri content://<pkg>.config-ingest/
# launcher.json < file`. The launcher exports a write-only ingest provider
# gated to shell/root (WRITE_SECURE_SETTINGS + uid check) that stores the
# bytes atomically at <external-files-dir>/config/launcher.json of THAT user.
# A plain `adb push` to /storage/emulated/<uid>/... is NOT an option: the
# shell only sees user 0's storage, every secondary user's path is
# "Permission denied" even with adb root (measured on the emulator
# 2026-09-19, documented in the fork's ADR 0003 §1a). An intermediate draft
# of this step pushed anyway and would have converged Home only. Same
# pattern the retired themectl helper used for wallpapers before 0.2.0.
# `content write` exits 0 even when the provider throws (it only prints the
# exception), so any output at all is treated as a failed write - and the
# diagnostics poll below would catch a silently missed write anyway, as
# configSha256 would never match.
#
# No foreground user switching, no UI automation: background users are
# started with am start-user, everything else is push/broadcast/content.
# A LOCKED profile cannot serve content providers - it is reported as failed,
# never unlocked.
#
# EXIT CODE: non-zero when ANY profile failed (missing, locked, package not
# installed, reload error, read-back mismatch). All profiles are attempted
# first - one broken zone must not hide the state of the others.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_device

THEME_FILE="$CONFIG_DIR/theming.json"
[ -f "$THEME_FILE" ] || die "config/theming.json missing"

LKEY="${LAUNCHER_CONFIG_KEY:-$(jq -r '.launcher // empty' "$THEME_FILE")}"
PKG="$(jq -r --arg k "$LKEY" '.launchers[$k].pkg // empty' "$THEME_FILE")"
[ -n "$LKEY" ] && [ -n "$PKG" ] || die "theming.json: .launcher/.launchers incomplete"

# Where the generated configs live. Overridable so a test can generate for a
# different launcher entry into a temp dir without touching the tracked files.
: "${LAUNCHER_CFG_DIR:=$CONFIG_DIR/launcher}"

if [ "$(jq -r --arg k "$LKEY" '.launchers[$k].config // false' "$THEME_FILE")" != "true" ]; then
  skip "launcher '$LKEY' has no config interface (config != true) - nothing to do"
  exit 0
fi

# ---- Failure accounting (strict) -------------------------------------------
# Same principle as the favorites accounting of the former UI step: the
# generated files PROMISE a launcher state per profile. A profile that does
# not end up converged and verified must fail the step, not produce one
# warning in a long log.
FAILED=()
problem() {   # $1=profile-key $2=reason; in DRY_RUN only a warning
  if [ "$DRY_RUN" = "1" ]; then
    warn "$2"
  else
    FAILED+=("$1|$2")
    warn "$2"
  fi
}

# Queries the launcher state provider and prints the served JSON document.
# 'content query' prints "Row: 0 <col>=<json>" - strip everything up to the
# first '{' and let jq decide whether what remains is a document.
query_state() {   # $1=path (config|diagnostics) $2=uid
  local out json
  out="$(ash_ro content query --uri "content://$PKG.state/$1" --user "$2" 2>/dev/null | tr -d '\r')" || return 1
  case "$out" in
    *\{*) json="{${out#*\{}";;
    *)    return 1;;
  esac
  printf '%s' "$json" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s' "$json"
}

# content write into an ingest URI, with a bounded retry for the moment right
# after `am start-user -w`: the user is already UNLOCKED, but its external
# storage and its package resolution land a little later. The provider then
# answers "External files directory unavailable", or the shell does not find
# the provider at all ("Could not find provider"). Measured in the full chain
# from the clean snapshot (2026-09-19): Cloud and Gadgets failed exactly
# there while Ops and Lab passed on the same run - a race, not a launcher
# error. Only those two messages are retried, for up to ~30 s; anything else
# is a real failure and fails at once. Deliberately WITHOUT the ash wrapper:
# it forces stdin from /dev/null, here stdin MUST be the file (adb shell v2
# is binary-safe). Sets WRITE_OUT (empty on success) and INGEST_RETRIES.
ingest_write() {   # $1=uri $2=file $3=uid
  local attempt=0
  INGEST_RETRIES=""
  _adb_args
  while :; do
    WRITE_OUT="$("$ADB" "${_AA[@]}" shell "content write --user $3 --uri $1" < "$2" 2>&1 | tr -d '\r')" || WRITE_OUT="${WRITE_OUT:-content write failed}"
    [ -z "$WRITE_OUT" ] && return 0
    case "$WRITE_OUT" in
      *"External files directory unavailable"*|*"Could not find provider"*)
        attempt=$((attempt+1))
        INGEST_RETRIES=$attempt
        [ $attempt -ge 15 ] && return 1
        sleep 2;;
      *) return 1;;
    esac
  done
}

configure_profile() {   # $1=profile-key
  local key="$1" label uid cfgfile ingest_uri want_sha wp wpf wpname
  label="$(profile_label "$key")"
  cfgfile="$LAUNCHER_CFG_DIR/$key.json"
  [ -f "$cfgfile" ] || { problem "$key" "$label: $cfgfile missing - run config/gen-launcher.sh"; return 1; }

  uid="$(resolve_uid "$key")"
  [ -n "$uid" ] || { problem "$key" "$label: profile does not exist - run 00-profiles.sh first"; return 1; }

  printf '\n'
  log "Profile $label (user $uid)"

  # Start evicted users ourselves - a stopped user has no provider to write
  # to or query. Background start only, never a foreground switch.
  if ! user_running_uid "$uid"; then
    ash am start-user -w "$uid" >/dev/null \
      && ok "$label started (had been evicted)" \
      || { problem "$key" "$label could not be started"; return 1; }
  fi

  # A locked user's credential-encrypted storage is sealed: no provider, no
  # app process. Report, never unlock.
  if [ "$DRY_RUN" != "1" ] && ! user_unlocked "$uid"; then
    problem "$key" "$label: profile locked - unlock it on the device, then run again"
    return 1
  fi

  pkg_installed_for_user "$PKG" "$uid" \
    || { problem "$key" "$label: $PKG not installed (user $uid) - run 10-apps.sh first"; return 1; }

  ingest_uri="content://$PKG.config-ingest/launcher.json"
  want_sha="$(sha256sum "$cfgfile" | awk '{print $1}')"

  # ---- Wallpaper upload ----------------------------------------------------
  # The generated config names the image (basename of the theming.json path);
  # the file itself is uploaded here, under that name, before the config, so
  # the reload finds it. {aspect} resolves against the device like in
  # 40-theming.sh. No wallpaper in theming.json means nothing to upload.
  wp="$(theme_field "$key" wallpaper)"
  if [ "$(jq -r --arg k "$LKEY" '.launchers[$k].wallpaper // false' "$THEME_FILE")" != "true" ]; then
    wp=""   # launcher entry without wallpaper support: nothing to upload, config has no key either
  fi
  if [ -n "$wp" ]; then
    case "$wp" in *'{aspect}'*) wp="${wp//\{aspect\}/$(device_aspect_class)}";; esac
    wpf="$REPO_ROOT/$wp"
    wpname="$(basename "$wp")"
    [ -f "$wpf" ] || { problem "$key" "$label: wallpaper file missing: $wp"; return 1; }
    if [ "$DRY_RUN" = "1" ]; then
      printf '   [dry-run] content write --user %s --uri content://%s.config-ingest/wallpapers/%s < %s\n' "$uid" "$PKG" "$wpname" "$wp"
    else
      if ! ingest_write "content://$PKG.config-ingest/wallpapers/$wpname" "$wpf" "$uid"; then
        printf '%s\n' "$WRITE_OUT" >&2
        problem "$key" "$label: wallpaper upload of $wpname failed (user $uid)"
        return 1
      fi
      ok "wallpaper uploaded ($wpname, $(du -h "$wpf" | cut -f1)${INGEST_RETRIES:+, after $INGEST_RETRIES retries})"
    fi
  fi

  if [ "$DRY_RUN" = "1" ]; then
    printf '   [dry-run] content write --user %s --uri %s < %s\n' "$uid" "$ingest_uri" "$cfgfile"
  else
    if ! ingest_write "$ingest_uri" "$cfgfile" "$uid"; then
      printf '%s\n' "$WRITE_OUT" >&2
      problem "$key" "$label: content write into $ingest_uri failed (user $uid)"
      return 1
    fi
    ok "config written ($(basename "$cfgfile"), sha256 ${want_sha:0:12}...${INGEST_RETRIES:+, after $INGEST_RETRIES retries})"
  fi

  # The content write above already started the app's process (a fresh
  # install would otherwise be in the stopped state, where Android does not
  # deliver even explicit broadcasts to a manifest receiver). The receiver is
  # exported but gated to shell/root, exactly like the ingest provider.

  # Explicit broadcast: deterministic for scripts (the file watcher is the
  # interactive path). Component + action, per user.
  ash am broadcast \
    -a "$PKG.action.RELOAD_CONFIG" \
    -n "$PKG/de.mm20.launcher2.config.service.ReloadConfigReceiver" \
    --user "$uid" >/dev/null \
    || { problem "$key" "$label: reload broadcast failed"; return 1; }

  if [ "$DRY_RUN" = "1" ]; then
    log "[dry-run] would poll content://$PKG.state/diagnostics until configSha256=${want_sha:0:12}... and verify /config"
    return 0
  fi

  # ---- Poll diagnostics: did the reload converge on OUR file? --------------
  # The launcher records the sha256 of the file it last loaded plus success /
  # error details. A matching sha with success=false is a failure with an
  # explanation from the launcher itself - surface it, don't retry it away.
  local attempt=0 diag got_sha success n_diag
  while [ $attempt -lt 30 ]; do
    if diag="$(query_state diagnostics "$uid")"; then
      got_sha="$(printf '%s' "$diag" | jq -r '.configSha256 // empty')"
      success="$(printf '%s' "$diag" | jq -r '.success // empty')"
      if [ "$got_sha" = "$want_sha" ]; then
        if [ "$success" = "true" ]; then
          ok "reload converged (diagnostics sha256 match)"
          # success=true does not mean the launcher had nothing to say. Warning
          # diagnostics ride the same channel as errors: today `unknown-key`,
          # and from andashi/home#47 on also `inert-key` - "accepted, but this
          # build has no renderer for it". Dropping them here is exactly how a
          # config can converge while describing a home screen that does not
          # exist: home.dock.enabled is accepted, echoed back, and draws
          # nothing, because the renderer left with the clock (andashi/home#46).
          # Printed, not interpreted - what a code means is the launcher's to
          # say, and guessing here is the heuristic we just removed elsewhere.
          n_diag="$(printf '%s' "$diag" | jq -r '(.diagnostics // []) | length')"
          if [ "${n_diag:-0}" -gt 0 ]; then
            warn "$label: converged, but the launcher reported $n_diag diagnostic(s):"
            printf '%s' "$diag" \
              | jq -r '(.diagnostics // [])[] | "     \(.severity // "?") \(.code // "?") \(.path // "-") \(.message // "")"' >&2
          fi
          break
        fi
        warn "$label: reload reported an error:"
        printf '%s\n' "$(printf '%s' "$diag" | jq -c .)" >&2
        problem "$key" "$label: launcher rejected the config (see diagnostics above)"
        return 1
      fi
    fi
    sleep 1
    attempt=$((attempt+1))
  done
  if [ $attempt -ge 30 ]; then
    problem "$key" "$label: diagnostics never confirmed the written config (last sha256: ${got_sha:-<none>})"
    return 1
  fi

  # ---- Read back /config: does the effective state match semantically? -----
  # NOT verbatim. /config is the document re-serialised from the launcher's
  # decoded model, and its Json sets no encodeDefaults - so a value that equals
  # the default is simply absent from what comes back. Dock favorites make that
  # visible, because the schema accepts two spellings of the same thing:
  #
  #   written {"packageName":"x","profile":"personal"} -> served {"packageName":"x"}
  #   written "x"                                      -> served {"packageName":"x"}
  #   written {"packageName":"x","profile":"work"}     -> served unchanged
  #
  # "personal" is the default and disappears, "work" is not and survives. A
  # verbatim comparison therefore rejected every zone with a favorite in the
  # personal profile, reporting a mismatch for a config that had converged
  # correctly (provisioning#6, found from the launcher side 2026-09-22).
  #
  # So both sides are canonicalised into the long form before comparing. The
  # normalisation is deliberately narrow: a swallowed favorite, a changed
  # profile, a different package and a different ORDER all still count as a
  # mismatch. A normalisation that accepts everything is worse than no check.
  local eff mism
  eff="$(query_state config "$uid")" \
    || { problem "$key" "$label: state provider did not serve /config"; return 1; }
  mism="$(jq -r -n --argjson eff "$eff" --slurpfile want "$cfgfile" '
    def canon:
      if ((.home.dock.favorites // null) | type) == "array" then
        .home.dock.favorites |= map(
          if type == "string" then { packageName: ., profile: "personal" }
          else { packageName: .packageName, profile: (.profile // "personal") }
          end)
      else . end;
    ($want[0] | canon) as $w
    | ($eff | canon) as $e
    | [ "schemaVersion", "icons", "appearance", "home" ]
    | map(select($e[.] != $w[.]))
    | join(", ")')"
  if [ -z "$mism" ]; then
    ok "$label: effective config verified"
    return 0
  fi
  warn "$label: effective config differs in: $mism"
  problem "$key" "$label: read-back /config does not match the written file ($mism)"
  return 1
}

while read -r key; do
  [ -z "$key" ] && continue
  # A managed profile (Work) has no home screen of its own - no config file
  # is generated for it either, so this is a deliberate skip, not a failure.
  if [ "$(profile_field "$key" type)" = "managed" ]; then
    skip "$(profile_label "$key"): managed profile - launcher runs in the parent profile"
    continue
  fi
  configure_profile "$key" || true
done < <(profile_keys)

# ---- Verdict ---------------------------------------------------------------
if [ "${#FAILED[@]}" -gt 0 ]; then
  printf '\n'
  warn "${#FAILED[@]} profile(s) did not converge to the generated config:"
  for entry in "${FAILED[@]}"; do
    printf '     %-12s %s\n' "${entry%%|*}" "${entry#*|}" >&2
  done
  die "launcher config failed for ${#FAILED[@]} profile(s) - fix and run again"
fi

[ "$DRY_RUN" = "1" ] || ok "All profiles converged and verified ($PKG)"
exit 0
