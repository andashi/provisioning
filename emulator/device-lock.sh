#!/usr/bin/env bash
# Advisory lock for the emulator instances, one lock per adb serial.
#
# Several sessions work on this repo at the same time and they all drive
# emulators. Two of them running UI automation on the same instance at once
# does not fail loudly - taps land in the wrong app, `am switch-user` fires
# mid-run, and the result looks like a flaky script rather than a collision.
# This makes the claim explicit instead of relying on people asking each other.
#
#   ./device-lock.sh acquire <owner> [serial]   claim the instance, fails if held
#   ./device-lock.sh release <owner> [serial]   give it back (only the owner may)
#   ./device-lock.sh status [serial]            who holds it, and for how long
#   ./device-lock.sh steal <owner> [serial]     take it anyway (prints who lost it)
#
# The serial names the instance (README, "Emulator instances"). Without the
# argument it comes from SERIAL (what run.sh and the launcher's e2e scripts
# export), then ADB_SERIAL (provision/), then ANDROID_SERIAL (adb itself), and
# falls back to emulator-5556. `status` with no serial from anywhere lists
# every instance that is held.
#
# It is ADVISORY: nothing stops a session from using adb without asking. It
# only works because everyone checks. `status` before any adb run is the habit
# that makes it worth having.
set -euo pipefail
cd "$(dirname "$0")/.."

STATE=".provision-state"
DEFAULT_SERIAL="emulator-5556"
# A full UI-automation run across six profiles takes hours, so a short
# threshold here cries wolf and trains people to ignore it. The age alone can
# never decide this anyway - only the session can.
STALE_MINUTES=180

mkdir -p "$STATE"

now()  { date +%s; }
fmt_age() {   # $1 = epoch seconds
  local s=$(( $(now) - $1 ))
  if   [ "$s" -lt 60 ];   then echo "${s}s"
  elif [ "$s" -lt 3600 ]; then echo "$((s/60))m"
  else echo "$((s/3600))h $(((s%3600)/60))m"
  fi
}

lock_for() { printf '%s/device-%s.lock' "$STATE" "$1"; }

read_lock() {   # $1 = lock file; sets HOLDER, SINCE; returns 1 if free
  HOLDER=""; SINCE=""
  [ -f "$1" ] || return 1
  # The file records SERIAL too; the file name already says it, and it must
  # not clobber the SERIAL this script was called with.
  local SERIAL=""
  # shellcheck disable=SC1090
  . "$1"
  [ -n "$HOLDER" ]
}

lock_body() { printf 'HOLDER=%q\nSINCE=%q\nSERIAL=%q\n' "$1" "$(now)" "$INSTANCE"; }

# Claim atomically: the lock appears complete or not at all. A check followed
# by a write lets two sessions that start in the same second both win.
claim() {   # $1 = owner; fails if the lock file exists
  local tmp; tmp="$(mktemp "$STATE/.device-lock.XXXXXX")"
  lock_body "$1" > "$tmp"
  if ln "$tmp" "$LOCK" 2>/dev/null; then rm -f "$tmp"; return 0; fi
  rm -f "$tmp"; return 1
}
overwrite() {   # $1 = owner
  local tmp; tmp="$(mktemp "$STATE/.device-lock.XXXXXX")"
  lock_body "$1" > "$tmp"
  mv -f "$tmp" "$LOCK"
}

# Until 2026-09-19 there was one lock for the whole machine, device.lock. A
# claim still sitting there belongs to the serial it recorded, or to
# emulator-5556, the only test instance back then.
migrate_legacy() {
  local legacy="$STATE/device.lock" HOLDER="" SINCE="" SERIAL="" dst
  [ -f "$legacy" ] || return 0
  # shellcheck disable=SC1090
  . "$legacy"
  dst="$(lock_for "${SERIAL:-$DEFAULT_SERIAL}")"
  if [ -e "$dst" ]; then
    echo "note: legacy $legacy (${HOLDER:-empty}) left alone, $dst exists - remove one by hand" >&2
  else
    mv "$legacy" "$dst"
  fi
}

# Is an emulator actually running on that instance? The lock and the instance
# had no connection in either direction: you could hold a lock on something
# that was never started, and an instance could run with nobody holding it -
# which is how one stayed up unlocked for five hours on a loaded host
# (2026-09-27). Knowing costs one pgrep, so status says it and release warns.
port_of() { printf '%s' "${1##*-}"; }
instance_running() {   # $1 = serial
  [ -n "$(pgrep -f "qemu-system.* -port $(port_of "$1")( |$)" 2>/dev/null | head -1)" ]
}
running_serials() {
  pgrep -af "qemu-system.* -port " 2>/dev/null \
    | sed -n 's/.* -port \([0-9][0-9]*\).*/emulator-\1/p' | sort -u
}

