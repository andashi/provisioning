# andashi / provisioning

A GrapheneOS phone set up as declared code: six profiles as network zones,
described in `config/`, applied over adb, verified by reading the device back.
"Hardened Android as Code".

The home screen is not configured here. It configures itself from a file this
repository delivers — the launcher is [andashi/home](https://github.com/andashi/home).

```bash
DRY_RUN=1 provision/run.sh      # show what would change
provision/run.sh                # apply, ~9 min for six zones
```

Running it again is the normal case, not the emergency case. Every step checks
before it writes.

## Where to read

| | |
|---|---|
| [docs/architecture/zones.md](docs/architecture/zones.md) | the model: six zones, their colors, the three-running-profiles limit |
| [docs/architecture/provisioning.md](docs/architecture/provisioning.md) | the chain, what it can promise, and the defect it keeps guarding against |
| [docs/architecture/launcher.md](docs/architecture/launcher.md) | the contract with `andashi/home` |
| [docs/architecture/boundaries.md](docs/architecture/boundaries.md) | why the privileged core needs adb and cannot be an app |
| [docs/architecture/catalog.md](docs/architecture/catalog.md) | which app lives in which zone, and how its binary is trusted |
| [docs/decisions/](docs/decisions/README.md) | the decisions behind all of it, each with its price |
| [docs/explorations/runtime-configuration.md](docs/explorations/runtime-configuration.md) | a possible path, not a decision: the phone as dotfiles at runtime |
| [docs/guides/emulator.md](docs/guides/emulator.md) | build, run, snapshots, and the lock between parallel sessions |
| [docs/guides/hardware.md](docs/guides/hardware.md) | what changes on the real device |
| [AGENTS.md](AGENTS.md) | how changes reach `main`: pull requests, review, the merge gate, tests |

## Layout

```
config/      the declarative heart: profiles, apps, settings, theming, launcher
provision/   numbered steps that make the device match it
lib/         shared adb and jq helpers
apks/        SHA256SUMS and pinned signer certs — no binaries in git
themes/      wallpaper per zone, referenced from theming.json
emulator/    build and run the GrapheneOS emulator
docs/        architecture, decisions, explorations, guides
```

## The chain

| Step | Does what |
|---|---|
| `00-profiles.sh` | create the zones, start them for provisioning, install the work profile's owner |
| `10-apps.sh` | install per profile: `install-existing` → APK from `apks/` → otherwise queued for MANUAL.md |
| `20-permissions.sh` | `net:false` revokes `INTERNET`, plus grants, revokes and appops |
| `30-settings.sh` | `settings put` per namespace, including private DNS off globally |
| `35-vpn.sh` | always-on VPN and lockdown per zone, with the VPN consent appop |
| `40-theming.sh` | Monet palette, dark mode, status bar, HOME role, default keyboard |
| `45-launcher-config.sh` | push the launcher config per profile, reload it, verify by read-back |
| `50-updater-config.sh` | hand each zone's updater its config, verify by the hash it reports, start a check |
| `90-manual.sh` | generate `MANUAL.md` from what is deliberately not scriptable |
| `99-finalize.sh` | bring each zone to its target runtime state, stopping what must be stopped |

`05-verify-catalog.sh` runs on demand: it checks package names against the real
APKs, and `--fix` writes corrections back into the catalog.

```bash
make check      # JSON, bash syntax, catalog, and that generated files are in sync
make from-lock  # the APKs from apks/lock.json: curl, sha256sum, jq - nothing else
make apks       # APK hashes and pinned signer certificates (maintainer)
make lock       # write apks/lock.json from the verified inventory (maintainer)
make update     # fetch newer APKs, verify them, bring every zone to them
```

**To set up a phone you need `make from-lock`, not `fetch.sh`.** The lock names
every APK, where to download it, and what it must hash to; the package names
and signers were checked when it was written. No JDK, no Android build tools,
no gpg ([0013](docs/decisions/0013-a-lock-for-the-first-install.md)).
`fetch.sh` is the maintainer's side, and it runs daily on its own:
`.github/workflows/lock-refresh.yml` fetches, verifies and locks
(`apks/refresh-lock.sh`). New versions under the pinned signers go onto `main`
by themselves; anything unusual - a new signer, a rebuilt version, a failed
run - becomes an issue labelled `lock-refresh` instead. By hand it is the same
command; `make check` fails until the lock is renewed.

`make update` matters more than it looks: four zones carry no app store, so for
everything this repository fetches, the chain is the update mechanism. Each run
ends by comparing what the device runs against the APKs on the host, so
"is anything stale?" has an answer rather than an assumption.

## After provisioning: `andashi`

`provision/run.sh` sets a phone up and proves every zone. Changing it afterwards
is `bin/andashi`, which runs the same steps but only the ones a change needs,
only for the zones it concerns, and never starts a stopped zone unless asked:

```bash
ln -s "$PWD/bin/andashi" ~/.local/bin/andashi     # once

andashi status                   # every zone: running or not, in sync or not, what waits
andashi diff                     # what apply would do; exit 1 when there is anything
andashi apply --zone current     # the zone on the screen - edit, apply, look, again
andashi apply                    # everything that changed, in every running zone
andashi apply --zone ops --all   # a stopped zone gets started for its pending change
andashi watch                    # apply to the zone in front on every save

andashi app add signal --zone lab            # edit the catalog, no phone needed
andashi app rm opencamera --zone home        # the next apply removes it there
andashi theme set glass.tint 0.3 --zone lab  # without --zone: every zone
```

The catalog commands run the same checks as `make check` and take a change
back when one refuses it. They are what `.claude/skills/andashi` tells an agent
to use: edit, check, commit - never `adb`, never `apply`; the door to the phone
stays with the person.

Measured on the Fold emulator: a glass change to the zone in front takes about
9 seconds, where a full run takes a minute and a half. What makes that safe is
the same record the full run keeps, per device and zone, in `.provision-state/`:

- **Every apply pulls first.** An arrangement made on the phone - a widget, the
  order of favourites, a glass value - is adopted into your catalog before
  anything is pushed, so the phone is never overwritten by a laptop that did
  not know. Adopting writes into `CONFIG_DIR`, so it needs your own catalog,
  never this template.
- **Both sides changed is a stop, not a merge.** That zone is left alone, both
  values are named, and the other zones go ahead.
- **A stopped zone is not started.** Android runs three profiles, and every
  start evicts one - usually Cloud, the one that must keep running. The change
  waits on the host and `andashi status` names it.
- **Only what the chain installed is taken away.** An app the catalog stops
  naming for a zone is removed there on the next run; an app somebody installed
  by hand is named by `andashi diff` and kept, unless `--prune-undeclared` says
  otherwise. A work profile's owner and sandboxed Play are never either.
- **The catalog cannot break its own rules.** `config/check-invariants.sh`:
  no sandboxed-Play app in a Play-free zone, one always-on zone besides Home,
  no `net: false` app granted `INTERNET`.

## What stays manual

By GrapheneOS design, not for convenience:

- **Profile PINs** — `locksettings set-password --user N` is unreliable for
  secondary profiles and would write credentials into the shell history.
- **"Run in background"** per profile — a UserManager restriction, writable only
  by a device or profile owner.
- **Notification forwarding** — neither readable nor writable over adb.
- **Sandboxed Play, logins, MFA** — no credentials through the adb shell.
- **Storage and contact scopes** — UI flows. The intent is declared in
  `config/apps.json` and ends up in MANUAL.md.

The generated `MANUAL.md` lists them, including the apps that a given
run could not install, by name.

Manual is not the same as unassisted. The 22 Play apps need an account and taps,
but nobody should have to search for them: `provision/95-play-queue.sh` switches
to a zone, opens each Play page directly by package name and waits for you to tap
Install. It is deliberately not part of `run.sh` — it waits for a human — and
installed apps drop out of its list, so it gets shorter every run.

## Emulator

The everyday target is a self-built GrapheneOS emulator image. Several sessions
share it, so the device lock comes first:

```bash
export SERIAL=emulator-5558 OVERLAY_DIR=$PWD/emulator/instances/test-2
emulator/device-lock.sh status
SNAPSHOT=clean emulator/run.sh start
ADB_SERIAL=$SERIAL provision/run.sh
```

`SERIAL` and `OVERLAY_DIR` always travel together and pick the instance; without
them you are on the working instance, `emulator-5554`.

**A build with the same application id but a different signer breaks every
secondary zone.** It is worth knowing before it happens, because it does not
look like what it is. The debug *variant* is harmless - it installs as
`org.andashi.home.debug` beside the release one. The trap is a **release** build
made without the keystore: it keeps the release application id and falls back to
the debug key ([andashi/home#137](https://github.com/andashi/home/issues/137)),
so installing it means uninstall and install - and the app's per-user directory
in external storage survives that with the ownership of the install that created
it. The new build then cannot write into its own directory: `content write`
fails with a null `ParcelFileDescriptor`, and underneath it is
`IOException: Permission denied` in `ConfigIngestProvider.newTempFile`. It is
permanent, not a race — measured on emulator-5558, twelve attempts over 24
seconds, identical every time — so retrying is twenty minutes wasted. Zone by
zone, and the user has to be **running** first, because `pm clear` on a stopped
user prints `Success` and does nothing:

```bash
adb -s "$SERIAL" shell am start-user -w <uid>
adb -s "$SERIAL" shell pm clear --user <uid> org.andashi.home
```

`45-launcher-config.sh` recognises the failure and prints both commands. It does
not run them: `pm clear` also destroys whatever was arranged on the device.
Starting from a snapshot that predates the swap avoids the whole thing.

Details, instances and snapshots: [docs/guides/emulator.md](docs/guides/emulator.md).

## Your catalog, not the template

`config/` in this repository is a **template**: it demonstrates every mechanism
with as few apps as possible, and it names nobody's car. A real phone wants a real
catalog, and that one does not belong here — it would describe its owner.

Both live side by side. `CONFIG_DIR` picks which one applies:

```bash
CONFIG_DIR=~/andashi-private/config provision/run.sh
CONFIG_DIR=~/andashi-private/config config/gen-launcher.sh
CONFIG_DIR=~/andashi-private/config config/gen-obtainium.sh
CONFIG_DIR=~/andashi-private/config config/gen-updater.sh
CAT=~/andashi-private/config/apps.json apks/fetch.sh
```

The generated files follow the catalog they come from: with `CONFIG_DIR` set,
`gen-launcher.sh` writes into that directory's `launcher/`, not into this one.

What is **not** separated yet is the binary inventory. `apks/` still belongs to
this repository, so a private app fetched with `CAT=` pins its signer into
`apks/certs/` and adds a line to `apks/SHA256SUMS` — both tracked, so a private
app name would end up in a public repository through its trust files. Until
`fetch.sh` learns `APKS_DIR` as well, fetch private apps into a copy and keep it
out of this tree.

## Before a real device

```bash
provision/05-verify-catalog.sh    # lists every still-unverified package name
```

`pkg_status: "unverified"` means the package name is a reasoned guess. Bring it to
`verified` before provisioning real hardware.
