#!/usr/bin/env bash
# Cases for gen-obtainium.sh: what Obtainium is offered to track, with and
# without the andashi updater in the catalog.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
t() { if eval "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }
gen() { OUT="$tmp/out.json" CONFIG_DIR="$tmp/c" ./gen-obtainium.sh > "$tmp/log" 2>&1; }
fresh() { rm -rf "$tmp/c"; mkdir -p "$tmp/c"; cp apps.json profiles.json "$tmp/c/"; }
q() { jq -r "$1" "$tmp/out.json"; }

fresh; gen
t "without the updater: every lock-covered app is offered" '[ $? = 0 ] && [ "$(q ".apps | length")" = "$(jq "[.apps[] | select((.source == \"obtainium\" and (.upstream // \"\") != \"\") or .source == \"fdroid\" or .source == \"torproject\" or .source == \"direct\")] | length" apps.json)" ]'
t "a direct app is tracked on its vendor directory" '[ "$(q ".apps[] | select(.id == \"com.yubico.yubioath\") | .url")" = "https://developers.yubico.com/yubioath-flutter/Releases/" ]'
t "... with a filter that keeps the desktop builds out" 'q ".apps[] | select(.id == \"com.yubico.yubioath\") | .additionalSettings" | jq -e ".apkFilterRegEx == \"^yubico-authenticator-.+-android\\\\.apk$\"" >/dev/null'
t "Play apps are never offered"                     '! q ".apps[].id" | grep -qx com.microsoft.teams'

upd() {   # $1 = the updater's zones as a JSON list
  jq --argjson z "$1" '.apps += [{"id": "updater", "label": "Andashi Updater", "pkg": "org.andashi.updater", "role": "updater", "source": "obtainium", "upstream": "https://github.com/andashi/updater", "profiles": $z}]' \
    "$tmp/c/apps.json" > "$tmp/a" && mv "$tmp/a" "$tmp/c/apps.json"
}
fresh; upd '["home","cloud","gadgets","ops","lab","anon"]'; gen
t "with the updater in every zone: nothing is offered, and it says why" '[ $? = 0 ] && [ "$(q ".apps | length")" = 0 ] && grep -q "left out on purpose" "$tmp/log"'
fresh; upd '["home","cloud","gadgets","ops","lab"]'; gen
t "an updater missing from Anon: the apps only Anon holds stay offered" '[ "$(q "[.apps[].id] | sort | join(\" \")")" = "$(jq -r "[.apps[] | select(.profiles == [\"anon\"]) | select(.source == \"obtainium\" or .source == \"fdroid\" or .source == \"torproject\" or .source == \"direct\") | .pkg] | sort | join(\" \")" apps.json)" ] && [ "$(q ".apps | length")" -gt 0 ]'
t "... and an app Anon shares with a covered zone is left out: its code is updated there" '! q ".apps[].id" | grep -qx org.andashi.home'
fresh; upd '["home","cloud","gadgets","ops","lab","anon"]'
jq '.apps += [{"id": "w", "label": "WorkOnly", "pkg": "w.only", "source": "obtainium", "upstream": "https://github.com/o/w", "profiles": ["work"]}]' "$tmp/c/apps.json" > "$tmp/a" && mv "$tmp/a" "$tmp/c/apps.json"; gen
t "an app only a managed profile holds: no updater runs there, so it stays offered" '[ "$(q "[.apps[].id] | join(\" \")")" = w.only ]'

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
