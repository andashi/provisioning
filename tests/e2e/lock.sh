#!/usr/bin/env bash
# End-to-end: a phone provisioned by a machine that has only what the lock asks
# for - adb, curl, jq, sha256sum - and never ran fetch.sh.
#
#   SERIAL=emulator-5562 OVERLAY_DIR=$PWD/emulator/instances/test-fold-gpu \
#   LOCK_OWNER=<yours> [LOCK_APKS=<dir to reuse>] tests/e2e/lock.sh
#
# From the `clean` snapshot, because the claim is about a first install. The
# APKs come from apks/from-lock.sh into an empty directory (or LOCK_APKS, which
# from-lock.sh re-checks byte for byte, to save the download on a re-run), and
# the whole chain runs with aapt2, apksigner, gpg and java removed from PATH:
# anything in it that still reached for them would fail or fall back loudly.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${SERIAL:?}" "${OVERLAY_DIR:?}" "${LOCK_OWNER:?}"
export ADB_SERIAL="$SERIAL" SERIAL OVERLAY_DIR LOCK_OWNER
pass=0; fail=0
check() { if eval "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }
WORK="$ROOT/.provision-state/e2e-lock"; rm -rf "$WORK"; mkdir -p "$WORK"
APKS="${LOCK_APKS:-$WORK/apks}"; mkdir -p "$APKS"

# A PATH without the tools a person should no longer need.
mkdir -p "$WORK/bin"
IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do
  for f in "$d"/*; do
    b="$(basename "$f")"
    case "$b" in aapt|aapt2|apksigner|gpg|gpg2|java|keytool) continue;; esac
    [ -e "$WORK/bin/$b" ] || ln -s "$f" "$WORK/bin/$b" 2>/dev/null
  done
done
LEAN="$WORK/bin"
for t in aapt2 apksigner gpg java; do
  check "$t is not on the lean PATH" '! PATH="$LEAN" command -v '"$t"' >/dev/null'
done

printf '\n== the APKs, from the lock only\n'
PATH="$LEAN" APK_ABI=x86_64 APKS_DIR="$APKS" "$ROOT/apks/from-lock.sh" > "$WORK/from-lock.log" 2>&1
check "from-lock.sh gets every file" '[ $? = 0 ] && grep -q ", 0 failed" "$WORK/from-lock.log"'
want="$(jq '[.entries[] | select(.abi == "universal" or .abi == "x86_64")] | length' "$ROOT/apks/lock.json")"
check "... exactly the $want the lock names for x86_64" '[ "$(find "$APKS" -name "*.apk" | wc -l)" = "$want" ]'

printf '\n== the full chain from clean\n'
"$ROOT/emulator/run.sh" restore clean >/dev/null 2>&1 || { echo "could not restore clean"; exit 1; }
sleep 5
dev="$(printf %s "$SERIAL" | tr -c 'A-Za-z0-9_.-' _)"
rm -rf "$ROOT/.provision-state/"{launcher-sha,applied,pending,installed}/"$dev"
t0="$(date +%s)"
PATH="$LEAN" APKS_DIR="$APKS" "$ROOT/provision/run.sh" > "$WORK/run.log" 2>&1
# rc is read by the check strings below, which run through eval.
# shellcheck disable=SC2034
rc=$?
secs=$(( $(date +%s) - t0 ))
check "provision/run.sh succeeds" '[ $rc = 0 ]'
check "no version was left uncompared for want of aapt2" '! grep -q "versions not comparable" "$WORK/run.log"'
check "every installed app matches the locked inventory" 'grep -qE "[0-9]+ app\(s\) match the APK inventory on the host" "$WORK/run.log" && ! grep -q "differ from the host inventory" "$WORK/run.log"'
check "all zones converged and verified" 'grep -q "All profiles converged and verified" "$WORK/run.log"'
check "Andashi Home is the locked build" '[ "$(adb -s "$SERIAL" shell dumpsys package org.andashi.home | tr -d "\r" | sed -n "s/.*versionName=//p" | head -1)" = "$(jq -r ".entries[] | select(.pkg == \"org.andashi.home\") | .version" "$ROOT/apks/lock.json")" ]'

printf '\n  %d ok, %d failed   (chain %ss)\n  logs: %s\n' "$pass" "$fail" "$secs" "$WORK"
[ "$fail" = 0 ]
