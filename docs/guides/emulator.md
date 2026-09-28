# Emulator

The everyday target. It proves everything that does not need Google's servers or
real radios — see
[../architecture/zones.md](../architecture/zones.md#what-the-emulator-cannot-prove)
for the line between the two.

## Build it once

```bash
emulator/build.sh prereqs          # hard check before anything else
tmux new -s gos 'emulator/build.sh all'
```

Sync and build run for hours, so they belong in a terminal multiplexer, not in a
session that can be closed. The result is a `sdk_phone64_x86_64` userdebug build of
the GrapheneOS tree, signed with test keys.

## Run it

Without `SERIAL` and `OVERLAY_DIR`, every command below addresses the **working
instance** `emulator-5554` on the build tree. Export the pair first to work on a
test instance — they always travel together, see [below](#one-instance-per-session).

```bash
export SERIAL=emulator-5558 OVERLAY_DIR=$PWD/emulator/instances/test-2

emulator/run.sh start              # cold boot, 1.5–2 min
SNAPSHOT=clean emulator/run.sh start   # load a snapshot instead, ~7 s
emulator/run.sh status
emulator/run.sh snapshot <name>    # save
emulator/run.sh restore <name>     # load into the running instance
emulator/run.sh stop               # waits for the process to be gone
```

`stop` is safe to check: it exits 0 when the port is free, whether or not
anything was running, and non-zero when it is not — the lock refused, or the
emulator outlived the 30 second wait. So a script wanting certainty writes
`run.sh stop || die`, and one writing `run.sh stop || true` is muting the
refusal rather than the noise.

`restore` and `snapshot` fail on the console's `KO:` reply — adb itself exits 0
there, which is exactly the kind of proxy success
[provisioning.md](../architecture/provisioning.md#verifying-and-the-one-recurring-defect)
warns about. Saving works despite `-no-snapshot-save`: that flag only drops the
quickboot save on exit. `READ_ONLY=1` discards all writes, but it disables
snapshots entirely, loading included.

Then point the chain at the same instance — `provision/` reads `ADB_SERIAL`, not
`SERIAL`:

```bash
ADB_SERIAL=$SERIAL provision/run.sh
```

## One instance per session

An instance is a serial **plus** an overlay directory, and the two always travel
together. `run.sh start` refuses an `OVERLAY_DIR` that another running emulator
already uses. Each instance gets its own qcow2 overlays over the read-only build
images and its own AVD identity, so instances never touch each other's disks.

| Serial | `OVERLAY_DIR` | Belongs to |
|---|---|---|
| `emulator-5554` | none (build tree) | the working instance: interactive, manual |
| `emulator-5556` | `emulator/instances/test` | launcher e2e from the [andashi/home](https://github.com/andashi/home) repo |
| `emulator-5558` | `emulator/instances/test-2` | this repo's verification runs |
| `emulator-5560` | `emulator/instances/test-fold` | foldable, for the launcher's grid tests on the Fold |
| `emulator-5562` | `emulator/instances/test-fold-gpu` | foldable on the host GPU, claimed by the launcher's unfold-timing work ([andashi/home#94](https://github.com/andashi/home/issues/94)) |

```bash
SERIAL=emulator-5558 OVERLAY_DIR=$PWD/emulator/instances/test-2 emulator/run.sh start
```

`test-fold-gpu` is the one instance that runs `GPU=host` from its first start, so
every snapshot on it is a host-GPU snapshot and none of them load in software.
That is not duplication of `test-fold`: frame times measured on SwiftShader say
nothing about a device, and mixing the two modes on one instance costs a cold
boot every time (see [below](#rendering-on-the-host-gpu)).

Each instance costs a few GB of RAM. Two side by side are comfortable on a large
host, but a cold boot of the second one under load takes minutes, not seconds.

## A zone from a snapshot is not set up

Every secondary user starts in the GrapheneOS setup wizard, and nothing in this
repository finishes it — `90-manual.sh` says a person walks the wizards, which is
right for a phone and never happens on an emulator. So a zone switched to after
loading any snapshot shows **"Welcome to GrapheneOS"**, the launcher never reaches
the foreground, and anything that needs the home screen measures the wizard
instead: no grid, no widget bind, no wallpaper applied.

One setting per zone replaces the six screens:

```bash
adb -s $SERIAL shell settings put global device_provisioned 1          # once per device
adb -s $SERIAL shell settings put secure --user <uid> user_setup_complete 1
adb -s $SERIAL shell am switch-user <uid>
```

Measured on emulator-5560, 2026-09-28, controlled on zone 13: before, the
foreground window is `app.grapheneos.setupwizard/.WelcomeActivity`; after, it is
`org.andashi.home/…LauncherActivity`.

**Check the foreground window, not `resolve-activity`.** Reported by the
optimization session as the verification step, and it is the wrong instrument —
measured here it still answers `app.grapheneos.setupwizard/.WelcomeActivity`
while the launcher is demonstrably in front and holds the HOME role. Ask the
question you mean:

```bash
adb -s $SERIAL shell dumpsys window | grep -m1 mCurrentFocus
```

## Not every user can hold the home screen

`cmd user list -v` on a provisioned device:

```
id=0,  name=Owner,   type=full.SYSTEM
id=10, name=Work,    type=profile.MANAGED   <- cannot hold HOME
id=11, name=Cloud,   type=full.SECONDARY
```

**The first user that is not 0 is the managed Work profile**, and
`cmd role add-role-holder --user 10 … HOME` answers `Failed` — the case
`40-theming.sh` skips deliberately, because a managed profile has no home screen
of its own. A script that picks "the first user above 0" picks the one zone that
can never host the launcher, and then reports whatever that produces. Pick by
type: `full.SECONDARY`, matched case-insensitively.

Both traps have the same shape, and it is the one this guide keeps coming back
to: a probe that does not first establish that the zone is set up and can hold a
home screen is measuring something else, confidently.

## The lock

Several sessions work on this repository at once and they all drive emulators. Two
of them on the same instance do not fail loudly — taps land in the wrong app, a
user switch fires mid-run, and the result looks like a flaky script rather than a
collision.

```bash
emulator/device-lock.sh status                  # every held instance, for a person
emulator/device-lock.sh holder  [serial]        # the owner or nothing, for a script
emulator/device-lock.sh acquire <owner> [serial]
emulator/device-lock.sh release <owner> [serial]
emulator/device-lock.sh steal   <owner> [serial]   # prints who lost it
```

`status` is prose and will be reworded; `holder` is the one to script against —
it prints the owner and nothing else, and exits non-zero when the instance is
free. The same split applies to the instance itself: `run.sh running` prints the
emulator's pid or exits non-zero, so nothing has to infer it from a sentence or
run its own `pgrep`.

The lock is **per instance**. Without an argument the serial comes from `SERIAL`,
then `ADB_SERIAL`, then `ANDROID_SERIAL`. Scripts put serial and pid in the owner
name (`l4-config@emulator-5556#<pid>`); `acquire` is re-entrant for the same owner.

It is advisory for **adb**: nothing stops a session from talking to a device
without asking, and that still works only because everyone checks first.
`status` before any adb run is the habit that makes it worth having.

It is **not** advisory for `run.sh` any more. `start`, `stop`, `snapshot` and
`restore` refuse an instance somebody else holds:

    x emulator-5562 is held by optimization-boot, refusing to stop it.
       If that session is gone:   LOCK_FORCE=1 emulator/run.sh stop
       If it is you:              LOCK_OWNER=optimization-boot emulator/run.sh stop

Say who you are with `LOCK_OWNER`, the same string you passed to `acquire`. An
unlocked instance is allowed with a warning, because not every use takes a lock;
`LOCK_FORCE=1` walks past a held one and prints whose run it is walking past.

This exists because on 2026-09-27 a sweep runner called `acquire` without
checking the result, `start` correctly refused with "already running", and `stop`
then killed the instance out from under the session that held it. The runner's
bug was fixed the same night, but it only reached the instance because `stop` let
it through: a lock that stops only the careful is not a lock, because any script
with a bug in its acquisition path becomes a script that ignores it.

**The lock and the instance are two different things**, and `status` says both
now — an instance can run with nobody holding it, and a lock can outlive the
emulator it was taken for:

```
device emulator-5556 held by: l4-grid@emulator-5556#2957191 (1m), running
device emulator-5560 held by: rows@emulator-5560 (2h 14m), NOT running
device emulator-5562 free, but an emulator is RUNNING on it - anybody may stop it
```

The last line is the dangerous one: it reads as free to whoever checks, which is
how an instance stayed up unlocked for five hours on a loaded host. `release`
says the same thing when it hands back an instance that is still running.

## Rendering on the host GPU

Every instance renders in software by default, even on a machine with a GPU:
the emulator's driver blocklist decides that on its own and logs

    Your GPU drivers ... may have a bug ... consider switching to software
    library_mode swangle_indirect gpu mode swangle_indirect

`hw.gpu.mode` in `config.ini` does not override it. `-gpu` on the command line
does, and `run.sh` passes it through:

```bash
GPU=host emulator/run.sh start
```

Measured on this host (AMD Radeon 890M, Mesa 26.1.8) 2026-09-23: the log then
says `library_mode host gpu mode host`, the guest reports

    GLES: Google (AMD), Android Emulator OpenGL ES Translator
          (AMD Radeon 890M Graphics (radeonsi, strix1, ACO, ...)), OpenGL ES 3.1

and the home screen renders correctly - wallpaper, status bar, the grid's glass
surface, no artefacts. So the blocklist entry is cautious rather than right for
this driver.

**The GPU mode is part of an instance's identity, not a flag to flip between
runs.** A snapshot carries GPU state, and one taken in software refuses to load
under `-gpu host`:

    KO: Snapshot load failure: different emulator features

`run.sh` reports that instead of continuing silently, and the instance cold
boots. An instance that should run on the host GPU therefore needs its own
snapshots, taken while `GPU=host` was in effect. Mixing the two costs a cold
boot every time.

Why it exists at all: frame-time measurements on SwiftShader say nothing about
the device. They are good for comparing two builds against each other on the
same renderer, and worthless as an answer to "is this fast enough on a Fold".

## The foldable instance

The everyday image is a phone. `emulator-5560` makes the same build behave as a
foldable, so the launcher's grid can be tested against the device this
distribution actually targets — 1080×2364 closed, 2076×2152 open, four device
states.

```bash
export SERIAL=emulator-5560 OVERLAY_DIR=$PWD/emulator/instances/test-fold
FOLDABLE=1 emulator/run.sh start     # only the FIRST start needs the flag
emulator/run.sh foldable-setup       # once, before the clean snapshot
emulator/run.sh snapshot clean

# in scripts
adb -s $SERIAL shell cmd device_state state 0       # fold
adb -s $SERIAL shell cmd device_state state 2       # unfold (or: state reset)
```

`FOLDABLE=1` matters only while the overlay directory is created: instead of
symlinking `config.ini` and `advancedFeatures.ini` from the build tree, it writes
real ones — the Pixel 10 Pro Fold geometry plus `SupportPixelFold = on`, without
which the emulator never creates a second built-in display. `hw.device.name` has
to stay `pixel_fold`; with `pixel_10_pro_fold` no second display appears.

### Why the hinge sensor alone does nothing

Three layers have to agree, and the AVD config is only the first:

| | What it does | Where it comes from |
|---|---|---|
| hinge sensor | reports an **angle** | `hw.sensor.hinge*` in `config.ini` |
| `device_state_configuration.xml` | turns angles into **states** | `/data/system/devicestate/`, else `/vendor/etc/devicestate/` (`DeviceStateProviderImpl.java`) |
| `display_layout_configuration.xml` | turns a state into a **display layout** | `/data/system/displayconfig/` (`DeviceStateToLayoutMap.java`) |

Set the sensor keys alone and the states appear while `wm size` never changes —
measured, and the reason `foldable-setup` exists. It places both tables by hand
into the userdata overlay, where the `clean` snapshot then carries them, and
enables the two shipped-but-disabled RROs that hold the foldable framework
resources.

Two layers are already in our image: the symlink
`vendor/etc/displayconfig -> /data/system/displayconfig` from `GoldfishSkinConfig`,
and an init trigger that copies a state table the emulator hands over at boot.
The emulator only hands it over for a foldable AVD, though: on this instance
`ro.boot.qemu.device_state` is empty and `init.svc.ranchu-device-state` stays
`stopped`. Hence by hand, once.

**A foldable build does not solve this.** `EMULATOR_DEVICE_TYPE_FOLDABLE=true`
copies the same four files to `/data/misc/pixel_fold/` (`base_phone.mk:33`),
which is not a path the framework reads — hours of build time and a second image
to keep current, for files nobody opens.

**What this instance does not prove.** Folding here is bolted onto a phone image,
so it tests what the software makes of two displays and four states. It says
nothing about GrapheneOS's own foldable handling on real hardware, where both
tables come from the vendor partition.

## Recordings for the website

The videos on andashi.org are taken here, and the website repository now has a
rule that a new take happens on "the same instance and the same GPU mode" as the
one it replaces ([its README, 3c31a20](https://github.com/andashi/website)). That
rule only works if the take says which those were, so every recording writes them
down next to the file:

    instance   emulator-5560, emulator/instances/test-fold
    gpu        host | software
    launcher   org.andashi.home <version>, from apks/SHA256SUMS
    source     adb -s <serial> emu screenrecord start --time-limit <n> <file>
    delivered  <what was cut, scaled or cropped before it went to the website>

The reason is not bookkeeping. A recording is a performance claim - "the inner
home screen appears in one step" is a statement about frame timing - and frame
timing on SwiftShader says nothing about a device
([above](#rendering-on-the-host-gpu)). Two takes are only comparable when both
say which renderer drew them.

**The 0.7.1 unfold take predates this**, and what is known about it came from the
handover message rather than from a line beside the file: `adb emu screenrecord`
on the Fold emulator, host GPU. The website repository has since written those
facts into its README, naming the handover as their source, so the record is at
least durable now. Its source was the unfolded inner display (2076x2152, cut to
948x1080 at 30 fps for the site). That is enough to take a comparable one - the
foldable, `GPU=host` - and not enough to reproduce it: no overlay directory, no
launcher build, and nothing on this side that can check the claim. Which is the
whole reason the lines above exist.

## Snapshots

- **`clean`** — first boot of the build, Owner only, nothing provisioned. The base
  for one specific claim: *the whole chain works on a device where nothing has been
  prepared*. A run meant to prove that has to start here. Everyday runs do not.
- **`profiles-ready`** — `clean` plus `provision/00-profiles.sh` and nothing else.
  The everyday base, for launcher work and for anything downstream of profile
  creation. It is script-produced, not hand-repaired, so a run from here is a
  smaller claim, not a weaker one — it simply says nothing about how the chain
  behaves before the profiles exist. It re-runs `00-profiles.sh` anyway, so drift
  from `config/profiles.json` is reconciled and becomes visible.

Pick the base by the claim you want to make, not by habit.

```bash
ls emulator/instances/<dir>/snapshots/          # without booting
adb -s <serial> emu avd snapshot list           # while running
```

A run that starts from a snapshot runs writable, and that is safe: loading resets
RAM and disks, and nothing is written back unless someone runs `run.sh snapshot`.

### Refreshing `profiles-ready`

Whoever changes `config/profiles.json` refreshes `profiles-ready` on every instance
that uses it, in the same session. A stale one does not fail runs, it just makes
them slow again. The order is the part people get wrong:

```bash
export SERIAL=emulator-5558 OVERLAY_DIR=$PWD/emulator/instances/test-2
emulator/device-lock.sh acquire "$USER@$SERIAL"
SNAPSHOT=clean emulator/run.sh start         # writable, so no READ_ONLY
ADB_SERIAL=$SERIAL bash provision/00-profiles.sh    # 49 s to 1m46s from clean
emulator/run.sh snapshot profiles-ready      # overwrites the old one
emulator/run.sh restore clean                # leave the live disk at clean
emulator/run.sh stop
emulator/device-lock.sh release "$USER@$SERIAL"
```

The `restore clean` at the end matters: without it the instance's live disk carries
the provisioned state, and the next run that forgets `SNAPSHOT=` starts from it.

### Adding an instance

Next free even port — the odd one above it is its adb port — and a new directory
under `emulator/instances/`:

```bash
export SERIAL=emulator-5560 OVERLAY_DIR=$PWD/emulator/instances/test-3
emulator/device-lock.sh acquire "$USER@$SERIAL"
emulator/run.sh start                        # creates the overlays, first boot ~2 min
adb -s $SERIAL shell cat /proc/loadavg       # wait for the first value below ~2.5
emulator/run.sh snapshot clean
```

Waiting for the load to settle is not politeness: a snapshot taken during first-boot
dexopt captures that work and hands it to everyone who loads it afterwards.

The instance is now running at `clean`, so continue with the `profiles-ready` steps
above. Cost per instance: about 4 GB of overlays, another ~3.5 GB per snapshot, and
a few GB of RAM while it runs. Add a row to the table above so the next session
knows the instance is taken.
