#!/usr/bin/env bash
# Visual identity per profile from config/theming.json.
# Monet palette, dark mode, statusbar icons, launcher (HOME role), keyboard (IME).
# Everything user-level: no build intervention, always reversible (delete
# the setting / hand back the role). Launcher/keyboard is installed by
# 10-apps.sh - here it's just activated. Idempotent like the rest:
# check-before-set.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_device

THEME_FILE="$CONFIG_DIR/theming.json"
[ -f "$THEME_FILE" ] || die "config/theming.json missing"

# .launcher picks the entry in .launchers (andashi-home, or andashi-home-debug
# for the fork's e2e runs). This step only assigns the HOME role; the
# launcher's own configuration is a file, pushed by 45-launcher-config.sh.
LKEY="$(jq -r '.launcher // empty' "$THEME_FILE")"
[ -n "$LKEY" ] || die "theming.json: .launcher missing"
LAUNCHER="$(jq -r --arg k "$LKEY" '.launchers[$k].pkg // empty' "$THEME_FILE")"
[ -n "$LAUNCHER" ] || die "theming.json: launcher '$LKEY' missing in .launchers"
KEYBOARD="$(jq -r '.keyboard_pkg // empty' "$THEME_FILE")"

# 'cmd uimode night' only takes effect immediately for the currently active
# profile; for all others the secure setting is read on the next profile switch.
CURRENT_USER="$(ash_ro am get-current-user 2>/dev/null | tr -d '\r' || true)"

# settings put with a comparison beforehand. $4 goes 1:1 to 'settings put' -
# for values with special characters (Monet JSON) the caller itself wraps
# '...' around it and passes the raw value for comparison as $5.
put_setting() {   # $1=uid $2=ns $3=key $4=put-value $5=target-value(raw)
  local cur want="${5:-$4}"
  cur="$(ash_ro settings --user "$1" get "$2" "$3" 2>/dev/null | tr -d '\r')" || cur=""
  if [ "$cur" = "$want" ]; then
    skip "$2/$3 = $want"
    return 0
  fi
  ash settings --user "$1" put "$2" "$3" "$4" >/dev/null \
    && { ok "$2/$3: ${cur:-<unset>} -> $want"; PUT_CHANGED=1; } \
    || warn "$2/$3 could not be set"
}

log "Global animation scales (device-wide)"
while read -r line; do
  [ -z "$line" ] && continue
  put_setting 0 global "${line%%=*}" "${line#*=}"
done < <(jq -r '.global // {} | to_entries[] | "\(.key)=\(.value)"' "$THEME_FILE")

