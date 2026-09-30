# From the emulator to the device

The emulator validates the scripts, not the phone. This is what carries over
unchanged, what has to be prepared on the device, and what the emulator cannot
show at all.

## What carries over unchanged

Provisioning needs **no root**. No `adb root`, no `su` — only commands the adb
shell (uid 2000) may run on a regular user build:

```
pm create-user · pm install-existing · pm grant · pm revoke · pm list
am start-user · am stop-user · appops set · settings --user · content · dumpsys · getprop
```

All of them address profiles through `--user N`. One adb connection from the owner
profile therefore covers all six zones; nothing has to be done from inside a zone.

There is no emulator-specific logic in `provision/` or `lib/` — the only mentions
of the emulator are comments and the `ADB_SERIAL` hint.

## Prepare the device first

1. **Enable developer options and ADB in the owner profile.** GrapheneOS treats ADB
   and the USB-C settings as dangerous settings: only the owner may change them, and
   it asks for the owner PIN even on an unlocked device. It cannot be done from a
   secondary profile.
2. **Confirm the ADB fingerprint** on the device.
3. **Check the USB-C setting.** GrapheneOS can disable USB while locked, which drops
   the connection mid-run.
4. **Keep the device unlocked** during the run.

## Fetch arm64 binaries

`make from-lock` asks the connected phone for its ABI and downloads the
universal builds plus that ABI's, checking each against `apks/lock.json`. Without
a phone attached it assumes `arm64-v8a`; `APK_ABI=x86_64` is the emulator.
The rest of this section is about `fetch.sh`, the maintainer's side.

`fetch.sh` prefers universal APKs and otherwise follows `APK_ABI`, default
`arm64-v8a` — so call it without an environment variable for the phone. Anyone who
fetched with `APK_ABI=x86_64` for the emulator has x86 binaries that will not
install:

```bash
./apks/fetch.sh
for f in apks/**/*.apk; do unzip -l "$f" | grep -oE 'lib/[a-z0-9_-]+/' | sort -u; done
```

The reverse holds too: arm64-only apps cannot be tested in the x86_64 emulator at
all. See [../architecture/catalog.md](../architecture/catalog.md).

## There is no rollback

On the emulator a snapshot is the safety net. On the device there is none, which
dictates the order:

```bash
DRY_RUN=1 provision/run.sh
provision/run.sh
```

Tearing a profile down stays possible (`pm remove-user N`), at the price of its
data.

## Wireless ADB

`ADB_SERIAL` also takes `host:port`, so the chain can run over the tailnet:

```bash
adb pair <ip>:<port>          # once, code from the device
adb connect <ip>:5555
ADB_SERIAL=<ip>:5555 provision/run.sh
```

## The first thing to test on real hardware

**Bluetooth binds to the foreground user.** `BluetoothManagerService.prepareUserSwitch()`
tears the stack down on a user switch, so a background secondary user has no
Bluetooth. A car key app in Cloud therefore only works while Cloud is the active
profile — which collides with the slot allocation in
[../architecture/zones.md](../architecture/zones.md#the-slot-allocation-is-therefore-fixed).

Profiles of the foreground user are not excluded: `AdapterService` broadcasts to
`getEnabledProfiles()` and managed profiles are handled explicitly, so Home and the
work profile would both give such an app Bluetooth. Home forbids Play Services by
hard rule, and the work profile is the company container, inside the MDM's wipe
range. There is only one managed profile per device, and the company has it.

Test in this order:

1. The app in Cloud, Cloud in the background. Expected: no key. If it works anyway,
   the reasoning above is wrong — say so.
2. The app in Home without Play: does it register a key at all? Bluetooth features
   are widely reported as unreliable without Play Services.
3. Only if 2 fails: the work profile, where sandboxed Play exists.

Carry the physical NFC card regardless of the outcome. It needs no phone, no
battery and no profile.

## What the emulator cannot prove

- sandboxed Play: install, login, and the apps that depend on it
- Play Integrity behaviour of individual apps
- the MAM broker and app protection policies
- FCM push, and therefore notification forwarding in daily use
- fingerprint, two-factor unlock, eSIM, NFC, car key
- arm64-only apps
