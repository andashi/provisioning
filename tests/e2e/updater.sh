#!/usr/bin/env bash
# End-to-end cases for the updater on the device: 10-apps.sh puts it on first
# and names it as the installer of every app it installs, 50-updater-config.sh
# hands each zone its config, and the updater's own state agrees.
#
#   SERIAL=emulator-5558 OVERLAY_DIR=$PWD/emulator/instances/test-2 \
#   SNAPSHOT=provisioned-061 LOCK_OWNER=<yours> \
#   UPDATER_APK=../updater/app/build/outputs/apk/debug/app-debug.apk tests/e2e/updater.sh
#
# The template catalog has no updater until its first release, so this works
# on a COPY of config/ with one entry added for UPDATER_APK, and on an
# inventory that is the repository's plus that file, with its signer pinned
# beside the others. A debug build carries the ".debug" suffix in every name;
# the entry takes the package name from the APK, so nothing here assumes one.
#
# Restores SNAPSHOT first and asserts that adbd runs as shell. Uses the
# network: the zones fetch the real lock.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${SERIAL:?SERIAL=emulator-NNNN}" "${OVERLAY_DIR:?OVERLAY_DIR=...}" "${SNAPSHOT:?SNAPSHOT=<provisioned snapshot>}"
: "${UPDATER_APK:?UPDATER_APK=<path to an updater APK>}"
export ADB_SERIAL="$SERIAL" SERIAL OVERLAY_DIR
A() { adb -s "$SERIAL" "$@"; }

pass=0; fail=0; FAILED=()
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); FAILED+=("$1"); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
section() { printf '\n== %s\n' "$*"; }

WORK="$ROOT/.provision-state/e2e-updater"
rm -rf "$WORK"; mkdir -p "$WORK/log"
LOG="$WORK/log"
run() {   # $1=name, rest=command; output to $LOG/<name>, exit code in $RC
  local name="$1" t0; shift; t0="$(date +%s)"
  "$@" > "$LOG/$name" 2>&1; RC=$?
  printf '  ..    %s: exit %s in %ss\n' "$name" "$RC" "$(( $(date +%s) - t0 ))"
}

# ---- the catalog and inventory this run uses --------------------------------
UPD="$(aapt2 dump badging "$UPDATER_APK" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")"
UVER="$(aapt2 dump badging "$UPDATER_APK" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p")"
[ -n "$UPD" ] || { echo "cannot read $UPDATER_APK"; exit 1; }
export CONFIG_DIR="$WORK/config" APKS_DIR="$WORK/apks"
cp -r "$ROOT/config" "$CONFIG_DIR"
for d in universal arm64-v8a x86_64; do
  mkdir -p "$APKS_DIR/$d"
  for f in "$ROOT/apks/$d"/*.apk; do [ -f "$f" ] && ln -s "$f" "$APKS_DIR/$d/"; done
done
cp -r "$ROOT/apks/certs" "$APKS_DIR/certs"
cp "$UPDATER_APK" "$APKS_DIR/universal/$UPD-$UVER.apk"
apksigner verify --print-certs "$UPDATER_APK" 2>/dev/null \
  | sed -n 's/.*certificate SHA-256 digest: \(.*\)/\1/p' | head -1 > "$APKS_DIR/certs/$UPD.cert"
zones="$(jq -c '[.profiles[] | select((.type // "") != "managed") | .key]' "$CONFIG_DIR/profiles.json")"
jq --indent 2 --arg p "$UPD" --argjson z "$zones" '.apps = [{id: "updater", label: "Andashi Updater", pkg: $p,
    pkg_status: "verified", role: "updater", source: "obtainium", upstream: "https://github.com/andashi/updater",
    profiles: $z, net: true}] + .apps' "$CONFIG_DIR/apps.json" > "$CONFIG_DIR/apps.json.new" \
  && mv "$CONFIG_DIR/apps.json.new" "$CONFIG_DIR/apps.json"
OUT_DIR="$CONFIG_DIR/updater" CERTS_DIR="$APKS_DIR/certs" "$ROOT/config/gen-updater.sh" >/dev/null \
  || { echo "gen-updater failed"; exit 1; }

# ---- the phone ----------------------------------------------------------------
section "setup: $SNAPSHOT on $SERIAL, updater $UPD $UVER"
"$ROOT/emulator/run.sh" restore "$SNAPSHOT" >/dev/null 2>&1 || { echo "could not restore $SNAPSHOT"; exit 1; }
sleep 5
# shellcheck source=identity.sh
source "$ROOT/tests/e2e/identity.sh"; as_shell
dev="$(printf %s "$SERIAL" | tr -c 'A-Za-z0-9_.-' _)"
rm -rf "$ROOT/.provision-state/launcher-sha/$dev" "$ROOT/.provision-state/applied/$dev" \
       "$ROOT/.provision-state/pending/$dev" "$ROOT/.provision-state/installed/$dev" \
       "$ROOT/.provision-state/updater/$dev"

uid_of() { A shell pm list users | tr -d '\r' | sed -n "s/.*UserInfo{\([0-9]*\):$1:.*/\1/p"; }
declare -A UID_OF=()
for k in $(jq -r '.[]' <<<"$zones"); do
  lbl="$(jq -r --arg k "$k" '.profiles[] | select(.key == $k) | .label' "$CONFIG_DIR/profiles.json")"
  if [ "$k" = home ]; then UID_OF[$k]=0; else UID_OF[$k]="$(uid_of "$lbl")"; fi
