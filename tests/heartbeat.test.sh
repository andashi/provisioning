#!/usr/bin/env bash
# Cases for apks/heartbeat.sh against a throwaway repository and a bare
# remote: what the heartbeat says, where it goes, and when it refuses.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
t() { if eval "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
      else printf '  FAIL  %s\n' "$1"; sed 's/^/        | /' "$tmp/out"; fail=$((fail+1)); fi; }
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

git init -q --bare "$tmp/remote.git"
git init -q -b main "$tmp/repo"; cd "$tmp/repo" || exit 1
git config user.name t; git config user.email t@example.org
mkdir apks; printf '{"lockVersion": 1, "entries": []}' > apks/lock.json   # no final newline on purpose
git add -A; git commit -q -m one; c1="$(git rev-parse HEAD)"
echo readme > README; git add -A; git commit -q -m "no lock change"
git rm -q apks/lock.json; git commit -q -m "lock gone"; c3="$(git rev-parse HEAD)"
git checkout -q "$c1" 2>/dev/null; echo dirty > untracked.txt
hb() { REMOTE="$tmp/remote.git" NOW=2026-10-10T12:00:00Z "$root/apks/heartbeat.sh" "$@" > "$tmp/out" 2>&1; }
r() { git --git-dir="$tmp/remote.git" "$@"; }

hb "${c1:0:7}" main
t "writes for main"                                    '[ $? = 0 ] && r rev-parse -q --verify refs/heads/lock-heartbeat >/dev/null'
t "one parentless commit, one file"                    '[ -z "$(r log -1 --format=%P lock-heartbeat)" ] && [ "$(r ls-tree --name-only lock-heartbeat)" = heartbeat.json ]'
t "lockSha256 is the hash of the lock's bytes, as a phone fetches them" \
  '[ "$(r show lock-heartbeat:heartbeat.json | jq -r .lockSha256)" = "$(git cat-file blob "$c1:apks/lock.json" | sha256sum | cut -d" " -f1)" ]'
t "mainCommit is the full commit that was checked"     '[ "$(r show lock-heartbeat:heartbeat.json | jq -r .mainCommit)" = "$c1" ]'
t "checked is when"                                    '[ "$(r show lock-heartbeat:heartbeat.json | jq -r .checked)" = 2026-10-10T12:00:00Z ]'
t "the work tree is untouched"                         '[ "$(git rev-parse HEAD)" = "$c1" ] && [ -f untracked.txt ] && [ -z "$(git status --porcelain --untracked-files=no)" ]'
hb "$c1" main
t "a second run replaces it, still without history"    '[ $? = 0 ] && [ -z "$(r log -1 --format=%P lock-heartbeat)" ] && [ "$(r rev-list --count lock-heartbeat)" = 1 ]'
phones="$(r rev-parse lock-heartbeat)"
hb "$c1" hbtest
t "another target writes its own branch, not the phones' one" '[ $? = 0 ] && r rev-parse -q --verify refs/heads/lock-heartbeat-hbtest >/dev/null && [ "$(r rev-parse lock-heartbeat)" = "$phones" ]'
hb deadbeef main
t "not a commit: refused"                              '[ $? != 0 ] && grep -q "is not a commit here" "$tmp/out"'
hb "$c3" main
t "a commit without a lock: refused"                   '[ $? != 0 ] && grep -q "has no apks/lock.json" "$tmp/out"'
REMOTE="$tmp/nowhere.git" NOW=x "$root/apks/heartbeat.sh" "$c1" main > "$tmp/out" 2>&1
t "a push that fails: the script fails"                '[ $? != 0 ]'

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
