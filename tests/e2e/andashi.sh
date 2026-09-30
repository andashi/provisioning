#!/usr/bin/env bash
# End-to-end cases for bin/andashi against an emulator instance.
#
#   SERIAL=emulator-5562 OVERLAY_DIR=$PWD/emulator/instances/test-fold-gpu \
#   SNAPSHOT=provisioned-0120 LOCK_OWNER=<yours> tests/e2e/andashi.sh
#
# Needs a running instance at a provisioned snapshot, and the device lock held
# by LOCK_OWNER (AGENTS.md). Restores SNAPSHOT before it starts, so it begins
# from a known phone; leaves the instance at whatever the last case produced.
# Every adb call runs as `shell`, and that is asserted after the restore
# (tests/e2e/identity.sh): a snapshot can carry a root adbd.
#
# It works on a COPY of config/ (a private catalog, as a person would have),
# so adopting edits from the phone has somewhere to write and the template is
# never touched. Wallpaper files it creates live under .provision-state/, which
# is inside the repository root (where theming.json paths resolve) and ignored.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${SERIAL:?SERIAL=emulator-NNNN}" "${OVERLAY_DIR:?OVERLAY_DIR=...}" "${SNAPSHOT:?SNAPSHOT=<provisioned snapshot>}"
export ADB_SERIAL="$SERIAL" SERIAL OVERLAY_DIR
A() { adb -s "$SERIAL" "$@"; }
PKG=org.andashi.home

pass=0; fail=0; FAILED=()
ok()   { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); FAILED+=("$1"); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
section() { printf '\n== %s\n' "$*"; }
# Numbers compare as numbers: the launcher serves 12 back as 12.0.
num() { [ -n "$1" ] && [ -n "$2" ] && jq -en --argjson a "$1" --argjson b "$2" '$a == $b' >/dev/null 2>&1; }

WORK="$ROOT/.provision-state/e2e-andashi"
rm -rf "$WORK"; mkdir -p "$WORK"
export CONFIG_DIR="$WORK/config"
cp -r "$ROOT/config" "$CONFIG_DIR"
rm -f "$CONFIG_DIR/launcher/.generated.sha256"
LOG="$WORK/log"; mkdir -p "$LOG"
andashi() { "$ROOT/bin/andashi" "$@"; }
run() {   # $1=name, rest=command; output to $LOG/<name>, exit code in $RC, seconds in $SECS
  local name="$1"; shift
  local t0; t0="$(date +%s.%N)"
  "$@" > "$LOG/$name" 2>&1; RC=$?
  SECS="$(printf '%.1f' "$(echo "$(date +%s.%N) - $t0" | bc)")"
  printf '  ..    %s: exit %s in %ss\n' "$name" "$RC" "$SECS"
}
tj() {   # $1=zone key, $2=jq assignment on theming.json
  jq --indent 2 --arg z "$1" "$2" "$CONFIG_DIR/theming.json" > "$CONFIG_DIR/theming.json.new" \
    && mv "$CONFIG_DIR/theming.json.new" "$CONFIG_DIR/theming.json"
}
eff() {   # $1=uid $2=jq path -> value from the launcher's effective config
  # The row is multi-line JSON after "Row: 0 json=": cut at the FIRST brace of
  # the whole output, the way query_state does - never per line.
  local out; out="$(A shell content query --user "$1" --uri "content://$PKG.state/config" 2>/dev/null | tr -d '\r')"
  case "$out" in *\{*) printf '{%s' "${out#*\{}" | jq -r "$2" 2>/dev/null;; esac
}
foreground_home() {
  A shell am switch-user 0 >/dev/null 2>&1; sleep 4
  A shell input keyevent KEYCODE_WAKEUP; A shell input swipe 540 1800 540 600 200; sleep 2
  A shell input keyevent KEYCODE_HOME; sleep 2
}

section "setup: $SNAPSHOT on $SERIAL"
"$ROOT/emulator/run.sh" restore "$SNAPSHOT" >/dev/null 2>&1 || { echo "could not restore $SNAPSHOT"; exit 1; }
sleep 5
# shellcheck source=identity.sh
source "$ROOT/tests/e2e/identity.sh"; as_shell
# The host's records describe the phone as the LAST run left it, and a restored
# snapshot is a different phone under the same serial. Kept, they make every
# guard in the chain see edits nobody made (the first run of this file found
# exactly that). So they go with the restore.
dev="$(printf %s "$SERIAL" | tr -c 'A-Za-z0-9_.-' _)"
rm -rf "$ROOT/.provision-state/launcher-sha/$dev" "$ROOT/.provision-state/applied/$dev" \
       "$ROOT/.provision-state/pending/$dev" "$ROOT/.provision-state/installed/$dev"