done
all_users="$(A shell pm list users | tr -d '\r' | sed -n 's/.*UserInfo{\([0-9]*\):.*/\1/p')"
holders() { local u; for u in $all_users; do A shell pm list packages --user "$u" "$1" | tr -d '\r' | grep -qx "package:$1" && printf '%s ' "$u"; done; }
installer() { A shell pm list packages -i --user "$2" "$1" | tr -d '\r' | sed -n "s/^package:$1  installer=//p"; }
managed="$(jq -r '[.[] ] | unique | .[]' < <(jq -c '[.managed[].pkg]' "$CONFIG_DIR"/updater/*.json | jq -s 'add'))"

# Which users held each managed package before: no install may add one the
# catalog does not place it in.
declare -A BEFORE=()
for p in $managed; do BEFORE[$p]="$(holders "$p")"; done
check "the updater is not on the snapshot yet" '[ -z "$(holders "$UPD")" ]'

section "10-apps: the updater first, every app named"
run apps-1 "$ROOT/provision/10-apps.sh"
check "10-apps succeeds" '[ $RC = 0 ]'
check "the updater went on before any other app" \
  '[ "$(grep -n "updater installed from\|from .*\.apk\|upgraded to\|handed to the updater" "$LOG/apps-1" | head -1 | grep -c "updater installed from")" = 1 ]'
check "it is its own installer of record" '[ "$(installer "$UPD" 0)" = "$UPD" ]'
check "it is on the device-idle allowlist" 'A shell dumpsys deviceidle whitelist | tr -d "\r" | grep -q "^user,$UPD,"'
for k in $(jq -r '.[]' <<<"$zones"); do
  u="${UID_OF[$k]}"
  check "$k (user $u): updater present, installer itself" '[ "$(installer "$UPD" "$u")" = "$UPD" ]'
  check "$k: may install (appop read back)" 'A shell appops get --user "$u" "$UPD" REQUEST_INSTALL_PACKAGES | tr -d "\r" | grep -q "^REQUEST_INSTALL_PACKAGES: allow"'
  check "$k: may notify (grant read back)" \
    'A shell dumpsys package "$UPD" | tr -d "\r" | awk -v u="    User $u:" '"'"'index($0,u)==1{p=1;next} /^    User [0-9]+:/{p=0} p&&/POST_NOTIFICATIONS: granted=true/{f=1} END{exit !f}'"'"''
done

