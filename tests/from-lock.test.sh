#!/usr/bin/env bash
# Cases for apks/from-lock.sh, the whole of what a person's machine does to get
# the apps. It may keep exactly one kind of file - bytes that hash to what the
# lock names - so the cases are mostly about everything else: bytes that
# differ, a mirror that is gone, a file already lying there with the wrong
# content, a URL that is not https. curl is replaced by a fake that serves
# fixture files, so none of this needs a network.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/serve"
ln -s "$root/tests/fixtures/fake-curl" "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH" FAKE_CURL_DIR="$tmp/serve" APK_ABI=x86_64
pass=0; fail=0
t() { if eval "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }

printf 'good bytes' > "$tmp/serve/good.apk";  good="$(sha256sum < "$tmp/serve/good.apk" | cut -d' ' -f1)"
printf 'evil bytes' > "$tmp/serve/evil.apk"
entry() {   # $1=label $2=abi $3=file $4=sha, rest=urls
  local l="$1" a="$2" f="$3" s="$4"; shift 4
  jq -n --arg l "$l" --arg a "$a" --arg f "$f" --arg s "$s" --args \
    '{pkg: $l, label: $l, version: "1", abi: $a, file: $f, sha256: $s, size: 10, signer: "x", urls: $ARGS.positional}' "$@"
}
lock() { jq -s '{lockVersion: 1, generated: "t", entries: .}' > "$tmp/lock.json"; }
fl() { LOCK="$tmp/lock.json" APKS_DIR="$tmp/apks" "$root/apks/from-lock.sh" > "$tmp/out" 2>&1; }

entry ok universal universal/a-1.apk "$good" https://x/good.apk | lock
rm -rf "$tmp/apks"; mkdir -p "$tmp/apks"; fl
t "locked bytes are kept"                 '[ $? = 0 ] && [ -f "$tmp/apks/universal/a-1.apk" ]'
fl
t "a second run leaves them alone"        '[ $? = 0 ] && grep -q "already here" "$tmp/out"'

entry bad universal universal/a-1.apk "$good" https://x/evil.apk | lock
rm -rf "$tmp/apks"; mkdir -p "$tmp/apks"; fl
t "different bytes are refused, exit 1"   '[ $? != 0 ] && grep -q "DIFFERENT bytes" "$tmp/out"'
t "... and nothing is kept"               '[ -z "$(find "$tmp/apks" -type f)" ]'

entry fb universal universal/a-1.apk "$good" https://x/gone.apk https://x/evil.apk https://x/good.apk | lock
rm -rf "$tmp/apks"; mkdir -p "$tmp/apks"; fl
t "a dead mirror and a bad one, then the right one" '[ $? = 0 ] && [ "$(sha256sum < "$tmp/apks/universal/a-1.apk" | cut -d" " -f1)" = "$good" ]'

entry stale universal universal/a-1.apk "$good" https://x/gone.apk | lock
rm -rf "$tmp/apks"; mkdir -p "$tmp/apks/universal"; printf 'old' > "$tmp/apks/universal/a-1.apk"; fl
t "a file already there with the wrong bytes, nothing serves the right ones: set aside" '[ $? != 0 ] && [ ! -e "$tmp/apks/universal/a-1.apk" ] && [ -f "$tmp/apks/stale/universal/a-1.apk" ]'

entry http universal universal/a-1.apk "$good" http://x/good.apk | lock
rm -rf "$tmp/apks"; mkdir -p "$tmp/apks"; fl
t "a non-https URL is refused"            '[ $? != 0 ] && grep -q "non-https" "$tmp/out" && [ ! -e "$tmp/apks/universal/a-1.apk" ]'

{ entry u universal universal/u-1.apk "$good" https://x/good.apk
  entry x x86_64 x86_64/x-1.apk "$good" https://x/good.apk
  entry a arm64-v8a arm64-v8a/a-1.apk "$good" https://x/good.apk; } | lock
rm -rf "$tmp/apks"; mkdir -p "$tmp/apks"; fl
t "universal and the phone's ABI, not the other one" '[ -f "$tmp/apks/universal/u-1.apk" ] && [ -f "$tmp/apks/x86_64/x-1.apk" ] && [ ! -e "$tmp/apks/arm64-v8a/a-1.apk" ]'

# All or nothing: one entry that cannot be had leaves the other one out too.
{ entry g universal universal/g-1.apk "$good" https://x/good.apk
  entry n universal universal/n-1.apk "$good" https://x/gone.apk; } | lock
rm -rf "$tmp/apks"; mkdir -p "$tmp/apks"; fl
t "one entry fails: the others are not promoted either" '[ $? != 0 ] && [ ! -e "$tmp/apks/universal/g-1.apk" ] && [ -z "$(find "$tmp/apks" -maxdepth 1 -name ".from-lock.*")" ]'

# A newer build lying in the inventory would win in apk_for_pkg.
entry g universal universal/g-1.apk "$good" https://x/good.apk | lock
rm -rf "$tmp/apks"; mkdir -p "$tmp/apks/universal"; printf 'newer' > "$tmp/apks/universal/g-2.apk"; fl
t "an APK the lock does not name is set aside"   '[ $? = 0 ] && [ ! -e "$tmp/apks/universal/g-2.apk" ] && [ -f "$tmp/apks/stale/universal/g-2.apk" ]'
t "... and the locked one is in place"           '[ -f "$tmp/apks/universal/g-1.apk" ]'

entry d universal universal/d-1.apk "$good" https://x/good.apk | lock
rm -rf "$tmp/apks"; mkdir -p "$tmp/apks/universal/d-1.apk"; fl
t "a directory where the file belongs is refused" '[ $? != 0 ] && grep -q "is a directory" "$tmp/out"'

entry m universal universal/m-1.apk "$good" https://x/good.apk | jq '.urls = null' | lock
rm -rf "$tmp/apks"; mkdir -p "$tmp/apks"; fl
t "a malformed entry stops everything before any download" '[ $? != 0 ] && grep -q "could not read the entries" "$tmp/out" && [ -z "$(find "$tmp/apks" -type f)" ]'

entry g universal universal/g-1.apk "$good" https://x/good.apk | lock
rm -rf "$tmp/apks"; mkdir -p "$tmp/apks/universal" "$tmp/apks/stale/universal"; printf 'newer' > "$tmp/apks/universal/g-2.apk"
chmod a-w "$tmp/apks/stale/universal"; fl
# rc is read by the check string, which runs through eval.
# shellcheck disable=SC2034
rc=$?
chmod u+w "$tmp/apks/stale/universal"
t "an APK that cannot be set aside fails the run" '[ $rc != 0 ] && grep -q "could not set universal/g-2.apk aside" "$tmp/out"'
t "... and the locked file it had promoted is taken back" '[ ! -e "$tmp/apks/universal/g-1.apk" ] && [ -f "$tmp/apks/universal/g-2.apk" ]'

# A promotion that fails halfway undoes the half.
{ entry u universal universal/u-1.apk "$good" https://x/good.apk
  entry x x86_64 x86_64/x-1.apk "$good" https://x/good.apk; } | lock
rm -rf "$tmp/apks"; mkdir -p "$tmp/apks/universal" "$tmp/apks/x86_64"; chmod a-w "$tmp/apks/x86_64"; fl
# shellcheck disable=SC2034
rc=$?
chmod u+w "$tmp/apks/x86_64"
t "a promotion that fails halfway is undone"   '[ $rc != 0 ] && grep -q "undoing" "$tmp/out" && [ ! -e "$tmp/apks/universal/u-1.apk" ] && [ ! -e "$tmp/apks/x86_64/x-1.apk" ]'

entry g universal universal/g-1.apk "$good" https://x/good.apk | lock
rm -rf "$tmp/apks"; mkdir -p "$tmp/apks/.from-lock.lock"; fl
t "a second run on the same inventory is refused" '[ $? != 0 ] && grep -q "another from-lock.sh is working" "$tmp/out" && [ ! -e "$tmp/apks/universal/g-1.apk" ]'
t "... and does not remove the other run's lock"  '[ -d "$tmp/apks/.from-lock.lock" ]'

printf '{"entries": []}' > "$tmp/lock.json"; fl
t "a file that is not a lock is refused"  '[ $? != 0 ] && grep -q "not a lock" "$tmp/out"'

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
