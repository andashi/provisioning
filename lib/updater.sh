#!/usr/bin/env bash
# The andashi updater on the device: installed first, named as the installer of
# every app this chain installs, and given what it needs to update them
# without a person (andashi/updater, docs/design.md §5.3, §6, §8).
# Sourced after lib/common.sh.
#
# Everything here hangs on ONE catalog entry: the app with "role": "updater".
# Without it nothing changes - apps are installed as before, with no installer
# of record - because naming an installer that is not on the device leaves the
# installer empty, and a phone without the updater still updates through
# Obtainium. With it, the updater goes onto the device before anything else,
# so every later install can name it.
#
# Measured 2026-10-10 on emulator-5558 (API 37, adb as shell, uid 2000):
# - The first install cannot name the updater as its own installer, because the
#   named package must already exist: installed once plainly, then the same APK
#   again with -i, which moves the installer of record to itself.
# - The installer of record belongs to the package, not to a user: an install
#   with -i in user 0 shows the updater as installer in user 15 as well, and
#   `pm install-existing` into another user carries it.
# - `adb install` WITHOUT --user installs for every user on the device, a
#   replace included: DAVx5, in Home only, was in all seven users after one
#   such install. With --user N the code updates for every user that has the
#   package and no other user gains it. So every install here names a user.

UPDATER_PKG="$(jq -r '[.apps[] | select(.role == "updater") | .pkg]
                      | if length > 1 then error("more than one app with role updater: \(join(", "))") else .[0] // empty end' \
               "$CONFIG_DIR/apps.json")" \
  || die "could not read the updater from $CONFIG_DIR/apps.json (config/check-invariants.sh says why)"
# The receiver's class lives in the app's code namespace, which a debug build's
# application id suffix does not change.
UPDATER_RECEIVER_CLASS="org.andashi.updater.host.ControlReceiver"

# The arguments that name the updater as installer, once it is on the device:
#   adb_ install "${INSTALLER_ARGS[@]}" --user N -r <apk>
# Empty while there is no updater, so the same line serves both cases.
INSTALLER_ARGS=()

# The installer of record of a package, as user $2 sees it: the package name,
# "null" for nobody, empty when the package is not installed for that user.
# `pm list packages` filters by substring, so the exact line is picked out.
installer_of() {   # $1=pkg $2=uid
  local out line
  out="$(ash_ro pm list packages -i --user "$2" "$1" 2>/dev/null | tr -d '\r')" || return 1
  while IFS= read -r line; do
    case "$line" in
      "package:$1  installer="*) printf '%s' "${line#*installer=}"; return 0;;
    esac
  done <<<"$out"
  return 0
}

# The device-idle allowlist holds the updater: without it, Android 12+ refuses
# the foreground service a background download needs (design §8).
updater_exempt() {
  local out
  out="$(ash_ro dumpsys deviceidle whitelist 2>/dev/null | tr -d '\r')" || return 1
  case $'\n'"$out" in *$'\n'"user,$UPDATER_PKG,"*) return 0;; esac
  return 1
}

