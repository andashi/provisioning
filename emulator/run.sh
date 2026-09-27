#!/usr/bin/env bash
# Starts the built GrapheneOS emulator headless and manages snapshots.
#   emulator/run.sh start|stop|snapshot <name>|restore <name>|shell|status
#
# Qt has NO Wayland backend. Headless (-no-window) is the normal case;
# for a GUI: GUI=1 -> QT_QPA_PLATFORM=xcb via XWayland.
set -euo pipefail

GOS_SRC="${GOS_SRC:-$HOME/android/grapheneos}"
# Absolute, because load_env cds into the build tree: anything this script
# reads from the repository afterwards must not depend on where it started.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOS_TARGET="${GOS_TARGET:-sdk_phone64_x86_64-cur-userdebug}"
AVD_NAME="${AVD_NAME:-graphene-fold}"
SERIAL="${SERIAL:-emulator-5554}"
# ADB serial implies the console port: emulator-5556 -> -port 5556.
PORT="${SERIAL#emulator-}"
[[ "$PORT" =~ ^[0-9]+$ ]] || { echo "x SERIAL must look like emulator-<port>, got: $SERIAL" >&2; exit 1; }
# Test instances get their own qcow2 overlays over the read-only build-tree
# images, so they never touch the working instance's *.qcow2 files:
#   OVERLAY_DIR=~/Development/GrapheneOS/emulator/instances/test SERIAL=emulator-5556 \
#     emulator/run.sh start
OVERLAY_DIR="${OVERLAY_DIR:-}"
# READ_ONLY=1 adds -read-only: all disk writes go to temp files and are
# discarded on exit. It disables snapshots ENTIRELY, load included - measured
# 2026-09-19: -snapshot at boot is ignored ("ignoring -snapshot option due to
# the use of -no-snapshot") and the console answers a load with "KO: Snapshot
# load is disabled because -read-only was specified". So a run that starts
# from a snapshot runs writable; that is safe, because loading a snapshot
# resets RAM and disks and nothing saves unless asked (-no-snapshot-save).
# Not needed for side-by-side runs when OVERLAY_DIR is set (own AVD identity =
# own multi-instance lock).
READ_ONLY="${READ_ONLY:-0}"
# Renderer for this instance: empty = the emulator decides (software on this
# host), "host" = the host GPU, also "swiftshader_indirect", "angle_indirect".
GPU="${GPU:-}"
# FOLDABLE=1 makes a NEW instance a foldable: two real files instead of the
# symlinks to the build tree, written once when the overlay dir is created.
# The OS image cannot do this on its own - see foldable_setup() for the three
# layers and why a foldable emulator build would not help.
FOLDABLE="${FOLDABLE:-0}"

c(){ [ -t 1 ] && printf '\033[%sm%s\033[0m\n' "$1" "$2" || printf '%s\n' "$2"; }
log(){ c '1;34' ":: $*"; }; ok(){ c '1;32' " + $*"; }
warn(){ c '1;33' " ! $*" >&2; }; die(){ c '1;31' " x $*" >&2; exit 1; }

# --- Ensure KVM access -------------------------------------------------
# After 'usermod -aG' the new group only takes effect on the next login.
# Instead of relogging: re-exec once via newgrp. After a reboot (udev
# default kvm/0666) or with an ACL this is a no-op.
kvm_ok() { [ -r /dev/kvm ] && [ -w /dev/kvm ]; }
ensure_kvm() {
  kvm_ok && return 0
  [ "${GOS_NEWGRP_RETRY:-0}" = "1" ] && die "no KVM access even after newgrp - check 'ls -l /dev/kvm'"
  local grp=""
  for g in plugdev kvm; do
    getent group "$g" 2>/dev/null | grep -qw "$USER" && { grp="$g"; break; }
  done
  [ -n "$grp" ] || die "no KVM access. Fix: sudo setfacl -m u:$USER:rw /dev/kvm"
  warn "KVM group '$grp' not active in this shell yet - re-exec via newgrp"
  local cmd; cmd="$(printf '%q ' "$(readlink -f "$0")" "$@")"
  exec newgrp "$grp" <<NEWGRP
export GOS_NEWGRP_RETRY=1
exec $cmd
NEWGRP
}

