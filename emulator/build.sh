#!/usr/bin/env bash
# Build GrapheneOS for the emulator. Phased + resumable.
#   emulator/build.sh prereqs|sync|build|all
#
# Source lives OUTSIDE the repo (136 GiB sync + ~100 GiB out):
#   GOS_SRC=... (default: ~/android/grapheneos)
set -euo pipefail

GOS_SRC="${GOS_SRC:-$HOME/android/grapheneos}"
GOS_BRANCH="${GOS_BRANCH:-17}"          # 17 = intended branch for emulator/generic
GOS_MANIFEST="${GOS_MANIFEST:-https://github.com/GrapheneOS/platform_manifest.git}"
GOS_TARGET="${GOS_TARGET:-sdk_phone64_x86_64-cur-userdebug}"
# The build is CPU-bound: nproc minus a reserve, so the machine stays usable.
# On this box (24 threads) that comes out to 20. Floor of 4 for small hosts.
_j=$(( $(nproc) - 4 )); [ "$_j" -lt 4 ] && _j=4
JOBS="${JOBS:-$_j}"

c() { [ -t 1 ] && printf '\033[%sm%s\033[0m\n' "$1" "$2" || printf '%s\n' "$2"; }
log(){ c '1;34' ":: $*"; }
ok(){  c '1;32' " + $*"; }
warn(){ c '1;33' " ! $*" >&2; }
die(){ c '1;31' " x $*" >&2; exit 1; }

prereqs() {
  log "Prereq check"
  local fail=0

  local ram; ram=$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)
  [ "$ram" -ge 32 ] && ok "RAM: ${ram} GiB" || { warn "RAM: ${ram} GiB (<32 GiB)"; fail=1; }

  mkdir -p "$(dirname "$GOS_SRC")"
  local free; free=$(df -BG --output=avail "$(dirname "$GOS_SRC")" | tail -1 | tr -dc '0-9')
  [ "$free" -ge 240 ] && ok "Space: ${free} GiB free under $(dirname "$GOS_SRC")" \
    || { warn "Space: ${free} GiB (<240 GiB: 136 sync + ~100 build)"; fail=1; }

  for t in repo git python3 gpg openssl unzip zip rsync yarnpkg curl; do
    command -v "$t" >/dev/null && ok "$t" || { warn "$t missing"; fail=1; }
  done

  # 32-bit runtime for Vanadium
  if pacman -Q lib32-glibc lib32-gcc-libs >/dev/null 2>&1; then
    ok "lib32-glibc / lib32-gcc-libs"
  else
    warn "lib32-glibc + lib32-gcc-libs missing (Vanadium build) - enable the multilib repo"; fail=1
  fi

  # KVM is only needed for the emulator START, not for the build.
  if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ok "KVM"; else warn "KVM not accessible (only relevant at emulator start)"; fi

  [ -n "${TMUX:-}" ] && ok "running in tmux" || warn "NOT in tmux - sync/build run for hours, use tmux"

  [ "$fail" = "0" ] || die "Prereqs incomplete"
  ok "all hard prereqs satisfied"
}

