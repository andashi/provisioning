#!/usr/bin/env bash
# Permissions + AppOps per profile.
# Core piece: net:false -> revoke android.permission.INTERNET
# (= the GrapheneOS network toggle, settable via adb).
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_device

# Is $3 granted to $1 for user $2? dumpsys reports two kinds of permission in
# two different places, and looking in only one of them is a wrong answer, not
# a missing one:
#
#   install permissions:                      <- install-time (signature,
#     <perm>: granted=true                       privileged, development...)
#     <perm>: granted=false, userId=10           default first, then per-user
#     ...                                        overrides
#   User 0: ...
#     runtime permissions:                    <- the dangerous ones
#       <perm>: granted=true, flags=[...]
#
# Reading only the "User N:" block reports every install-time permission as
# not granted. Measured 2026-09-21: INTERACT_ACROSS_USERS is granted to
# Inter Profile Sharing in Home and Cloud (default granted=true, overridden to
# false for the zones it does not live in) - and a User-block-only check
# called both of them a failed grant.
#
# Parsed in bash on purpose: no 'grep -q'/'head -1' in a pipeline while
# pipefail is active - both exit on the match, the upstream dies from SIGPIPE,
# and a GRANTED permission then reads as "not granted".
perm_granted() {  # $1=pkg $2=uid $3=perm
  local out line in_install=0 in_user=0 by_user="" by_default="" perm_name uid_of
  out="$(ash_ro dumpsys package "$1" 2>/dev/null | tr -d '\r')" || return 1
  while IFS= read -r line; do
    case "$line" in
      *"install permissions:"*) in_install=1; in_user=0; continue;;
      *"User $2:"*)             in_user=1;    in_install=0; continue;;
      *"User "[0-9]*":"*)       in_user=0;    in_install=0; continue;;
    esac
    # The permission name is a FIELD, so it is compared as one. As a substring
    # match, `*"$3: granted="*` also accepted a different permission whose name
    # ends with the one asked for - com.vendor.android.permission.READ_CONTACTS
    # answering for android.permission.READ_CONTACTS - and this function decides
    # whether a grant took.
    perm_name="${line%%:*}"; perm_name="${perm_name#"${perm_name%%[![:space:]]*}"}"
    [ "$perm_name" = "$3" ] || continue
    if [ "$in_user" = 1 ]; then
      # The user's own runtime block is authoritative - decide here.
      case "$line" in *granted=true*) return 0;; *) return 1;; esac
    elif [ "$in_install" = 1 ]; then
      # Same again, on the user id: `, userId=1` matched `, userId=15` as a
      # substring, so one user's override could answer for another. The value
      # is read out and compared as a number.
      case "$line" in
        *", userId="*)
          uid_of="${line##*, userId=}"; uid_of="${uid_of%%[!0-9]*}"
          [ "$uid_of" = "$2" ] && by_user="$line" ;;
        *) by_default="$line";;
      esac
    fi
  done <<<"$out"
  line="${by_user:-$by_default}"
  case "$line" in *granted=true*) return 0;; *) return 1;; esac
}

# Does $1 hold the bind-widget grant for user $2? The grant lives in
# AppWidgetService, not in the package manager, so perm_granted() cannot see
# it. dumpsys appwidget lists it under "Grants:" as
#   [0] user=10 package=org.andashi.home
# Same reason as above for parsing in bash instead of grep -q in a pipeline.
bind_granted() {  # $1=pkg $2=uid
  local out line in_grants=0
  out="$(ash_ro dumpsys appwidget 2>/dev/null | tr -d '\r')" || return 1
  while IFS= read -r line; do
    case "$line" in
      "Grants:"*) in_grants=1; continue;;
      [A-Za-z]*)  in_grants=0; continue;;
    esac
    [ "$in_grants" = 1 ] || continue
    case "$line" in *" user=$2 package=$1") return 0;; esac
  done <<<"$out"
  return 1
}

