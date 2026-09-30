#!/usr/bin/env bash
# Cases for apks/refresh-lock.sh: what it runs, when it stops, and what its
# summary tells a reviewer. fetch, verify and lock are fakes - the real ones
# have case files of their own - so these cases are about the routine and the
# report: a failure must stop it before any lock, a newly pinned signer must
# come first, and a same-version rebuild must not hide in an unchanged table.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
t() { if eval "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }

mkdir -p "$tmp/fake"
cat > "$tmp/fake/fetch" <<'F'
#!/usr/bin/env bash
echo "fetch ${APK_ABI:-?} $*" >> "$CALLS"
[ -n "${FAKE_FETCH_FAIL:-}" ] && exit 1
[ -n "${FAKE_NEW_CERT:-}" ] && echo x > "certs/$FAKE_NEW_CERT.cert"
exit 0
F
printf '#!/usr/bin/env bash\necho verify >> "$CALLS"\n' > "$tmp/fake/verify"
printf '#!/usr/bin/env bash\necho lock >> "$CALLS"\ncp "$FAKE_LOCK" lock.json\n' > "$tmp/fake/lock"
chmod +x "$tmp/fake/"*

e() { jq -n --arg p "$1" --arg v "$2" --arg s "$3" '{pkg: $p, label: $p, abi: "universal", version: $v, sha256: $s, urls: ["https://x/\($p)"]}'; }
lockof() { jq -s '{lockVersion: 1, generated: "g", entries: .}'; }
setup() {   # stdin: the lock as it is before
  rm -rf "$tmp/inv"; mkdir -p "$tmp/inv/certs"; echo a > "$tmp/inv/certs/app.a.cert"
  cat > "$tmp/inv/lock.json"; : > "$tmp/calls"; rm -f "$tmp/summary.md"
}
run() {   # env passed through; stdin: the lock lock.sh "writes"
  cat > "$tmp/newlock"
  CALLS="$tmp/calls" FAKE_LOCK="$tmp/newlock" APKS_DIR="$tmp/inv" \
    FETCH="$tmp/fake/fetch" VERIFY="$tmp/fake/verify" LOCKER="$tmp/fake/lock" \
    "$@" "$root/apks/refresh-lock.sh" --summary "$tmp/summary.md" > "$tmp/out" 2>&1
}

{ e app.a 1.0 aa; } | lockof | setup
{ e app.a 1.1 ab; } | lockof | run env
t "both ABIs are fetched, the second pass prunes, then verify, then lock" \
  '[ "$(tr "\n" "|" < "$tmp/calls")" = "fetch arm64-v8a |fetch x86_64 --prune|verify|lock|" ]'
t "a new version is a row: was, now"              'grep -qF "| app.a | universal | 1.0 | 1.1 |" "$tmp/summary.md"'
t "... and nothing claims the lock did not change" '! grep -q "did not change" "$tmp/summary.md"'

{ e app.a 1.0 aa; } | lockof | setup
{ e app.a 1.0 aa; } | lockof | run env FAKE_FETCH_FAIL=1
t "a failed fetch stops everything: exit non-zero" '[ $? != 0 ]'
t "... no verify, no lock, no summary"            '! grep -qE "verify|lock" "$tmp/calls" && [ ! -e "$tmp/summary.md" ]'

{ e app.a 1.0 aa; } | lockof | setup
{ e app.a 1.0 aa; e app.b 2.0 bb; } | lockof | run env FAKE_NEW_CERT=app.b
t "a signer pinned for the first time comes first" '[ "$(grep -m1 "^## " "$tmp/summary.md")" = "## ⚠ Signers pinned for the first time - review before merging" ] && grep -q "\`app.b\`" "$tmp/summary.md"'
t "... and the new app is a row too"              'grep -qF "| app.b | universal | new | 2.0 |" "$tmp/summary.md"'

{ e app.a 1.0 aa; } | lockof | setup
{ e app.a 1.0 zz; } | lockof | run env
t "same version, other bytes: its own section, first" '[ "$(grep -m1 "^## " "$tmp/summary.md")" = "## Same version, changed entry - look at these" ] && grep -qF "| app.a | universal | 1.0 | same version, OTHER BYTES |" "$tmp/summary.md"'
t "... and not \"did not change\""                 '! grep -q "did not change" "$tmp/summary.md"'

{ e app.a 1.0 aa; e app.gone 3.0 cc; } | lockof | setup
{ e app.a 1.0 aa; } | lockof | run env
t "an entry that left the lock is a row"          'grep -qF "| app.gone | universal | 3.0 | removed |" "$tmp/summary.md"'

{ e app.a 1.0 aa; } | lockof | setup
{ e app.a 1.0 aa; } | lockof | run env
t "nothing changed: says so"                      '[ $? = 0 ] && grep -q "The lock did not change." "$tmp/summary.md"'

"$root/apks/refresh-lock.sh" --nonsense > "$tmp/out" 2>&1
t "an unknown argument is refused, exit 2"        '[ $? = 2 ] && grep -q "unknown argument" "$tmp/out"'

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