sync() {
  log "Syncing to $GOS_SRC (branch $GOS_BRANCH)"
  mkdir -p "$GOS_SRC"; cd "$GOS_SRC"

  # SYNC_DEPTH=N -> shallow clone. A lifeline for slow connections: GitHub
  # cuts off git operations after ~1h. Anyone who can't get a multi-GB repo
  # through in that hour loses EVERYTHING (git fetch doesn't resume) and gets
  # stuck in an endless loop of failed attempts. --depth=1 only fetches the
  # tip commit and fits inside the window. For the dev-target emulator the
  # missing history doesn't matter; for a release build later, sync fresh
  # without SYNC_DEPTH.
  # WARNING: --depth is an option of 'repo init', NOT of 'repo sync'.
  local depth_args=()
  [ -n "${SYNC_DEPTH:-}" ] && depth_args=(--depth="$SYNC_DEPTH")
  if [ -d .repo ]; then
    ok ".repo exists - incremental sync"
    if [ ${#depth_args[@]} -gt 0 ]; then
      repo init -u "$GOS_MANIFEST" -b "$GOS_BRANCH" "${depth_args[@]}" >/dev/null \
        && warn "shallow sync enabled (--depth=$SYNC_DEPTH)" \
        || die "repo init --depth failed"
    fi
  else
    repo init -u "$GOS_MANIFEST" -b "$GOS_BRANCH" "${depth_args[@]}"
  fi

  # NO --fail-fast: dropped fetches are normal over WiFi, repo sync is
  # resumable. But not every failure is a network problem - blindly retrying
  # invocation errors just burns attempts.
  # SYNC_CURRENT_BRANCH=1 -> 'repo sync -c': fetches ONLY the manifest branch.
  # Without -c, repo fetches "+refs/heads/*" AND "+refs/tags/*", i.e. every
  # branch and tag of every project. Measured on
  # platform_packages_apps_Settings: 860 MB (and then aborted) versus 88 MB
  # for the one branch actually needed. --depth only limits the depth, -c the
  # breadth - both are needed. Tag-pinned AOSP projects are unaffected by
  # this, their revision is fixed in the manifest and keeps getting fetched.
  local out="$GOS_SRC/.repo-sync-last.log"
  local attempt=1 max="${SYNC_RETRIES:-20}"
  # base stays the same across all attempts, extra gets added on retry. Keep
  # them separate: a shared array would silently drop -c on the first retry.
  local base=(-j"${SYNC_JOBS:-2}") extra=()
  [ "${SYNC_CURRENT_BRANCH:-1}" = "1" ] && base+=(-c)
  # SYNC_JOBS kept separate from JOBS: the build is CPU-bound and wants many
  # jobs. The sync, on the other hand, is throttled by GitHub - measured on
  # the same repo, at the same time, over the same connection:
  # android.googlesource.com 6.66 MB/s, github.com/GrapheneOS 1.2 MB/s. The
  # network was never the bottleneck. More parallelism just spreads the
  # throttled rate over more connections and stretches out each fetch until it
  # breaks and discards EVERYTHING (git fetch doesn't resume). Fewer jobs are
  # faster than many here.
  until repo sync "${base[@]}" "${extra[@]}" 2>&1 | tee "$out"; do
    if grep -qE 'no such option|^Usage: repo|unrecognized arguments' "$out"; then
      die "repo rejects the call, not a network problem: $(grep -m1 -hE 'no such option|unrecognized' "$out")"
    fi
    if [ "$attempt" -ge "$max" ]; then
      die "repo sync failed after $max attempts - this is no longer a network problem"
    fi
    warn "sync attempt $attempt aborted - retrying in 30s ($((max-attempt)) attempts left)"
    extra=(--force-sync)
    attempt=$((attempt+1))
    sleep 30
  done
  ok "sync done after $attempt attempt(s)"
}

build() {
  [ -d "$GOS_SRC/.repo" ] || die "$GOS_SRC is not synced - run 'build.sh sync' first"
  log "Build $GOS_TARGET"
  cd "$GOS_SRC"
  # envsetup.sh needs bash/zsh. Dev build ('m'), NO target-files-package - the
  # emulator kernel is prebuilt, vendor files aren't needed for this target.
  # AOSP's build environment isn't nounset-safe: envsetup.sh and the functions
  # it defines (lunch, m) read unset variables. 'set -u' therefore has to stay
  # off for the ENTIRE section, not just for the source - otherwise lunch dies
  # on ANDROID_LUNCH_BUILD_PATHS.
  set +u
  source build/envsetup.sh
  lunch "$GOS_TARGET"
  m -j"$JOBS"
  local rc=$?
  set -u
  [ "$rc" -eq 0 ] || die "Build failed (exit $rc)"
  ok "Build done: $GOS_SRC/out/target/product/*/"
}

case "${1:-all}" in
  prereqs) prereqs ;;
  sync)    prereqs; sync ;;
  build)   build ;;
  all)     prereqs; sync; build ;;
  *) die "usage: $0 prereqs|sync|build|all" ;;
esac
