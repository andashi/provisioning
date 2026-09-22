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
  local out line in_install=0 in_user=0 by_user="" by_default=""
  out="$(ash_ro dumpsys package "$1" 2>/dev/null | tr -d '\r')" || return 1
  while IFS= read -r line; do
    case "$line" in
      *"install permissions:"*) in_install=1; in_user=0; continue;;
      *"User $2:"*)             in_user=1;    in_install=0; continue;;
      *"User "[0-9]*":"*)       in_user=0;    in_install=0; continue;;
    esac
    case "$line" in *"$3: granted="*) ;; *) continue;; esac
    if [ "$in_user" = 1 ]; then
      # The user's own runtime block is authoritative - decide here.
      case "$line" in *granted=true*) return 0;; *) return 1;; esac
    elif [ "$in_install" = 1 ]; then
      case "$line" in
        *", userId=$2"*) by_user="$line";;   # an override for exactly this user
        *", userId="*)   ;;                  # some other user's override
        *)               by_default="$line";;
      esac
    fi
  done <<<"$out"
  line="${by_user:-$by_default}"
  case "$line" in *granted=true*) return 0;; *) return 1;; esac
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
    only="$(jq -r '.perms.only_profiles // [] | join(" ")' <<<"$app")"
    if [ -n "$only" ] && ! grep -qw "$key" <<<"$only"; then
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

    # AppOps
    while read -r line; do
      [ -z "$line" ] && continue
      op="${line%%=*}"; val="${line#*=}"
      ash appops set --user "$uid" "$pkg" "$op" "$val" 2>/dev/null \
        && ok "$lbl: appops $op=$val" || warn "$lbl: appops $op failed"
    done < <(jq -r '.appops // {} | to_entries[]? | "\(.key)=\(.value)"' <<<"$app")

  done < <(apps_for_profile "$key")
done < <(profile_keys)