show() {   # $1 = serial
  if read_lock "$(lock_for "$1")"; then
    if instance_running "$1"; then
      echo "device $1 held by: $HOLDER ($(fmt_age "$SINCE")), running"
    else
      echo "device $1 held by: $HOLDER ($(fmt_age "$SINCE")), NOT running"
    fi
    if [ $(( ($(now) - SINCE) / 60 )) -ge "$STALE_MINUTES" ]; then
      echo "  held for over $((STALE_MINUTES/60))h - check whether that session is still alive"
      echo "  (ListAgents, or just ask it). 'steal <yourname> $1' takes it anyway."
    fi
  elif instance_running "$1"; then
    echo "device $1 free, but an emulator is RUNNING on it - anybody may stop it"
  else
    echo "device $1 free"
  fi
}

cmd_status() {
  if [ -n "$INSTANCE" ]; then show "$INSTANCE"; return; fi
  local f s any=0
  for f in "$STATE"/device-*.lock; do
    [ -e "$f" ] || continue
    s="${f##*/device-}"; s="${s%.lock}"
    read_lock "$f" || continue
    show "$s"; any=1
  done
  # A running instance nobody holds is the case worth seeing: it is the one
  # that gets stopped by somebody who checked and found it free.
  for s in $(running_serials); do
    read_lock "$(lock_for "$s")" && continue
    echo "device $s free, but an emulator is RUNNING on it - anybody may stop it"
    any=1
  done
  [ "$any" = 1 ] || echo "all devices free, nothing running"
}

# run.sh refuses an instance held by somebody else, and it decides who you are
# from LOCK_OWNER. Taking a lock without exporting it is therefore a trap that
# springs one command later - and it sprang on the author of the check within
# hours of writing it, as a start that "hung" because its output was muted.
# The hint goes where the situation is created, not where it is discovered.
hint_owner() {   # $1 = owner
  [ "${LOCK_OWNER:-}" = "$1" ] && return 0
  echo "  export LOCK_OWNER=$(printf '%q' "$1")   # so run.sh knows this instance is yours"
}

cmd_acquire() {
  local owner="$1"
  claim "$owner" && { echo "device $INSTANCE acquired by $owner"; hint_owner "$owner"; return 0; }
  if read_lock "$LOCK" && [ "$HOLDER" != "$owner" ]; then
    echo "device $INSTANCE held by $HOLDER since $(fmt_age "$SINCE") ago - not acquired" >&2
    return 1
  fi
  # Our own claim (refreshed) or an empty leftover file.
  overwrite "$owner"
  echo "device $INSTANCE acquired by $owner"
  hint_owner "$owner"
}

cmd_release() {
  local owner="$1"
  if ! read_lock "$LOCK"; then rm -f "$LOCK"; echo "device $INSTANCE was not held"; return 0; fi
  if [ "$HOLDER" != "$owner" ]; then
    echo "device $INSTANCE is held by $HOLDER, not by $owner - refusing to release" >&2
    echo "use 'steal $owner $INSTANCE' if that session is really gone" >&2
    return 1
  fi
  rm -f "$LOCK"
  echo "device $INSTANCE released by $owner"
  if instance_running "$INSTANCE"; then
    echo "  note: an emulator is still running on $INSTANCE. It is unlocked now," >&2
    echo "  so any session may stop it or load a snapshot into it." >&2
  fi
}

cmd_steal() {
  local owner="$1"
  if read_lock "$LOCK"; then echo "taking device $INSTANCE from $HOLDER (held $(fmt_age "$SINCE"))"; fi
  overwrite "$owner"
  echo "device $INSTANCE acquired by $owner"
}

cmd_holder() {
  # For scripts. `status` is prose for a person - "held by X (2h 14m), running"
  # - and a caller grepping that makes a lifecycle decision out of an English
  # sentence: one rewording and it silently flips. This prints the owner and
  # nothing else, and the exit status says whether there is one.
  if read_lock "$LOCK"; then printf '%s\n' "$HOLDER"; return 0; fi
  return 1
}

usage() { echo "usage: $0 {status [serial]|holder [serial]|acquire <owner> [serial]|release <owner> [serial]|steal <owner> [serial]}" >&2; exit 2; }

cmd="${1:-status}"
case "$cmd" in
  status|holder)        arg="${2:-}" ;;
  acquire|release|steal) [ $# -ge 2 ] || usage; arg="${3:-}" ;;
  *) usage ;;
esac
INSTANCE="${arg:-${SERIAL:-${ADB_SERIAL:-${ANDROID_SERIAL:-}}}}"
case "$cmd" in status) ;; *) INSTANCE="${INSTANCE:-$DEFAULT_SERIAL}" ;; esac
# Adb serials: emulator-5556, a hardware serial, host:port. Never a path.
[ -z "$INSTANCE" ] || [[ "$INSTANCE" =~ ^[A-Za-z0-9._:-]+$ ]] || { echo "not an adb serial: $INSTANCE" >&2; exit 2; }
LOCK="$(lock_for "${INSTANCE:-$DEFAULT_SERIAL}")"

migrate_legacy

case "$cmd" in
  status)  cmd_status ;;
  holder)  cmd_holder ;;
  acquire) cmd_acquire "$2" ;;
  release) cmd_release "$2" ;;
  steal)   cmd_steal "$2" ;;
esac
