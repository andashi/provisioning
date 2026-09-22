#!/usr/bin/env bash
# Pins the signer certificate + hash of an APK (Trust On First Use).
#   ./pin.sh <file.apk> [...]        pin individual APKs
#   ./pin.sh --rehash                 just rewrite SHA256SUMS
#
# Before pinning: check the origin (official repo/release) and, if possible,
# cross-check against AppVerifier or the fingerprint published by upstream.
set -euo pipefail
cd "$(dirname "$0")"

rehash() {
  shopt -s nullglob
  local apks=(universal/*.apk arm64-v8a/*.apk x86_64/*.apk *.apk)
  [ ${#apks[@]} -gt 0 ] || { echo "no APKs"; return 0; }
  sha256sum "${apks[@]}" > SHA256SUMS
  echo "SHA256SUMS: ${#apks[@]} entries"
}

[ "${1:-}" = "--rehash" ] && { rehash; exit 0; }
[ $# -ge 1 ] || { echo "usage: $0 <file.apk> [...] | --rehash" >&2; exit 1; }

mkdir -p certs
for apk in "$@"; do
  pkg="$(aapt2 dump packagename "$apk")"
  cert="$(apksigner verify --print-certs "$apk" | sed -n 's/.*certificate SHA-256 digest: \(.*\)/\1/p' | head -1)"
  [ -n "$cert" ] || { echo "x $apk: no valid signature" >&2; exit 1; }
  if [ -f "certs/$pkg.cert" ] && [ "$(cat "certs/$pkg.cert")" != "$cert" ]; then
    echo "x $pkg: pin already exists with a DIFFERENT cert. Deliberate? Then delete certs/$pkg.cert by hand." >&2
    exit 1
  fi
  printf '%s\n' "$cert" > "certs/$pkg.cert"
  echo " + $pkg pinned: $cert"
done
rehash
