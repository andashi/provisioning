#!/usr/bin/env bash
# Cases for the two decisions apks/fetch.sh makes for a vendor's download
# directory (source direct): which version a listing offers, and whether a
# detached signature is accepted. The functions are taken from fetch.sh
# itself, so a case cannot drift from the code.
#
# Offline: curl answers from fixture files, and the keys are made here, in a
# throwaway keyring, so no case depends on a keyserver or on Yubico.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'gpgconf --homedir "$tmp/gpg" --kill all 2>/dev/null; rm -rf "$tmp"' EXIT
pass=0; fail=0
t() { if eval "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }

ok(){ printf ' + %s\n' "$*"; }; bad(){ printf ' x %s\n' "$*" >&2; }
eval "$(sed -n '/^direct_versions() {/,/^}/p; /^verify_detached_sig() {/,/^}/p' "$root/apks/fetch.sh")"
declare -F direct_versions verify_detached_sig >/dev/null || { echo "functions not found in fetch.sh" >&2; exit 1; }

mkdir -p "$tmp/bin" "$tmp/serve"
ln -s "$root/tests/fixtures/fake-curl" "$tmp/bin/curl"
export FAKE_CURL_DIR="$tmp/serve"
curl() { "$tmp/bin/curl" "$@"; }

# --- direct_versions -----------------------------------------------------
listing='<a href="v-7.4.1-android.apk">x</a> <a href="v-7.4.1-android.apk.sig">s</a>
<a href="v-7.10.0-android.apk">x</a> <a href="v-7.4.2-win64.msi">w</a>
<a href="v-8.0-androidXapk">dot is a dot</a> <a href="w-9.9-android.apk">other app</a>
<a href="v-../x-android.apk">no digit</a>'
vers() { direct_versions 'v-{version}-android.apk' <<<"$listing" | sort -V | tr '\n' ' '; }
t "every version of the pattern, once, .sig and desktop builds left out" '[ "$(vers)" = "7.4.1 7.10.0 " ]'
t "the highest by version order, not by text"   '[ "$(direct_versions "v-{version}-android.apk" <<<"$listing" | sort -V | tail -1)" = 7.10.0 ]'
t "a dot in the pattern matches only a dot"      '! vers | grep -q 8.0'
t "a version starts with a digit"                '! vers | grep -q "\.\."'
t "nothing offered: nothing, not an error"       '[ -z "$(direct_versions "v-{version}-android.apk" <<<"empty")" ]'

# --- verify_detached_sig ---------------------------------------------------
G="$tmp/gpg"; mkdir -p "$G"; chmod 700 "$G"
gen() { gpg --homedir "$G" --batch --quiet --passphrase '' --quick-gen-key "$1" ed25519 sign never 2>/dev/null
        gpg --homedir "$G" --batch --with-colons --fingerprint "$1" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}'; }
fa="$(gen vendor@example)"; fb="$(gen intruder@example)"
gpg --homedir "$G" --batch --armor --export "$fa" > "$tmp/vendor.asc"
gpg --homedir "$G" --batch --armor --export "$fa" "$fb" > "$tmp/two.asc"
printf 'the apk\n' > "$tmp/app.apk"
gpg --homedir "$G" --batch --quiet --local-user "$fa" --detach-sign -o "$tmp/serve/good.sig" "$tmp/app.apk"
gpg --homedir "$G" --batch --quiet --local-user "$fb" --detach-sign -o "$tmp/serve/intruder.sig" "$tmp/app.apk"
printf 'tampered\n' > "$tmp/tampered.apk"
v() { verify_detached_sig "$@" > "$tmp/out" 2>&1; }

v "$tmp/app.apk" https://v.example/good.sig "$fa" "$tmp/vendor.asc"
t "the vendor's signature over these bytes: accepted"  '[ $? = 0 ]'
v "$tmp/tampered.apk" https://v.example/good.sig "$fa" "$tmp/vendor.asc"
t "other bytes under the same signature: refused"      '[ $? != 0 ] && grep -q "does NOT verify" "$tmp/out"'
v "$tmp/app.apk" https://v.example/intruder.sig "$fa" "$tmp/vendor.asc"
t "a signature by a key not in the file: refused"      '[ $? != 0 ] && grep -q "does NOT verify" "$tmp/out"'
v "$tmp/app.apk" https://v.example/intruder.sig "$fa" "$tmp/two.asc"
t "a key file that carries a second key: refused before that key could sign" '[ $? != 0 ] && grep -q "is not exactly the key" "$tmp/out"'
v "$tmp/app.apk" https://v.example/good.sig "$fb" "$tmp/vendor.asc"
t "a key file that is not the named key: refused"      '[ $? != 0 ] && grep -q "is not exactly the key" "$tmp/out"'
v "$tmp/app.apk" https://v.example/gone.sig "$fa" "$tmp/vendor.asc"
t "no signature to download: refused"                  '[ $? != 0 ] && grep -q "signature not downloadable" "$tmp/out"'
v "$tmp/app.apk" https://v.example/good.sig "$fa" "$tmp/missing.asc"
t "no key file: refused"                               '[ $? != 0 ] && grep -q "missing" "$tmp/out"'

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