# Once per device: the updater on the device, its own installer of record,
# exempt from battery restrictions. Afterwards INSTALLER_ARGS names it.
# A step that cannot get there stops: the catalog says the updater manages
# these apps, and installing them without it would hand them to nobody.
#
# A dry run reads everything and changes nothing: what it would do is said
# for exactly the steps the device still needs, and a missing APK is still
# a refusal.
ensure_updater_device() {
  [ -n "$UPDATER_PKG" ] || return 0
  local apk inst
  apk="$(apk_for_pkg "$UPDATER_PKG" || true)"

  inst="$(installer_of "$UPDATER_PKG" 0)" || die "updater: could not read the packages of user 0"
  if [ -z "$inst" ]; then
    [ -n "$apk" ] || die "updater: the catalog names $UPDATER_PKG but there is no APK for it - make from-lock"
    if [ "$DRY_RUN" = "1" ]; then
      printf '   [dry-run] updater: install %s for user 0, then again naming itself\n' "$(basename "$apk")"
      inst="$UPDATER_PKG"
    else
      adb_ install -r --user 0 "$apk" >/dev/null \
        || die "updater: installing $(basename "$apk") failed"
      ok "updater installed from $(basename "$apk")"
      inst="$(installer_of "$UPDATER_PKG" 0)"
    fi
  fi
  if [ "$inst" != "$UPDATER_PKG" ] && [ "$DRY_RUN" = "1" ]; then
    [ -n "$apk" ] || die "updater: installer of record is '${inst:-?}', and there is no APK to repair it with - make from-lock"
    printf '   [dry-run] updater: installer of record is %s - install %s again naming itself\n' "${inst:-null}" "$(basename "$apk")"
  elif [ "$inst" != "$UPDATER_PKG" ]; then
    [ -n "$apk" ] || die "updater: installer of record is '${inst:-?}', and there is no APK to repair it with - make from-lock"
    # The same build again, naming itself. If the device runs a newer build
    # (it updated itself) than the host has, the replace is refused as a
    # downgrade - and then the host has to catch up, not the device go back.
    adb_ install -r -i "$UPDATER_PKG" --user 0 "$apk" >/dev/null \
      || die "updater: could not make it its own installer (installer is '$inst'; does the device run a newer build than $(basename "$apk")?)"
    inst="$(installer_of "$UPDATER_PKG" 0)"
    [ "$inst" = "$UPDATER_PKG" ] \
      || die "updater: installed again with -i, but the installer of record reads '${inst:-nothing}'"
    ok "updater is its own installer of record"
  fi

  if ! updater_exempt && [ "$DRY_RUN" = "1" ]; then
    printf '   [dry-run] updater: cmd deviceidle whitelist +%s\n' "$UPDATER_PKG"
  elif ! updater_exempt; then
    ash cmd deviceidle whitelist "+$UPDATER_PKG" >/dev/null \
      || die "updater: cmd deviceidle whitelist +$UPDATER_PKG failed"
    updater_exempt || die "updater: added to the device-idle allowlist, but dumpsys deviceidle does not list it"
    ok "updater exempt from battery restrictions (device-idle allowlist)"
  fi
  INSTALLER_ARGS=(-i "$UPDATER_PKG")
}

# Into every zone the catalog places it in, before any app is installed
# anywhere: `-i <updater>` takes only in a user that holds the updater, and an
# app's first zone in the chain need not be one the updater reached yet (found
# 2026-10-10: RethinkDNS, handled first in Work, handed over through Work
# while the updater was still only in Home). `pm install-existing` works on a
# stopped user, so no zone is started for this.
ensure_updater_in_zones() {
  [ -n "$UPDATER_PKG" ] || return 0
  local key uid label bad=0
  while read -r key; do
    jq -e --arg p "$UPDATER_PKG" --arg k "$key" '.apps[] | select(.pkg == $p) | .profiles | index($k)' "$CONFIG_DIR/apps.json" >/dev/null || continue
    uid="$(resolve_uid "$key")"; label="$(profile_label "$key")"
    [ -n "$uid" ] || continue                     # 00-profiles has not made it yet
    pkg_installed_for_user "$UPDATER_PKG" "$uid" && continue
    if [ "$DRY_RUN" = "1" ]; then
      printf '   [dry-run] %s: pm install-existing %s\n' "$label" "$UPDATER_PKG"
    elif ash pm install-existing --user "$uid" "$UPDATER_PKG" >/dev/null; then
      ok "$label: updater added"
    else
      warn "$label: pm install-existing $UPDATER_PKG failed"; bad=1
    fi
  done < <(profile_keys)
  return "$bad"
}

