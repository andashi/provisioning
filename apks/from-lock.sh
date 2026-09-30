#!/usr/bin/env bash
# Downloads the APKs apks/lock.json names, and keeps only bytes whose SHA-256
# is the one locked.
#
#   apks/from-lock.sh                     ABI of the connected phone, else arm64-v8a
#   APK_ABI=x86_64 apks/from-lock.sh      for the emulator
#   APKS_DIR=~/.cache/andashi/apks apks/from-lock.sh
#
# This is the whole of what a person's machine does to get the apps: curl,
# sha256sum, jq. The package name, the signer and the version were checked on
# the maintainer's machine when the lock was written (apks/lock.sh), and the
# hash carries that result here - a file that hashes right IS the file that
# was checked. Anything else is deleted, never kept "for now": provisioning
# installs whatever lies in the inventory.
#
# Each entry may list more than one URL, because upstreams delete old builds
# (dist.torproject.org keeps a handful; archive.torproject.org keeps all).
# They are tried in order, and each one has to produce the locked bytes.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
LOCK="${LOCK:-$here/lock.json}"
: "${APKS_DIR:=$here}"

c(){ [ -t 1 ] && printf '\033[%sm%s\033[0m\n' "$1" "$2" || printf '%s\n' "$2"; }
ok(){ c '1;32' " + $*"; }; bad(){ c '1;31' " x $*" >&2; }; log(){ c '1;34' ":: $*"; }; skip(){ c '1;30' " = $*"; }

for t in curl sha256sum jq; do command -v "$t" >/dev/null || { bad "$t missing"; exit 1; }; done
[ -f "$LOCK" ] || { bad "no lock at $LOCK"; exit 1; }
jq -e '.lockVersion == 1 and (.entries | type) == "array"' "$LOCK" >/dev/null \
  || { bad "$LOCK is not a lock this script understands"; exit 1; }

if [ -z "${APK_ABI:-}" ]; then
  APK_ABI="$(adb ${ADB_SERIAL:+-s "$ADB_SERIAL"} shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r' || true)"
  : "${APK_ABI:=arm64-v8a}"
fi
case "$APK_ABI" in arm64-v8a|x86_64) ;; *) bad "no builds for ABI $APK_ABI in this lock"; exit 1;; esac
log "APKs for $APK_ABI from $(basename "$LOCK") (generated $(jq -r .generated "$LOCK")) into $APKS_DIR"

hash_of() { sha256sum "$1" | cut -d' ' -f1; }
fail=0; got=0; had=0
while IFS=$'\t' read -r label file sha urls; do
  dest="$APKS_DIR/$file"
  if [ -f "$dest" ] && [ "$(hash_of "$dest")" = "$sha" ]; then skip "$label (already here)"; had=$((had+1)); continue; fi
  mkdir -p "$(dirname "$dest")"
  done_one=0
  for url in $urls; do
    case "$url" in https://*) ;; *) bad "$label: refusing a non-https URL: $url"; continue;; esac
    part="$dest.part"
    if ! curl -fsSL --retry 2 --max-time 1200 -o "$part" "$url"; then
      rm -f "$part"; bad "$label: $url did not answer"; continue
    fi
    if [ "$(hash_of "$part")" != "$sha" ]; then
      rm -f "$part"; bad "$label: $url served DIFFERENT bytes than the lock names - discarded"; continue
    fi
    mv "$part" "$dest"; ok "$label ($(basename "$file"))"; got=$((got+1)); done_one=1; break
  done
  if [ "$done_one" = 0 ]; then
    # A file that was here with the wrong bytes must not stay either.
    [ -f "$dest" ] && rm -f "$dest"
    bad "$label: no URL served the locked bytes - not in the inventory"; fail=$((fail+1))
  fi
done < <(jq -r --arg abi "$APK_ABI" '.entries[] | select(.abi == "universal" or .abi == $abi)
          | [.label, .file, .sha256, (.urls | join(" "))] | @tsv' "$LOCK")

log "$got downloaded, $had already here, $fail failed"
[ "$fail" = 0 ]