foreground_home
check "home is the current user" '[ "$(A shell am get-current-user | tr -d "\r")" = 0 ]'
check "launcher 0.12.0 or later installed" \
  '[ "$(printf "0.12.0\n%s\n" "$(A shell dumpsys package $PKG | sed -n "s/.*versionName=//p" | head -1 | tr -d "\r")" | sort -V | head -1)" = 0.12.0 ]'

# The state a full run leaves: launcher records agreed with the device, and an
# applied record per zone. One full run from the provisioned snapshot writes
# both, through the same code a person's run uses.
run full-run "$ROOT/provision/run.sh"
check "a full run records what it installed, per zone" '[ -s "$ROOT/.provision-state/installed/$dev/home" ]'
check "a full run records what it applied, per zone" \
  '[ $RC = 0 ] && [ "$(ls "$ROOT/.provision-state/applied/$dev/" | wc -l)" -ge 6 ]'
FULL_SECS="$SECS"

section "nothing changed"
run diff-clean andashi diff
check "diff on a converged phone: nothing to do, exit 0" '[ $RC = 0 ] && grep -q "nothing to do" "$LOG/diff-clean"'
run apply-clean andashi apply
check "apply with nothing changed does nothing" '[ $RC = 0 ] && grep -q "nothing changed since the last apply" "$LOG/apply-clean"'
check "... and starts no zone" '! grep -q "started" "$LOG/apply-clean"'

section "the loop: one glass value in the zone you are looking at"
tj home '.per_profile[$z].glass = ((.per_profile[$z].glass // {}) + {tint: 0.3})'
run diff-tint andashi diff
check "diff names home, exit 1" '[ $RC = 1 ] && grep -q "^home" "$LOG/diff-tint"'
check "diff names no other zone" '[ "$(grep -cE "^(cloud|gadgets|ops|lab|anon|work)$" "$LOG/diff-tint")" = 0 ]'
run apply-tint andashi apply --zone current
check "apply --zone current converges" '[ $RC = 0 ] && grep -q "Home: effective config verified" "$LOG/apply-tint"'
check "only the theme and launcher steps ran" \
  '! grep -qE "===== (00|10|20|30|35|90|99)-" "$LOG/apply-tint" && grep -q "===== 45-launcher-config (home)" "$LOG/apply-tint"'
check "the wallpaper was not uploaded again" 'grep -q "wallpaper unchanged" "$LOG/apply-tint"'
check "the device serves tint 0.3" 'num "$(eff 0 .appearance.glass.tint)" 0.3'
TINT_SECS="$SECS"
run diff-after-tint andashi diff
check "diff afterwards: nothing to do" '[ $RC = 0 ]'

section "--only applies part of a change, and the rest stays outstanding"
tj home '.per_profile[$z].glass.tint = 0.35 | .per_profile[$z].style = "TONAL_SPOT"'
run apply-only andashi apply --zone home --only launcher
check "--only launcher runs only the launcher step" '[ $RC = 0 ] && ! grep -q "===== 40-theming" "$LOG/apply-only"'
run diff-after-only andashi diff --zone home
check "... and the theme is still reported as changed" '[ $RC = 1 ] && grep -q "inputs changed: .*theme" "$LOG/diff-after-only"'
tj home '.per_profile[$z] |= del(.style)'
run apply-rest andashi apply --zone home
check "a plain apply afterwards settles it" '[ $RC = 0 ]'
run diff-settled andashi diff --zone home
check "... and nothing is outstanding" '[ $RC = 0 ]'