notowned=""; spread=""
for p in $managed; do
  h="$(holders "$p")"; [ -n "$h" ] || continue
  i="$(installer "$p" "${h%% *}")"
  # An app the device runs ahead of the host cannot be handed over from here
  # (10-apps.sh says so); everything else must be the updater's.
  lbl="$(jq -r --arg p "$p" '[.apps[] | select(.pkg == $p) | .label][0]' "$CONFIG_DIR/apps.json")"
  if [ "$i" != "$UPD" ] && ! grep -qF "$lbl: installer of record is '${i:-null}' - handed to the updater once the host has build" "$LOG/apps-1"; then
    notowned="$notowned $p($i)"
  fi
  for u in $h; do
    case " ${BEFORE[$p]} " in *" $u "*) continue;; esac
    z="$(for k in "${!UID_OF[@]}"; do [ "${UID_OF[$k]}" = "$u" ] && echo "$k"; done)"
    jq -e --arg p "$p" --arg z "$z" '.apps[] | select(.pkg == $p) | .profiles | index($z)' "$CONFIG_DIR/apps.json" >/dev/null \
      || spread="$spread $p->user$u"
  done
done
check "every managed app on the phone is the updater's (or said why not)" '[ -z "$notowned" ] || { echo "       not the updater'"'"'s:$notowned"; false; }'
check "no app landed in a zone the catalog keeps it out of" '[ -z "$spread" ] || { echo "       spread:$spread"; false; }'

section "50-updater-config: each zone holds its config"
run cfg-1 "$ROOT/provision/50-updater-config.sh"
check "50-updater-config succeeds" '[ $RC = 0 ]'
for k in $(jq -r '.[]' <<<"$zones"); do
  u="${UID_OF[$k]}"
  A shell pm list users | tr -d '\r' | grep -q "{$u:.*} running" \
    || { printf '  ..    %s stopped - checked by its record only\n' "$k"; continue; }
  want="$(sha256sum "$CONFIG_DIR/updater/$k.json" | cut -d' ' -f1)"
  got="$(A shell content query --user "$u" --uri "content://$UPD.state/diagnostics" | tr -d '\r' | sed 's/^Row: 0 json=//' | jq -r .configSha256)"
  check "$k: the updater reports exactly this config" '[ "$got" = "$want" ]'
done
sleep 20
st="$(A shell content query --user 0 --uri "content://$UPD.state/state" | tr -d '\r' | sed 's/^Row: 0 json=//')"
check "Home: the updater's state names every managed app of Home" \
  '[ "$(jq -r "[.apps[].pkg] | sort | join(\" \")" <<<"$st")" = "$(jq -r "[.managed[].pkg] | sort | join(\" \")" "$CONFIG_DIR/updater/home.json")" ]'
check "Home: none of them not-owner" '[ -z "$(jq -r ".apps[] | select(.state == \"not-owner\") | .pkg" <<<"$st")" ] || { jq -c "[.apps[] | select(.state == \"not-owner\") | {pkg, installer}]" <<<"$st"; false; }'
check "Home: exemption granted" '[ "$(jq -r .exemption <<<"$st")" = granted ]'
printf '  ..    Home states: %s\n' "$(jq -r '[.apps[].state] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' <<<"$st")"

section "again: nothing left to do"
run apps-2 "$ROOT/provision/10-apps.sh"
check "a second 10-apps run installs nothing" \
  '[ $RC = 0 ] && ! grep -q "updater installed from\|handed to the updater (installer\| from .*\.apk$" "$LOG/apps-2"'
run cfg-2 "$ROOT/provision/50-updater-config.sh"
check "a second 50-updater-config run writes nothing" '[ $RC = 0 ] && ! grep -q "config loaded" "$LOG/cfg-2"'

printf '\n  %d ok, %d failed   (instance %s, snapshot %s, updater %s %s, adb as shell)\n' \
  "$pass" "$fail" "$SERIAL" "$SNAPSHOT" "$UPD" "$UVER"
[ "$fail" = 0 ] || { printf '  failed: %s\n' "${FAILED[@]}"; printf '  logs in %s\n' "$LOG"; exit 1; }
