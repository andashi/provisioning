#!/usr/bin/env bash
# Cases for check-lock.sh: the real lock passes, and each way a lock can stop
# describing the inventory fails - by the smallest edit that causes it.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
fresh() { rm -rf "${tmp:?}"/*; cp lock.json SHA256SUMS "$tmp/"; cp -r certs "$tmp/certs"; cp ../config/apps.json "$tmp/apps.json"; }
t() {   # $1=name $2=expected fragment ("" = must pass)
  local out rc
  out="$(LOCK="$tmp/lock.json" SUMS="$tmp/SHA256SUMS" CERTS="$tmp/certs" CAT="$tmp/apps.json" ./check-lock.sh 2>&1)"; rc=$?
  if [ -z "$2" ]; then
    if [ "$rc" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n        %s\n' "$1" "$out"; fail=$((fail+1)); fi
  elif [ "$rc" != 0 ] && printf '%s' "$out" | grep -qF -- "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n        expected [%s], rc=%s: %s\n' "$1" "$2" "$rc" "$out"; fail=$((fail+1)); fi
}
lk() { jq "$1" "$tmp/lock.json" > "$tmp/l" && mv "$tmp/l" "$tmp/lock.json"; }
H='select(.pkg == "org.andashi.home")'

fresh; t "the real lock passes" ""
fresh; lk "(.entries[] | $H | .sha256) = \"0000\""
t "a hash that is not the inventory's" "lock says 0000"
fresh; lk "(.entries[] | $H | .signer) = \"ffff\""
t "a signer that is not the pinned one" "not the one pinned"
fresh; lk "(.entries[] | $H | .urls) = [\"http://example.org/a.apk\"]"
t "a URL that is not https" "a URL that is not https"
fresh; lk "(.entries[] | $H | .urls) = []"
t "an entry without a URL" "no URL"
fresh; lk "del(.entries[] | $H)"
t "a pinned app missing from the lock" "org.andashi.home (universal): provisioning would install universal/org.andashi.home-0.12.0.apk, the lock has nothing"
fresh; printf '%s  universal/org.andashi.home-0.13.0.apk\n' "$(printf %064d 1)" >> "$tmp/SHA256SUMS"
t "fetch.sh brought a newer build, the lock was not renewed" "provisioning would install universal/org.andashi.home-0.13.0.apk"
fresh; jq '(.apps[] | select(.pkg == "org.andashi.home") | .release_tag) = "v0.11.0"' "$tmp/apps.json" > "$tmp/a" && mv "$tmp/a" "$tmp/apps.json"
t "a release_tag pin decides which file belongs in the lock" "provisioning would install universal/org.andashi.home-0.11.0.apk"
fresh; jq 'del(.apps[] | select(.pkg == "org.andashi.home"))' "$tmp/apps.json" > "$tmp/a" && mv "$tmp/a" "$tmp/apps.json"
t "an entry for a package the catalog dropped" "org.andashi.home is not in the catalog"
fresh; lk "(.entries[] | $H) |= del(.versionCode)"
t "an entry without a versionCode" "no versionCode"

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
