#!/usr/bin/env bash
# Fetches APKs from the official GitHub releases of the apps listed in the
# catalog as source=obtainium, verifies the signature, and pins it on first
# use (TOFU).
#
#   ./fetch.sh                  all
#   ./fetch.sh signal immich    only these IDs
#   ./fetch.sh --prune          afterwards, keep only the newest per app and ABI
#   APK_ABI=x86_64 ./fetch.sh   ABI preference (default arm64-v8a = the Fold)
#
# Universal APKs are preferred, because they run on the device AND the emulator.
set -uo pipefail
cd "$(dirname "$0")"
# Overridable, so you can work against a test catalog without touching
# the real one:  CAT=/path/apps.json ./fetch.sh <id>
: "${CAT:=../config/apps.json}"
: "${APK_ABI:=arm64-v8a}"

c(){ [ -t 1 ] && printf '\033[%sm%s\033[0m\n' "$1" "$2" || printf '%s\n' "$2"; }
ok(){ c '1;32' " + $*"; }; warn(){ c '1;33' " ! $*" >&2; }
bad(){ c '1;31' " x $*" >&2; }; log(){ c '1;34' ":: $*"; }

# Maps an APK to a subdirectory. universal = runs on the device AND the
# emulator, so it's only kept once. Only the few APKs that ship exactly one
# architecture exist twice.
classify_abi() {   # $1 = apk file
  local listing abis
  # unzip's own status decides, not its output. An empty listing has two
  # meanings - an APK with no native libraries, which IS universal, and an
  # unzip that failed on a truncated or unreadable download, which is nothing
  # at all. Treating both as universal filed a broken file as the one build
  # that installs on every device and the emulator alike.
  #
  # What that cost, measured rather than assumed: less than it looks. A
  # truncated download is caught two steps below, where `aapt2 dump
  # packagename` comes back empty and the package-name check quarantines it -
  # verified on a half-copy of 0.8.0 - so this never put a corrupt APK into
  # SHA256SUMS. What it did cost is a misfiled one: an APK that unzip cannot
  # read but aapt2 can, sorted as universal and then offered by apk_for_pkg
  # for an architecture it does not carry.
  listing="$(unzip -l "$1" 2>/dev/null)" || return 1
  abis="$(printf '%s\n' "$listing" | grep -oE 'lib/[a-z0-9_-]+/' | sed 's|lib/||;s|/||' | sort -u)"
  if [ -z "$abis" ]; then echo universal
  elif grep -q arm64-v8a <<<"$abis" && grep -q x86_64 <<<"$abis"; then echo universal
  elif grep -q arm64-v8a <<<"$abis"; then echo arm64-v8a
  else echo x86_64; fi
}

# The Tor Project signs every release file with a detached .asc. That is the
# only source in this catalog where we can check an UPSTREAM SIGNATURE instead
# of merely pinning whatever arrived first - worth the extra code for the app
# whose entire purpose is anonymity.
# The key is committed (keys/torbrowser.asc) so the check does not depend on a
# keyserver being reachable or honest; its fingerprint is verified before use.
TORBROWSER_FPR="EF6E286DDA85EA2A4BA7DE684E2C6E8793298290"
verify_detached_sig() {  # $1 = local file, $2 = signature URL, $3 = expected key fingerprint
  local file="$1" sigurl="$2" fpr="$3" home sig rc=0
  [ -f keys/torbrowser.asc ] || { bad "keys/torbrowser.asc missing"; return 1; }
  home="$(mktemp -d)"; sig="$home/sig.asc"
  chmod 700 "$home"
  if ! gpg --homedir "$home" --batch --quiet --import keys/torbrowser.asc 2>/dev/null; then
    bad "signing key could not be imported"; rm -rf "$home"; return 1
  fi
  # The committed file must be the key we think it is, not just any key.
  if ! gpg --homedir "$home" --batch --with-colons --fingerprint 2>/dev/null \
       | awk -F: '$1=="fpr"{print $10}' | grep -qx "$fpr"; then
    bad "keys/torbrowser.asc does not carry fingerprint $fpr"; rm -rf "$home"; return 1
  fi
  if ! curl -fsSL --max-time 120 "$sigurl" -o "$sig"; then
    bad "signature not downloadable: $sigurl"; rm -rf "$home"; return 1
  fi
  gpg --homedir "$home" --batch --verify "$sig" "$file" 2>/dev/null || rc=1
  rm -rf "$home"
  [ "$rc" = 0 ] || { bad "GPG signature does NOT verify - discarding the download"; return 1; }
  ok "GPG signature verified against $fpr"
}

