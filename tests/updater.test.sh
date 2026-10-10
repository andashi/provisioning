#!/usr/bin/env bash
# Cases for the updater on the device (lib/updater.sh) and the install paths
# of 10-apps.sh that name it: installed first and twice, its own installer of
# record, exempt from battery restrictions, allowed to install and notify in
# each zone - every setting read back - and every install naming a user.
#
# Offline: adb is tests/fixtures/fake-pm, a package manager that behaves as
# the real one was measured to, including the trap that started this: an
# install without --user lands in every user. ensure_pinned_version and
# user_holding are taken from 10-apps.sh itself.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
t() { if eval "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
      else printf '  FAIL  %s\n' "$1"; sed 's/^/        | /' "$tmp/out" 2>/dev/null; fail=$((fail+1)); fi; }

mkdir -p "$tmp/bin"; ln -s "$root/tests/fixtures/fake-aapt2" "$tmp/bin/aapt2"
export PATH="$tmp/bin:$PATH" ADB="$root/tests/fixtures/fake-pm" ADB_SERIAL=fake FAKE_DEV="$tmp/dev"
export CONFIG_DIR="$tmp/config" APKS_DIR="$tmp/apks" DRY_RUN=0

U=org.andashi.updater
apk() { printf 'vc=%s\npkg=%s\n' "$3" "$1" > "$APKS_DIR/universal/$1-$2.apk"; }
fresh() {   # $1 = catalog with ("with") or without ("without") the updater
  rm -rf "$tmp/dev" "$CONFIG_DIR" "$APKS_DIR"
  mkdir -p "$tmp/dev/pkg" "$tmp/dev/appops" "$tmp/dev/grants" "$CONFIG_DIR" "$APKS_DIR/universal"
  printf '0\n10\n15\n' > "$tmp/dev/users"; : > "$tmp/dev/log"
  local upd=""
  [ "${1:-with}" = with ] && upd='{"id": "updater", "label": "Andashi Updater", "pkg": "'$U'", "role": "updater", "source": "obtainium", "profiles": ["home", "anon"]},'
  cat > "$CONFIG_DIR/apps.json" <<JSON
{"apps": [ $upd
  {"id": "tor",  "label": "Tor",  "pkg": "t.tor",  "source": "torproject", "profiles": ["anon"]},
  {"id": "play", "label": "Play", "pkg": "p.play", "source": "play-sandboxed", "profiles": ["home"]}
]}
JSON
  cat > "$CONFIG_DIR/profiles.json" <<'JSON'
{"profiles": [
  {"key": "home", "label": "Home", "create": false, "user_id": 0},
  {"key": "work", "label": "U10", "type": "managed"},
  {"key": "anon", "label": "U15"}
]}
JSON
  echo '{"features": {}}' > "$CONFIG_DIR/features.json"
  apk "$U" 1.0 10; apk t.tor 15.0 150; apk p.play 1.0 1
}
# The device as it is: put a package there directly.
dev_has() {   # $1=pkg $2=vc $3=installer $4..=users
  local p="$1" vc="$2" inst="$3"; shift 3
  mkdir -p "$tmp/dev/pkg/$p"; printf '%s\n' "$@" > "$tmp/dev/pkg/$p/users"
  echo "$vc" > "$tmp/dev/pkg/$p/vc"; echo "$inst" > "$tmp/dev/pkg/$p/installer"
}
inst() { cat "$tmp/dev/pkg/$1/installer"; }
users() { sort -n "$tmp/dev/pkg/$1/users" | tr '\n' ' '; }
installs() { grep -c '^install ' "$tmp/dev/log"; }
# Runs bash code with the libraries loaded, in a subshell, because die exits.
run() {
  ( source "$root/lib/common.sh"; source "$root/lib/updater.sh"
    eval "$(sed -n '/^ensure_pinned_version() {/,/^}/p; /^user_holding() {/,/^}/p' "$root/provision/10-apps.sh")"
    declare -A _PIN_CHECKED=(); UPDATER_FAILED=()
    eval "$1"; rc=$?
    printf 'ARGS=%s\nFAILED=%s\n' "${INSTALLER_ARGS[*]:-}" "${#UPDATER_FAILED[@]}"
    exit $rc ) > "$tmp/out" 2>&1
}

