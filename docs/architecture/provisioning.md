# Provisioning

Provisioning is the host-side half of the distribution. It reads a declared
desired state from `config/` and applies it to a device over adb. The on-device
half — the launcher and its home screens — configures itself from a file that this
chain delivers; see [launcher.md](launcher.md). Why the split runs exactly there
is in [boundaries.md](boundaries.md).

## Two directories and one rule

```
config/     the desired state, declarative, reviewable as a diff
provision/  numbered steps that make the device match it
lib/        the shared adb and jq helpers every step uses
```

The rule is **check before write**. Every step reads what is on the device,
compares it with what is declared, and only acts on a difference. Running the
chain again is the normal case, not the emergency case:

```bash
DRY_RUN=1 provision/run.sh      # print what would change, read nothing but state
provision/run.sh                # apply
```

A dry run still *reads* the device. A run that may not read the current state
cannot say what it would change — it would only echo its own command text back
into its checks.

## The chain

`provision/run.sh` runs the steps in order. Each is a standalone script and can be
run alone.

| Step | Owns |
|---|---|
| `00-profiles` | creates the zones, their runtime state, the work profile's owner |
| `10-apps` | installs per profile from the catalog; what it cannot install it queues for `MANUAL.md` |
| `20-permissions` | permissions and appops, including `INTERNET` revocation (the GrapheneOS network toggle) |
| `30-settings` | `settings put` per profile across the global, secure and system namespaces |
| `35-vpn` | the always-on VPN slot per zone, with lockdown where the zone demands it |
| `40-theming` | Monet palette, dark mode, status bar, the HOME role, the keyboard |
| `45-launcher-config` | pushes the launcher config per profile, reloads it, reads it back |
| `90-manual` | generates `MANUAL.md` from what is deliberately not scriptable |
| `99-finalize` | brings each zone to its declared runtime state, stopping what must be stopped |

`05-verify-catalog` is not in the chain. It checks package names in the catalog
against the real APKs and is run on demand, with `--fix` to correct them.

Ordering is a convenience, not a dependency the steps rely on. `00-profiles`
installs the work profile's owner from the catalog itself rather than assuming
`10-apps` ran first, because on a fresh device it has not.

## Two kinds of state

This distinction decides what the chain can promise.

**Convergent.** Profiles, apps, permissions, appops, everything in
`Settings.Secure`, the VPN slots, the launcher configuration. The step reads the
current value, compares, writes on difference, and reads the result back. It
detects drift and repairs it. Safe to run at any time, in any order.

**Set-once and unverifiable.** State an app keeps privately, in
`/data/user/N/<pkg>`, owned by the app's own uid. A script can put it there but
never read it back, so it cannot detect drift and cannot repair it — only re-apply
blindly.

The second class used to include the entire launcher layer, which was configured
by driving its settings UI with uiautomator: 688 lines, roughly 27 minutes per
run, and no way to verify the result. That layer moved into the first class by
changing the launcher rather than the script — it now ingests a config file and
serves its effective state back for reading. **Everything the chain sets today is
convergent.** When something new cannot be verified, that is a reason to change
the thing being configured, not to accept a blind write.

## Verifying, and the one recurring defect

Five separate failures in this chain shared a single shape: *a step read a proxy
and called it success.* A marker file on the host instead of the state on the
device. An exit code instead of the result. A fixed sleep instead of a condition.
They stayed invisible because the failures were always already repaired by hand —
every earlier run happened on a device where someone had installed the app,
dismissed the wizard, set the wallpaper.

The rules that came out of it, all of them currently held by the code:

- **Read the device, never the host.** A `.sha256` marker beside the repo claimed
  work was done that a device reset had undone. Host-side state may cache, never
  decide.
- **Verify the result, not the call.** `am start` returns 0 for an activity that
  never ran, because it only runs for the foreground user. `content write` exits 0
  while printing the provider's exception. Both are checked by reading state back.
- **Poll a condition, never sleep a guess.** Wallpaper application and launcher
  reloads are bounded polls against `dumpsys` and the launcher's diagnostics.
- **Guard every capture under `pipefail`.** `cur="$(... )"` without `|| cur=""`
  turns one unreadable key into a dead run: GrapheneOS refuses reads of protected
  settings, adb exits 255, and the assignment carries that status. An unknown
  current value must mean "attempt the write and report", not "abort".
- **Account for failures per profile.** A step that touches six zones attempts all
  six, then fails if any did not converge. One broken zone must not hide the state
  of the others, and must not drown in a long log as a single warning.

## What stays manual

Three things are not scriptable and are written into `MANUAL.md` by
`90-manual.sh` rather than pretended away:

- **Profile PINs.** `locksettings set-password --user N` exists but is unreliable
  for secondary profiles and would write credentials into the shell history.
- **"Run in background"** per profile — a UserManager restriction, writable only
  by a device or profile owner. See [zones.md](zones.md#what-provisioning-cannot-set-here).
- **Notification forwarding** — neither readable nor writable over adb, adb root
  included. Do not re-advertise it as automated; it was once, and it was wrong.

Plus everything that needs a Google account: sandboxed Play login and anything
gated behind it.

`MANUAL.md` is generated, not written. Apps that could not be installed are queued
during `10-apps` and appear in it by name, so the list reflects the run that
actually happened.

## Checks that run without a device

```bash
make check
```

validates every config file as JSON, every script with `bash -n`, the catalog for
duplicate packages, and — the part that matters — that the **generated files are
in sync with their generators**. `config/obtainium.json` and
`config/launcher/*.json` are checked in *and* generated; the check regenerates
them into a temporary directory and diffs. A stale generated file is a failed
check, not a surprise on the device.

CI (`.github/workflows/verify-apks.yml`) repeats those checks and verifies that
the pinned certificates and hashes still describe the same apps as the catalog.
It cannot verify the binaries themselves — they are deliberately not in the
repository, so that check runs where they are: `make apks`, locally, before a pin
is committed. See [catalog.md](catalog.md).

## Running against something

The chain talks to whatever adb offers, emulator or hardware:

```bash
ADB_SERIAL=emulator-5558 provision/run.sh
```

The emulator is the everyday target, including its snapshots and the lock that
keeps parallel sessions from fighting over one device — see
[../guides/emulator.md](../guides/emulator.md). What an emulator can and cannot
prove is in [zones.md](zones.md#what-the-emulator-cannot-prove).
