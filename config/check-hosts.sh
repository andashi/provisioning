#!/usr/bin/env bash
# Every URL a phone is told to fetch must be on a host the distribution chose:
# the lock's own URL and heartbeat, and every download URL in apks/lock.json,
# against allowedHosts in config/distribution.json.
#
# The lock is refreshed every day without a person (AGENTS.md, the one
# exception), and the updater on the phone refuses any host outside the list
# it was given. If that list followed the lock, a lock that gained a host would
# hand it to every phone on the next provisioning run. So the list is the
# decision and the lock is checked against it: a refresh that brings a new
# host fails `make check`, is not committed, and becomes an issue.
#
# A host is compared whole and exactly. A URL whose authority carries a user
# (https://github.com@elsewhere/) or a port is refused outright: the host a
# person reads in it is not the host a client connects to.
set -euo pipefail
cd "$(dirname "$0")"
: "${CONFIG_DIR:=$PWD}"
: "${LOCK:=$PWD/../apks/lock.json}"
DIST="$CONFIG_DIR/distribution.json"

[ -f "$DIST" ] || { echo "check-hosts: $DIST missing" >&2; exit 1; }
[ -f "$LOCK" ] || { echo "check-hosts: $LOCK missing" >&2; exit 1; }

hosts="$(jq -r '.allowedHosts
  | if type != "array" or length == 0 then error("allowedHosts must be a non-empty list") else .[] end
  | if type == "string" and test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")
    then . else error("allowedHosts: \(tojson) is not a plain lower-case host name") end' "$DIST")" \
  || { echo "check-hosts: $DIST: allowedHosts is malformed - see above" >&2; exit 1; }

# A URL with a control character or a space in it is refused before anything
# else: the lines below are split on tabs, and a tab inside a URL would let
# the host check see only the part before it.
weird="$(jq -r '[.lock.url, .lock.heartbeatUrl][] | select(type != "string" or (explode | any(. <= 32 or . == 127)))
                | "  config/distribution.json: a lock URL that is not a plain string: \(tojson)"' "$DIST")
$(jq -r '.entries[] | .file as $f | .urls[] | select(type != "string" or (explode | any(. <= 32 or . == 127)))
                | "  \($f): a URL with a control character or space: \(tojson)"' "$LOCK")" \
  || { echo "check-hosts: could not read the URLs" >&2; exit 1; }
if [ -n "$(tr -d '[:space:]' <<<"$weird")" ]; then
  printf 'URLs a phone could not be held to a host by:\n%s\n' "$weird" >&2
  exit 1
fi

# url<TAB>where, for every URL a phone gets from this distribution.
urls="$( { jq -r '.lock.url, .lock.heartbeatUrl | "\(.)\tconfig/distribution.json"' "$DIST"
           jq -r '.entries[] | .file as $f | .urls[] | "\(.)\t\($f)"' "$LOCK"; } )" \
  || { echo "check-hosts: could not read the URLs" >&2; exit 1; }

bad=""
while IFS=$'\t' read -r url where; do
  case "$url" in
    https://*) ;;
    *) bad="$bad  $where: not https: $url"$'\n'; continue;;
  esac
  auth="${url#https://}"; auth="${auth%%[/?#]*}"
  if [[ "$auth" == *[@:]* ]] || [ -z "$auth" ]; then
    bad="$bad  $where: a user or port in the address: $url"$'\n'; continue
  fi
  grep -qxF "$auth" <<<"$hosts" || bad="$bad  $where: $auth is not in allowedHosts ($url)"$'\n'
done <<<"$urls"

if [ -n "$bad" ]; then
  printf 'URLs outside the hosts this distribution allows:\n%s  add the host to allowedHosts in config/distribution.json, in a pull request, if it belongs there\n' "$bad" >&2
  exit 1
fi
echo "ok: every lock URL is on an allowed host ($(wc -l <<<"$hosts") hosts)"
