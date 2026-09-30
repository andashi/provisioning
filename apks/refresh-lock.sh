#!/usr/bin/env bash
# Brings apks/lock.json up to what the upstreams publish today: fetch both
# ABIs, verify hashes and signers, write the lock, and say what changed.
#
#   apks/refresh-lock.sh [--summary FILE]
#
# The maintainer's whole routine in one command, and what the scheduled
# workflow runs (.github/workflows/lock-refresh.yml). It changes files in
# apks/ and nothing else; proposing them is the caller's business.
#
# What the summary puts first is what a reviewer has to look at: a signer
# pinned for the first time. fetch.sh pins whatever signs a package it has
# never seen - trust on first use - and on a runner that first use happens
# without anybody watching, so the pull request is where it gets watched.
# A signer that CHANGED is not in the summary: fetch.sh rejects that build
# and fails, and so does this script, before any lock is written.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"

summary=""
while [ $# -gt 0 ]; do
  case "$1" in
    --summary) summary="${2:?--summary needs a file}"; shift 2;;
    *) echo "refresh-lock: unknown argument $1" >&2; exit 2;;
  esac
done

old="$(mktemp)"; trap 'rm -f "$old"' EXIT
if [ -f lock.json ]; then cp lock.json "$old"; else echo '{"entries": []}' > "$old"; fi
certs_before="$(ls certs/ 2>/dev/null | sort)"

# Both ABIs: the lock serves the phone (arm64-v8a) and the emulator (x86_64),
# and universal builds land once, whichever pass meets them first.
# The second pass prunes: older builds leave the inventory (a release_tag pin
# is kept, fetch.sh knows that), so SHA256SUMS lists what the lock can name.
APK_ABI=arm64-v8a ./fetch.sh
APK_ABI=x86_64 ./fetch.sh --prune
./verify.sh
./lock.sh

new_certs="$(comm -13 <(printf '%s\n' "$certs_before") <(ls certs/ | sort) | sed 's/\.cert$//')"
changes="$(jq -r -n --slurpfile o "$old" --slurpfile n lock.json '
  ($o[0].entries | map({key: "\(.pkg) \(.abi)", value: .version}) | from_entries) as $ov
  | $n[0].entries[] | ($ov["\(.pkg) \(.abi)"] // null) as $was
  | select($was != .version)
  | "| \(.label) | \(.abi) | \($was // "new") | \(.version) |"')"
gone="$(jq -r -n --slurpfile o "$old" --slurpfile n lock.json '
  ($n[0].entries | map("\(.pkg) \(.abi)")) as $keep
  | $o[0].entries[] | select(("\(.pkg) \(.abi)") as $k | $keep | index($k) | not)
  | "| \(.label // .pkg) | \(.abi) | \(.version) | removed |"')"

report() {
  echo "Fetched from upstream, verified against the pinned signers, locked (\`apks/refresh-lock.sh\`)."
  echo
  if [ -n "$new_certs" ]; then
    echo "## ⚠ Signers pinned for the first time - review before merging"
    echo
    echo "fetch.sh pinned these on first sight. Compare each fingerprint in \`apks/certs/\` with a second source (\`make provenance\`) before this lock is trusted:"
    echo
    printf '%s\n' "$new_certs" | sed 's/^/- `/; s/$/`/'
    echo
  fi
  if [ -n "$changes$gone" ]; then
    echo "## Versions"
    echo
    echo "| App | ABI | was | now |"
    echo "|---|---|---|---|"
    [ -z "$changes" ] || printf '%s\n' "$changes"
    [ -z "$gone" ] || printf '%s\n' "$gone"
  else
    echo "No version changed; the lock differs only in when it was written."
  fi
}
if [ -n "$summary" ]; then report > "$summary"; fi
report
