#!/usr/bin/env bash
# Sourced by the e2e scripts: make adbd run as shell, and prove it.
#
# The claim of this repository is about the adb shell (uid 2000), because
# that is all a production GrapheneOS phone offers. The emulator is a
# userdebug build, and emulator/run.sh start runs `adb root` on every start -
# so a snapshot saved afterwards carries a root adbd, and every test loaded
# from it ran as root while its pull request said shell. Found 2026-09-30,
# when `pm set-installer` failed with "Unknown calling UID: 0". The identity
# is part of the result, so it is set and asserted, never assumed.
as_shell() {   # uses $SERIAL; exits the test if adbd will not run as shell
  local id _
  id="$(adb -s "$SERIAL" shell id -u 2>/dev/null | tr -d '\r')"
  if [ "$id" != 2000 ]; then
    adb -s "$SERIAL" unroot >/dev/null 2>&1 || true
    for _ in $(seq 1 "${IDENTITY_WAIT:-30}"); do
      sleep "${IDENTITY_POLL:-1}"
      id="$(adb -s "$SERIAL" shell id -u 2>/dev/null | tr -d '\r')"
      [ "$id" = 2000 ] && break
    done
  fi
  [ "$id" = 2000 ] || { echo "e2e: adbd does not run as shell (uid ${id:-?}) - refusing to test" >&2; exit 2; }
  printf '  ..    adbd identity: uid %s (shell)\n' "$id"
}
