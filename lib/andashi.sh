#!/usr/bin/env bash
# The decisions bin/andashi makes, kept apart from the commands so the case
# files can ask them without a device. Sourced after lib/common.sh.

# The chain, in the order run.sh runs it. `apply` never reorders it: every
# later step assumes the earlier ones have run (apps before permissions,
# the theme before the launcher that is restarted by a palette change).
STEP_ORDER=(00-profiles 10-apps 20-permissions 30-settings 35-vpn 40-theming 45-launcher-config 90-manual 99-finalize)
SECTIONS="profiles apps permissions settings vpn theme launcher manual"

# What a person changes, mapped to the steps that deliver it. The launcher
# step is in `apps` because the home screen resolves favourites and search
# against what is installed, and in `theme` because glass, wallpaper and grid
# are theming.json keys that only the launcher applies.
section_steps() {   # $1=section -> step names, one per line
  case "$1" in
    profiles)    printf '%s\n' 00-profiles 99-finalize;;
    apps)        printf '%s\n' 10-apps 20-permissions 45-launcher-config 90-manual;;
    permissions) printf '%s\n' 20-permissions;;
    settings)    printf '%s\n' 30-settings;;
    vpn)         printf '%s\n' 35-vpn;;
    theme)       printf '%s\n' 40-theming 45-launcher-config;;
    launcher)    printf '%s\n' 45-launcher-config;;
    manual)      printf '%s\n' 90-manual;;
    *)           return 1;;
  esac
}

# Which sections an input file feeds. profiles.json and features.json decide
# which zones exist and what lives in them, so a change there is a change to
# everything; the others are narrower. `wallpapers` is not a file but the
# bytes of every image theming.json points at: the launcher step notices new
# bytes under an old name, but only if something makes it look.
sections_for_input() {   # $1=input name -> sections, one per line
  case "$1" in
    profiles.json|features.json) printf '%s\n' $SECTIONS;;
    apps.json)                   printf '%s\n' apps permissions launcher manual;;
    settings.json)               printf '%s\n' settings;;
    theming.json)                printf '%s\n' theme launcher;;
    wallpapers)                  printf '%s\n' launcher;;
    *)                           return 1;;
  esac
}

# Steps for a set of sections, in chain order, each once. A section that
# starts zones (profiles, apps, permissions) also ends with 99-finalize, which
# puts every zone back into its target runtime state - otherwise an `apply`
# would leave running what the model says is stopped.
steps_for_sections() {   # $@=sections -> step names in STEP_ORDER
  local want=" " s st starts=0
  for s in "$@"; do
    section_steps "$s" >/dev/null || { printf 'unknown section: %s\n' "$s" >&2; return 1; }
    while read -r st; do want="$want$st "; done < <(section_steps "$s")
    case "$s" in profiles|apps|permissions) starts=1;; esac
  done
  [ "$starts" = 1 ] && want="${want}99-finalize "
  for st in "${STEP_ORDER[@]}"; do
    case "$want" in *" $st "*) printf '%s\n' "$st";; esac
  done
}

# What one zone is made of, as "name sha" lines. Each input is hashed through
# the part of it that concerns this zone, not as a file: changing Lab's palette
# must not mark five other zones as changed, or every stopped one would be
# reported as owing a theme it does not owe. The shared parts (global keys,
# all_profiles, the launcher entry) are in every zone's projection, because a
# change there is a change for all of them.
#
# `wallpapers` hashes the bytes of the zone's image in both aspect variants;
# which one a device gets is the device's to say.
zone_snapshot() {   # $1=zone
  local z="$1" w a f
  printf 'profiles.json %s\n' "$(jq -cS --arg z "$z" '.profiles[] | select(.key == $z)' "$CONFIG_DIR/profiles.json" | sha256sum | cut -d' ' -f1)"
  printf 'apps.json %s\n' "$(jq -cS --arg z "$z" '[.apps[] | select((.profiles // []) | index($z))]' "$CONFIG_DIR/apps.json" | sha256sum | cut -d' ' -f1)"
  printf 'settings.json %s\n' "$(jq -cS --arg z "$z" '{g: .global, a: .all_profiles, p: .per_profile[$z]}' "$CONFIG_DIR/settings.json" | sha256sum | cut -d' ' -f1)"
  printf 'theming.json %s\n' "$(jq -cS --arg z "$z" '{g: .global, k: .keyboard_pkg, l: .launcher, ls: .launchers, a: .all_profiles, p: .per_profile[$z]}' "$CONFIG_DIR/theming.json" | sha256sum | cut -d' ' -f1)"
  printf 'features.json %s\n' "$(jq -cS . "$CONFIG_DIR/features.json" | sha256sum | cut -d' ' -f1)"
  w="$(jq -r --arg z "$z" '((.all_profiles // {}) * (.per_profile[$z] // {})).wallpaper // empty' "$CONFIG_DIR/theming.json")"
  printf 'wallpapers %s\n' "$(
    for a in tall square; do
      f="$REPO_ROOT/${w//\{aspect\}/$a}"
      [ -n "$w" ] && [ -f "$f" ] && sha256sum < "$f"
    done | sha256sum | cut -d' ' -f1)"
}

