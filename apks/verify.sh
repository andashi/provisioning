#!/usr/bin/env bash
# Verifies all APKs in apks/ against:
#   1. SHA256SUMS          (bit-identity of the file)
#   2. certs/<pkg>.cert    (pinned signer cert fingerprint -> TOFU per app)
# Runs where the binaries are, i.e. locally (`make apks`) - in CI there are none
# and this script would exit 0 without checking anything. Exit != 0 on any mismatch.
set -euo pipefail
cd "$(dirname "$0")"

c(){ [ -t 1 ] && printf '\033[%sm%s\033[0m\n' "$1" "$2" || printf '%s\n' "$2"; }
ok(){ c '1;32' " + $*"; }; bad(){ c '1;31' " x $*" >&2; }; warn(){ c '1;33' " ! $*" >&2; }

command -v apksigner >/dev/null || { bad "apksigner missing"; exit 1; }
shopt -s nullglob
# All ABI subdirectories; the flat layout remains allowed as legacy inventory.
apks=(universal/*.apk arm64-v8a/*.apk x86_64/*.apk *.apk)
if [ ${#apks[@]} -eq 0 ]; then warn "no APKs present - nothing to check"; exit 0; fi

fail=0

# 1) Hashes
if [ -f SHA256SUMS ]; then
  if sha256sum -c SHA256SUMS --quiet; then ok "SHA256SUMS: all hashes match"
  else bad "SHA256SUMS: mismatch"; fail=1; fi
else
  warn "SHA256SUMS missing - generate with ./pin.sh"; fail=1
fi

# 2) Signer certificates
for apk in "${apks[@]}"; do
  pkg="$(aapt2 dump packagename "$apk" 2>/dev/null || true)"
  [ -n "$pkg" ] || { bad "$apk: package name not readable"; fail=1; continue; }
  got="$(apksigner verify --print-certs "$apk" 2>/dev/null | sed -n 's/.*certificate SHA-256 digest: \(.*\)/\1/p' | head -1)"
  [ -n "$got" ] || { bad "$apk: not signed / invalid signature"; fail=1; continue; }
  pin="certs/${pkg}.cert"
  if [ ! -f "$pin" ]; then
    bad "$pkg: no pinned certificate ($pin) - ./pin.sh $apk after manual review"
    fail=1
  elif [ "$(cat "$pin")" = "$got" ]; then
    ok "$pkg: signer cert matches"
  else
    bad "$pkg: SIGNER CHANGED! expected $(cat "$pin"), got $got"
    fail=1
  fi
done

# 3) Is the provenance snapshot still about THESE pins?
# Deliberately offline. provenance.sh downloads ~75 MB of repository indexes and
# needs the network; this check runs in the same second as the rest and answers
# the only question that can be answered locally: does certs/PROVENANCE.tsv
# still describe the pins that are actually here? A pin added or changed after
# the last audit is a trust anchor nobody has ever asked a second party about.
prov="certs/PROVENANCE.tsv"
missing=(); stale=()
if [ ! -f "$prov" ]; then
  warn "certs/PROVENANCE.tsv missing - run ./provenance.sh"
  [ "${PROVENANCE_STRICT:-0}" = "1" ] && fail=1
else
  for cert in certs/*.cert; do
    [ -e "$cert" ] || continue
    p="$(basename "$cert" .cert)"
    awk -F'\t' -v p="$p" '$1==p{found=1} END{exit !found}' "$prov" || missing+=("$p")
    [ "$cert" -nt "$prov" ] && stale+=("$p")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    warn "never audited: ${missing[*]} - run ./provenance.sh"
    [ "${PROVENANCE_STRICT:-0}" = "1" ] && fail=1
  fi
  if [ ${#stale[@]} -gt 0 ]; then
    warn "pinned after the last audit: ${stale[*]} - run ./provenance.sh"
    [ "${PROVENANCE_STRICT:-0}" = "1" ] && fail=1
  fi
  [ ${#missing[@]} -eq 0 ] && [ ${#stale[@]} -eq 0 ] && ok "provenance snapshot covers every pin"
fi

[ "$fail" = "0" ] && ok "all checks passed" || { bad "Verification failed"; exit 1; }