section "new bytes under the same wallpaper name"
mkdir -p "$ROOT/.provision-state/e2e-andashi/wp/tall" "$ROOT/.provision-state/e2e-andashi/wp/square"
for a in tall square; do cp "$ROOT/themes/synthwave/$a/lab.jpg" "$ROOT/.provision-state/e2e-andashi/wp/$a/home.jpg"; done
tj home '.per_profile[$z].wallpaper = ".provision-state/e2e-andashi/wp/{aspect}/home.jpg"'
run apply-wp1 andashi apply --zone home
check "a new wallpaper path applies" '[ $RC = 0 ] && grep -q "wallpaper uploaded (home.jpg" "$LOG/apply-wp1"'
for a in tall square; do cp "$ROOT/themes/synthwave/$a/ops.jpg" "$ROOT/.provision-state/e2e-andashi/wp/$a/home.jpg"; done
run diff-wp2 andashi diff
check "diff sees new bytes under the old name" '[ $RC = 1 ] && grep -A2 "^home" "$LOG/diff-wp2" | grep -q launcher'
run apply-wp2 andashi apply --zone home
check "... and apply uploads them" '[ $RC = 0 ] && grep -q "wallpaper uploaded (home.jpg" "$LOG/apply-wp2"'
check "... and the device converged on them" 'grep -q "Home: effective config verified" "$LOG/apply-wp2"'

section "a stopped zone"
ops_uid="$(A shell pm list users | tr -d '\r' | sed -n 's/.*UserInfo{\([0-9]*\):Ops:.*/\1/p')"
A shell am stop-user -w -f "$ops_uid" >/dev/null 2>&1
tj ops '.per_profile[$z].glass = ((.per_profile[$z].glass // {}) + {tint: 0.25})'
run apply-ops andashi apply
check "apply without --all does not start Ops" '[ $RC = 0 ] && users="$(A shell pm list users | tr -d "\r")" && ! grep -q "{$ops_uid:Ops:.*running" <<<"$users"'
check "... and says the change waits" 'grep -q "Ops: stopped - the change stays pending" "$LOG/apply-ops"'
run status-ops andashi status
check "status names what Ops owes" 'grep -E "^ops " "$LOG/status-ops" | grep -q "pending: .*launcher"'
run apply-ops-all andashi apply --zone ops --all
check "apply --zone ops --all delivers it" '[ $RC = 0 ] && grep -q "Ops: effective config verified" "$LOG/apply-ops-all"'
check "... and the device serves it" 'num "$(eff "$ops_uid" .appearance.glass.tint)" 0.25'
check "... and nothing is pending any more" '! andashi status 2>/dev/null | grep -E "^ops " | grep -q pending'

section "an edit made on the phone is adopted, not overwritten"
# What edit mode does, without the UI: the launcher's file changes on the
# device. The ingest provider takes the file the way the launcher's own
# write-back would leave it.
eff 0 . | jq '.appearance.glass.radius = 12' > "$WORK/device-edit.json"
check "the simulated phone edit is a real document" 'num "$(jq -r .appearance.glass.radius "$WORK/device-edit.json")" 12'
A shell "content write --user 0 --uri content://$PKG.config-ingest/launcher.json" < "$WORK/device-edit.json"
A shell am broadcast -a "$PKG.action.RELOAD_CONFIG" -n "$PKG/de.mm20.launcher2.config.service.ReloadConfigReceiver" --user 0 >/dev/null
sleep 4
run diff-edit andashi diff
check "diff says home was edited on the phone" 'grep -A3 "^home" "$LOG/diff-edit" | grep -q "edited on the phone"'
cp "$CONFIG_DIR/theming.json" "$WORK/theming.before-dry"
run apply-edit-dry andashi apply --zone home --dry-run
check "a dry run does not adopt it" 'diff -q "$WORK/theming.before-dry" "$CONFIG_DIR/theming.json" >/dev/null && grep -q "would adopt" "$LOG/apply-edit-dry"'
run apply-edit andashi apply --zone home
check "apply notices it with nothing changed on the host" 'grep -q "^:: home: launcher" "$LOG/apply-edit"'
check "apply adopts it into the catalog" '[ $RC = 0 ] && num "$(jq -r .per_profile.home.glass.radius "$CONFIG_DIR/theming.json")" 12'
check "... keeps the host's own earlier change" 'num "$(jq -r .per_profile.home.glass.tint "$CONFIG_DIR/theming.json")" 0.35'
check "... and the phone still has it" 'num "$(eff 0 .appearance.glass.radius)" 12'