echo "the device"
fresh without; run ensure_updater_device
t "no updater in the catalog: nothing happens, nothing named" '[ $? = 0 ] && [ ! -s "$tmp/dev/log" ] && grep -qx "ARGS=" "$tmp/out"'

fresh; run ensure_updater_device
t "fresh device: installed, then installed again naming itself" '[ $? = 0 ] && [ "$(installs)" = 2 ] && grep -q "^install -r --user 0 " "$tmp/dev/log" && grep -q "^install -r -i $U --user 0 " "$tmp/dev/log"'
t "... it is its own installer of record"         '[ "$(inst $U)" = "$U" ]'
t "... only in user 0, not spread"                '[ "$(users $U)" = "0 " ]'
t "... exempt from the device-idle allowlist"     'grep -q "^user,$U," "$tmp/dev/idle"'
t "... and later installs name it"                'grep -qx "ARGS=-i $U" "$tmp/out"'

fresh; dev_has "$U" 10 "$U" 0; echo "user,$U,10201" > "$tmp/dev/idle"; run ensure_updater_device
t "already in place: nothing is changed"          '[ $? = 0 ] && [ ! -s "$tmp/dev/log" ]'

fresh; dev_has "$U" 10 null 0; echo "user,$U,10201" > "$tmp/dev/idle"; run ensure_updater_device
t "installer stripped by a shell install: one reinstall with -i" '[ $? = 0 ] && [ "$(installs)" = 1 ] && [ "$(inst $U)" = "$U" ]'

fresh; dev_has "$U" 12 null 0; run ensure_updater_device
t "device runs a newer updater than the host has: refused, says why" '[ $? != 0 ] && grep -q "newer build" "$tmp/out"'

fresh; rm "$APKS_DIR/universal/$U-1.0.apk"; run ensure_updater_device
t "no APK for the updater: refused, nothing installed" '[ $? != 0 ] && grep -q "no APK" "$tmp/out" && [ "$(installs)" = 0 ]'

fresh; FAKE_IDLE_NOOP=1 run ensure_updater_device
t "an allowlist entry that does not read back: refused" '[ $? != 0 ] && grep -q "does not list it" "$tmp/out"'

fresh; DRY_RUN=1 run ensure_updater_device
t "dry run on a fresh device: says install and allowlist, changes nothing" '[ $? = 0 ] && [ ! -s "$tmp/dev/log" ] && grep -q "dry-run\] updater: install" "$tmp/out" && grep -q "deviceidle whitelist" "$tmp/out"'
fresh; dev_has "$U" 10 "$U" 0; echo "user,$U,10201" > "$tmp/dev/idle"; DRY_RUN=1 run ensure_updater_device
t "dry run on a converged device: says nothing"       '[ $? = 0 ] && ! grep -q "dry-run" "$tmp/out"'
fresh; rm "$APKS_DIR/universal/$U-1.0.apk"; DRY_RUN=1 run ensure_updater_device
t "dry run without the APK: refused all the same"     '[ $? != 0 ] && grep -q "no APK" "$tmp/out"'
fresh; dev_has "$U" 10 "$U" 0; DRY_RUN=1 run 'ensure_updater_zone 15 Anon'
t "dry run for a zone: names the three missing steps, changes nothing" '[ ! -s "$tmp/dev/log" ] && [ "$(grep -c "dry-run\] Anon" "$tmp/out")" = 3 ]'
fresh; jq '.apps += [.apps[0] | .pkg = "org.other.updater" | .id = "u2"]' "$CONFIG_DIR/apps.json" > "$tmp/a" && mv "$tmp/a" "$CONFIG_DIR/apps.json"; run true
t "two apps with role updater: refused before anything" '[ $? != 0 ] && grep -q "more than one app with role updater" "$tmp/out" && [ ! -s "$tmp/dev/log" ]'