# Per zone: the updater present, allowed to install, allowed to tell the
# person. Each setting is read back, because the commands' exit codes do not
# say whether it took: `pm grant` exits 0 for a permission the app does not
# even declare (20-permissions.sh learnt that the hard way).
# Prints what is wrong and returns 1; the caller decides what that costs.
ensure_updater_zone() {   # $1=uid $2=label
  [ -n "$UPDATER_PKG" ] || return 0
  local uid="$1" label="$2" out inst bad=0
  inst="$(installer_of "$UPDATER_PKG" "$uid")" || { warn "$label: could not read its packages"; return 1; }
  if [ "$DRY_RUN" = "1" ]; then
    [ -n "$inst" ] || printf '   [dry-run] %s: pm install-existing %s\n' "$label" "$UPDATER_PKG"
    out="$(ash_ro appops get --user "$uid" "$UPDATER_PKG" REQUEST_INSTALL_PACKAGES 2>/dev/null | tr -d '\r')" || out=""
    case $'\n'"$out" in *$'\n'"REQUEST_INSTALL_PACKAGES: allow"*) ;;
      *) printf '   [dry-run] %s: appops set REQUEST_INSTALL_PACKAGES allow\n' "$label";; esac
    notifications_granted "$uid" || printf '   [dry-run] %s: pm grant POST_NOTIFICATIONS\n' "$label"
    return 0
  fi
  if [ -z "$inst" ]; then
    ash pm install-existing --user "$uid" "$UPDATER_PKG" >/dev/null \
      || { warn "$label: pm install-existing $UPDATER_PKG failed"; return 1; }
    inst="$(installer_of "$UPDATER_PKG" "$uid")"
    ok "$label: updater added"
  fi
  [ "$inst" = "$UPDATER_PKG" ] \
    || { warn "$label: the updater's installer of record reads '${inst:-nothing}', not itself"; bad=1; }

  ash appops set --user "$uid" "$UPDATER_PKG" REQUEST_INSTALL_PACKAGES allow >/dev/null 2>&1 || true
  out="$(ash_ro appops get --user "$uid" "$UPDATER_PKG" REQUEST_INSTALL_PACKAGES 2>/dev/null | tr -d '\r')" || out=""
  # `appops get` may append "; time=..." after the mode.
  case $'\n'"$out" in
    *$'\n'"REQUEST_INSTALL_PACKAGES: allow"*) ;;
    *) warn "$label: REQUEST_INSTALL_PACKAGES did not read back as allow (got: ${out:-nothing})"; bad=1;;
  esac

  ash pm grant --user "$uid" "$UPDATER_PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
  notifications_granted "$uid" \
    || { warn "$label: POST_NOTIFICATIONS did not read back as granted - the updater could not say when it needs a tap"; bad=1; }

  [ "$bad" = 0 ] && ok "$label: updater may install and notify"
  return "$bad"
}

# dumpsys package lists runtime permissions per user, under "    User N:".
notifications_granted() {   # $1=uid
  local out
  out="$(ash_ro dumpsys package "$UPDATER_PKG" 2>/dev/null | tr -d '\r')" || return 1
  awk -v u="    User $1:" '
    index($0, u) == 1 { p = 1; next }
    /^    User [0-9]+:/ { p = 0 }
    p && /android\.permission\.POST_NOTIFICATIONS: granted=true/ { found = 1 }
    END { exit !found }' <<<"$out"
}

# Whether this chain owes a package to the updater: an app with a source the
# lock covers, on a device where the updater runs.
updater_manages() {   # $1=source
  [ "${#INSTALLER_ARGS[@]}" -gt 0 ] || return 1
  case "$1" in obtainium|fdroid|torproject|direct) return 0;; esac
  return 1
}

# ---- What the updater says --------------------------------------------------
# The zone's state as JSON (andashi/updater design §9.2), or status 1 when the
# zone's updater does not answer - not installed, zone stopped, provider gone.
updater_state() {   # $1=uid
  local out
  out="$(ash_ro content query --user "$1" --uri "content://$UPDATER_PKG.state/state" 2>/dev/null | tr -d '\r')" || return 1
  out="${out#Row: 0 json=}"
  jq -e .apps >/dev/null 2>&1 <<<"$out" || return 1
  printf '%s' "$out"
}

# One line for a person, from a state document on stdin: what is fine, what is
# on its way, what needs somebody - and the lock it was all measured against.
# The groups are the design's: an app is fine only when the package manager
# confirmed the lock's build with the updater as its installer.
updater_summary() {
  jq -r '
    def grp: if . == "current" or . == "ahead" then "ok"
             elif . == "behind" or . == "downloading" or . == "verifying" or . == "installing"
                  or . == "waiting-constraints" then "pending"
             else "attention" end;
    . as $st
    | ([.apps[] | .state] | group_by(.) | map({s: .[0], n: length})) as $c
    | [ ($c[] | select(.s | grp == "ok")        | "\(.n) \(.s)"),
        ($c[] | select(.s | grp == "pending")   | "\(.n) \(.s)"),
        ($c[] | select(.s | grp == "attention") | "\(.n) \(.s | ascii_upcase)") ] | join(", ")
    | . + " | lock \(($st.lock.generated // "none")[:10]) (\($st.lock.freshness // "?"))"
        + (if $st.lock.lastError then " ERROR \($st.lock.lastError)" else "" end)
        + (if $st.exemption == "granted" then "" else " | battery exemption \($st.exemption // "?")" end)'
}

# The packages that need somebody, one "pkg state" per line.
updater_attention() {
  jq -r '.apps[] | select(.state as $s | ["current","ahead","behind","downloading","verifying","installing","waiting-constraints"] | index($s) | not)
         | "\(.pkg) \(.state)\(if .error then " (\(.error))" else "" end)"'
}