load_env() {
  [ -d "$GOS_SRC/.repo" ] || die "$GOS_SRC not synced - emulator/build.sh sync"
  cd "$GOS_SRC"
  # Like in build.sh: nounset has to stay off across lunch.
  set +u
  source build/envsetup.sh >/dev/null
  lunch "$GOS_TARGET" >/dev/null
  set -u
  command -v emulator >/dev/null || die "'emulator' not in PATH after lunch - incomplete build?"
}

# Create (once) a qcow2 overlay in $OVERLAY_DIR backed by a build-tree image,
# named exactly like the base (qemu detects the format by content).
# $1 = image file name, $2 = backing format (raw|qcow2).
overlay() {
  local base="$ANDROID_PRODUCT_OUT/$1" dst="$OVERLAY_DIR/$1"
  [ -f "$base" ] || die "base image missing: $base"
  [ -f "$dst" ] || qemu-img create -f qcow2 -b "$base" -F "$2" "$dst" >/dev/null
}

# Writes the foldable variant of one build-tree file into the overlay dir.
# Keys we override are dropped from the base first, so the file has each key
# once - the emulator is not documented to take the last one.
# Geometry is the Pixel 10 Pro Fold's, but hw.device.name MUST stay pixel_fold:
# with pixel_10_pro_fold no second display appears (measured 2026-09-22).
foldable_file() {   # $1 = base file in the build tree, $2 = destination
  case "$(basename "$1")" in
    advancedFeatures.ini)
      { grep -v '^SupportPixelFold' "$1"; echo "SupportPixelFold = on"; } > "$2"
      ;;
    config.ini)
      grep -vE '^(hw\.lcd\.(width|height|density)|hw\.device\.(name|manufacturer)|hw\.sensor\.hinge|hw\.sensor\.posture_list|hw\.displayRegion|skin\.(name|path))' "$1" > "$2"
      cat >> "$2" <<'FOLD'
# --- foldable profile (Pixel 10 Pro Fold, keys from the SDK's pixel_10_pro_fold AVD) ---
hw.lcd.width=2076
hw.lcd.height=2152
hw.lcd.density=390
hw.displayRegion.0.1.xOffset=0
hw.displayRegion.0.1.yOffset=0
hw.displayRegion.0.1.width=1080
hw.displayRegion.0.1.height=2364
hw.sensor.hinge=yes
hw.sensor.hinge.count=1
hw.sensor.hinge.type=1
hw.sensor.hinge.sub_type=1
hw.sensor.hinge.ranges=0-180
hw.sensor.hinge.defaults=180
hw.sensor.hinge.areas=1038-0-0-2152
hw.sensor.posture_list=1, 2, 3
hw.sensor.hinge_angles_posture_definitions=0-30, 30-150, 150-180
hw.sensor.hinge.fold_to_displayRegion.0.1_at_posture=1
hw.sensor.hinge.resizable.config=1
hw.device.name=pixel_fold
hw.device.manufacturer=Google
# The skin is the emulator window, so it has to be the INNER display - with the
# base skin the window stays phone-sized and the unfolded state has nowhere to go.
skin.name=2076x2152
skin.path=2076x2152
FOLD
      ;;
  esac
}

