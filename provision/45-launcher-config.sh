#!/usr/bin/env bash
# Pushes the generated launcher config (config/launcher/<profile>.json, see
# config/gen-launcher.sh) into every non-managed profile and lets the
# launcher converge to it. The only supported launcher is Andashi Home
# (config: true in theming.json); the former UI-automation step for launchers
# without a config interface is gone, together with those launchers.
#
# Flow per profile (Kvaesitso fork ADR 0002/0003, services/config module):
#   content write launcher.json into the launcher's ingest provider of that
#   45-launcher-config.sh          push the generated config to every zone
#   45-launcher-config.sh --pull   bring the device's arrangement back first
#
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
# What the device reported the last time we agreed with it, per device and
# zone. Not a version counter: the launcher writes launcher.json itself once
# edit mode ships, and a counter would have to be maintained on both sides.
# The sha the launcher already publishes in its diagnostics is enough for a
# compare-and-swap on content.
device_id() { printf '%s' "${ADB_SERIAL:-$(adb get-serialno 2>/dev/null || echo unknown)}" | tr -c 'A-Za-z0-9_.-' '_'; }
sha_record() { printf '%s/launcher-sha/%s/%s' "$STATE_DIR" "$(device_id)" "$1"; }

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
  INGEST_HINT=""
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
      # Not a race, so not retried: the app cannot create a file in its own
      # per-user external directory. That directory survives an uninstall and
      # keeps the ownership of the install that made it, so a build installed
      # with a different signer - release traded for debug, which is what
      # launcher work does - finds a directory it may not write to and every
      # upload into that zone fails for good. Measured 2026-09-24 on
      # emulator-5558: twelve attempts over 24s, always
      # "IOException: Permission denied" in File.createTempFile, and a
      # `pm clear` for that user fixed it immediately - but only while the
      # user was running. On a stopped user the same command prints Success
      # and changes nothing, because its storage is not mounted.
      #
      # Only the hint is given, never the command: `pm clear` also destroys the
      # arrangement somebody made on the device, and this step exists to
      # protect exactly that.
      *"getFileDescriptor()"*|*"Permission denied"*)
        INGEST_HINT="the per-user data of $PKG is from an earlier install (different signer?). The user has to be RUNNING for the clear to take, it reports Success either way: adb -s ${ADB_SERIAL:-<serial>} shell am start-user -w $3 \&\& adb -s ${ADB_SERIAL:-<serial>} shell pm clear --user $3 $PKG"
        return 1;;
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
  # ---- Pull before push -------------------------------------------------
  # Once edit mode ships, the launcher writes launcher.json itself: a push can
  # overwrite an arrangement somebody made by hand. So compare what the device
  # reports NOW against what it reported when we last agreed with it, and
  # refuse if someone changed it in between. No record yet means a device we
  # have never written to - nothing to protect, so it proceeds and records.
  #
  # Note the deliberate asymmetry with the read-back check further down. That
  # one IGNORES grid geometry, because we never declared it and the device is
  # free to place an item. This guard must NOT ignore it: dragging a widget
  # changes exactly those fields, so geometry is the arrangement, and a guard
  # that looked past it would silently overwrite what it exists to protect.
  # Measured on 0.4.0: the launcher completes the geometry in the document it
  # SERVES but does not rewrite launcher.json for it, so a placement alone
  # does not move the hash and this does not fire without a real change.
  local rec dev_sha
  rec="$(sha_record "$key")"
  if [ "$DRY_RUN" != "1" ] && [ -f "$rec" ]; then
    dev_sha="$(query_state diagnostics "$uid" 2>/dev/null | jq -r '.configSha256 // empty')"
    if [ -n "$dev_sha" ] && [ "$dev_sha" != "$(tr -d '[:space:]' < "$rec")" ]; then
      warn "$label: device has ${dev_sha:0:12}..., we last agreed on $(tr -d '[:space:]' < "$rec" | cut -c1-12)..."
      problem "$key" "$label: the config changed on the device since our last run - pull it first ($0 --pull), then push"
      return 1
    fi
  fi

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
        problem "$key" "$label: wallpaper upload of $wpname failed (user $uid)${INGEST_HINT:+ - $INGEST_HINT}"
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
      problem "$key" "$label: content write into $ingest_uri failed (user $uid)${INGEST_HINT:+ - $INGEST_HINT}"
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
  local attempt=0 diag got_sha success n_diag fatal_diag
  while [ $attempt -lt 30 ]; do
    if diag="$(query_state diagnostics "$uid")"; then
      got_sha="$(printf '%s' "$diag" | jq -r '.configSha256 // empty')"
      success="$(printf '%s' "$diag" | jq -r '.success // empty')"
      if [ "$got_sha" = "$want_sha" ]; then
        if [ "$success" = "true" ]; then
          ok "reload converged (diagnostics sha256 match)"
          # The device now holds exactly what we wrote, and that is what the
          # guard above wants to know - not whether we were happy with it.
          # Recording only after a successful read-back made a FAILED push
          # block the next one: the zone kept our rejected file, the record
          # still named the one before it, and the guard reported a device-side
          # edit that never happened. Measured 2026-09-23 while testing the
          # glass: false path against 0.5.0 - six zones refused the correcting
          # run and pointed at --pull, which would have pulled the bad config
          # into the catalog.
          mkdir -p "$(dirname "$rec")" && printf '%s\n' "$want_sha" > "$rec"
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
          # One of them is not a warning but a failure: the launcher saying
          # that appearance.transparency no longer does anything (0.5.0
          # replaced it with appearance.glass, andashi/home#24). It means this
          # host still generates the pre-glass shape against a release that has
          # moved on - the zone then runs on the glass defaults of the launcher
          # while the catalog claims to set the look. The fix is theming.json
          # (glass: true), not another attempt, so it fails here with the
          # launcher's own sentence rather than as a read-back difference in
          # `appearance`, which names the section but not the cause.
          #
          # Deliberately a named key and not "every inert key is fatal": a key
          # can be inert in one release and still be the right thing to keep
          # writing. home.dock.enabled was exactly that - inert since 0.3.0 and
          # kept on purpose - and then schema 2 removed it outright, with the
          # dock returning as a grid item rather than as a key. So a blanket
          # rule would have been wrong twice: fatal while it was merely quiet,
          # and silent about the release that actually deleted it.
          fatal_diag="$(printf '%s' "$diag" | jq -r '
            (.diagnostics // [])[]
            | select((.code // "") == "inert-key" and (.path // "") == "appearance.transparency")
            | (.message // "appearance.transparency is inert")' | head -1)"
          if [ -n "$fatal_diag" ]; then
            problem "$key" "$label: $fatal_diag - set glass: true for the launcher entry in theming.json"
            return 1
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
  # correctly (reported from the launcher side 2026-09-22; the thread is in
  # ~/Development/andashi/issues-archive-provisioning/issue-6.md, from before
  # this repository was reset - the issue numbers here are not the same ones).
  #
  # Schema v2 adds a second reason to compare meaning rather than text: the
  # device completes what we left open. Grid items are pushed without geometry,
  # the launcher places them and writes the coordinates back, so the document
  # that comes back is richer than the one that went out - by design.
  #
  # So both sides are canonicalised into the long form before comparing. The
  # normalisation is deliberately narrow: a swallowed favorite, a changed
  # profile, a different package and a different ORDER all still count as a
  # mismatch. A normalisation that accepts everything is worse than no check.
  local eff mism
  eff="$(query_state config "$uid")" \
    || { problem "$key" "$label: state provider did not serve /config"; return 1; }
  # The exit status decides, not the output: a jq that fails prints nothing,
  # and nothing is what "no mismatches" looks like. A comparison that cannot
  # run must fail the profile, not bless it.
  if ! mism="$(jq -r -n --argjson eff "$eff" --slurpfile want "$cfgfile" -f "$(dirname "${BASH_SOURCE[0]}")/../lib/readback-compare.jq")"; then
    problem "$key" "$label: the read-back comparison could not run (jq failed)"
    return 1
  fi
  if [ -z "$mism" ]; then
    ok "$label: effective config verified"
    return 0
  fi
  warn "$label: effective config differs in: $mism"
  problem "$key" "$label: read-back /config does not match the written file ($mism)"
  return 1
}

# ---- Pull: bring the device's arrangement back into the catalog -----------
# The counterpart to the guard above. It writes into the catalog the chain was
# pointed at, never into this repository's template: config/ here demonstrates
# mechanisms and is diffed against the generator by `make check`, so a device's
# arrangement has no business in it. A private catalog is selected with
# CONFIG_DIR (lib/common.sh).
pull_all() {
  # The destination is the SOURCE, not the generated files. Writing the
  # arrangement back into config/launcher/<zone>.json would put it where the
  # generator rebuilds over it; theming.json is the file a person edits, which
  # is the whole point of the round trip (provisioning#11, decided 2026-09-26).
  #
  # The grid block is copied through UNREAD. The launcher is the only component
  # that understands grid geometry, so any representation of ours would be a
  # second truth that has to be kept in step. An overlay file was considered and
  # rejected for the reason ricing already knows: your dotfiles are the truth,
  # nothing merges invisibly on top of them.
  local theme="$THEME_FILE"
  case "$(cd "$(dirname "$theme")" 2>/dev/null && pwd)" in
    "$REPO_ROOT/config")
      die "refusing to pull into the repository's template ($theme).
   Point the chain at your own catalog first:  CONFIG_DIR=/path/to/config $0 --pull" ;;
  esac
  require_device
  local key label uid eff dev_sha rec n=0 tmp lay favs glass unres
  tmp="$(mktemp)"; cp "$theme" "$tmp"
  log "Pulling what the device has into $theme"
  while read -r key; do
    label="$(profile_label "$key")"
    [ "$(profile_field "$key" type)" = "managed" ] && { skip "$label: managed profile - no home screen"; continue; }
    uid="$(resolve_uid "$key")"
    [ -n "$uid" ] || { warn "$label: profile does not exist - skipped"; continue; }
    user_running_uid "$uid" || ash am start-user -w "$uid" >/dev/null 2>&1
    eff="$(query_state config "$uid")" || { warn "$label: /config not served - skipped"; continue; }
    dev_sha="$(query_state diagnostics "$uid" 2>/dev/null | jq -r '.configSha256 // empty')"

    lay="$(printf '%s' "$eff" | jq -c '.home.grid.layouts // null')"

    # Favorites come back as package names and go into the catalog vocabulary,
    # because that is what a person reads. A package the catalog does not know
    # has no label to become, and writing the raw name would produce a file that
    # fails its own generation later - so the zone keeps its list and says which
    # app is missing.
    unres="$(printf '%s' "$eff" | jq -r --slurpfile cat "$CONFIG_DIR/apps.json" '
      [ (.home.favorites // [])[].packageName
        | . as $p | select(([ $cat[0].apps[] | select(.pkg == $p) ] | length) != 1) ] | join(", ")')"
    if [ -n "$unres" ]; then
      warn "$label: favorites left alone - not in the catalog: $unres"
      favs="null"
    else
      favs="$(printf '%s' "$eff" | jq -c --slurpfile cat "$CONFIG_DIR/apps.json" '
        [ (.home.favorites // [])[].packageName
          | . as $p | ([ $cat[0].apps[] | select(.pkg == $p) | .label ])[0] ]')"
    fi

    # Glass: only what differs from all_profiles.glass. The device serves the
    # section complete, so copying it whole would write five values per zone
    # and bury the one somebody changed.
    glass="$(printf '%s' "$eff" | jq -c --slurpfile t "$tmp" '
      ($t[0].all_profiles.glass // {}) as $d
      | [ (.appearance.glass // {}) | to_entries[] | select($d[.key] != .value) ] | from_entries')"

    jq --indent 2 --arg k "$key" --argjson lay "$lay" --argjson favs "$favs" --argjson glass "$glass" '
      (if $lay  == null then . else .per_profile[$k].layouts   = $lay  end)
      | (if $favs == null then . else .per_profile[$k].favorites = $favs end)
      | (if ($glass | length) > 0 then .per_profile[$k].glass = $glass
         else (if (.per_profile[$k] | type) == "object" then .per_profile[$k] |= del(.glass) else . end) end)
    ' "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp" \
      || { warn "$label: could not update $theme"; continue; }

    rec="$(sha_record "$key")"
    mkdir -p "$(dirname "$rec")"
    printf '%s\n' "$dev_sha" > "$rec"
    ok "$label: pulled (device sha ${dev_sha:0:12}...)"
    n=$((n + 1))
  done < <(profile_keys)

  mv "$tmp" "$theme"
  printf '\n'
  # The wallpaper is not pulled: the launcher reports the image NAME it applied,
  # and theming.json holds a repo path with an {aspect} placeholder - one name
  # can come from several paths, so the reverse is a guess. The palette is not
  # in launcher.json at all; it is a system setting 40-theming.sh writes.
  ok "$n profile(s) pulled into $(basename "$theme") - wallpaper and palette are not pulled"
  log "now regenerate and review:  config/gen-launcher.sh && git diff"
}

[ "${1:-}" = "--pull" ] && { pull_all; exit 0; }

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
