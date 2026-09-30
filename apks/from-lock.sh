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
#
# All or nothing. Everything is downloaded into a staging directory first and
# promoted only when every entry is there with the right bytes; a run that
# fails leaves the inventory exactly as it found it. On promotion, any OTHER
# APK in the directories concerned is moved to stale/: apk_for_pkg installs
# the highest version it finds, so a newer file left lying there would be
# installed although the lock never named it.
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

# The selection, read with its status checked before anything is fetched. A
# jq that stopped halfway through a process substitution used to end the loop
# early and still report "0 failed".
sel="$(jq -r --arg abi "$APK_ABI" '
  .entries[] | select(.abi == "universal" or .abi == $abi)
  | if (.urls | type) != "array" or (.urls | length) == 0 or (.file | type) != "string"
       or (.sha256 | type) != "string" then error("malformed entry: \(.pkg // "?")") else . end
  | [.label, .file, .sha256, (.urls | join(" "))] | @tsv' "$LOCK")" \
  || { bad "could not read the entries of $LOCK - nothing fetched"; exit 1; }
[ -n "$sel" ] || { bad "$LOCK names nothing for $APK_ABI - nothing fetched"; exit 1; }

stage="$APKS_DIR/.from-lock.staging"
rm -rf "$stage"; mkdir -p "$stage"
trap 'rm -rf "$stage"' EXIT
fail=0; got=0; had=0; keep=" "; wrong=()
while IFS=$'\t' read -r label file sha urls; do
  keep="$keep$file "
  dest="$APKS_DIR/$file"
  [ -d "$dest" ] && { bad "$label: $dest is a directory - refusing"; fail=$((fail+1)); continue; }
  if [ -f "$dest" ] && [ "$(hash_of "$dest")" = "$sha" ]; then skip "$label (already here)"; had=$((had+1)); continue; fi
  [ -f "$dest" ] && wrong+=("$file")
  mkdir -p "$stage/$(dirname "$file")"
  done_one=0
  for url in $urls; do
    case "$url" in https://*) ;; *) bad "$label: refusing a non-https URL: $url"; continue;; esac
    part="$stage/$file"
    if ! curl -fsSL --retry 2 --max-time 1200 -o "$part" "$url"; then
      rm -f "$part"; bad "$label: $url did not answer"; continue
    fi
    if [ "$(hash_of "$part")" != "$sha" ]; then
      rm -f "$part"; bad "$label: $url served DIFFERENT bytes than the lock names - discarded"; continue
    fi
    ok "$label ($(basename "$file"))"; got=$((got+1)); done_one=1; break
  done
  [ "$done_one" = 1 ] || { bad "$label: no URL served the locked bytes"; fail=$((fail+1)); }
done <<<"$sel"

# The one exception to "left as it was": a file under a locked name whose
# bytes are not the locked ones. Left there, provisioning would install it as
# if it were the locked build. It goes to stale/ whatever else happens.
for file in ${wrong[@]+"${wrong[@]}"}; do
  mkdir -p "$APKS_DIR/stale/$(dirname "$file")"
  mv -f "$APKS_DIR/$file" "$APKS_DIR/stale/$file" \
    && bad "$file had other bytes than the lock names - moved to stale/"
done

if [ "$fail" != 0 ]; then
  log "$got downloaded, $had already here, $fail failed - nothing else in the inventory was changed"
  exit 1
fi

# Promotion. Each move is checked: a move that failed is not a file in place.
while IFS= read -r -d '' f; do
  rel="${f#"$stage"/}"
  mkdir -p "$APKS_DIR/$(dirname "$rel")"
  mv -f -T "$f" "$APKS_DIR/$rel" && [ -f "$APKS_DIR/$rel" ] \
    || { bad "could not put $rel into $APKS_DIR"; exit 1; }
done < <(find "$stage" -type f -name '*.apk' -print0)

# What the lock did not name, in the directories it speaks for, is set aside.
moved=0
for dir in universal "$APK_ABI"; do
  for f in "$APKS_DIR/$dir"/*.apk; do
    [ -e "$f" ] || continue
    case "$keep" in *" $dir/$(basename "$f") "*) continue;; esac
    mkdir -p "$APKS_DIR/stale/$dir"
    mv -f "$f" "$APKS_DIR/stale/$dir/" && moved=$((moved+1))
  done
done
[ "$moved" = 0 ] || log "$moved APK(s) the lock does not name moved to $APKS_DIR/stale/"

log "$got downloaded, $had already here, 0 failed"