# The sections whose inputs differ between two snapshots ("name sha" lines).
# A name missing from the old snapshot counts as changed: an input we never
# applied is not one we can call unchanged. An empty old snapshot therefore
# yields everything, which is right for a device this host has not applied to.
changed_sections() {   # $1=old snapshot text $2=new snapshot text -> sections
  local name sha old s out=" "
  while read -r name sha; do
    [ -n "$name" ] || continue
    old="$(awk -v n="$name" '$1 == n { print $2 }' <<<"$1")"
    [ "$old" = "$sha" ] && continue
    while read -r s; do out="$out$s "; done < <(sections_for_input "$name")
  done <<<"$2"
  for s in $SECTIONS; do
    case "$out" in *" $s "*) printf '%s\n' "$s";; esac
  done
}

# One zone's launcher, three hashes: what we are about to push (want), what we
# last agreed on (rec), what the device loaded (dev). The answer decides
# whether `apply` pushes, adopts the device's edit into the catalog first, or
# stops for a person. It is the three-way merge #7 asks for, reduced to what
# can be told apart without guessing:
#
#   first     no record - nothing was agreed, so nothing can be protected
#   none      nobody changed anything
#   push      only the host changed
#   adopt     only the device changed - pull it into the catalog, then push
#   conflict  both changed since the agreement
#   unknown   the device did not say what it holds
reconcile_plan() {   # $1=want_sha $2=rec_sha $3=dev_sha
  [ -n "$2" ] || { printf 'first'; return 0; }
  [ -n "$3" ] || { printf 'unknown'; return 0; }
  local host=0 dev=0
  [ "$1" != "$2" ] && host=1
  [ "$3" != "$2" ] && dev=1
  case "$host$dev" in
    00) printf 'none';;
    10) printf 'push';;
    01) printf 'adopt';;
    11) [ "$1" = "$3" ] && printf 'none' || printf 'conflict';;
  esac
}

# What this host last applied to a zone of this device: the zone's snapshot at
# the end of a run that went through. `apply` compares against it to find what
# changed; a full run (provision/run.sh) writes it too, so the first `apply`
# after provisioning does not redo the whole chain.
applied_record() { printf '%s/applied/%s/%s' "$STATE_DIR" "$(device_id)" "$1"; }
record_applied() {   # $1=zone
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  local f; f="$(applied_record "$1")"
  mkdir -p "$(dirname "$f")"
  zone_snapshot "$1" > "$f.tmp" && mv "$f.tmp" "$f"
}

# The packages the catalog declares for a zone, the way 10-apps.sh decides
# them: every app placed there whose feature, if it names one, is on.
declared_pkgs() {   # $1=zone -> package names, one per line
  local app feat
  while read -r app; do
    feat="$(jq -r 'if has("feature") then .feature else "" end' <<<"$app")"
    [ -z "$feat" ] || feature_enabled "$feat" || continue
    jq -r .pkg <<<"$app"
  done < <(apps_for_profile "$1")
}
# Of those, the ones this host can install: those it has an APK for. Play and
# manual apps go through MANUAL.md, and an app whose APK was never fetched
# cannot be installed by running apply again - calling either "missing" would
# make every apply start the zone to fail at the same thing.
installable_pkgs() {   # $1=zone
  local app feat pkg
  while read -r app; do
    feat="$(jq -r 'if has("feature") then .feature else "" end' <<<"$app")"
    [ -z "$feat" ] || feature_enabled "$feat" || continue
    case "$(jq -r .source <<<"$app")" in play-sandboxed|manual) continue;; esac
    pkg="$(jq -r .pkg <<<"$app")"
    apk_for_pkg "$pkg" >/dev/null || continue
    printf '%s\n' "$pkg"
  done < <(apps_for_profile "$1")
}

# Apps on the device against the catalog, three lists (space separated):
#   missing  installable, declared, not installed
#   remove   installed by this chain, no longer declared - apply removes them
#   foreign  installed, not declared, not by this chain - somebody's own;
#            named, never removed unless asked (--prune-undeclared)
# $1=declared $2=installable $3=installed (all) $4=third-party $5=record
# $6=the zone's own system packages (zone_system_pkgs)
apps_drift() {
  local p missing="" remove="" foreign=""
  for p in $2; do case " $3 " in *" $p "*) ;; *) missing="$missing $p";; esac; done
  for p in $5; do
    case " $1 " in *" $p "*) continue;; esac
    case " $3 " in *" $p "*) remove="$remove $p";; esac
  done
  for p in $4; do
    case " $1 $5 ${6:-} " in *" $p "*) continue;; esac
    foreign="$foreign $p"
  done
  printf 'missing=%s\nremove=%s\nforeign=%s\n' "${missing# }" "${remove# }" "${foreign# }"
}
