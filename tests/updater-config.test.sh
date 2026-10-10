#!/usr/bin/env bash
# Cases for provision/50-updater-config.sh, run whole against
# tests/fixtures/fake-pm: when a zone's updater counts as holding its config,
# and every way it does not - a refusal, a write that never loaded, an old
# report mistaken for the new one, a stopped, locked or missing zone.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
dev=fake-updater-config
cleanup() { rm -rf "$tmp" "$root/.provision-state/updater/$dev" "$root/.provision-state/pending/$dev"; }
trap cleanup EXIT; cleanup; mkdir -p "$tmp"
pass=0; fail=0
t() { if eval "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
      else printf '  FAIL  %s\n' "$1"; sed 's/^/        | /' "$tmp/out"; fail=$((fail+1)); fi; }

export ADB="$root/tests/fixtures/fake-pm" ADB_SERIAL="$dev" FAKE_DEV="$tmp/dev" CONFIG_DIR="$tmp/config" UPDATER_POLL=0 DRY_RUN=0
U=org.andashi.updater
fresh() {
  rm -rf "$tmp/dev" "$CONFIG_DIR" "$root/.provision-state/updater/$dev" "$root/.provision-state/pending/$dev"
  mkdir -p "$tmp/dev/pkg" "$CONFIG_DIR/updater"
  printf '0\n10\n15\n' > "$tmp/dev/users"; : > "$tmp/dev/log"; : > "$tmp/dev/running"
  cat > "$CONFIG_DIR/profiles.json" <<'JSON'
{"profiles": [
  {"key": "home", "label": "Home", "create": false, "user_id": 0},
  {"key": "work", "label": "U10", "type": "managed"},
  {"key": "anon", "label": "U15"}
]}
JSON
  echo '{"features": {}}' > "$CONFIG_DIR/features.json"
  echo '{"apps": [{"id": "updater", "label": "Andashi Updater", "pkg": "'$U'", "role": "updater", "source": "obtainium", "profiles": ["home", "anon"]}]}' > "$CONFIG_DIR/apps.json"
  for z in home anon; do echo "{\"zone\": \"$z\"}" > "$CONFIG_DIR/updater/$z.json"; done
  mkdir -p "$tmp/dev/pkg/$U"; printf '0\n15\n' > "$tmp/dev/pkg/$U/users"; echo 1 > "$tmp/dev/pkg/$U/vc"; echo "$U" > "$tmp/dev/pkg/$U/installer"
}
run() { "$root/provision/50-updater-config.sh" > "$tmp/out" 2>&1; }
sha() { sha256sum "$CONFIG_DIR/updater/$1.json" | cut -d' ' -f1; }
writes() { grep -c "^content write" "$tmp/dev/log"; }

fresh; echo 15 >> "$tmp/dev/running"; run
t "both zones take their config: success"            '[ $? = 0 ] && grep -q "every running zone" "$tmp/out" && [ "$(writes)" = 2 ]'
t "... and each gets CHECK_NOW"                      '[ "$(grep -c "am broadcast --user .* -a $U.action.CHECK_NOW" "$tmp/dev/log")" = 2 ]'
t "... and the host records what each holds"         '[ "$(cat "$root/.provision-state/updater/$dev/anon")" = "$(sha anon)" ]'
run
t "again: already held, nothing written"             '[ $? = 0 ] && [ "$(writes)" = 2 ] && grep -q "already holds this config" "$tmp/out"'

fresh; echo 15 >> "$tmp/dev/running"; FAKE_INGEST=refuse run
t "a refused config: the step fails with the updater's reason" '[ $? != 0 ] && grep -q "refused the config: bad config" "$tmp/out"'
t "... and nothing is recorded as held"              '[ ! -f "$root/.provision-state/updater/$dev/anon" ]'

fresh; echo 15 >> "$tmp/dev/running"; FAKE_INGEST=ignore run
t "a write that never loaded: fails, names the hash it got" '[ $? != 0 ] && grep -q "did not load this file" "$tmp/out"'

fresh; echo 15 >> "$tmp/dev/running"; mkdir -p "$tmp/dev/diag"
echo '{"configSha256":"old","success":false,"error":"an earlier refusal","at":"t0"}' > "$tmp/dev/diag/15"
FAKE_DIAG_LAG=1 run
t "an earlier refusal still on show after the write is not this file's" '[ $? = 0 ] && ! grep -q "earlier refusal" "$tmp/out" && grep -q "U15: config loaded" "$tmp/out"'

fresh; run
t "a stopped zone is started to take a new config"   '[ $? = 0 ] && grep -q "am start-user -w 15" "$tmp/dev/log"'
run_stop() { : > "$tmp/dev/running"; }
run_stop; : > "$tmp/dev/log"; run
t "a stopped zone whose config did not change stays stopped" '[ $? = 0 ] && ! grep -q "start-user" "$tmp/dev/log" && grep -q "unchanged since the last push - not started" "$tmp/out"'
fresh; NO_START=1 run
t "NO_START: a stopped zone's change is left pending on the host" '[ $? = 0 ] && ! grep -q "start-user" "$tmp/dev/log" && grep -qx "anon updater" "$root/.provision-state/pending/$dev"'
fresh; DRY_RUN=1 run
t "dry run: says it would start and write, does neither, claims nothing" '[ $? = 0 ] && ! grep -q "start-user\|content write" "$tmp/dev/log" && grep -q "dry-run\] am start-user -w 15" "$tmp/out" && ! grep -q "started (had been evicted)" "$tmp/out"'

fresh; echo 15 >> "$tmp/dev/running"; echo 15 > "$tmp/dev/locked"; run
t "a locked zone: fails, says unlock it"             '[ $? != 0 ] && grep -q "U15: profile locked" "$tmp/out"'
fresh; echo 15 >> "$tmp/dev/running"; echo 0 > "$tmp/dev/pkg/$U/users"; run
t "the updater missing in a zone: fails, says run 10-apps" '[ $? != 0 ] && grep -q "not installed (user 15)" "$tmp/out"'
fresh; echo 15 >> "$tmp/dev/running"; rm "$CONFIG_DIR/updater/anon.json"; run
t "a zone without a generated config: fails, says generate" '[ $? != 0 ] && grep -q "run config/gen-updater.sh" "$tmp/out"'
fresh; jq '.apps = []' "$CONFIG_DIR/apps.json" > "$tmp/a" && mv "$tmp/a" "$CONFIG_DIR/apps.json"; run
t "no updater in the catalog: nothing to do, success" '[ $? = 0 ] && grep -q "nothing to configure" "$tmp/out" && [ ! -s "$tmp/dev/log" ]'

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
