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
# The inventory, and the three tools, can be pointed elsewhere - which is what
# tests/refresh-lock.test.sh does with fakes. By default: this directory and
# the scripts beside it.
# fetch.sh and verify.sh always work in their own directory, so another
# inventory with the real tools would be fetched and verified in one place and
# locked in the other. That combination is refused rather than half-honoured.
if [ -n "${APKS_DIR:-}" ] && [ "$(cd "$APKS_DIR" 2>/dev/null && pwd)" != "$here" ] \
   && { [ -z "${FETCH:-}" ] || [ -z "${VERIFY:-}" ]; }; then
  echo "refresh-lock: APKS_DIR points elsewhere, but fetch.sh and verify.sh only work in $here - refusing" >&2
  exit 2
fi
cd "${APKS_DIR:-$here}"
FETCH="${FETCH:-$here/fetch.sh}"; VERIFY="${VERIFY:-$here/verify.sh}"; LOCKER="${LOCKER:-$here/lock.sh}"

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
APK_ABI=arm64-v8a "$FETCH"
APK_ABI=x86_64 "$FETCH" --prune
"$VERIFY"
"$LOCKER"

new_certs="$(comm -13 <(printf '%s\n' "$certs_before") <(ls certs/ | sort) | sed 's/\.cert$//')"
changes="$(jq -r -n --slurpfile o "$old" --slurpfile n lock.json '
  ($o[0].entries | map({key: "\(.pkg) \(.abi)", value: .version}) | from_entries) as $ov
  | $n[0].entries[] | ($ov["\(.pkg) \(.abi)"] // null) as $was
  | select($was != .version)
  | "| \(.label) | \(.abi) | \($was // "new") | \(.version) |"')"
# Same version, other bytes: an upstream rebuild, or a re-signed build. Rare,
# and exactly what a reviewer must not miss, so it gets its own rows - the
# version table alone would show nothing at all for it.
rebuilt="$(jq -r -n --slurpfile o "$old" --slurpfile n lock.json '
  ($o[0].entries | map({key: "\(.pkg) \(.abi)", value: .}) | from_entries) as $ov
  | $n[0].entries[] | ($ov["\(.pkg) \(.abi)"] // null) as $was
  | select($was != null and $was.version == .version and ($was.sha256 != .sha256 or $was.urls != .urls))
  | "| \(.label) | \(.abi) | \(.version) | \(if $was.sha256 != .sha256 then "same version, OTHER BYTES" else "other URLs" end) |"')"
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
  if [ -n "$rebuilt" ]; then
    echo "## Same version, changed entry - look at these"
    echo
    echo "| App | ABI | version | what changed |"
    echo "|---|---|---|---|"
    printf '%s\n' "$rebuilt"
    echo
  fi
  if [ -n "$changes$gone" ]; then
    echo "## Versions"
    echo
    echo "| App | ABI | was | now |"
    echo "|---|---|---|---|"
    [ -z "$changes" ] || printf '%s\n' "$changes"
    [ -z "$gone" ] || printf '%s\n' "$gone"
  elif [ -z "$rebuilt$new_certs" ]; then
    # lock.sh leaves an unchanged lock alone, so there is nothing to propose.
    echo "The lock did not change."
  fi
}
if [ -n "$summary" ]; then report > "$summary"; fi
report