echo "a zone"
fresh; dev_has "$U" 10 "$U" 0; run 'ensure_updater_zone 15 Anon'
t "the updater carried into the zone, installer kept" '[ $? = 0 ] && [ "$(users $U)" = "0 15 " ] && [ "$(inst $U)" = "$U" ]'
t "... allowed to install, read back"             'grep -q "^$U REQUEST_INSTALL_PACKAGES allow" "$tmp/dev/appops/15"'
t "... allowed to notify, read back"              'grep -q "^$U android.permission.POST_NOTIFICATIONS" "$tmp/dev/grants/15"'
fresh; dev_has "$U" 10 "$U" 0; FAKE_GRANT_NOOP=1 run 'ensure_updater_zone 15 Anon'
t "a grant that exits 0 and does not take: reported, not ok" '[ $? != 0 ] && grep -q "POST_NOTIFICATIONS did not read back" "$tmp/out" && ! grep -q "may install and notify" "$tmp/out"'
fresh; run 'ensure_updater_zone 15 Anon'
t "no updater on the device at all: refused for the zone" '[ $? != 0 ] && grep -q "install-existing" "$tmp/out"'

echo "the apps"
fresh; dev_has "$U" 10 "$U" 0 15; dev_has t.tor 140 null 15; echo "user,$U,10201" > "$tmp/dev/idle"
run 'ensure_updater_device; ensure_pinned_version t.tor Tor torproject'
t "an upgrade names a user that holds the app"   '[ $? = 0 ] && grep -q "^install -i $U --user 15 -r " "$tmp/dev/log"'
t "... and the app stays in that zone only"      '[ "$(users t.tor)" = "15 " ]'
t "... at the new version, the updater's"        '[ "$(cat "$tmp/dev/pkg/t.tor/vc")" = 150 ] && [ "$(inst t.tor)" = "$U" ]'

fresh; dev_has "$U" 10 "$U" 0 15; dev_has t.tor 150 null 15; echo "user,$U,10201" > "$tmp/dev/idle"
run 'ensure_updater_device; ensure_pinned_version t.tor Tor torproject'
t "the right build without the updater as installer: handed over" '[ $? = 0 ] && grep -q "handed to the updater (installer was null)" "$tmp/out" && [ "$(inst t.tor)" = "$U" ] && [ "$(users t.tor)" = "15 " ]'

fresh; dev_has "$U" 10 "$U" 0 15; dev_has t.tor 150 dev.imranr.obtainium 15; echo "user,$U,10201" > "$tmp/dev/idle"
run 'ensure_updater_device; ensure_pinned_version t.tor Tor torproject'
t "an app Obtainium took over is handed back"    '[ "$(inst t.tor)" = "$U" ]'

fresh; dev_has "$U" 10 "$U" 0 15; dev_has t.tor 150 null 10 15; echo "user,$U,10201" > "$tmp/dev/idle"
run 'ensure_updater_device; ensure_pinned_version t.tor Tor torproject'
t "handed over through a zone where the updater runs, not the first holder" '[ "$(inst t.tor)" = "$U" ] && grep -q -- "--user 15 " "$tmp/dev/log" && [ "$(users t.tor)" = "10 15 " ]'

fresh; dev_has "$U" 10 "$U" 0; dev_has t.tor 160 "$U" 15; echo "user,$U,10201" > "$tmp/dev/idle"
run 'ensure_updater_device; ensure_pinned_version t.tor Tor torproject'
t "the updater ran an app past the host: nothing to say, nothing done" '[ $? = 0 ] && ! grep -q "Tor" "$tmp/out" && [ "$(installs)" = 0 ]'

fresh; dev_has "$U" 10 "$U" 0; dev_has t.tor 150 null 10 15; echo "user,$U,10201" > "$tmp/dev/idle"
run 'ensure_updater_device; ensure_updater_in_zones; ensure_pinned_version t.tor Tor torproject'
t "the updater reaches all its zones before any app: a hand-over through any of them takes" \
  '[ $? = 0 ] && [ "$(users $U)" = "0 15 " ] && [ "$(inst t.tor)" = "$U" ] && ! grep -q "pm install-existing --user 10 $U" "$tmp/dev/log"'

fresh; dev_has "$U" 10 "$U" 0 15; dev_has t.tor 150 null 10; echo "user,$U,10201" > "$tmp/dev/idle"
run 'ensure_updater_device; ensure_pinned_version t.tor Tor torproject'
t "an app only a zone without the updater holds: said, not failed, nothing installed" '[ $? = 0 ] && grep -q "no zone that holds it runs the updater" "$tmp/out" && grep -qx "FAILED=0" "$tmp/out" && [ "$(installs)" = 0 ]'

