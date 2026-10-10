#!/usr/bin/env bash
# Cases for check-hosts.sh: the real distribution and lock pass, and each way
# a URL could reach a phone from outside the chosen hosts fails.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
fresh() { cp distribution.json "$tmp/"; cp ../apks/lock.json "$tmp/lock.json"; }
t() {   # $1=name $2=expected fragment ("" = must pass)
  local out rc
  out="$(CONFIG_DIR="$tmp" LOCK="$tmp/lock.json" ./check-hosts.sh 2>&1)"; rc=$?
  if [ -z "$2" ]; then
    if [ "$rc" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
    else printf '  FAIL  %s\n        expected a pass, got: %s\n' "$1" "$out"; fail=$((fail+1)); fi
  elif [ "$rc" != 0 ] && printf '%s' "$out" | grep -qF "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n        expected [%s], rc=%s, got: %s\n' "$1" "$2" "$rc" "$out"; fail=$((fail+1)); fi
}
edit() { jq "$2" "$tmp/$1" > "$tmp/$1.new" && mv "$tmp/$1.new" "$tmp/$1"; }
url() { edit lock.json "(.entries[0].urls) = [\"$1\"]"; }

fresh; t "the real distribution and lock pass" ""

fresh; url "https://mirror.example.org/x.apk"
t "a lock URL on a new host" "mirror.example.org is not in allowedHosts"
fresh; edit lock.json '.entries[0].urls += ["https://mirror.example.org/x.apk"]'
t "a second URL on a new host, after an allowed one" "mirror.example.org is not in allowedHosts"
fresh; url "http://github.com/x.apk"
t "plain http" "not https"
fresh; url "https://github.com@mirror.example.org/x.apk"
t "an allowed name as the user part" "a user or port"
fresh; url "https://github.com:8443/x.apk"
t "an allowed host on another port" "a user or port"
fresh; url "https://evilgithub.com/x.apk"
t "a host that only ends like an allowed one" "evilgithub.com is not in allowedHosts"
fresh; url "https://github.com.example.org/x.apk"
t "a host that only starts like an allowed one" "github.com.example.org is not in allowedHosts"
fresh; url "https://GitHub.com/x.apk"
t "a host in other case is not the listed one" "GitHub.com is not in allowedHosts"
fresh; edit distribution.json '.lock.url = "https://lock.example.org/lock.json"'
t "the lock URL itself on a new host" "lock.example.org is not in allowedHosts"
fresh; edit distribution.json '.lock.heartbeatUrl = "http://raw.githubusercontent.com/h.json"'
t "a heartbeat over http" "not https"
fresh; edit lock.json '(.entries[0].urls) = ["https://github.com\t:8443/x.apk"]'
t "a tab in a URL, which would split the host check" "a URL with a control character or space"
fresh; edit lock.json '(.entries[0].urls) = ["https://github.com /x.apk"]'
t "a space in a URL" "a URL with a control character or space"
fresh; edit distribution.json '.lock.url = "https://raw.githubusercontent.com/\n/lock.json"'
t "a newline in the lock URL" "a lock URL that is not a plain string"
fresh; edit distribution.json '.lock = "https://raw.githubusercontent.com/x/lock.json"'
t "a lock that is not an object: refused, not skipped" "could not read the lock URLs"
fresh; edit distribution.json '.allowedHosts += ["*.example.org"]'
t "a wildcard in the list" "is not a plain lower-case host name"
fresh; edit distribution.json '.allowedHosts = []'
t "an empty list" "non-empty list"
fresh; edit distribution.json '.allowedHosts -= ["codeberg.org"]'
t "a host the lock uses taken out of the list" "codeberg.org is not in allowedHosts"

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