# Checks whether something usable already exists for the REQUESTED ABI. Only
# universal/ and the target directory count - a file for the other
# architecture does NOT make the download unnecessary, otherwise
# APK_ABI=x86_64 would never fetch the emulator variant, because the arm64
# file has the same name.
find_existing() {  # $1 = file name
  local d
  for d in universal "$APK_ABI"; do
    [ -n "$d" ] && [ -f "$d/$1" ] && { echo "$d/$1"; return 0; }
  done
  return 1
}

# Picks the APK asset for the requested ABI, or NOTHING.
#
# Three things this has to get right, each learned from a release that got it
# wrong:
#
# 1. Upstreams spell ABIs their own way. Android says x86_64, Haven says x64,
#    other projects say aarch64 or armv7. A literal match on "$APK_ABI" misses
#    all of those.
# 2. A missed ABI must not fall through to "take any APK". That is how
#    APK_ABI=x86_64 ended up fetching an arm64 binary: the file was sorted
#    correctly by classify_abi afterwards, so the inventory looked fine, and
#    the emulator then failed with INSTALL_FAILED_NO_MATCHING_ABIS. An empty
#    result and "take whatever" have to be distinguishable.
# 3. Many projects ship flavours next to the real build - '-fdroid' variants,
#    Haven's '-terminal', HeliBoard's 'nouserlib'. asset_exclude/asset_prefer
#    in the catalog decide per app; guessing centrally would be wrong.
pick_asset() {   # stdin = JSON array of assets; picks the best APK URL
  jq -r --arg abi "$APK_ABI" --arg excl "${ASSET_EXCLUDE:-}" --arg pref "${ASSET_PREFER:-}" '
    def abipat($a):
        if   $a == "x86_64"      then "x86[-_]?64|x64"
        elif $a == "arm64-v8a"   then "arm64([-_]?v8a)?|aarch64"
        elif $a == "armeabi-v7a" then "armeabi([-_]?v7a)?|armv7|arm32"
        elif $a == "x86"         then "x86(?![-_]?64)"
        else $a end;
    "x86[-_]?64|x64|arm64|aarch64|armeabi|armv7|arm32" as $anyabi
    | [ .[] | select(.name|test("\\.apk$";"i"))
            | select(.name|test("debug|androidTest|-sources|nouserlib";"i")|not)
            | select($excl == "" or (.name|test($excl;"i")|not)) ] as $apks
    | ( if $pref != "" and ([ $apks[] | select(.name|test($pref;"i")) ]|length) > 0
          then [ $apks[] | select(.name|test($pref;"i")) ] else $apks end ) as $apks
    | [ $apks[] | select(.name|test("universal";"i")) ] as $uni
    | [ $apks[] | select(.name|test(abipat($abi);"i")) ] as $mine
    | [ $apks[] | select(.name|test($anyabi;"i")) ] as $tagged
    | ( if   ($uni|length)    > 0 then $uni
        elif ($mine|length)   > 0 then $mine
        elif ($tagged|length) > 0 then []
        else $apks end )
    | .[0].browser_download_url // empty'
}

PRUNE=0
[ "${1:-}" = "--prune" ] && { PRUNE=1; shift; }

# GitHub's release API allows 60 unauthenticated requests an hour per address.
# One pass over the catalog takes about 22, and a runner shares its address
# with strangers - the scheduled lock refresh ran out after two passes on
# 2026-09-30 and reported seven "release query failed". With GITHUB_TOKEN or
# GH_TOKEN set, the requests are authenticated (5000 an hour); the token only
# reads public releases.
gh_curl() {   # $1=api url
  local tok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [ -n "$tok" ]; then curl -fsSL -H "Authorization: Bearer $tok" "$1" 2>/dev/null
  else curl -fsSL "$1" 2>/dev/null; fi
}

