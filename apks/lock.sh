#!/usr/bin/env bash
# Writes apks/lock.json: for every APK a phone gets from this inventory, where
# to download exactly those bytes, and what they must hash to.
#
#   apks/lock.sh              after fetch.sh and verify.sh, on the maintainer's machine
#
# The lock is what lets somebody provision a phone WITHOUT running fetch.sh -
# without Java, aapt2, apksigner and gpg, and without trusting whatever an
# upstream serves the first time they ask. Those checks ran here, once, and the
# lock records their result as a hash: whoever downloads from it compares
# SHA-256 and nothing else (apks/from-lock.sh). See
# docs/decisions/0013-a-lock-for-the-first-install.md.
#
# Which file goes in: per package and ABI directory, the one apk_for_pkg in
# lib/common.sh would install - the release_tag version if the catalog pins
# one, the highest otherwise. Older builds lying in the inventory are not the
# phone's business.
#
# Where it came from is worked out and PROVEN, never guessed: a GitHub asset
# matches by the SHA-256 digest GitHub publishes for it (or, for an asset
# older than those digests, like the Codeberg case below), a Codeberg asset by
# its size and then its bytes (and nothing is locked when two could match),
# an F-Droid or Tor Browser URL is fetched and hashed. No record of where
# fetch.sh once downloaded from is needed, and none could be trusted more
# than the hash anyway.
#
# Upstreams delete old builds. dist.torproject.org keeps a handful - Tor
# Browser 15.0.23, in this inventory, was already gone from it on 2026-09-30
# while archive.torproject.org still served it - and f-droid.org/repo keeps
# the latest few, moving the rest to f-droid.org/archive. So those entries
# carry the archive URL too, and from-lock.sh tries them in order.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# The inventory to lock: this directory, or APKS_DIR (which the case file uses).
cd "${APKS_DIR:-$here}"
: "${CAT:=$here/../config/apps.json}"
OUT="${OUT:-lock.json}"

c(){ [ -t 1 ] && printf '\033[%sm%s\033[0m\n' "$1" "$2" || printf '%s\n' "$2"; }
ok(){ c '1;32' " + $*"; }; bad(){ c '1;31' " x $*" >&2; }; log(){ c '1;34' ":: $*"; }

for t in jq curl sha256sum aapt2; do command -v "$t" >/dev/null || { bad "$t missing"; exit 1; }; done
[ -f SHA256SUMS ] || { bad "no SHA256SUMS - run fetch.sh first"; exit 1; }

# A GitHub API call, authenticated when gh is logged in (60 unauthenticated
# calls an hour would run out halfway through a lock).
gh_api() {
  if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then gh api "$1"
  else curl -fsSL "https://api.github.com/$1"; fi
}
version_code() { aapt2 dump badging "$1" 2>/dev/null | sed -n "s/.*versionCode='\([0-9]*\)'.*/\1/p" | head -1; }
# The hash of what a URL serves, or nothing when it serves nothing - never the
# hash of an empty download.
url_hash() {
  local t; t="$(mktemp)"
  if curl -fsSL --max-time 600 -o "$t" "$1" 2>/dev/null; then sha256sum < "$t" | cut -d' ' -f1; fi
  rm -f "$t"
}
# Of the given URLs, those that serve $sha (from the caller), in order.
proven() { local u; for u in "$@"; do [ "$(url_hash "$u")" = "$sha" ] && printf '%s\n' "$u"; done; return 0; }

# The file apk_for_pkg would pick in one directory, or nothing.
chosen() {   # $1=dir $2=pkg $3=release_tag-version-or-empty
  local f
  if [ -n "$3" ] && [ -f "$1/$2-$3.apk" ]; then printf '%s' "$1/$2-$3.apk"; return; fi
  f="$(ls -1 "$1/$2-"*.apk 2>/dev/null | sort -V | tail -1 || true)"
  [ -z "$f" ] || printf '%s' "$f"
}

