#!/usr/bin/env bash
# Cases for apks/lock.sh, the maintainer's side of the lock: which URL it
# records for a file, and when it refuses to write at all. Its promise is that
# every URL in the lock was proven to serve the locked bytes, so most cases
# are the ways a URL could slip in unproven - a mirror that is gone, one that
# serves other bytes, two assets of the same size - and the ways the lock
# could be replaced by something emptier than the one before.
#
# Offline: curl answers from fixture files (whole-URL names for API answers),
# aapt2 reads a versionCode from the fixture APK, and gh is not on PATH, so
# lock.sh takes its unauthenticated curl path.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
t() { if eval "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }

mkdir -p "$tmp/bin"
IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do
  for f in "$d"/*; do
    b="$(basename "$f")"
    case "$b" in gh|curl|aapt2) continue;; esac
    [ -e "$tmp/bin/$b" ] || ln -s "$f" "$tmp/bin/$b" 2>/dev/null
  done
done
ln -s "$root/tests/fixtures/fake-curl" "$tmp/bin/curl"
ln -s "$root/tests/fixtures/fake-aapt2" "$tmp/bin/aapt2"
key() { printf '%s' "$1" | tr '/:' '__'; }
serve() { cp "$2" "$tmp/serve/$(key "$1")"; }            # $1=url $2=file
api() { printf '%s' "$2" > "$tmp/serve/$(key "https://api.github.com/$1")"; }

setup() {
  rm -rf "$tmp/inv" "$tmp/serve"; mkdir -p "$tmp/inv/universal" "$tmp/inv/arm64-v8a" "$tmp/inv/certs" "$tmp/serve"
  printf 'vc=10\ndigest app\n'   > "$tmp/inv/universal/a.dig-1.0.apk"
  printf 'vc=20\nno digest\n'    > "$tmp/inv/universal/b.old-2.0.apk"
  printf 'vc=30\ntor browser\n'  > "$tmp/inv/arm64-v8a/org.torproject.torbrowser-15.0.apk"
  (cd "$tmp/inv" && sha256sum universal/*.apk arm64-v8a/*.apk > SHA256SUMS)
  for p in a.dig b.old org.torproject.torbrowser; do echo "cert-$p" > "$tmp/inv/certs/$p.cert"; done
  cat > "$tmp/apps.json" <<'JSON'
{"apps": [
  {"id": "dig", "label": "Dig", "pkg": "a.dig", "source": "obtainium", "upstream": "https://github.com/o/dig", "profiles": ["home"]},
  {"id": "old", "label": "Old", "pkg": "b.old", "source": "obtainium", "upstream": "https://github.com/o/old", "profiles": ["home"]},
  {"id": "tor", "label": "Tor", "pkg": "org.torproject.torbrowser", "source": "torproject", "profiles": ["anon"]}
]}
JSON
  dsha="$(sha256sum < "$tmp/inv/universal/a.dig-1.0.apk" | cut -d' ' -f1)"
  osize="$(stat -c %s "$tmp/inv/universal/b.old-2.0.apk")"
  api repos/o/dig/releases/tags/v1.0 '{"assets": [
    {"name": "other.apk", "size": 5, "digest": "sha256:0000", "browser_download_url": "https://github.com/o/dig/releases/download/v1.0/other.apk"},
    {"name": "a.apk", "size": 99, "digest": "sha256:'"$dsha"'", "browser_download_url": "https://github.com/o/dig/releases/download/v1.0/a.apk"}]}'
  api repos/o/old/releases/tags/v2.0 '{"assets": [
    {"name": "b.apk", "size": '"$osize"', "digest": null, "browser_download_url": "https://github.com/o/old/releases/download/v2.0/b.apk"},
    {"name": "b-debug.apk", "size": 3, "digest": null, "browser_download_url": "https://github.com/o/old/releases/download/v2.0/b-debug.apk"}]}'
  serve https://github.com/o/old/releases/download/v2.0/b.apk "$tmp/inv/universal/b.old-2.0.apk"
  serve https://archive.torproject.org/tor-package-archive/torbrowser/15.0/tor-browser-android-aarch64-15.0.apk "$tmp/inv/arm64-v8a/org.torproject.torbrowser-15.0.apk"
  echo '{"lockVersion": 1, "generated": "before", "entries": [{"pkg": "kept"}]}' > "$tmp/inv/lock.json"
}
run() { PATH="$tmp/bin" FAKE_CURL_DIR="$tmp/serve" APKS_DIR="$tmp/inv" CAT="$tmp/apps.json" "$root/apks/lock.sh" > "$tmp/out" 2>&1; }
urls() { jq -r --arg p "$1" '.entries[] | select(.pkg == $p) | .urls | join(" ")' "$tmp/inv/lock.json"; }
kept() { [ "$(jq -r .generated "$tmp/inv/lock.json")" = before ]; }

setup; run
t "all three proven: the lock is written"            '[ $? = 0 ] && [ "$(jq ".entries | length" "$tmp/inv/lock.json")" = 3 ]'
t "GitHub: the asset whose published digest matches" '[ "$(urls a.dig)" = "https://github.com/o/dig/releases/download/v1.0/a.apk" ]'
t "no digest: the one asset of this size, by its bytes" '[ "$(urls b.old)" = "https://github.com/o/old/releases/download/v2.0/b.apk" ]'
t "Tor: the archive, and not the mirror that serves nothing" '[ "$(urls org.torproject.torbrowser)" = "https://archive.torproject.org/tor-package-archive/torbrowser/15.0/tor-browser-android-aarch64-15.0.apk" ]'
t "each entry carries the versionCode aapt2 read"   '[ "$(jq -r ".entries[] | select(.pkg == \"a.dig\") | .versionCode" "$tmp/inv/lock.json")" = 10 ]'

setup
serve https://dist.torproject.org/torbrowser/15.0/tor-browser-android-aarch64-15.0.apk "$tmp/inv/arm64-v8a/org.torproject.torbrowser-15.0.apk"
run
t "a mirror that serves the bytes is recorded after the archive" '[ "$(urls org.torproject.torbrowser | wc -w)" = 2 ]'

setup
printf 'something else' > "$tmp/x"; serve https://dist.torproject.org/torbrowser/15.0/tor-browser-android-aarch64-15.0.apk "$tmp/x"
run
t "a mirror that serves other bytes is left out"    '[ "$(urls org.torproject.torbrowser | wc -w)" = 1 ]'

setup
api repos/o/old/releases/tags/v2.0 '{"assets": [
  {"name": "b.apk", "size": '"$osize"', "digest": null, "browser_download_url": "https://github.com/o/old/releases/download/v2.0/b.apk"},
  {"name": "b2.apk", "size": '"$osize"', "digest": null, "browser_download_url": "https://github.com/o/old/releases/download/v2.0/b2.apk"}]}'
run
t "two assets of the same size: not locked, exit 1" '[ $? != 0 ] && grep -q "Old: no URL serves" "$tmp/out"'
t "... and the old lock is left as it was"          'kept'

setup
api repos/o/dig/releases/tags/v1.0 '{"assets": [{"name": "a.apk", "size": 99, "digest": "sha256:ffff", "browser_download_url": "https://github.com/o/dig/releases/download/v1.0/a.apk"}]}'
run
t "a digest that does not match: not locked"        '[ $? != 0 ] && grep -q "Dig: no URL serves" "$tmp/out" && kept'

setup; printf 'vc=11\nreplaced after verify\n' > "$tmp/inv/universal/a.dig-1.0.apk"; run
t "a file whose bytes are not its SHA256SUMS line: refused, kept" '[ $? != 0 ] && grep -q "does not hash to its SHA256SUMS line" "$tmp/out" && kept'

setup; printf '{ broken' > "$tmp/apps.json"; run
t "a broken catalog: refused, the old lock kept"    '[ $? != 0 ] && grep -q "could not read the catalog" "$tmp/out" && kept'
setup; echo '{"apps": []}' > "$tmp/apps.json"; run
t "a catalog with nothing to lock: refused, kept"   '[ $? != 0 ] && kept'

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