while read -r key; do
  label="$(profile_label "$key")"
  uid="$(resolve_uid "$key")"
  [ -n "$uid" ] || { warn "Profile $label does not exist - run 00-profiles.sh first"; continue; }

  printf '\n'
  log "Profile $label (user $uid)"

  # Start stopped users ourselves - same eviction trap as in 10-apps.sh:
  # role/ime need a running user. Unless NO_START asks not to (the
  # edit-and-look loop, see 45-launcher-config.sh): then the zone keeps its
  # theme until it runs, and the host remembers that it owes it one.
  if ! user_running_uid "$uid" && [ "${NO_START:-0}" = "1" ]; then
    pending_add "$key" theme
    warn "$label: stopped - its theme stays pending here until $label runs (or apply --all)"
    continue
  fi
  if ! user_running_uid "$uid"; then
    ash am start-user -w "$uid" >/dev/null && ok "$label started (had been evicted)" \
      || warn "$label could not be started - theming may fail"
  fi

  # ---- Monet palette (profile color) ----
  restart_launcher=0
  seed="$(jq -r --arg k "$key" '.per_profile[$k].palette // empty' "$THEME_FILE")"
  if [ -n "$seed" ]; then
    style="$(jq -r --arg k "$key" '.per_profile[$k].style // "TONAL_SPOT"' "$THEME_FILE")"
    monet="$(printf '{"android.theme.customization.system_palette":"%s","android.theme.customization.theme_style":"%s","android.theme.customization.color_source":"preset"}' "$seed" "$style")"
    # '...' around it: adb shell joins arguments into ONE string that the
    # device shell parses - without quotes it would eat the "" of the JSON.
    PUT_CHANGED=0
    put_setting "$uid" secure theme_customization_overlay_packages "'$monet'" "$monet"
    [ "${PUT_CHANGED:-0}" = "1" ] && restart_launcher=1
  fi

  # ---- Dark mode ----
  night="$(theme_field "$key" night)"
  if [ -n "$night" ]; then
    put_setting "$uid" secure ui_night_mode "$night"
    if [ "$uid" = "$CURRENT_USER" ] && [ "$DRY_RUN" != "1" ]; then
      case "$night" in
        2) ash cmd uimode night yes >/dev/null || true;;
        1) ash cmd uimode night no  >/dev/null || true;;
        0) ash cmd uimode night auto >/dev/null || true;;
      esac
    fi
  fi

  # ---- Clean up statusbar ----
  bl="$(theme_field "$key" icon_blacklist)"
  [ -n "$bl" ] && put_setting "$uid" secure icon_blacklist "$bl"

  # ---- Launcher role + keyboard: not in managed profiles ----
  # A managed profile (Work) has no home screen and no IME of its own; it uses
  # the parent profile's. 45-launcher-config.sh skips it for that reason, this
  # step did not - and warned either way: on a device that happens to carry the
  # launcher in Work, 'cmd role' threw a RuntimeException and the run printed a
  # stack trace; on one that does not, the warning told the reader to run
  # 10-apps.sh, which can never install it there - 'work' is not among the
  # launcher's profiles. Wrong advice is worse than noise.
  # The palette, dark mode and statusbar settings above DO still apply to Work:
  # those are per-user settings the managed profile owns.
  if [ "$(profile_field "$key" type)" = "managed" ]; then
    skip "$label: managed profile - launcher and keyboard come from the parent profile"
  else

  # ---- Launcher: HOME role ----
  if [ -n "$LAUNCHER" ]; then
    if pkg_installed_for_user "$LAUNCHER" "$uid"; then
      cur_home="$(ash_ro cmd role get-role-holders --user "$uid" android.app.role.HOME 2>/dev/null | tr -d '\r')" || cur_home=""
      if [ "$cur_home" = "$LAUNCHER" ]; then
        skip "HOME role = $LAUNCHER"
      else
        ash cmd role add-role-holder --user "$uid" android.app.role.HOME "$LAUNCHER" >/dev/null || true
        if [ "$DRY_RUN" = "1" ]; then :; else
          cur_home="$(ash_ro cmd role get-role-holders --user "$uid" android.app.role.HOME 2>/dev/null | tr -d '\r')" || cur_home=""
          [ "$cur_home" = "$LAUNCHER" ] \
            && ok "HOME role: -> $LAUNCHER" \
            || warn "HOME role could not be set (is: ${cur_home:-<empty>})"
        fi
      fi
    else
      warn "$LAUNCHER not installed (user $uid) - run 10-apps.sh first"
    fi
  fi

  # ---- Browser: android.app.role.BROWSER ----
  # Only where the zone names one (profiles.json "browser"). Every user has
  # Vanadium, a system app the chain never removes, and without a choice it
  # holds the role - measured 2026-09-24 on emulator-5558: in Anon, every
  # https link resolved to Vanadium alone, outside Tor. With the role on Tor
  # Browser, the same link resolves to it (provisioning#10).
  # Read back twice: the holder, and where a plain link actually resolves -
  # the second is the effect, the first only the acceptance.
  zone_browser="$(profile_field "$key" browser)"
  if [ -n "$zone_browser" ]; then
    if pkg_installed_for_user "$zone_browser" "$uid"; then
      cur_browser="$(ash_ro cmd role get-role-holders --user "$uid" android.app.role.BROWSER 2>/dev/null | tr -d '\r')" || cur_browser=""
      if [ "$cur_browser" != "$zone_browser" ]; then
        ash cmd role add-role-holder --user "$uid" android.app.role.BROWSER "$zone_browser" >/dev/null || true
      fi
      if [ "$DRY_RUN" != "1" ]; then
        cur_browser="$(ash_ro cmd role get-role-holders --user "$uid" android.app.role.BROWSER 2>/dev/null | tr -d '\r')" || cur_browser=""
        link_to="$(ash_ro cmd package resolve-activity --brief --user "$uid" -a android.intent.action.VIEW \
                     -c android.intent.category.BROWSABLE -d https://example.org 2>/dev/null | tr -d '\r' | tail -1)"
        if [ "$cur_browser" = "$zone_browser" ] && [ "${link_to%%/*}" = "$zone_browser" ]; then
          ok "browser: $zone_browser (role held, links resolve to it)"
        else
          warn "browser: wanted $zone_browser, role is ${cur_browser:-<empty>}, a link resolves to ${link_to:-<nothing>}"
        fi
      fi
    else
      warn "browser $zone_browser not installed (user $uid) - run 10-apps.sh first"
    fi
  fi

  # ---- Keyboard: default IME ----
  if [ -n "$KEYBOARD" ]; then
    if pkg_installed_for_user "$KEYBOARD" "$uid"; then
      # Pull the IME id from the list, without a grep pipeline
      # (pipefail/SIGPIPE trap, see common.sh): collect first, then search in bash.
      imes="$(ash_ro ime list -s -a --user "$uid" 2>/dev/null | tr -d '\r')" || imes=""
      ime_id=""
      while IFS= read -r l; do
        case "$l" in "$KEYBOARD/"*) ime_id="$l"; break;; esac
      done <<<"$imes"
      if [ -z "$ime_id" ]; then
        warn "$KEYBOARD installed, but no IME id found"
      else
        cur_ime="$(ash_ro settings --user "$uid" get secure default_input_method 2>/dev/null | tr -d '\r')" || cur_ime=""
        if [ "$cur_ime" = "$ime_id" ]; then
          skip "IME = $ime_id"
        else
          ash ime enable --user "$uid" "$ime_id" >/dev/null || true
          ash ime set --user "$uid" "$ime_id" >/dev/null \
            && ok "IME: ${cur_ime:-<unset>} -> $ime_id" \
            || warn "IME could not be set"
        fi
      fi
    else
      warn "$KEYBOARD not installed (user $uid) - run 10-apps.sh first"
    fi
  fi

  fi  # end: not a managed profile

  # Wallpaper: no longer set here. Andashi Home applies appearance.wallpaper
  # from its config; 45-launcher-config.sh uploads the image and reloads.

  # The launcher caches icon tints until the process ends - restart it once
  # after a palette change, otherwise the icons still carry the old color
  # (the "Hulk effect", first seen with Lawnchair, still true for themed icons).
  if [ "$restart_launcher" = "1" ] && [ -n "$LAUNCHER" ] && [ "$DRY_RUN" != "1" ] \
     && pkg_installed_for_user "$LAUNCHER" "$uid"; then
    ash am force-stop --user "$uid" "$LAUNCHER" >/dev/null \
      && ok "Launcher restarted (palette changed)" || true
  fi
  pending_clear "$key" theme
done < <(profile_keys)