fresh; dev_has p.play 1 com.android.vending 0
run 'ensure_updater_device; ensure_pinned_version p.play Play play-sandboxed'
t "a Play app is never taken from Play"          '[ "$(inst p.play)" = com.android.vending ] && ! grep -q "p.play" "$tmp/dev/log"'

fresh; dev_has "$U" 10 "$U" 0; dev_has t.tor 160 null 15; echo "user,$U,10201" > "$tmp/dev/idle"
run 'ensure_updater_device; ensure_pinned_version t.tor Tor torproject'
t "device ahead of the host, installer stripped: said, not failed" '[ $? = 0 ] && grep -q "handed to the updater once the host has build 160" "$tmp/out" && grep -qx "FAILED=0" "$tmp/out" && [ "$(installs)" = 0 ]'

fresh without; dev_has t.tor 140 null 15
run 'ensure_updater_device; ensure_pinned_version t.tor Tor torproject'
t "no updater: the upgrade names no installer, but still a user" '[ $? = 0 ] && grep -q "^install --user 15 -r " "$tmp/dev/log" && [ "$(users t.tor)" = "15 " ]'

t "no install anywhere in 10-apps.sh or 00-profiles.sh without --user" \
  '! grep -nE "adb_ install" "$root/provision/10-apps.sh" "$root/provision/00-profiles.sh" | grep -v -- "--user"'

echo "what the updater says"
fresh; run 'updater_state 15'
t "a zone without the updater is not asked: no provider of that name is trusted" '[ $? != 0 ] && ! grep -q "unexpected" "$tmp/out"'
st='{"apps":[{"pkg":"a\u001b[2Jx","state":"failed","error":"bad\u001b]0;x\u0007"},{"pkg":"b","state":"current"}],"lock":{"generated":"2026-10-09T11:56:22Z","freshness":"fresh","lastError":"e\u001b[31m"},"exemption":"granted"}'
fresh; run "updater_summary <<<'$st'; updater_attention <<<'$st'"
t "control characters from the phone never reach the terminal" '! grep -q $'"'"'\x1b\|\x07'"'"' "$tmp/out" && grep -q "a?\[2Jx failed" "$tmp/out"'
t "the summary groups fine, pending and attention"  'grep -q "^1 current, 1 FAILED | lock 2026-10-09 (fresh) ERROR" "$tmp/out"'

st='{"apps":[{"pkg":"b","state":"current"}],"lock":{"generated":"2026-10-09T11:56:22Z","freshness":"fresh"},"exemption":"granted","foreign":[{"pkg":"m.teams","installer":"com.android.vending"},{"pkg":"s.side","installer":null},{"pkg":"o.obt","installer":"dev.imranr.obtainium"},{"pkg":"a.ver","installer":"app.accrescent.client"}]}'
fresh; run "updater_summary <<<'$st'; updater_attention <<<'$st'"
t "foreign apps counted by who keeps them current"   'grep -q "foreign 4: 1 Accrescent, 1 Obtainium, 1 Play, 1 nobody" "$tmp/out"'
t "one that nobody updates is named"                 'grep -q "^s.side FOREIGN, installed by nobody" "$tmp/out"'
t "... and one under Obtainium too, which updates only what it tracks" 'grep -q "^o.obt FOREIGN, installer dev.imranr.obtainium" "$tmp/out"'
t "a store app is not called a problem"              '! grep -q "^m.teams\|^a.ver" "$tmp/out"'
st2='{"apps":[],"lock":{},"exemption":"granted","foreign":[{"pkg":"t.tor","installer":"'$U'"}]}'
fresh; run "updater_summary <<<'$st2'; updater_attention <<<'$st2'"
t "an app the updater keeps current from another zone is not a problem" 'grep -q "foreign 1: 1 the updater, from another zone" "$tmp/out" && ! grep -q "^t.tor FOREIGN" "$tmp/out"'

echo "who is managed"
fresh; run 'ensure_updater_device; for s in obtainium fdroid torproject direct play-sandboxed accrescent system manual; do updater_manages $s && printf "%s " $s; done; echo'
t "the lock-covered sources, once the updater runs" 'grep -qx "obtainium fdroid torproject direct " "$tmp/out"'
fresh without; run 'for s in obtainium fdroid; do updater_manages $s && printf "%s " $s; done; echo "|"'
t "nothing, while there is no updater"           'grep -qx "|" "$tmp/out"'

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
