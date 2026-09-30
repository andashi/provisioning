#!/usr/bin/env bash
# Cases for apk_version_code's answer on a machine without aapt2: the lock
# stands in, for bytes that hash to a locked entry and for nothing else.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# A PATH that has everything this machine has except aapt2.
mkdir -p "$tmp/bin"
IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do
  for f in "$d"/*; do
    b="$(basename "$f")"
    [ "$b" = aapt2 ] || [ -e "$tmp/bin/$b" ] || ln -s "$f" "$tmp/bin/$b" 2>/dev/null
  done
done
printf 'locked bytes' > "$tmp/a-1.apk"; printf 'other bytes' > "$tmp/b-1.apk"
sha="$(sha256sum < "$tmp/a-1.apk" | cut -d' ' -f1)"
jq -n --arg s "$sha" '{lockVersion: 1, entries: [{file: "universal/a-1.apk", sha256: $s, versionCode: 4711}]}' > "$tmp/lock.json"
pass=0; fail=0
t() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s: expected "%s", got "%s"\n' "$1" "$3" "$2"; fail=$((fail+1)); fi; }
q() { PATH="$tmp/bin" LOCK_FILE="$tmp/lock.json" bash -c 'source "$0/common.sh" 2>/dev/null; command -v aapt2 >/dev/null && { echo HAS-AAPT2; exit; }; apk_version_code "$1" || echo none' "$here" "$1"; }

t "without aapt2, locked bytes answer from the lock"   "$(q "$tmp/a-1.apk")" 4711
t "other bytes get no answer, whatever their name"     "$(q "$tmp/b-1.apk")" none
cp "$tmp/b-1.apk" "$tmp/a-1.apk"
t "... also under a locked file's name"                "$(q "$tmp/a-1.apk")" none

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
