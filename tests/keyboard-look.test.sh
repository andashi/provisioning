#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
source "$root/lib/keyboard-look.sh"

case_input="$tmp/config.json"
printf '%s\n' '{"schemaVersion":2,"appearance":{"glass":{"blur":12,"tint":0.3,"specular":0},"theme":{"palette":{"dark":{"surface":"#21191F","error":"#FFB4AB"}}}}}' > "$case_input"
hash=$(sha256sum "$case_input" | cut -d' ' -f1)
expected='{"schemaVersion":2,"appearance":{"glass":{"blur":12,"tint":0.3,"floor":0,"scheme":"dark"},"theme":{"palette":{"dark":{"surface":"#21191F"}}}}}'
export DRY_RUN=0
package_result='package:org.andashi.keyboard'
written="$tmp/writes"
fake_report="$tmp/report"
fake_effective="$tmp/effective"
printf '%s\n' "$expected" > "$fake_effective"

ash_ro() {
    [[ "$*" == "pm list packages --user 10 org.andashi.keyboard" ]] || return 2
    [[ "$package_result" != failure ]] || return 1
    printf '%s\n' "$package_result"
}
ingest_write() {
    [[ "$1" == content://org.andashi.keyboard.config-ingest/launcher.json && "$2" == "$case_input" && "$3" == 10 ]] || return 2
    printf 'write\n' >> "$written"
    [[ "${write_succeeds:-yes}" == yes ]] || return 1
    printf '{"success":true,"configSha256":"%s"}\n' "$hash" > "$fake_report"
}
query_state() {
    [[ "$PKG" == org.andashi.keyboard && "$2" == 10 ]] || return 2
    if [[ "$1" == diagnostics ]]; then cat "$fake_report"; else cat "$fake_effective"; fi
}
log() { :; }
ok() { :; }
warn() { :; }
sleep() { :; }
assert() {
    local description=$1
    shift
    if "$@"; then printf 'ok: %s\n' "$description"; else printf 'failed: %s\n' "$description" >&2; exit 1; fi
}
refuses() { if "$@"; then return 1; fi; }

package_result='package:org.andashi.keyboard.debug'
assert "a different package is skipped" sync_keyboard_look 10 "$case_input" "$hash" Test
assert "skipping did not upload" test ! -e "$written"

package_result=failure
assert "a failed package lookup is not a skip" refuses sync_keyboard_look 10 "$case_input" "$hash" Test
package_result='package:org.andashi.keyboard'
printf '{}\n' > "$fake_report"
DRY_RUN=1 assert "dry run can inspect an installed keyboard" sync_keyboard_look 10 "$case_input" "$hash" Test
assert "dry run did not upload" test ! -e "$written"

assert "upload uses the same host file and confirms its hash and roles" sync_keyboard_look 10 "$case_input" "$hash" Test
assert "one upload occurred" test "$(wc -l < "$written")" -eq 1
assert "matching state is idempotent" sync_keyboard_look 10 "$case_input" "$hash" Test
assert "idempotence did not upload again" test "$(wc -l < "$written")" -eq 1

printf '%s\n' "$expected" | jq '.appearance.theme.palette.dark.surface = "#FFFFFF"' > "$fake_effective"
assert "matching hash with wrong palette is a failure" refuses sync_keyboard_look 10 "$case_input" "$hash" Test
assert "a repair was attempted" test "$(wc -l < "$written")" -eq 2
