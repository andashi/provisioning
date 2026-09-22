#!/usr/bin/env bash
# Generates MANUAL.md: everything that is NOT scriptable by design.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

OUT="$REPO_ROOT/MANUAL.md"
MANUAL_QUEUE="$STATE_DIR/manual-installs.tsv"
mkdir -p "$(dirname "$OUT")"

{
  echo "# MANUAL.md - manual steps after the provisioning run"
  echo
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo
  echo "> Everything here is **by design** not scriptable: Storage/Contact Scopes are UI-only,"
  echo "> sandboxed Play is installed via the GrapheneOS Apps app, and credentials"
  echo "> never go through the adb shell, on principle."
  echo
  echo "## 1. Set profile PINs"
  echo
  echo "**Do this AFTER the first full provisioning run, not before.** The order decides"
  echo "whether the run is unattended. A locked profile has sealed credential-encrypted"
  echo "storage: no wallpaper can be set (\`40-theming.sh\`) and the launcher's ingest"
  echo "provider is not reachable (\`45-launcher-config.sh\`). Both steps report a locked"
  echo "profile as failed and never unlock anything themselves, because credentials do"
  echo "not go through the adb shell. Set the PINs first and every later theming or"
  echo "launcher run needs you to unlock each profile by hand at the device."
  echo
  echo "\`locksettings set-password --user N\` is flaky for secondary profiles and would write"
  echo "the password into the shell history. So by hand, per profile:"
  echo
  echo "**Where you do it:** the first time you switch into a freshly created profile, GrapheneOS"
  echo "opens its setup wizard there - Welcome, then Location services, then **Set a PIN**. That"
  echo "third screen is the place; you are already standing in the right profile and do not have"
  echo "to go looking through Settings."
  echo
  echo "**Watch out:** that screen has a \`Skip\` button next to \`Next\`. Skipping leaves the zone"
  echo "with no lock at all, and nothing later points it out. That matters more than convenience:"
  echo "the zone model assumes a stopped profile is frozen and encrypted at rest, and that holds"
  echo "only while the profile has a credential of its own. Verified on the device 2026-09-17 -"
  echo "the wizard asks, it does not insist."
  echo
  echo "The wizard blocks nothing in provisioning: every step either talks to Android directly or"
  echo "drives the launcher's settings activity, and none of them needs the home screen. You can"
  echo "let the full run finish first and walk the wizards afterwards."
  echo
  while read -r key; do
    [ "$(jq -r --arg k "$key" '.profiles[]|select(.key==$k)|.create' "$CONFIG_DIR/profiles.json")" = "true" ] || continue
    lbl="$(jq -r --arg k "$key" '.profiles[]|select(.key==$k)|.label' "$CONFIG_DIR/profiles.json")"
    unl="$(jq -r --arg k "$key" '.profiles[]|select(.key==$k)|.unlock' "$CONFIG_DIR/profiles.json")"
    echo "- [ ] **$lbl** - $unl"
  done < <(jq -r '.profiles[].key' "$CONFIG_DIR/profiles.json")
  echo "- [ ] **Home (Owner)** - enable 2-factor fingerprint+PIN"
  echo
  echo "## 2. Sandboxed Play Services"
  echo
  echo "GrapheneOS Apps app -> install \"Google Play\". 3 taps, deliberately not scriptable."
  echo
  echo "- [ ] **Cloud**: sandboxed Play + throwaway account #1"
  echo "- [ ] **Gadgets**: sandboxed Play + throwaway account #2 *(test first whether it's even needed)*"
  echo "- [ ] Make sure: **Home stays Play-free** (hard rule)"
  echo
  echo "## 3. Apps that need to be installed manually"
  echo

  if [ -s "$MANUAL_QUEUE" ]; then
    echo "| Profile | App | Package | Source |"
    echo "|---|---|---|---|"
    sort -u "$MANUAL_QUEUE" | while IFS=$'\t' read -r prof lbl pkg src; do
      echo "| $prof | $lbl | \`$pkg\` | $src |"
    done
  else
    echo "_No open installs (or 10-apps.sh hasn't been run yet)._"
  fi

  echo
  echo "Order note: apps can be installed via adb **before** Play exists in the"
  echo "profile - they only activate fully after Play + login."
  echo
  echo "Don't search for these by hand. \`provision/95-play-queue.sh\` walks them:"
  echo "it switches to the zone, opens each Play page directly by package name, and"
  echo "waits for you to tap Install. Already installed apps drop out, so the list"
  echo "gets shorter every run."
  echo
  echo '```bash'
  echo "provision/95-play-queue.sh            # every zone that still has Play apps"
  echo "provision/95-play-queue.sh cloud      # or one zone at a time"
  echo '```'
  echo
  echo "## 4. Curate scopes (UI-only)"
  echo
  echo "On the **first launch** of each app, not before:"
  echo
  echo "| Profile | App | Scope spec |"
  echo "|---|---|---|"
  jq -r '.apps[] | select(.scopes) | . as $a | $a.profiles[] | "| \(.) | \($a.label) | \($a.scopes) |"' "$CONFIG_DIR/apps.json"
  echo
  echo "## 5. VPN slots (one per profile - conflicts are hard)"
  echo
  echo "| Profile | VPN | Special note |"
  echo "|---|---|---|"
  echo "| Home | Tailscale (private tailnet) | - |"
  echo "| Cloud | RethinkDNS (monitor/block) | - |"
  echo "| Gadgets | RethinkDNS (aggressive) | - |"
  echo "| Ops | Tailscale (business tailnet) | - |"
  echo "| Anon | Orbot | Always-on VPN **+ \"block connections without VPN\"**, **exclude** Tor Browser from the per-app routing (Tor-over-Tor) |"
  echo
  echo "Always-on, lockdown, **and the VPN consent** are set by \`provision/35-vpn.sh\`"
  echo "(the consent dialog only records the \`ACTIVATE_VPN\` AppOp, and appops is"
  echo "adb-settable). What is left by hand:"
  echo
  echo "- [ ] **Anon**: exclude Tor Browser from Orbot's per-app routing (Tor-over-Tor)"
  echo "- [ ] Check globally: **Private DNS = off** (collides with the per-profile VPNs)"
  echo
  echo "## 6. Network to set up, then closed again"
  echo
  echo "These apps are set to \`net:false\`, but need network access **once** to"
  echo "become operational at all. Provisioning revokes INTERNET immediately -"
  echo "so set them up first, then run \`provision/20-permissions.sh\` again."
  echo
  nset=0
  while read -r line; do
    [ -z "$line" ] && continue
    nset=1
    lbl="${line%%|*}"; note="${line#*|}"
    echo "- [ ] **$lbl** — grant INTERNET, set up, then revoke"
    echo "      $note"
  done < <(jq -r '.apps[]|select(.net_setup == true)|"\(.label)|\(.notes // "")"' "$CONFIG_DIR/apps.json")
  [ "$nset" = "0" ] && echo "_None._"
  echo
  echo "Grant network temporarily:"
  echo
  echo "\`\`\`bash"
  echo "adb shell pm grant --user N <package> android.permission.INTERNET"
  echo "# set up, then:"
  echo "provision/20-permissions.sh   # restores the catalog state"
  echo "\`\`\`"
  echo
  echo "## 7. Background operation - only ONE secondary profile!"
  echo
  echo "GrapheneOS only lets **3 users run at the same time**, owner included."
  echo "If a fourth starts, Android evicts whichever has been in the background the"
  echo "longest - what got hit in testing was **Cloud**, of all things the profile"
  echo "that's needed permanently."
  echo
  echo "Settings -> System -> Multiple users -> per profile:"
  echo
  echo "- [ ] **Cloud: \"Run in background\" = ON** (anything that has to stay reachable"
  echo "      while you are elsewhere: a car key, a door lock, work push notifications)"
  echo "- [ ] **Gadgets: OFF**"
  echo "- [ ] **Ops: OFF**"
  echo "- [ ] **Lab: OFF**"
  echo "- [ ] **Anon: OFF**"
  echo
  echo "> Turning on background operation for a **second** secondary profile kicks"
  echo "> Cloud out on the next profile switch - the car key and the work"
  echo "> notifications then die silently, without an error message."
  echo
  echo "Not settable via adb - confirmed, not just suspected: the switch is a"
  echo "UserManager restriction (\`no_run_in_background\`, inverted), and restrictions"
  echo "go only through the DevicePolicyManager - settable by a device owner **or a"
  echo "profile owner**, per AOSP's documentation on the constant. Device-owner"
  echo "provisioning would contradict the MAM-only approach (unmanaged device);"
  echo "a profile owner per zone would not, in principle. But GrapheneOS ships"
  echo "secondary users with the restriction already SET and the toggle clears it,"
  echo "so Cloud needs it cleared - and whether a profile owner may clear a base"
  echo "restriction set by the system is unverified. Stays manual."
  echo
  echo "Remember for everyday use: you don't leave a profile with background"
  echo "operation enabled by simply switching away, but via \"End session\" ->"
  echo "the owner lock screen. So the route from Ops to Gadgets always goes via Home."
  echo
  # Notification forwarding has been automated since 30-settings.sh (secure
  # setting send_censored_notifications_to_current_user per profile from
  # profiles.json) - the former manual section is therefore gone.
  echo "## 8. Logins & MFA"
  echo
  echo "- [ ] FIDO2/YubiKey everywhere possible"
  echo "- [ ] YubiKey TOTP for the important accounts"
  echo "- [ ] Unlock Bitwarden in Home / Cloud / Ops + enable autofill"
  echo "- [ ] Set up MS Authenticator (Cloud) as the MAM broker"
  echo "- [ ] **Remember:** YubiKey cannot unlock profiles (Android limitation, verified)"
  echo
  echo "## 9. Migration iPhone -> Fold"
  echo
  echo "- [ ] Transfer eSIM"
  echo "- [ ] **Deregister iMessage for the number** (otherwise SMS disappear)"
  echo "- [ ] Signal: set up the Fold as primary, iPhone as linked device (45-day window)"
  echo "- [ ] iPhone into the drawer: Find My terminal for AirTags + iOS test device"
  echo "- [ ] Private mail to own domain @ mailbox.org, DAVx5 (Home) against CalDAV/CardDAV"
  echo
  echo "## 10. Theming (UI-only)"
  echo
  echo "If a profile here reports \"Lock screen active\", its PIN was set before this ran"
  echo "(see section 1). Unlock the profile at the device, then run the step again."
  echo
  echo "Accent color, dark mode, launcher role, and keyboard are set by \`provision/40-theming.sh\`."
  echo "The launcher itself (Andashi Home, \`org.andashi.home\`) is configured by file:"
  echo "\`provision/45-launcher-config.sh\` pushes \`config/launcher/<profile>.json\` into each"
  echo "profile, the launcher converges to it and reports its effective state back. Icons,"
  echo "transparency, search bar, dock and widgets are all in that file - nothing to tap."
  echo "The rest is UI-only, per profile:"
  echo
  echo "- [ ] **Wallpaper**: comes declaratively from config/theming.json (\`wallpaper:\` per"
  echo "      profile, applied by Andashi Home for home+lock screen via 45-launcher-config.sh). Only manual"
  echo "      part left: put the image into themes/<name>/. The profile color is preserved"
  echo "      (\`color_source=preset\` pins it against Monet)"
  echo "- [ ] **HeliBoard**: optionally load the glide-typing library (Settings -> Gesture typing;"
  echo "      needs the release variant, fetch.sh already excludes nouserlib)"
  echo "- [ ] Dark mode only takes effect for background profiles after the next"
  echo "      profile switch - cycle through once and check visually: every zone"
  echo "      has its own color"
  echo
  echo "**Troubleshooting: a profile's home screen looks wrong** (missing favorites,"
  echo "wrong icons, wrong layout): run \`provision/45-launcher-config.sh\` again. It writes"
  echo "the file, waits until the launcher confirms the file's sha256 and compares the"
  echo "launcher's effective config with the file - a profile that does not match fails"
  echo "the step loudly, with the launcher's own diagnostics. If the launcher's state is"
  echo "wedged beyond that, \`adb shell pm clear --user N org.andashi.home\` resets only the"
  echo "launcher's data (accounts, messages, photos and app data survive); then run the"
  echo "step again. Deleting the whole profile is the wrong tool once it holds anything real."
  echo
  echo "## 11. Active features (deliberate exceptions)"
  echo
  anyf=0
  if [ -f "$FEATURES_FILE" ]; then
    while read -r fkey; do
      feature_enabled "$fkey" || continue
      anyf=1
      echo "### $(feature_field "$fkey" label)"
      echo
      fcost="$(feature_field "$fkey" cost)"
      [ -n "$fcost" ] && { echo "> Cost: $fcost"; echo; }
      jq -r --arg k "$fkey" '.features[$k].manual[]? | "- [ ] " + .' "$FEATURES_FILE"
      echo
    done < <(feature_keys)
  fi
  [ "$anyf" = "0" ] && { echo "_None - all feature switches are off (config/features.json)._"; echo; }

  echo "## 12. Final check"
  echo
  echo "- [ ] \`provision/99-finalize.sh\` has run (Ops/Anon/Gadgets stopped)"
  echo "- [ ] Home contains **no** Play Services"
  echo "- [ ] Cross-profile sharing disabled"
  echo "- [ ] Immich: backup ON only in Home, OFF everywhere else"
} > "$OUT"

ok "MANUAL.md written ($(wc -l < "$OUT") lines)"