# Populate $OVERLAY_DIR as a complete image directory: symlinks for read-only
# content, qcow2 overlays for the images the instance writes to.
prepare_overlay_sysdir() {
  mkdir -p "$OVERLAY_DIR"
  local f base
  for f in "$ANDROID_PRODUCT_OUT"/*; do
    base="$(basename "$f")"
    case "$base" in
      # writable images -> overlaid below
      system-qemu.img|vendor-qemu.img|userdata-qemu.img|cache.img|encryptionkey.img) continue ;;
      # the working instance's qcow2 overlays — never link these in
      *.qcow2) continue ;;
      # per-instance state generated by the emulator
      *.lock|hardware-qemu.ini|bootcompleted.ini|version_num.cache|\
      snapshots|data|cache|tmpAdbCmds|modem_simulator|initrd) continue ;;
      # A foldable instance needs these two as REAL files: the emulator reads
      # config.ini from the image dir, and the second built-in display exists
      # only with SupportPixelFold, which the GrapheneOS build does not carry.
      config.ini|advancedFeatures.ini)
        if [ "$FOLDABLE" = "1" ]; then
          [ -e "$OVERLAY_DIR/$base" ] || foldable_file "$f" "$OVERLAY_DIR/$base"
        else
          [ -e "$OVERLAY_DIR/$base" ] || ln -s "$f" "$OVERLAY_DIR/$base"
        fi
        ;;
      *) [ -e "$OVERLAY_DIR/$base" ] || ln -s "$f" "$OVERLAY_DIR/$base" ;;
    esac
  done
  overlay system-qemu.img raw
  overlay vendor-qemu.img raw
  overlay userdata-qemu.img qcow2
  overlay cache.img raw
  overlay encryptionkey.img raw
}

# One-shot guest setup for a foldable instance, run once before its `clean`
# snapshot. Folding needs THREE layers to agree, and only the first comes from
# the AVD config:
#
#   1. the hinge sensor reports an ANGLE (hw.sensor.hinge* in config.ini)
#   2. device_state_configuration.xml turns angles into device STATES
#      (DeviceStateProviderImpl.java reads /data/system/devicestate/, falling
#      back to /vendor/etc/devicestate/)
#   3. display_layout_configuration.xml turns a state into a DISPLAY LAYOUT
#      (DeviceStateToLayoutMap.java reads /data/system/displayconfig/)
#
# Sensor keys alone give you states and no resize - measured, and the reason
# this verb exists. Our image already has the plumbing for 2 and 3: the
# GoldfishSkinConfig symlink vendor/etc/displayconfig -> /data/system/displayconfig,
# and an init trigger that copies a state table the emulator hands over at boot.
# But the emulator only hands it over for a foldable AVD: on this instance
# ro.boot.qemu.device_state is empty and init.svc.ranchu-device-state stays
# stopped, so the tables have to be placed by hand, once, into the userdata
# overlay - where the `clean` snapshot then carries them.
#
# Rebuilding the image with EMULATOR_DEVICE_TYPE_FOLDABLE=true does NOT help:
# it copies the same files to /data/misc/pixel_fold/, which is not a path the
# framework reads (base_phone.mk:33).
foldable_setup() {
  local src="$GOS_SRC/device/generic/goldfish/pixel_fold"
  [ -d "$src" ] || die "goldfish foldable configs not found: $src"
  adb -s "$SERIAL" wait-for-device
  adb -s "$SERIAL" root >/dev/null 2>&1 || die "adb root failed - foldable setup needs a userdebug build"
  adb -s "$SERIAL" wait-for-device
  ash_ mkdir -p /data/system/devicestate /data/system/displayconfig
  adb -s "$SERIAL" push "$src/device_state_configuration.xml"   /data/system/devicestate/ >/dev/null \
    || die "pushing device_state_configuration.xml failed"
  adb -s "$SERIAL" push "$src/display_layout_configuration.xml" /data/system/displayconfig/ >/dev/null \
    || die "pushing display_layout_configuration.xml failed"
  ash_ chown -R system:system /data/system/devicestate /data/system/displayconfig
  ok "state and layout tables in place"
  # Shipped but disabled in this build; they carry the framework resources for
  # the foldable geometry.
  local rro
  for rro in com.android.internal.emulation.pixel_fold com.android.systemui.emulation.pixel_fold; do
    if ash_ cmd overlay enable "$rro" >/dev/null 2>&1; then ok "overlay enabled: $rro"
    else warn "overlay not enabled: $rro"; fi
  done
  log "rebooting - the tables are read at boot"
  adb -s "$SERIAL" reboot
  adb -s "$SERIAL" wait-for-device
  until [ "$(adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
  local states
  states="$(ash_ cmd device_state print-states-simple 2>/dev/null | tr -d '\r' | paste -sd,)"
  [ -n "$states" ] && ok "device states: $states" || warn "no device states - check the two XML files"
  log "fold with: adb -s $SERIAL shell cmd device_state state 0    unfold: state 2 (or: state reset)"
}

ash_() { adb -s "$SERIAL" shell "$@" </dev/null >/dev/null 2>&1; }

# The qemu process of THIS instance: the console port is unique per instance,
# so it identifies the process without touching the other one's.
# Which process IS this instance? `pgrep -f "qemu-system.* -port $PORT"` was
# not an answer to that: -f matches the whole command line, so any shell that
# merely mentions the string counts. Demonstrated 2026-09-27 - a bash whose
# argv contained "qemu-system-x86_64 -port 5599" was reported as the emulator
# on 5599, which makes `start` refuse, `stop` wait thirty seconds and fail,
# and `status` lie. A check that can find itself is the purest form of a check
# that means nothing.
#
# So: the PROGRAM has to be a qemu-system binary (/proc/<pid>/comm, not the
# command line), and the port has to be an actual argument pair rather than a
# substring anywhere in it.
qemu_pids() {
  local pid comm
  for pid in $(pgrep -f qemu-system 2>/dev/null); do
    comm="$(cat "/proc/$pid/comm" 2>/dev/null)" || continue
    case "$comm" in qemu-system*) printf '%s\n' "$pid" ;; esac
  done
}
has_arg_pair() {   # $1=pid $2=flag $3=value - adjacent argv entries
  tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null \
    | awk -v f="$2" -v v="$3" 'p == f && $0 == v { hit = 1; exit } { p = $0 } END { exit !hit }'
}
emu_pid() {
  local pid
  for pid in $(qemu_pids); do
    has_arg_pair "$pid" -port "$PORT" && { printf '%s' "$pid"; return 0; }
  done
  return 1
}

# The emulator keeps a multiinstance.lock next to its images (per
# ANDROID_PRODUCT_OUT, i.e. per instance). It stays behind when the process
# is killed instead of shut down, and a later start then refuses with
# "Another emulator instance is running" - measured 2026-09-19: a queued L4
# run hung 20 minutes in wait-for-device behind such a stale file. So: a lock
# without a process is stale and removed; a lock with a live process is
# respected, that is a real collision.
clear_stale_lock() {
  local dir="${OVERLAY_DIR:-${ANDROID_PRODUCT_OUT:-}}" lock
  [ -n "$dir" ] || return 0
  lock="$dir/multiinstance.lock"
  [ -e "$lock" ] || return 0
  if [ -z "$(emu_pid)" ]; then
    rm -f "$lock" && warn "stale $lock removed (no emulator on port $PORT)"
  fi
}

# An overlay dir belongs to exactly one instance (README, "Emulator
# instances"). A qemu on ANOTHER port using the same dir means SERIAL and
# OVERLAY_DIR were paired wrong: both would write the same qcow2 files, and
# clear_stale_lock would take the live one's multiinstance.lock for stale.
# ---- The device lock, enforced rather than hoped for ----------------------
# The lock was advisory: device-lock.sh knew who held an instance, and run.sh
# killed it regardless. On 2026-09-27 that cost another session its run - a
# sweep runner called acquire without checking the result, start correctly
# refused with "already running", and stop then killed the instance out from
# under its owner. The runner's bug is theirs and fixed; it only reached the
# instance because stop let it through.
#
# Four autonomous sessions share five instances here. A lock that only stops
# the careful is not a lock, because any script with a bug in its acquisition
# path becomes a script that ignores it.
#
# LOCK_OWNER says who you are - the same string you passed to
# `device-lock.sh acquire`. Without it you are refused whenever somebody else
# holds the instance. LOCK_FORCE=1 overrides, for cleaning up after a session
# that is really gone; it prints who is being walked past.
lock_holder() {
  local f=".provision-state/device-${SERIAL}.lock" HOLDER="" SINCE="" SERIAL=""
  [ -f "$REPO_ROOT/$f" ] || return 1
  # shellcheck disable=SC1090
  . "$REPO_ROOT/$f"
  [ -n "$HOLDER" ] && printf '%s' "$HOLDER"
}

require_lock() {   # $1 = what is about to happen
  local holder
  if ! holder="$(lock_holder)"; then
    warn "$SERIAL is not locked - $1 anyway. Other sessions cannot tell this instance is yours:"
    warn "  emulator/device-lock.sh acquire \"<owner>\" $SERIAL"
    return 0
  fi
  [ "$holder" = "${LOCK_OWNER:-}" ] && return 0
  if [ "${LOCK_FORCE:-0}" = "1" ]; then
    warn "$SERIAL is held by $holder - $1 anyway (LOCK_FORCE=1)"
    return 0
  fi
  die "$SERIAL is held by $holder, refusing to $1.
   If that session is gone:   LOCK_FORCE=1 $0 $CMD
   If it is you:              LOCK_OWNER=$holder $0 $CMD"
}

guard_overlay_dir() {
  [ -n "$OVERLAY_DIR" ] || return 0
  [[ "$OVERLAY_DIR" = /* ]] || die "OVERLAY_DIR must be an absolute path (run.sh changes into $GOS_SRC), got: $OVERLAY_DIR"
  local pid
  pid=""
  for pid in $(qemu_pids) ""; do
    [ -n "$pid" ] || break
    has_arg_pair "$pid" -snapstorage "$OVERLAY_DIR/snapshots.img" && break
  done
  [ -z "$pid" ] || [ "$pid" = "$(emu_pid)" ] \
    || die "$OVERLAY_DIR is in use by the emulator pid $pid on another port - SERIAL and OVERLAY_DIR must stay paired"
}

start() {
  require_lock "start it"
  ensure_kvm "$@"
  guard_overlay_dir
  [ "$READ_ONLY" != "1" ] || [ -z "${SNAPSHOT:-}" ] \
    || die "READ_ONLY=1 cannot load snapshots (see the READ_ONLY comment) - start without READ_ONLY to load '$SNAPSHOT'"
  load_env
  clear_stale_lock
  [ -z "$(emu_pid)" ] || die "an emulator is already running on port $PORT (pid $(emu_pid)) - stop it first"
  local args=(-no-snapshot-save -no-boot-anim -accel on -port "$PORT")
  # GPU=host renders on the host GPU instead of SwiftShader. Opt-in, because
  # the emulator's driver blocklist switches this host to software on its own
  # ("Your GPU drivers may have a bug") and -gpu on the command line is what
  # overrides that - hw.gpu.mode in config.ini does not. Off by default, so
  # nothing that works today changes.
  #
  # Snapshots carry GPU state: one taken under software rendering may refuse
  # to load, or load wrong, under a different mode. Treat GPU as part of the
  # instance's identity, not as a flag to flip between runs.
  [ -n "${GPU:-}" ] && args+=(-gpu "$GPU")
  if [ "$READ_ONLY" = "1" ]; then
    args+=(-read-only)
  elif [ -z "$OVERLAY_DIR" ]; then
    # Only the working instance gets -writable-system: its system/vendor
    # overlays always land in the build tree (even with -system/-vendor
    # pointing elsewhere), so a test instance must not request it.
    args+=(-writable-system)
  fi
  if [ -n "$OVERLAY_DIR" ]; then
    prepare_overlay_sysdir
    # Point the build-tree launcher at the overlay dir: the pseudo-AVD
    # identity (and with it the multi-instance lock) is derived from
    # ANDROID_PRODUCT_OUT, so the test instance no longer collides with the
    # working instance — while keeping the build-mode launch path (PCI disk
    # bus, correct image wiring) that a bare SDK-style -avd launch gets wrong.
    export ANDROID_PRODUCT_OUT="$OVERLAY_DIR"
    args+=(-snapstorage "$OVERLAY_DIR/snapshots.img")
  fi
  local log="$GOS_SRC/emulator.log"
  [ "$PORT" != "5554" ] && log="$GOS_SRC/emulator-$PORT.log"
  if [ "${GUI:-0}" = "1" ]; then
    export QT_QPA_PLATFORM=xcb
    log "GUI mode via XWayland (QT_QPA_PLATFORM=xcb)"
  else
    args+=(-no-window)
  fi
  # SNAPSHOT is loaded via the console as soon as it answers (see below),
  # not via -snapshot: together with -no-snapshot-save the emulator silently
  # ignores -snapshot ("ignoring -snapshot option due to the use of
  # -no-snapshot") and cold-boots from whatever the overlay disk holds.
  # Measured 2026-09-19: a "run from clean" that found six provisioned
  # profiles waiting. Early load measured at 7 s from launch to active.

  local ro=""
  [ "$READ_ONLY" = "1" ] && ro=", read-only"
  log "Emulator starting (${GUI:+GUI}${GUI:-headless}, port $PORT${OVERLAY_DIR:+, overlays $OVERLAY_DIR}$ro)"
  nohup emulator "${args[@]}" >"$log" 2>&1 &
  ok "PID $! - Log: $log"
  if [ -n "${SNAPSHOT:-}" ]; then
    # Load as soon as the console answers, not after the cold boot has
    # finished: the load replaces RAM and disks anyway, so every second of
    # the cold boot (1.5-2 min, more on a provisioned disk) would be wasted.
    log "waiting for the console, then loading snapshot '$SNAPSHOT'"
    local i=0
    until adb -s "$SERIAL" emu avd snapshot list 2>/dev/null | grep -q "^OK"; do
      sleep 2; i=$((i+1))
      [ $i -lt 90 ] || die "console on port $PORT did not answer within 180 s - see $log"
    done
    restore "$SNAPSHOT"
    adb -s "$SERIAL" wait-for-device
    until [ "$(adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
    ok "snapshot '$SNAPSHOT' active: $SERIAL"
  else
    log "waiting for boot"
    adb -s "$SERIAL" wait-for-device
    until [ "$(adb -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do sleep 2; done
    ok "booted: $SERIAL"
  fi
  adb -s "$SERIAL" root >/dev/null 2>&1 || warn "adb root not available (needs a userdebug build)"
  status
}

# Stop, then WAIT for the process: 'emu kill' returns immediately, while the
# emulator takes up to 20 s to shut down and holds its lock and port until
# then. A start right after an unwaited stop collides with exactly that.
# Exit status is the whole point of calling this from a script: 0 means the
# port is free - whether or not anything was running - and non-zero means it
# is NOT, either because the lock refused or because the emulator outlived the
# wait. It used to return whatever clear_stale_lock happened to return, so
# "still alive after 30 s" exited 0: a failure reported as success, in the one
# verb whose entire job is to make something stop. Found 2026-09-27 while
# looking at why other sessions write `|| true` around it - the refusal was
# the loud part and the real failure was the silent one.
stop() {
  require_lock "stop it"
  adb -s "$SERIAL" emu kill 2>/dev/null && ok "stop requested" || warn "was not running"
  local i=0
  while [ -n "$(emu_pid)" ] && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
  if [ -n "$(emu_pid)" ]; then
    warn "emulator on port $PORT still alive after 30 s (pid $(emu_pid))"
    clear_stale_lock
    return 1
  fi
  ok "stopped (port $PORT free)"
  clear_stale_lock
  return 0
}
# The console answers a failed load or save with "KO: ..." and adb still exits
# 0. Measured 2026-09-19: `snapshot load does-not-exist` printed "KO: Snapshot
# load failure: snapshot doesn't exist" with exit code 0, and the run would
# have gone on from the cold-booted disk. So the reply decides, not the code.
emu_snapshot() {   # $1 = save|load, $2 = name
  local out
  out="$(adb -s "$SERIAL" emu avd snapshot "$1" "$2" 2>&1 | tr -d '\r')" \
    || die "snapshot $1 '$2' on $SERIAL: adb failed: $out"
  if grep -q '^KO' <<<"$out"; then
    die "snapshot $1 '$2' on $SERIAL failed: $(grep '^KO' <<<"$out" | tail -1)"
  fi
  if ! grep -q '^OK' <<<"$out"; then
    die "snapshot $1 '$2' on $SERIAL: unexpected console reply: $out"
  fi
}
snapshot() { [ -n "${1:-}" ] || die "name missing"; require_lock "write a snapshot on it"; emu_snapshot save "$1"; ok "snapshot '$1' saved"; }
restore()  { [ -n "${1:-}" ] || die "name missing"; require_lock "load a snapshot into it"; emu_snapshot load "$1"; ok "snapshot '$1' loaded"; }
shell_()   { adb -s "$SERIAL" shell; }
# An answer instead of an inference: callers were deducing this from the prose
# of `status`, or running their own pgrep with the flaw described above.
running() {
  local pid
  if pid="$(emu_pid)"; then echo "$pid"; return 0; fi
  return 1
}
status() {
  adb -s "$SERIAL" shell getprop ro.modversion 2>/dev/null | tr -d '\r' | sed 's/^/   GrapheneOS: /' || true
  adb -s "$SERIAL" shell pm list users 2>/dev/null | tr -d '\r' | sed 's/^/   /' || true
}

CMD="${1:-status}"
case "$CMD" in
  start) shift; start "$@" ;;
  stop) stop ;;
  running) running ;;
  snapshot) shift; snapshot "${1:-}" ;;
  restore)  shift; restore  "${1:-}" ;;
  foldable-setup) foldable_setup ;;
  shell) shell_ ;;
  status) status ;;
  *) die "usage: $0 start|stop|snapshot <name>|restore <name>|foldable-setup|shell|status" ;;
esac