section "both sides changed: that zone stops, the others go on"
eff 0 . | jq '.appearance.glass.blur = 8' > "$WORK/device-edit2.json"
check "the second phone edit is a real document" 'num "$(jq -r .appearance.glass.blur "$WORK/device-edit2.json")" 8'
A shell "content write --user 0 --uri content://$PKG.config-ingest/launcher.json" < "$WORK/device-edit2.json"
A shell am broadcast -a "$PKG.action.RELOAD_CONFIG" -n "$PKG/de.mm20.launcher2.config.service.ReloadConfigReceiver" --user 0 >/dev/null
sleep 4
tj home '.per_profile[$z].glass.blur = 40'
cloud_uid="$(A shell pm list users | tr -d '\r' | sed -n 's/.*UserInfo{\([0-9]*\):Cloud:.*/\1/p')"
# Running on purpose: "the others go on" is about a zone that can be pushed,
# and the --all start of Ops above may have evicted Cloud.
A shell am start-user -w "$cloud_uid" >/dev/null 2>&1
tj cloud '.per_profile[$z].glass = ((.per_profile[$z].glass // {}) + {tint: 0.2})'
run apply-conflict andashi apply --zone home,cloud
check "apply exits 1 and names the conflict" '[ $RC = 1 ] && grep -q "home: changed on the phone AND here" "$LOG/apply-conflict"'
check "... names what differs" 'grep -q "home: they differ in:" "$LOG/apply-conflict"'
check "... and no step touches home" '! grep -qE "===== [0-9]+-[a-z-]+ \\([^)]*home" "$LOG/apply-conflict"'
check "... leaves the phone's value in home" 'num "$(eff 0 .appearance.glass.blur)" 8'
check "... and still applies cloud" 'grep -q "Cloud: effective config verified" "$LOG/apply-conflict" && num "$(eff "$cloud_uid" .appearance.glass.tint)" 0.2'

section "favourites rearranged on the phone survive apply and regeneration"
# The conflict above left home disagreeing on blur. Take the phone's side the
# way that message says, and apply, so this case starts from agreement and
# the adoption below is apply's doing, not pull's.
tj home '.per_profile[$z].glass |= del(.blur)'
run pull-home andashi pull --zone home
run agree-home andashi apply --zone home
check "home agrees again after the conflict" '[ $RC = 0 ] && num "$(eff 0 .appearance.glass.blur)" 8'
eff 0 . | jq '.home.favorites |= reverse' > "$WORK/device-favs.json"
check "the simulated reorder is a real document" '[ "$(jq -r ".home.favorites[0].packageName" "$WORK/device-favs.json")" = app.vanadium.browser ]'
A shell "content write --user 0 --uri content://$PKG.config-ingest/launcher.json" < "$WORK/device-favs.json"
A shell am broadcast -a "$PKG.action.RELOAD_CONFIG" -n "$PKG/de.mm20.launcher2.config.service.ReloadConfigReceiver" --user 0 >/dev/null
sleep 4
run apply-favs andashi apply --zone home
check "apply adopts the order into the catalog" '[ $RC = 0 ] && [ "$(jq -r ".per_profile.home.favorites[0]" "$CONFIG_DIR/theming.json")" = Vanadium ]'
OUT_DIR="$CONFIG_DIR/launcher" "$ROOT/config/gen-launcher.sh" >/dev/null 2>&1
check "... and a regeneration keeps it" '[ "$(jq -r ".home.favorites[0].packageName // .home.favorites[0]" "$CONFIG_DIR/launcher/home.json")" = app.vanadium.browser ]'
check "... and the phone still shows it" '[ "$(eff 0 ".home.favorites[0].packageName")" = app.vanadium.browser ]'

section "apps: added, taken out, and somebody's own"
lab_uid="$(A shell pm list users | tr -d '\r' | sed -n 's/.*UserInfo{\([0-9]*\):Lab:.*/\1/p')"
# Collect, then match. `grep -q` in a pipeline under pipefail exits at the
# first match, adb dies of SIGPIPE, and the match reads as a miss - which
# turns every "is not installed" check here into a pass (lib/common.sh).
# And a failed query is neither answer: `pkg_state` prints yes or no only for
# a list it read, and nothing otherwise - so after a failed query both
# inlab and notinlab are false, and a check that relied on either fails
# instead of passing on an empty list.
pkg_state() { local out; out="$(A shell pm list packages --user "$1" | tr -d '\r')" && [ -n "$out" ] \
                || { echo "e2e: could not list packages of user $1" >&2; return 1; }
              case $'\n'"$out"$'\n' in *$'\n'"package:$2"$'\n'*) echo yes;; *) echo no;; esac; }