# Every URL this file is known to be served from, primary first; empty when
# none could be proven.
resolve_urls() {   # $1=file $2=sha256 $3=catalog row
  local file="$1" sha="$2" row="$3" src up pkg ver slug rel url size code tabi name
  src="$(jq -r .source <<<"$row")"; up="$(jq -r '.upstream // ""' <<<"$row")"; pkg="$(jq -r .pkg <<<"$row")"
  name="$(basename "$file")"; ver="${name#"$pkg"-}"; ver="${ver%.apk}"

  case "$src" in
    torproject)
      case "$file" in arm64-v8a/*) tabi=aarch64;; x86_64/*) tabi=x86_64;; *) return 0;; esac
      # The archive first: it is the one that keeps old builds. Each URL goes
      # into the lock only if it serves these bytes today - an unproven
      # mirror in the lock would be a URL nobody checked.
      proven "https://archive.torproject.org/tor-package-archive/torbrowser/$ver/tor-browser-android-$tabi-$ver.apk" \
             "https://dist.torproject.org/torbrowser/$ver/tor-browser-android-$tabi-$ver.apk"
      return 0;;
    fdroid)
      code="$(version_code "$file")"; [ -n "$code" ] || return 0
      proven "https://f-droid.org/repo/${pkg}_${code}.apk" "https://f-droid.org/archive/${pkg}_${code}.apk"
      return 0;;
  esac

  # GitHub publishes each asset's digest, so the match needs no download.
  if [[ "$up" == *github.com* ]]; then
    slug="$(sed -n 's#.*github\.com/\([^/]*/[^/]*\).*#\1#p' <<<"$up")"
    for tag in "v$ver" "$ver"; do
      rel="$(gh_api "repos/$slug/releases/tags/$tag" 2>/dev/null)" || continue
      url="$(jq -r --arg d "sha256:$sha" '[.assets[] | select(.digest == $d) | .browser_download_url][0] // empty' <<<"$rel")"
      [ -n "$url" ] && { printf '%s\n' "$url"; return 0; }
      # Assets uploaded before GitHub computed digests have none (Shizuku
      # 13.6.0): then the Codeberg way - one asset of this size, proven by
      # its bytes.
      size="$(stat -c %s "$file")"
      mapfile -t cand < <(jq -r --argjson s "$size" '.assets[] | select(.digest == null and .size == $s) | .browser_download_url' <<<"$rel")
      if [ "${#cand[@]}" = 1 ] && [ "$(url_hash "${cand[0]}")" = "$sha" ]; then printf '%s\n' "${cand[0]}"; return 0; fi
    done
    return 0
  fi
  if [[ "$up" == *codeberg.org* ]]; then
    slug="$(sed -n 's#.*codeberg\.org/\([^/]*/[^/]*\).*#\1#p' <<<"$up")"
    size="$(stat -c %s "$file")"
    for tag in "v$ver" "$ver"; do
      rel="$(curl -fsSL "https://codeberg.org/api/v1/repos/$slug/releases/tags/$tag" 2>/dev/null)" || continue
      # No digest on Codeberg: the size narrows it to one asset, the bytes prove it.
      mapfile -t cand < <(jq -r --argjson s "$size" '.assets[] | select(.size == $s) | .browser_download_url' <<<"$rel")
      [ "${#cand[@]}" = 1 ] || continue
      [ "$(url_hash "${cand[0]}")" = "$sha" ] && { printf '%s\n' "${cand[0]}"; return 0; }
    done
    return 0
  fi
  return 0
}

# The catalog is read before anything else, with its status checked. Read
# through a process substitution, a missing or broken catalog yielded no rows,
# and the lock was replaced by a valid-looking empty one.
rows="$(jq -c '.apps[] | select(.source == "obtainium" or .source == "fdroid" or .source == "torproject")' "$CAT")" \
  || { bad "could not read the catalog $CAT - lock.json left as it was"; exit 1; }
[ -n "$rows" ] || { bad "the catalog $CAT names no app to lock - lock.json left as it was"; exit 1; }

entries="[]"; missing=()
while read -r row; do
  pkg="$(jq -r .pkg <<<"$row")"; label="$(jq -r .label <<<"$row")"
  tag="$(jq -r '.release_tag // ""' <<<"$row")"; tag="${tag#v}"
  [ -f "certs/$pkg.cert" ] || continue          # nothing of it was ever fetched here
  signer="$(tr -d '[:space:]' < "certs/$pkg.cert")"
  found=0
  for dir in universal arm64-v8a x86_64; do
    f="$(chosen "$dir" "$pkg" "$tag")"; [ -n "$f" ] || continue
    found=1
    sha="$(awk -v f="$f" '$2 == f { print $1 }' SHA256SUMS)"
    [ -n "$sha" ] || { bad "$label: $f is not in SHA256SUMS - run fetch.sh/verify.sh"; missing+=("$f"); continue; }
    mapfile -t urls < <(resolve_urls "$f" "$sha" "$row")
    if [ "${#urls[@]}" = 0 ] || [ -z "${urls[0]}" ]; then
      bad "$label: no URL serves $f with its hash - not locked"; missing+=("$f"); continue
    fi
    v="$(basename "$f")"; v="${v#"$pkg"-}"; v="${v%.apk}"
    # versionCode rides along so that 10-apps can compare what a phone runs
    # with what the host has, on a machine that has no aapt2 to ask the APK.
    vc="$(version_code "$f")"
    [ -n "$vc" ] || { bad "$label: aapt2 found no versionCode in $f"; missing+=("$f"); continue; }
    entries="$(jq -c --arg pkg "$pkg" --arg label "$label" --arg ver "$v" --arg dir "$dir" \
      --arg file "$f" --arg sha "$sha" --arg signer "$signer" --argjson size "$(stat -c %s "$f")" \
      --argjson vc "$vc" \
      --args '. + [{pkg: $pkg, label: $label, version: $ver, versionCode: $vc, abi: $dir, file: $file,
                    sha256: $sha, size: $size, signer: $signer, urls: $ARGS.positional}]' \
      "${urls[@]}" <<<"$entries")"
    ok "$label $v ($dir) <- ${urls[0]}"
  done
  [ "$found" = 1 ] || { bad "$label: pinned but no APK in the inventory"; missing+=("$pkg"); }
done <<<"$rows"

[ "$(jq length <<<"$entries")" -gt 0 ] || { bad "nothing could be locked - lock.json left as it was"; exit 1; }
if [ "${#missing[@]}" -gt 0 ]; then
  bad "${#missing[@]} file(s) could not be locked - lock.json NOT written"
  exit 1
fi
jq -n --argjson e "$entries" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{lockVersion: 1, generated: $at, entries: ($e | sort_by(.pkg, .abi))}' > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
log "$(jq '.entries | length' "$OUT") file(s) locked in $OUT"