log "Setting permissions"
while read -r key; do
  label="$(profile_label "$key")"
  uid="$(resolve_uid "$key")"
  [ -n "$uid" ] || continue
  printf '\n'; log "Profile $label (user $uid)"

  while read -r app; do
    pkg="$(jq -r '.pkg'   <<<"$app")"
    lbl="$(jq -r '.label' <<<"$app")"
    # NOT '.net // true': jq's // operator also treats FALSE as empty and
    # would turn "net": false into true - the network toggle would never have
    # applied to a single app. Check via has() instead.
    net="$(jq -r 'if has("net") then .net else true end' <<<"$app")"

    # Same gate as in 10-apps.sh: if the feature is off, the app was never
    # installed - so don't set permissions here either.
    feat="$(jq -r 'if has("feature") then .feature else "" end' <<<"$app")"
    if [ -n "$feat" ] && ! feature_enabled "$feat"; then
      skip "$lbl (feature '$feat' is off)"; continue
    fi

    pkg_installed_for_user "$pkg" "$uid" || { skip "$lbl not installed"; continue; }

    # Network toggle
    if [ "$net" = "false" ]; then
      if perm_granted "$pkg" "$uid" android.permission.INTERNET; then
        ash pm revoke --user "$uid" "$pkg" android.permission.INTERNET 2>/dev/null \
          && ok "$lbl: INTERNET revoked" || warn "$lbl: INTERNET revoke failed"
      else
        skip "$lbl: INTERNET already revoked"
      fi
    fi

    # Explicit grants/revokes from the catalog. The optional
    # perms.only_profiles narrows them to named zones - without it they apply
    # in EVERY profile the app lives in, and a launcher that may read contacts
    # in Home has no business doing so in Anon.
    # Membership is decided in jq, on the array, not by matching text. It was
    # `grep -qw "$key"` against the space-joined list, and -w does not protect
    # a name with a hyphen in it: a hyphen is a word boundary, so a zone key
    # `home` would match an entry `home-lab` and the grant would land in a zone
    # the catalog never named. No zone key has a hyphen today, which is the
    # only reason this was not already wrong - in the one place whose entire
    # job is that a launcher which may read contacts in Home may not in Anon.
    only="$(jq -r '.perms.only_profiles // [] | join(" ")' <<<"$app")"
    if [ -n "$only" ] && ! jq -e --arg k "$key" '((.perms.only_profiles // []) | index($k)) != null' <<<"$app" >/dev/null; then
      skip "$lbl: perms only in [$only], not in '$key'"
    else

    # The exit code of 'pm grant' cannot decide whether anything happened: it
    # is 0 even when the package does not DECLARE the permission, in which
    # case nothing is granted and the only trace is
    #   E PermissionService: Permission <p> isn't requested by package <pkg>
    # in logcat. Measured 2026-09-21: the catalog still asked the launcher for
    # READ_CALENDAR after Andashi Home 0.3.0 had dropped calendar search, and
    # six runs in a row reported "+ READ_CALENDAR" for a grant that never
    # existed. So read the state back instead - perm_granted() is the same
    # check the INTERNET toggle above already uses.
    while read -r p; do
      [ -z "$p" ] && continue
      ash pm grant --user "$uid" "$pkg" "$p" 2>/dev/null || true
      if [ "$DRY_RUN" = "1" ]; then :
      elif perm_granted "$pkg" "$uid" "$p"; then ok "$lbl: +$p"
      else warn "$lbl: grant $p did NOT take - does $pkg still declare it? (05-verify-catalog.sh)"
      fi
    done < <(jq -r '.perms.grant[]? // empty' <<<"$app")

    # Same read-back for revoke. Note the asymmetry: for a permission the app
    # no longer declares, "not granted" IS the wanted end state, so this
    # reports success - correctly about the state, while saying nothing about
    # the stale catalog entry. That is what the static check exists for.
    while read -r p; do
      [ -z "$p" ] && continue
      ash pm revoke --user "$uid" "$pkg" "$p" 2>/dev/null || true
      if [ "$DRY_RUN" = "1" ]; then :
      elif perm_granted "$pkg" "$uid" "$p"; then warn "$lbl: revoke $p did NOT take"
      else ok "$lbl: -$p"
      fi
    done < <(jq -r '.perms.revoke[]? // empty' <<<"$app")
    fi

    # Bind-widget grant (appwidget_bind: true). A launcher may only bind the
    # AppWidgets its home.grid names once the user has said "always allow" in
    # the system's bind dialog; this gives that same per-package, per-user
    # grant (AppWidgetServiceImpl.setBindAppWidgetPermission) without the
    # dialog. It is convenience, not function: without it every widget cell
    # offers an Allow action and the zone stays usable. Decided in
    # provisioning#2 - a declared widget should appear, not ask. Applies in
    # every zone the app lives in, deliberately outside perms.only_profiles:
    # a grid in Anon is as much the declaration as one in Home.
    #
    # AppWidgetService only holds the state of a started, unlocked user: for a
    # stopped one grantbind dies (exit 137) and dumpsys lists nothing, so it
    # would read as "not granted" either way. Measured 2026-09-24 on
    # emulator-5558, where Cloud..Anon sat stopped after the previous run.
    # Start it the way 10-apps.sh does; 99-finalize puts every zone back into
    # its target state afterwards.
    if [ "$(jq -r '.appwidget_bind // false' <<<"$app")" = "true" ]; then
      if [ "$DRY_RUN" != "1" ] && ! user_running_uid "$uid"; then
        ash am start-user -w "$uid" >/dev/null && ok "$label started (had been evicted)" \
          || warn "$label could not be started"
      fi
      if [ "$DRY_RUN" != "1" ] && ! user_unlocked "$uid"; then
        warn "$lbl: $label is locked - bind-widget grant waits for the next run"
      elif [ "$DRY_RUN" != "1" ] && bind_granted "$pkg" "$uid"; then
        skip "$lbl: bind-widget grant already given"
      else
        ash appwidget grantbind --package "$pkg" --user "$uid" >/dev/null 2>&1 || true
        if [ "$DRY_RUN" = "1" ]; then :
        elif bind_granted "$pkg" "$uid"; then ok "$lbl: bind-widget grant"
        else warn "$lbl: bind-widget grant did NOT take - widget cells will ask instead"
        fi
      fi
    fi

    # AppOps
    while read -r line; do
      [ -z "$line" ] && continue
      op="${line%%=*}"; val="${line#*=}"
      ash appops set --user "$uid" "$pkg" "$op" "$val" 2>/dev/null \
        && ok "$lbl: appops $op=$val" || warn "$lbl: appops $op failed"
    done < <(jq -r '.appops // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$app")

  done < <(apps_for_profile "$key")
done < <(profile_keys)
