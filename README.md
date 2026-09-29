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
| `90-manual.sh` | generate `MANUAL.md` from what is deliberately not scriptable |
| `99-finalize.sh` | bring each zone to its target runtime state, stopping what must be stopped |

`05-verify-catalog.sh` runs on demand: it checks package names against the real
APKs, and `--fix` writes corrections back into the catalog.

```bash
make check      # JSON, bash syntax, catalog, and that generated files are in sync
make apks       # APK hashes and pinned signer certificates
make update     # fetch newer APKs, verify them, bring every zone to them
```

`make update` matters more than it looks: four zones carry no app store, so for
everything this repository fetches, the chain is the update mechanism. Each run
ends by comparing what the device runs against the APKs on the host, so
"is anything stale?" has an answer rather than an assumption.

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
