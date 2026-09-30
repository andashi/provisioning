#!/usr/bin/env bash
# Cases for tests/e2e/identity.sh: the e2e scripts' claim that every adb call
# ran as shell rests on this function, so it must not let a root adbd - or an
# adbd it could not ask - through. adb is a fake whose answer to `id -u` is
# held in a state file, and `unroot` either works, works late, or never does.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/adb" <<'FAKE'
#!/usr/bin/env bash
# state: $STATE/uid (current answer), $STATE/after_unroot (answer once unroot
# was called; empty = unroot changes nothing), $STATE/calls (log)
[ "$1" = "-s" ] && shift 2
echo "$*" >> "$STATE/calls"
case "$*" in
  "shell id -u") [ -s "$STATE/uid" ] && cat "$STATE/uid" || exit 1;;
  "unroot") [ -s "$STATE/after_unroot" ] && cp "$STATE/after_unroot" "$STATE/uid"; exit 0;;
  *) echo "fake adb: unexpected: $*" >&2; exit 97;;
esac
FAKE
chmod +x "$tmp/bin/adb"
pass=0; fail=0
t() { if eval "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }
run() {   # $1=uid now $2=uid after unroot ("" = unchanged)
  rm -rf "$tmp/s"; mkdir -p "$tmp/s"; printf '%s' "$1" > "$tmp/s/uid"; printf '%s' "$2" > "$tmp/s/after_unroot"
  PATH="$tmp/bin:$PATH" STATE="$tmp/s" SERIAL=emulator-0 IDENTITY_WAIT=3 IDENTITY_POLL=0 \
    bash -c 'source "$0/tests/e2e/identity.sh"; as_shell; echo REACHED' "$root" > "$tmp/out" 2>&1
}

run 2000 ""
t "already shell: passes, says so, no unroot" '[ $? = 0 ] && grep -q "uid 2000 (shell)" "$tmp/out" && grep -q REACHED "$tmp/out" && ! grep -q unroot "$tmp/s/calls"'
run 0 2000
t "root: unroots, then passes as shell"        '[ $? = 0 ] && grep -q unroot "$tmp/s/calls" && grep -q "uid 2000 (shell)" "$tmp/out"'
run 0 ""
t "root that will not unroot: refuses, exit 2" '[ $? = 2 ] && grep -q "does not run as shell (uid 0)" "$tmp/out" && ! grep -q REACHED "$tmp/out"'
run "" ""
t "no answer at all: refuses"                  '[ $? = 2 ] && grep -q "uid ?" "$tmp/out" && ! grep -q REACHED "$tmp/out"'
run 1000 ""
t "any other uid: refuses"                     '[ $? = 2 ] && ! grep -q REACHED "$tmp/out"'

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