inlab()     { [ "$(pkg_state "$lab_uid" "$1")" = yes ]; }
inhome()    { [ "$(pkg_state 0 "$1")" = yes ]; }
notinlab()  { [ "$(pkg_state "$lab_uid" "$1")" = no ]; }
notinhome() { [ "$(pkg_state 0 "$1")" = no ]; }
run app-add andashi app add tubular --zone lab
check "app add edits the catalog, no phone involved" '[ $RC = 0 ] && jq -e ".apps[] | select(.id == \"tubular\") | .profiles | index(\"lab\")" "$CONFIG_DIR/apps.json" >/dev/null'
run diff-add andashi diff --zone lab
check "diff names it" '[ $RC = 1 ] && grep -q "inputs changed: .*apps" "$LOG/diff-add"'
run apply-add andashi apply --zone lab
check "apply installs it in Lab" '[ $RC = 0 ] && inlab org.polymorphicshade.tubular'
run app-rm andashi app rm opencamera --zone home
run diff-rm andashi diff --zone home
check "diff says it will be removed" 'grep -q "apps to remove (no longer in the catalog): net.sourceforge.opencamera" "$LOG/diff-rm" || grep -q "inputs changed: .*apps" "$LOG/diff-rm"'
run apply-rm andashi apply --zone home
check "apply removes it from Home" '[ $RC = 0 ] && notinhome net.sourceforge.opencamera && grep -q "net.sourceforge.opencamera removed - no longer in the catalog for Home" "$LOG/apply-rm"'
A shell pm install-existing --user "$lab_uid" im.molly.app >/dev/null 2>&1
check "an app installed by hand in Lab" 'inlab im.molly.app'
run diff-foreign andashi diff --zone lab
check "diff names it as not in the catalog" 'grep -q "not in the catalog, kept: .*im.molly.app" "$LOG/diff-foreign"'
check "... without calling that a to-do" '[ $RC = 0 ]'
run apply-foreign andashi apply --zone lab --only apps
check "apply keeps it" '[ $RC = 0 ] && inlab im.molly.app'
run diff-prune andashi diff --zone lab --prune-undeclared
check "diff --prune-undeclared previews the removal, exit 1" '[ $RC = 1 ] && grep -q "apps to remove (--prune-undeclared): .*im.molly.app" "$LOG/diff-prune"'
run apply-prune andashi apply --zone lab --prune-undeclared
check "--prune-undeclared removes it, and says so" '[ $RC = 0 ] && notinlab im.molly.app && grep -q "im.molly.app removed - not in the catalog for Lab" "$LOG/apply-prune"'

section "an unreadable catalog removes nothing"
cp "$CONFIG_DIR/apps.json" "$WORK/apps.good"
printf '{ broken' > "$CONFIG_DIR/apps.json"
run apps-broken env ZONES=lab "$ROOT/provision/10-apps.sh"
check "the apps step stops" '[ $RC != 0 ] && grep -q "could not read" "$LOG/apps-broken"'
check "... and Lab still has everything the chain put there" 'inlab org.polymorphicshade.tubular && inlab helium314.keyboard'
cp "$WORK/apps.good" "$CONFIG_DIR/apps.json"

section "watch: save, and the zone in front follows"
foreground_home
"$ROOT/bin/andashi" watch > "$LOG/watch" 2>&1 &
wpid=$!
sleep 4
tj home '.per_profile[$z].glass.tint = 0.45'
# Wait for the apply that watch started to finish, not for the phone to show
# the value: the value arrives before the read-back that proves it.
for _ in $(seq 1 60); do grep -qE "applied in|apply finished" "$LOG/watch" && break; sleep 1; done
check "a saved change reaches the phone without an apply" 'num "$(eff 0 .appearance.glass.tint)" 0.45'
kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
check "... through apply --zone current" 'grep -q "Home: effective config verified" "$LOG/watch"'

section "the template cannot adopt"
run template-pull env CONFIG_DIR="$ROOT/config" "$ROOT/bin/andashi" pull
check "pull into the template refuses" '[ $RC != 0 ] && grep -q "template" "$LOG/template-pull"'

section "selection mistakes refuse"
run typo andashi status --zone lap
check "an unknown zone refuses" '[ $RC != 0 ] && grep -q "not a zone" "$LOG/typo"'
run only-typo andashi apply --only themes
check "an unknown section refuses" '[ $RC != 0 ] && grep -q "not a section" "$LOG/only-typo"'

check "adbd still ran as shell at the end" '[ "$(adb -s "$SERIAL" shell id -u | tr -d "\r")" = 2000 ]'

printf '\n  %d ok, %d failed   (full run %ss, one-zone glass change %ss)\n' "$pass" "$fail" "$FULL_SECS" "$TINT_SECS"
printf '  logs: %s\n' "$LOG"
[ "$fail" = 0 ]
