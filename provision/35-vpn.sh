#!/usr/bin/env bash
# Sets the always-on VPN per profile from config/profiles.json.
#
# Why bother at all: "one VPN slot per profile" is the core of the zone
# model, but the switch for it used to be entirely manual work - six times
# Settings -> Network -> VPN -> gear icon -> two toggles. For Anon that's
# not a matter of convenience: without "block connections without VPN",
# traffic runs around Tor, silently and unnoticed. In a config file it's
# visible, versionable, and reproducible on every run.
#
# The VPN consent ("App X wants to set up a VPN connection") used to be the
# one manual tap left here. It doesn't have to be: that dialog records exactly
# one thing, the ACTIVATE_VPN AppOp for the package (Vpn.setPackageAuthorization),
# and appops is settable from adb - 20-permissions.sh already uses it for other
# ops. So the consent is declared here too, see set_vpn_consent below.
# That also settles the old open question whether always_on_vpn_app takes
# effect without consent: it does not. VpnManagerService reads the setting when
# the user starts and refuses to bring up a tunnel for an unauthorized package,
# so without the AppOp the setting is decoration.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
require_device

log "Setting always-on VPN per profile"

set_one() {   # $1=uid $2=namespace-key $3=target-value $4=label
  local cur
  cur="$(ash_ro settings --user "$1" get secure "$2" 2>/dev/null | tr -d '\r')" || cur=""
  [ "$cur" = "null" ] && cur=""
  if [ "$cur" = "$3" ]; then
    skip "$4: $2 = ${3:-<empty>}"
  elif [ -z "$3" ]; then
    ash settings --user "$1" delete secure "$2" >/dev/null 2>&1 \
      && ok "$4: $2 removed" || warn "$4: $2 could not be removed"
  else
    ash settings --user "$1" put secure "$2" "$3" >/dev/null \
      && ok "$4: $2 = $3" || warn "$4: $2 could not be set"
  fi
}

# The op defaults to 'ignore' (check with: appops get <pkg> ACTIVATE_VPN),
# i.e. denied until something allows it. ACTIVATE_VPN covers VpnService apps -
# Tailscale, RethinkDNS and Orbot are all of that kind. Platform VPNs (IKEv2
# profiles configured in Settings) would need ACTIVATE_PLATFORM_VPN instead;
# no zone uses those.
# Reversible at any time:  adb shell appops set --user N <pkg> ACTIVATE_VPN default
vpn_consent_mode() {   # $1=uid $2=pkg -> current mode, or empty
  local out l mode=""
  out="$(ash_ro appops get --user "$1" "$2" ACTIVATE_VPN 2>/dev/null | tr -d '\r')" || return 1
  # No grep/head pipeline (SIGPIPE + pipefail, see common.sh): an explicit
  # per-op line wins, otherwise the printed default applies.
  while IFS= read -r l; do
    case "$l" in
      # Matches both the bare "ACTIVATE_VPN: allow; time=..." line and the
      # uid-level variant, which prefixes it with "Uid mode: ".
      *"ACTIVATE_VPN: "*) mode="${l##*ACTIVATE_VPN: }"; mode="${mode%%;*}"; mode="${mode%% *}"; break;;
      "Default mode: "*) [ -z "$mode" ] && mode="${l#Default mode: }";;
    esac
  done <<<"$out"
  printf '%s' "$mode"
}

set_vpn_consent() {   # $1=uid $2=pkg $3=label
  local mode
  mode="$(vpn_consent_mode "$1" "$2")" || mode=""
  if [ "$mode" = "allow" ]; then
    skip "$3: VPN consent already granted"
    return 0
  fi
  ash appops set --user "$1" "$2" ACTIVATE_VPN allow >/dev/null 2>&1 \
    && ok "$3: VPN consent granted (ACTIVATE_VPN: ${mode:-unset} -> allow)" \
    || warn "$3: VPN consent could not be granted - confirm the dialog once by hand"
}

while read -r key; do
  label="$(profile_label "$key")"
  uid="$(resolve_uid "$key")"
  [ -n "$uid" ] || { warn "$label does not exist - run 00-profiles.sh first"; continue; }

  pkg="$(profile_field "$key" vpn_pkg)"
  lock="$(profile_field "$key" vpn_lockdown)"
  slot="$(profile_field "$key" vpn)"

  printf '\n'
  if [ -z "$pkg" ]; then
    log "Profile $label (user $uid) - no VPN package declared ($slot), skipped"
    continue
  fi
  log "Profile $label (user $uid) - $slot"

  # A VPN that isn't even installed in the profile would be a dead setting.
  if ! pkg_installed_for_user "$pkg" "$uid"; then
    warn "$pkg is not installed in $label - the setting would be ineffective, skipped"
    continue
  fi

  # Consent first, then the always-on settings: the other order leaves a window
  # in which the setting points at a package that isn't allowed to run yet.
  set_vpn_consent "$uid" "$pkg" "$label"
  set_one "$uid" always_on_vpn_app "$pkg" "$label"
  # jq returns true/false, the setting expects 1/0
  [ "$lock" = "true" ] && want=1 || want=0
  set_one "$uid" always_on_vpn_lockdown "$want" "$label"
done < <(profile_keys)

printf '\n'
log "VPN consent comes from appops now - no per-zone dialog left to confirm."
warn "Still by hand: exclude Tor Browser from Orbot's per-app routing in Anon (Tor-over-Tor)."