# Old versions pile up: nothing ever deleted them, SHA256SUMS lists every file
# on disk, and Tor Browser alone is ~106 MB per version and ABI. Harmless for
# installs (apk_for_pkg takes the highest version) but not free.
prune_inventory() {
  local d pkg f keep tag why n=0
  for d in universal arm64-v8a x86_64; do
    [ -d "$d" ] || continue
    # The package name is everything before the FIRST dash: Android package
    # names cannot contain one, versions frequently do (im.molly.app-8.19.2-4).
    for pkg in $(ls -1 "$d"/*.apk 2>/dev/null | xargs -r -n1 basename | sed 's/-.*//' | sort -u); do
      mapfile -t versions < <(ls -1 "$d/$pkg-"*.apk 2>/dev/null | sort -V)
      [ "${#versions[@]}" -le 1 ] && continue
      keep="${versions[-1]}"
      # A deliberately pinned release is never "superseded" - it is the one we
      # ship, and deleting it would undo a rollback the catalog just asked for.
      tag="$(jq -r --arg p "$pkg" '[.apps[]|select(.pkg==$p)|.release_tag//empty][0] // empty' "$CAT" 2>/dev/null)"
      tag="${tag#v}"
      why="superseded by $(basename "$keep")"
      if [ -n "$tag" ] && [ -f "$d/$pkg-$tag.apk" ]; then
        keep="$d/$pkg-$tag.apk"; why="catalog pins $tag"
      fi
      for f in "${versions[@]}"; do
        [ "$f" = "$keep" ] && continue
        rm -f "$f" && { ok "pruned $(basename "$f") ($why)"; n=$((n+1)); }
      done
    done
  done
  [ "$n" -eq 0 ] && log "nothing to prune" || log "$n superseded APK(s) removed"
}

# apk_for_pkg searches by DIRECTORY first (device ABI, then universal), not by
# version. So an old ABI-specific copy beats a newer universal one and nobody
# notices. That is the one inventory state pruning cannot fix, because both
# files are the newest in their own directory.
warn_abi_skew() {
  local d pkg newest prev prevdir
  declare -A best=()
  for d in universal arm64-v8a x86_64; do
    [ -d "$d" ] || continue
    for pkg in $(ls -1 "$d"/*.apk 2>/dev/null | xargs -r -n1 basename | sed 's/-.*//' | sort -u); do
      newest="$(ls -1 "$d/$pkg-"*.apk 2>/dev/null | sort -V | tail -1)"
      newest="$(basename "$newest")"; newest="${newest#"$pkg-"}"; newest="${newest%.apk}"
      if [ -n "${best[$pkg]:-}" ]; then
        prev="${best[$pkg]%%|*}"; prevdir="${best[$pkg]##*|}"
        [ "$prev" = "$newest" ] || \
          warn "$pkg: $prevdir has $prev, $d has $newest - apk_for_pkg picks by directory, not by version"
      else
        best[$pkg]="$newest|$d"
      fi
    done
  done
}

ids=("$@")
if [ ${#ids[@]} -eq 0 ]; then
  mapfile -t ids < <(jq -r '.apps[]|select((.source=="obtainium" and (.upstream|test("github.com|codeberg.org"))) or .source=="fdroid" or .source=="torproject")|.id' "$CAT")
fi

mkdir -p certs
fail=0
for id in "${ids[@]}"; do
  row=$(jq -c --arg i "$id" '.apps[]|select(.id==$i)' "$CAT")
  [ -z "$row" ] && { warn "$id: not in the catalog"; continue; }
  pkg=$(jq -r '.pkg' <<<"$row"); label=$(jq -r '.label' <<<"$row"); up=$(jq -r '.upstream' <<<"$row")
  src=$(jq -r '.source' <<<"$row")
  sigurl=""
  # Per-app asset filters: which flavour of a release is the real build is an
  # upstream idiosyncrasy, so the catalog decides and pick_asset only obeys.
  ASSET_EXCLUDE="$(jq -r 'if has("asset_exclude") then .asset_exclude else "" end' <<<"$row")"
  ASSET_PREFER="$(jq -r 'if has("asset_prefer") then .asset_prefer else "" end' <<<"$row")"

  # F-Droid instead of GitHub: some upstreams publish no APK asset at all.
  # Shelter's GitHub releases carry source only (tag 1.6), while F-Droid has
  # 1.9.1 - going by GitHub would silently install a three-year-old build.
  # The signature check and TOFU pinning below are the same for both sources.
  if [ "$src" = "torproject" ]; then
    # dist.torproject.org has no release API: the version directories are the
    # index. Take the highest one that actually carries our ABI.
    case "$APK_ABI" in
      arm64-v8a) tabi=aarch64 ;;
      x86_64)    tabi=x86_64 ;;
      *) warn "$label: no Tor Browser build for ABI $APK_ABI"; continue ;;
    esac
    log "$label (dist.torproject.org, $tabi)"
    ver=$(curl -fsSL --max-time 60 "https://dist.torproject.org/torbrowser/" 2>/dev/null \
          | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?/' | tr -d '/' | sort -V | tail -1)
    [ -z "$ver" ] && { bad "$label: could not read the version index"; fail=1; continue; }
    url="https://dist.torproject.org/torbrowser/$ver/tor-browser-android-$tabi-$ver.apk"
    sigurl="$url.asc"
  elif [ "$src" = "fdroid" ]; then
    log "$label (F-Droid)"
    idx=$(curl -fsSL "https://f-droid.org/api/v1/packages/$pkg" 2>/dev/null)
    [ -z "$idx" ] && { bad "$label: F-Droid index query failed"; fail=1; continue; }
    code=$(jq -r '.suggestedVersionCode // empty' <<<"$idx")
    [ -z "$code" ] && { bad "$label: no suggestedVersionCode in the F-Droid index"; fail=1; continue; }
    ver=$(jq -r --argjson c "$code" '[.packages[]|select(.versionCode==$c)|.versionName][0] // empty' <<<"$idx")
    [ -z "$ver" ] && ver="$code"
    url="https://f-droid.org/repo/${pkg}_${code}.apk"
  elif [[ "$up" == *codeberg.org* ]]; then
    # Codeberg (Forgejo) speaks the same release API shape as GitHub, so
    # pick_asset and everything below it work unchanged.
    slug=$(sed -n 's#.*codeberg\.org/\([^/]*/[^/]*\).*#\1#p' <<<"$up")
    [ -z "$slug" ] && { warn "$label: no Codeberg repo ($up)"; continue; }
    log "$label ($slug, Codeberg)"
    # NOT /releases/latest: CoMaps tags -apple releases that carry no APK at
    # all, and latest would then hand us an empty asset list. Take the newest
    # release that actually ships one.
    rels=$(curl -fsSL "https://codeberg.org/api/v1/repos/$slug/releases?limit=10" 2>/dev/null)
    [ -z "$rels" ] && { bad "$label: release query failed"; fail=1; continue; }
    rel=$(jq -c '[ .[] | select([ .assets[]? | select(.name|test("\\.apk$";"i")) ] | length > 0) ][0] // empty' <<<"$rels")
    [ -z "$rel" ] && { warn "$label: no release with an APK asset in the last 10"; continue; }
    tag=$(jq -r '.tag_name // "?"' <<<"$rel")
    url=$(jq '.assets' <<<"$rel" | pick_asset)
    if [ -z "$url" ]; then
      warn "$label: no usable APK asset in release $tag"
      continue
    fi
    ver=$(sed 's/^v//' <<<"$tag")
  else
  slug=$(sed -n 's#.*github\.com/\([^/]*/[^/]*\).*#\1#p' <<<"$up")
  [ -z "$slug" ] && { warn "$label: no GitHub repo ($up)"; continue; }

  log "$label ($slug)"
  # Optional tag pinning in the catalog (release_tag): for deliberate version
  # pins (Andashi Home) and for upstreams that make /releases/latest useless
  # (Lawnchair, when it was still in the catalog, had marked everything as
  # prerelease since 2022 - latest returned a 2019 APK with a different
  # package name).
  pin=$(jq -r 'if has("release_tag") then .release_tag else empty end' <<<"$row")
  if [ -n "$pin" ]; then
    rel=$(gh_curl "https://api.github.com/repos/$slug/releases/tags/$pin")
  else
    rel=$(gh_curl "https://api.github.com/repos/$slug/releases/latest")
  fi
  [ -z "$rel" ] && { bad "$label: release query failed${pin:+ (tag $pin)}"; fail=1; continue; }
  tag=$(jq -r '.tag_name // "?"' <<<"$rel")
  url=$(jq '.assets' <<<"$rel" | pick_asset)
  if [ -z "$url" ]; then
    warn "$label: no APK asset in release $tag (does upstream ship it differently?)"
    continue
  fi

  ver=$(sed 's/^v//' <<<"$tag")
  fi

  name="${pkg}-${ver}.apk"
  if have=$(find_existing "$name"); then ok "$label $ver already present ($have)"; continue; fi
  curl -fsSL -o ".$name.part" "$url" || { bad "$label: download failed"; rm -f ".$name.part"; fail=1; continue; }
  if [ -n "$sigurl" ]; then
    verify_detached_sig ".$name.part" "$sigurl" "$TORBROWSER_FPR" \
      || { rm -f ".$name.part"; fail=1; continue; }
  fi
  # The ABI can only be determined after the download, so sort it in now.
  sub="$(classify_abi ".$name.part")" \
    || { bad "$label: cannot read the downloaded APK - not an archive?"; rm -f ".$name.part"; fail=1; continue; }
  mkdir -p "$sub"
  out="$sub/$name"
  mv ".$name.part" "$out"

  # A rejected download must LEAVE the inventory. It used to stay where it had
  # been moved to, which made a refusal cosmetic: SHA256SUMS is regenerated at
  # the end of this script and would happily record the rejected file, and
  # apk_for_pkg takes the HIGHEST version it finds - so the next provisioning
  # run would install exactly the APK this check refused. Quarantine instead of
  # delete, because a signer change is the one case worth looking at by hand.
  reject() {  # $1 = file, $2 = reason
    mkdir -p rejected
    mv -f "$1" "rejected/$(basename "$1")" 2>/dev/null || rm -f "$1"
    bad "$2 - moved to rejected/, NOT part of the inventory"
  }
  real=$(aapt2 dump packagename "$out" 2>/dev/null)
  if [ "$real" != "$pkg" ]; then
    reject "$out" "$label: package name mismatch - catalog '$pkg', APK '$real'"; fail=1; continue
  fi
  cert=$(apksigner verify --print-certs "$out" 2>/dev/null | sed -n 's/.*certificate SHA-256 digest: \(.*\)/\1/p' | head -1)
  [ -z "$cert" ] && { reject "$out" "$label: no valid signature"; fail=1; continue; }
  if [ -f "certs/$pkg.cert" ]; then
    if [ "$(cat "certs/$pkg.cert")" != "$cert" ]; then
      reject "$out" "$label: SIGNER CHANGED - expected $(cat "certs/$pkg.cert"), got $cert"; fail=1; continue
    fi
    ok "$label $ver -> $sub/ ($(du -h "$out"|cut -f1)), signer matches"
  else
    printf '%s\n' "$cert" > "certs/$pkg.cert"
    ok "$label $ver -> $sub/ ($(du -h "$out"|cut -f1)), signer newly pinned"
  fi
done

[ "$PRUNE" = "1" ] && prune_inventory
warn_abi_skew

shopt -s nullglob
a=(universal/*.apk arm64-v8a/*.apk x86_64/*.apk)
[ ${#a[@]} -gt 0 ] && sha256sum "${a[@]}" > SHA256SUMS
log "${#a[@]} APK(s) present, SHA256SUMS updated"
exit $fail
