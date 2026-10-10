#!/usr/bin/env bash
# Cases for gen-updater.sh: which apps a zone's updater keeps current, where
# it looks for the lock, and when generation refuses to write anything.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
t() { if eval "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }

fresh() {
  rm -rf "$tmp/c" "$tmp/certs"; mkdir -p "$tmp/c" "$tmp/certs"
  cp distribution.json "$tmp/c/"
  cat > "$tmp/c/profiles.json" <<'JSON'
{"profiles": [
  {"key": "home", "user_id": 0},
  {"key": "work", "type": "managed", "parent": "home"},
  {"key": "anon"},
  {"key": "vault", "feature": "vaults"}
]}
JSON
  cat > "$tmp/c/features.json" <<'JSON'
{"features": {"eid": {"enabled": false}, "vaults": {"enabled": false}}}
JSON
  cat > "$tmp/c/apps.json" <<'JSON'
{"apps": [
  {"id": "upd",  "label": "Updater", "pkg": "org.andashi.updater", "source": "obtainium", "upstream": "https://github.com/andashi/updater", "profiles": ["home", "anon"], "net": true},
  {"id": "tor",  "label": "Tor",     "pkg": "t.tor",  "source": "torproject", "profiles": ["anon"], "net": true},
  {"id": "cam",  "label": "Cam",     "pkg": "c.cam",  "source": "fdroid",     "profiles": ["home"], "net": false},
  {"id": "yub",  "label": "Yub",     "pkg": "y.yub",  "source": "direct",     "profiles": ["home"], "net": false},
  {"id": "play", "label": "Play",    "pkg": "p.play", "source": "play-sandboxed", "profiles": ["home"]},
  {"id": "acc",  "label": "AccApp",  "pkg": "a.acc",  "source": "accrescent", "profiles": ["home"], "net": false},
  {"id": "eid",  "label": "Eid",     "pkg": "e.eid",  "source": "obtainium", "upstream": "https://github.com/o/eid", "profiles": ["home"], "feature": "eid"}
]}
JSON
  for p in org.andashi.updater t.tor c.cam y.yub; do printf '%s\n' "$(printf '%s' "$p" | sha256sum | cut -d' ' -f1)" > "$tmp/certs/$p.cert"; done
  rm -rf "$tmp/out"
}
gen() { CONFIG_DIR="$tmp/c" CERTS_DIR="$tmp/certs" OUT_DIR="$tmp/out" ./gen-updater.sh > "$tmp/log" 2>&1; }
q() { jq -r "$2" "$tmp/out/$1.json"; }

fresh; gen
t "generates"                                           '[ $? = 0 ]'
t "one file per non-managed zone whose feature is on"   '[ "$(ls "$tmp/out" | tr "\n" " ")" = "anon.json home.json " ]'
t "managed: the lock-covered sources, sorted by pkg"   '[ "$(q home "[.managed[].pkg] | join(\" \")")" = "c.cam org.andashi.updater y.yub" ]'
t "Play and Accrescent apps are not the updater's"     '! q home ".managed[].pkg" | grep -qE "p.play|a.acc"'
t "an app whose feature is off is not managed"          '! q home ".managed[].pkg" | grep -q e.eid'
t "the updater manages itself, in each of its zones"   'q anon ".managed[].pkg" | grep -qx org.andashi.updater'
t "each managed app carries its pinned signer"          '[ "$(q home ".managed[] | select(.pkg == \"y.yub\") | .signer")" = "$(cat "$tmp/certs/y.yub.cert")" ]'
t "netFalse: every net:false app of the zone, any source" '[ "$(q home ".checks.netFalse | join(\" \")")" = "a.acc c.cam y.yub" ]'
t "lock URL and hosts come from distribution.json"     '[ "$(q anon .lock.url)" = "$(jq -r .lock.url distribution.json)" ] && [ "$(q anon ".lock.allowedHosts | length")" = "$(jq ".allowedHosts | length" distribution.json)" ]'
t "schema 1, mode fetch, zone named"                    '[ "$(q anon "[.schemaVersion, .lock.mode, .zone] | join(\" \")")" = "1 fetch anon" ]'

fresh; jq '.lock.url = "https://raw.githubusercontent.com/someone/fork/main/apks/lock.json"' "$tmp/c/distribution.json" > "$tmp/d" && mv "$tmp/d" "$tmp/c/distribution.json"; gen
t "a fork's lock URL reaches every zone"                '[ "$(q home .lock.url)" = "https://raw.githubusercontent.com/someone/fork/main/apks/lock.json" ]'

fresh; gen; rm "$tmp/certs/y.yub.cert"; cp "$tmp/out/home.json" "$tmp/before"; gen
t "a managed app without a pin: refused"                '[ $? != 0 ] && grep -q "Yub (y.yub) is managed in home but has no pinned signer" "$tmp/log"'
t "... and nothing is rewritten"                        'cmp -s "$tmp/before" "$tmp/out/home.json"'

fresh; gen; jq '(.features.vaults.enabled) = true' "$tmp/c/features.json" > "$tmp/f" && mv "$tmp/f" "$tmp/c/features.json"; gen
t "a zone whose feature is switched on gets its file"   '[ -f "$tmp/out/vault.json" ]'
jq '(.features.vaults.enabled) = false' "$tmp/c/features.json" > "$tmp/f" && mv "$tmp/f" "$tmp/c/features.json"; gen
t "... and loses it when the feature goes off again"    '[ $? = 0 ] && [ ! -f "$tmp/out/vault.json" ]'

fresh; jq '.features.vaults.enabled = "false"' "$tmp/c/features.json" > "$tmp/f" && mv "$tmp/f" "$tmp/c/features.json"; gen
t "an enabled that is a string, not a boolean: refused" '[ $? != 0 ] && grep -q "vaults.enabled is neither true nor false" "$tmp/log"'
fresh; jq '.features.eid.enabled = null' "$tmp/c/features.json" > "$tmp/f" && mv "$tmp/f" "$tmp/c/features.json"; gen
t "a missing enabled on an app's feature: refused, not off" '[ $? != 0 ] && grep -q "eid.enabled is neither true nor false" "$tmp/log"'

fresh; jq 'del(.allowedHosts)' "$tmp/c/distribution.json" > "$tmp/d" && mv "$tmp/d" "$tmp/c/distribution.json"; gen
t "a distribution without allowedHosts: refused, never copied as null" '[ $? != 0 ] && grep -q "lacks a valid allowedHosts" "$tmp/log" && [ -z "$(ls "$tmp/out" 2>/dev/null)" ]'
fresh; jq '.lock.url = "http://raw.githubusercontent.com/x/lock.json"' "$tmp/c/distribution.json" > "$tmp/d" && mv "$tmp/d" "$tmp/c/distribution.json"; gen
t "a lock URL over http: refused"                       '[ $? != 0 ] && grep -q "lacks a valid" "$tmp/log"'
fresh; jq '.lock.url = "https://lock.example.org/andashi/lock.json"' "$tmp/c/distribution.json" > "$tmp/d" && mv "$tmp/d" "$tmp/c/distribution.json"; gen
t "a fork's lock on a host it did not allow: refused, not written for the phone to reject" '[ $? != 0 ] && grep -q "on an allowed host" "$tmp/log"'
fresh; jq '.lock.url = "https://lock.example.org/andashi/lock.json" | .allowedHosts += ["lock.example.org"]' "$tmp/c/distribution.json" > "$tmp/d" && mv "$tmp/d" "$tmp/c/distribution.json"; gen
t "... and accepted once the host is on the list" '[ $? = 0 ] && [ "$(jq -r .lock.url "$tmp/out/home.json")" = "https://lock.example.org/andashi/lock.json" ]'
fresh; jq '.lock.heartbeatUrl = "https://raw.githubusercontent.com:8443/h.json"' "$tmp/c/distribution.json" > "$tmp/d" && mv "$tmp/d" "$tmp/c/distribution.json"; gen
t "a heartbeat with a port: refused" '[ $? != 0 ]'

fresh; : > "$tmp/certs/y.yub.cert"; gen
t "an empty pin file: refused, not passed on as signer \"\"" '[ $? != 0 ] && grep -q "y.yub.cert is not a SHA-256 fingerprint" "$tmp/log"'
fresh; gen; jq '.profiles |= map(.type = "managed")' "$tmp/c/profiles.json" > "$tmp/p" && mv "$tmp/p" "$tmp/c/profiles.json"; gen
t "no zone left to configure: succeeds, and the old files go" '[ $? = 0 ] && [ -z "$(ls "$tmp/out")" ]'

fresh; jq '.apps[0].feature = "nope"' "$tmp/c/apps.json" > "$tmp/a" && mv "$tmp/a" "$tmp/c/apps.json"; gen
t "an unknown feature in the catalog: refused"          '[ $? != 0 ] && grep -q "unknown feature" "$tmp/log"'

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
