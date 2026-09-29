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
PENDING=()
problem() {   # $1=profile-key $2=reason; in DRY_RUN only a warning
  if [ "$DRY_RUN" = "1" ]; then
    warn "$2"
  else
    FAILED+=("$1|$2")
    warn "$2"
  fi
}

# Records, decisions and the state provider: lib/launcher-state.sh.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/launcher-state.sh"

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
  local key="$1" label uid cfgfile ingest_uri want_sha wp wpf wpname wp_sha plan rec
  label="$(profile_label "$key")"
  cfgfile="$LAUNCHER_CFG_DIR/$key.json"
  [ -f "$cfgfile" ] || { problem "$key" "$label: $cfgfile missing - run config/gen-launcher.sh"; return 1; }

  uid="$(resolve_uid "$key")"
  [ -n "$uid" ] || { problem "$key" "$label: profile does not exist - run 00-profiles.sh first"; return 1; }

  printf '\n'
  log "Profile $label (user $uid)"

  ingest_uri="content://$PKG.config-ingest/launcher.json"
  want_sha="$(sha256sum "$cfgfile" | awk '{print $1}')"
  rec="$(sha_record "$key")"

  # ---- The wallpaper this zone should hold -----------------------------------
  # The generated config names the image (basename of the theming.json path);
  # the file itself is uploaded under that name before the config, so the
  # reload finds it. {aspect} resolves against the device like in
  # 40-theming.sh. No wallpaper in theming.json means nothing to upload.
  # Resolved before anything is started, because whether the zone needs
  # anything at all depends on these bytes too.
  wp="$(theme_field "$key" wallpaper)"
  if [ "$(jq -r --arg k "$LKEY" '.launchers[$k].wallpaper // false' "$THEME_FILE")" != "true" ]; then
    wp=""   # launcher entry without wallpaper support: nothing to upload, config has no key either
  fi
  wp_sha="none"
  if [ -n "$wp" ]; then
    case "$wp" in *'{aspect}'*) wp="${wp//\{aspect\}/$(device_aspect_class)}";; esac
    wpf="$REPO_ROOT/$wp"
    wpname="$(basename "$wp")"
    [ -f "$wpf" ] || { problem "$key" "$label: wallpaper file missing: $wp"; return 1; }
    wp_sha="$(sha256sum "$wpf" | awk '{print $1}')"
  fi

  # ---- Only what changed (ONLY_CHANGED=1, set by `andashi apply`) ------------
  # A full provisioning run pushes every zone every time, and that is deliberate:
  # a fresh reload is a fresh report, and the report is how an app uninstalled
  # since, or a widget unbound, becomes visible. The edit-and-look loop wants
  # the opposite - touch what changed and nothing else - because every zone it
  # starts evicts another (measured 2026-09-30: this step took 48 s on a
  # device where nothing had changed). So the loop asks, and the full run
  # does not.
  plan="changed"
  if [ "${ONLY_CHANGED:-0}" = "1" ]; then
    plan="$(launcher_plan "$want_sha" "$(record_field "$rec" sha 2>/dev/null || true)" \
                          "$wp_sha" "$(record_field "$rec" wallpaper 2>/dev/null || true)")"
  fi

  # Start evicted users ourselves - a stopped user has no provider to write
  # to or query. Background start only, never a foreground switch.
  if ! user_running_uid "$uid"; then
    if [ "$plan" = "unchanged" ]; then
      skip "$label: unchanged since the last push - not started"
      return 0
    fi
    # NO_START=1: starting a zone evicts another one, and which one is
    # Android's choice (it tends to be Cloud, the zone that must keep running).
    # So the change waits on the host, and `andashi status` names it, until
    # the zone runs or somebody asks for --all.
    if [ "${NO_START:-0}" = "1" ]; then
      PENDING+=("$key|$label")
      pending_add "$key" launcher
      warn "$label: stopped - the change stays pending here until $label runs (or apply --all)"
      return 0
    fi
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

  # The host has nothing new - does the device still hold what we sent? The
  # same three fields the guard below reads: the hash of the file it loaded,
  # the report number and the store. A device that loaded our file, succeeded,
  # and saved no report since has nothing for us to do. Anything else falls
  # through to the guard and the push, which know what to make of it.
  if [ "$plan" = "unchanged" ] && [ "$DRY_RUN" != "1" ]; then
    local d_now d_sha d_ok d_seq d_store
    d_now="$(query_state diagnostics "$uid" 2>/dev/null || true)"
    d_sha="$(printf '%s' "$d_now" | jq -r '.configSha256 // empty' 2>/dev/null || true)"
    d_ok="$(printf '%s' "$d_now" | jq -r '.success // empty' 2>/dev/null || true)"
    d_seq="$(printf '%s' "$d_now" | jq -r '.sequence // empty' 2>/dev/null || true)"
    d_store="$(printf '%s' "$d_now" | jq -r '.storeId // empty' 2>/dev/null || true)"
    if [ -n "$d_sha" ] && [ "$d_sha" = "$want_sha" ] && [ "$d_ok" = "true" ] \
       && [ "$d_store" = "$(record_field "$rec" storeId 2>/dev/null || true)" ] \
       && ! report_moved "$d_seq" "$d_store" "$(record_field "$rec" sequence 2>/dev/null || true)" "$d_store"; then
      skip "$label: unchanged, and the device still reports what we pushed"
      pending_clear "$key" launcher
      return 0
    fi
    log "$label: nothing new on the host, but the device moved - pushing"
  fi

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
  #
  # The sha alone cannot see everything worth refusing. Since andashi/home#226
  # a report carries `sequence`, which counts SAVED REPORTS - not reloads - and
  # moves for two things the sha does not: a reload that changed nothing, and a
  # change made on the device that the launcher kept OUT of the file (a
  # `write-back-skipped:` warning added to the last report). The second is the
  # one this guard exists for and could not see: a push then overwrites the
  # change somebody made.
  #
  # Three rules, all of them theirs and none of them guessable:
  #   - `sequence` is comparable only within one `storeId`. A different id is a
  #     NEW store (pm clear, reinstall, signer swap), not a number that went
  #     backwards, so nothing may be concluded across it.
  #   - Numbers may have GAPS. A save that failed half way leaves one. Compare,
  #     never count.
  #   - Both fields are null on a build before 0.10.x, meaning UNKNOWN, not
  #     zero. Every device we run today answers null, which is why the sha path
  #     below stays the primary one rather than a fallback.
  #
  # And what it does NOT mean: an unchanged `sequence` does not prove no reload
  # happened. A grid measurement that finds nothing new saves nothing. That is
  # correct here - it changed nothing the file cares about - but this field is
  # not a reload detector, and reading it as one later would be a quiet mistake.
  #
  # Measured on 0.11.0, the first release carrying the fields: an ordinary
  # RELOAD_CONFIG broadcast over an UNCHANGED file does save a report, 3 -> 4.
  # So this guard fires on any reload we did not cause, not only on an edit -
  # which is what we want (somebody was here) and more sensitive than the
  # phrase "a device change" suggests. The remedy is the documented one and it
  # was measured too: --pull records the new number and the next push goes
  # through.
  local diag_now diag_before dev_sha dev_seq dev_store rec_sha rec_seq rec_store
  if [ "$DRY_RUN" != "1" ] && [ -f "$rec" ]; then
    diag_now="$(query_state diagnostics "$uid" 2>/dev/null || true)"
    dev_sha="$(printf '%s' "$diag_now" | jq -r '.configSha256 // empty' 2>/dev/null || true)"
    dev_seq="$(printf '%s' "$diag_now" | jq -r '.sequence // empty' 2>/dev/null || true)"
    dev_store="$(printf '%s' "$diag_now" | jq -r '.storeId // empty' 2>/dev/null || true)"
    rec_sha="$(record_field "$rec" sha || true)"
    rec_seq="$(record_field "$rec" sequence || true)"
    rec_store="$(record_field "$rec" storeId || true)"
    if [ -n "$dev_sha" ] && [ "$dev_sha" != "$rec_sha" ]; then
      warn "$label: device has ${dev_sha:0:12}..., we last agreed on $(printf '%s' "$rec_sha" | cut -c1-12)..."
      problem "$key" "$label: the config changed on the device since our last run - pull it first ($0 --pull), then push"
      return 1
    fi
    # A moved number says LOOK, not REFUSE. Measured on 0.11.0 with a config
    # that carries no waiting code at all: an unrelated package event moves
    # nothing, and a launcher RESTART moves it by two. Restarts are ordinary -
    # every upgrade of the launcher is one, and so is the process being killed
    # under memory pressure - so refusing on the number alone would refuse the
    # next run after every update, for ever, until somebody pulled by hand.
    # On a device whose config names something absent it is worse: the
    # launcher re-reads on every package signal (andashi/home, ConfigWatcher),
    # so the number climbs all night.
    #
    # So the number decides whether to look, and the effective config decides
    # whether to refuse - the same comparison the push uses afterwards, which
    # is the only thing that can tell "somebody rearranged this zone" from "the
    # launcher restarted". A guard that fires on ordinary events gets removed,
    # and then the case it exists for arrives unnoticed.
    if report_moved "$dev_seq" "$dev_store" "$rec_seq" "$rec_store"; then
      local eff_now mism_now
      eff_now="$(query_state config "$uid" 2>/dev/null || true)"
      if [ -z "$eff_now" ]; then
        warn "$label: report $dev_seq since our $rec_seq, and /config did not answer"
        problem "$key" "$label: something was saved on the device and we cannot see what - pull it first ($0 --pull), then push"
        return 1
      fi
      mism_now="$(jq -r -n --argjson eff "$eff_now" --slurpfile want "$cfgfile" \
        -f "$(dirname "${BASH_SOURCE[0]}")/../lib/readback-compare.jq" 2>/dev/null || true)"
      if [ -n "$mism_now" ]; then
        warn "$label: report $dev_seq since our $rec_seq, and the device differs in: $mism_now"
        problem "$key" "$label: the device was changed since our last run - pull it first ($0 --pull), then push"
        return 1
      fi
      log "$label: report $dev_seq since our $rec_seq, but the device still matches our file - continuing"
    fi
  fi

  # ---- Wallpaper upload ------------------------------------------------------
  # Skipped in the loop when these bytes are what the zone already holds - only
  # while the launcher's store is the one we recorded: a cleared app has a new
  # store and an empty wallpapers directory, whatever our record says.
  local wp_skip=0
  if [ -n "$wp" ] && [ "${ONLY_CHANGED:-0}" = "1" ] && [ "$DRY_RUN" != "1" ] \
     && [ "$wp_sha" = "$(record_field "$rec" wallpaper 2>/dev/null || true)" ]; then
    local s_now s_rec
    s_now="$(query_state diagnostics "$uid" 2>/dev/null | jq -r '.storeId // empty' 2>/dev/null || true)"
    s_rec="$(record_field "$rec" storeId 2>/dev/null || true)"
    [ -n "$s_now" ] && [ "$s_now" = "$s_rec" ] && wp_skip=1
  fi
  if [ -n "$wp" ] && [ "$wp_skip" = "1" ]; then
    skip "wallpaper unchanged ($wpname)"
  elif [ -n "$wp" ]; then
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
    diag_before="$(query_state diagnostics "$uid" 2>/dev/null || true)"
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
  # What the device had reported BEFORE our push. The poll below waits for a
  # report newer than this one, not merely for one carrying our hash - because
  # a push of bytes the last report already describes (every run that pushes an
  # unchanged file) satisfies a hash-only wait instantly, on the PREVIOUS
  # report. Its `success` would usually be right, since the bytes are the same,
  # and its diagnostics would be stale: an app uninstalled since, a permission
  # withdrawn, a widget unbound. Measured on 0.11.0 the new report was already
  # there and we read it - so the race did not bite on an idle emulator, which
  # is exactly the kind of evidence that should not be trusted for a phone.
  #
  # Reported by the launcher side from a code reading (andashi/home#260).
  local pre_seq pre_store
  pre_seq="$(printf '%s' "${diag_before:-}" | jq -r '.sequence // empty' 2>/dev/null || true)"
  pre_store="$(printf '%s' "${diag_before:-}" | jq -r '.storeId // empty' 2>/dev/null || true)"
  local attempt=0 diag got_sha success n_diag fatal_diag seq_now dev_seq_now dev_store_now
  while [ $attempt -lt 30 ]; do
    if diag="$(query_state diagnostics "$uid")"; then
      got_sha="$(printf '%s' "$diag" | jq -r '.configSha256 // empty')"
      success="$(printf '%s' "$diag" | jq -r '.success // empty')"
      dev_seq_now="$(printf '%s' "$diag" | jq -r '.sequence // empty')"
      dev_store_now="$(printf '%s' "$diag" | jq -r '.storeId // empty')"
      # A build before 0.11.0 reports no sequence at all, and then the hash is
      # all there is - which is what this did until today.
      if [ "$got_sha" = "$want_sha" ] \
         && { [ -z "$pre_seq" ] || [ -z "$dev_seq_now" ] || [ "$dev_store_now" != "$pre_store" ] \
              || [ "$dev_seq_now" -gt "$pre_seq" ]; }; then
        if [ "$success" = "true" ]; then
          # The report number is printed, not just recorded: our runs show
          # `.diagnostics[]` and no top-level fields, so a counter nobody can
          # see while watching a push is a counter that helps only a script.
          # Absent on a build before andashi/home#226, and absent is fine.
          seq_now="$(printf '%s' "$diag" | jq -r '.sequence // empty')"
          ok "reload converged (diagnostics sha256 match${seq_now:+, report $seq_now})"
          # The device now holds exactly what we wrote, and that is what the
          # guard above wants to know - not whether we were happy with it.
          # Recording only after a successful read-back made a FAILED push
          # block the next one: the zone kept our rejected file, the record
          # still named the one before it, and the guard reported a device-side
          # edit that never happened. Measured 2026-09-23 while testing the
          # glass: false path against 0.5.0 - six zones refused the correcting
          # run and pointed at --pull, which would have pulled the bad config
          # into the catalog.
          record_write "$rec" "$want_sha" \
            "$(printf '%s' "$diag" | jq -r '.sequence // empty')" \
            "$(printf '%s' "$diag" | jq -r '.storeId // empty')" \
            "$wp_sha"
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
    pending_clear "$key" launcher
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
  local key label uid eff diag_pull dev_sha rec n=0 tmp lay favs glass unres dev_img want_img
  tmp="$(mktemp)"; cp "$theme" "$tmp"
  log "Pulling what the device has into $theme"
  while read -r key; do
    label="$(profile_label "$key")"
    [ "$(profile_field "$key" type)" = "managed" ] && { skip "$label: managed profile - no home screen"; continue; }
    uid="$(resolve_uid "$key")"
    [ -n "$uid" ] || { warn "$label: profile does not exist - skipped"; continue; }
    user_running_uid "$uid" || ash am start-user -w "$uid" >/dev/null 2>&1
    eff="$(query_state config "$uid")" || { warn "$label: /config not served - skipped"; continue; }
    diag_pull="$(query_state diagnostics "$uid" 2>/dev/null || true)"
    dev_sha="$(printf '%s' "$diag_pull" | jq -r '.configSha256 // empty' 2>/dev/null || true)"

    dev_img="$(printf '%s' "$eff" | jq -r '.appearance.wallpaper.image // empty')"
    want_img="$(jq -r --arg k "$key" '.per_profile[$k].wallpaper // empty' "$tmp")"
    if wallpaper_drifted "$dev_img" "$want_img"; then
      warn "$label: the device shows wallpaper '$dev_img', the catalog asks for '${want_img##*/}'"
      warn "$label: somebody changed it on the device - NOT pulled, decide it in theming.json"
    fi

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
    record_write "$rec" "$dev_sha" \
      "$(printf '%s' "$diag_pull" | jq -r '.sequence // empty')" \
      "$(printf '%s' "$diag_pull" | jq -r '.storeId // empty')"
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

# Pending is not failed and not converged. Printed last, where a person
# reading the run looks, and counted in the final line, so "all converged"
# is never said of a zone that still waits.
if [ "${#PENDING[@]}" -gt 0 ]; then
  printf '\n'
  warn "${#PENDING[@]} zone(s) stopped with a change waiting on this host:"
  for entry in "${PENDING[@]}"; do printf '     %s\n' "${entry#*|}" >&2; done
  [ "$DRY_RUN" = "1" ] || ok "The running zones converged and verified ($PKG); ${#PENDING[@]} pending"
  exit 0
fi
[ "$DRY_RUN" = "1" ] || ok "All profiles converged and verified ($PKG)"
exit 0
