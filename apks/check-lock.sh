#!/usr/bin/env bash
# Does apks/lock.json still describe this inventory? Offline, so CI can ask it:
# everything it compares is checked in (SHA256SUMS, certs/, the catalog), and
# none of it needs the binaries.
#
#   - every entry's hash is the one SHA256SUMS records for that file, and its
#     signer the one pinned in certs/
#   - every URL is https, every entry has one, every package is in the catalog
#   - per package and ABI directory, the lock holds the file provisioning
#     would install (release_tag, else the highest version SHA256SUMS lists).
#     A fetch.sh that brought a newer build without a new lock fails here, not
#     on somebody's first install, where the old one would quietly go on.
#   - every pinned app has at least one entry
#
# Cases: check-lock.test.sh.
set -euo pipefail
cd "$(dirname "$0")"
: "${LOCK:=lock.json}" "${SUMS:=SHA256SUMS}" "${CERTS:=certs}" "${CAT:=../config/apps.json}"
[ -f "$LOCK" ] || { echo "check-lock: no $LOCK - run apks/lock.sh" >&2; exit 1; }
jq -e '.lockVersion == 1 and (.entries | type) == "array"' "$LOCK" >/dev/null \
  || { echo "check-lock: $LOCK is not a version-1 lock" >&2; exit 1; }

bad=""
while IFS=$'\t' read -r pkg file sha signer nurls allhttps vc; do
  want="$(awk -v f="$file" '$2 == f { print $1 }' "$SUMS")"
  [ -n "$want" ] || { bad="$bad  $file: not in $SUMS"$'\n'; continue; }
  [ "$want" = "$sha" ] || bad="$bad  $file: lock says ${sha:0:12}, $SUMS says ${want:0:12}"$'\n'
  cert="$(tr -d '[:space:]' < "$CERTS/$pkg.cert" 2>/dev/null || true)"
  [ "$cert" = "$signer" ] || bad="$bad  $file: signer in the lock is not the one pinned in $CERTS/$pkg.cert"$'\n'
  [ "$nurls" -gt 0 ] || bad="$bad  $file: no URL"$'\n'
  [ "$allhttps" = true ] || bad="$bad  $file: a URL that is not https"$'\n'
  [[ "$vc" =~ ^[0-9]+$ ]] || bad="$bad  $file: no versionCode"$'\n'
  jq -e --arg p "$pkg" '.apps[] | select(.pkg == $p)' "$CAT" >/dev/null || bad="$bad  $file: $pkg is not in the catalog"$'\n'
done < <(jq -r '.entries[] | [.pkg, .file, .sha256, .signer, (.urls | length),
                  (all(.urls[]; startswith("https://"))), (.versionCode // "" | tostring)] | @tsv' "$LOCK")

# The file provisioning would install, from the paths SHA256SUMS lists.
while read -r pkg tag; do
  [ -f "$CERTS/$pkg.cert" ] || continue
  n=0
  for dir in universal arm64-v8a x86_64; do
    files="$(awk '{print $2}' "$SUMS" | grep -F "$dir/$pkg-" | grep -E "^$dir/${pkg//./\\.}-[^/]*\.apk$" || true)"
    [ -n "$files" ] || continue
    if [ -n "$tag" ] && grep -qxF "$dir/$pkg-$tag.apk" <<<"$files"; then chosen="$dir/$pkg-$tag.apk"
    else chosen="$(sort -V <<<"$files" | tail -1)"; fi
    locked="$(jq -r --arg p "$pkg" --arg d "$dir" '[.entries[] | select(.pkg == $p and .abi == $d) | .file][0] // empty' "$LOCK")"
    [ "$locked" = "$chosen" ] || bad="$bad  $pkg ($dir): provisioning would install $chosen, the lock has ${locked:-nothing}"$'\n'
    n=$((n+1))
  done
  [ "$n" -gt 0 ] || bad="$bad  $pkg: pinned in $CERTS but no file in $SUMS"$'\n'
done < <(jq -r '.apps[] | select(.source == "obtainium" or .source == "fdroid" or .source == "torproject")
                | "\(.pkg) \((.release_tag // "") | ltrimstr("v"))"' "$CAT")

if [ -n "$bad" ]; then
  printf 'apks/lock.json does not describe the inventory:\n%s  after fetch.sh: apks/lock.sh\n' "$bad" >&2
  exit 1
fi
echo "ok: lock matches the inventory ($(jq '.entries | length' "$LOCK") files)"
