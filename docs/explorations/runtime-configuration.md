# Runtime configuration — a possible path

**Status:** exploration, not a decision. Written down on 2026-09-21 so the
argument does not have to be rebuilt from scratch. Nothing in this document is
implemented, and several claims are marked as unverified. If a part of it is ever
adopted, that part gets a decision file with a price attached; the rest stays here.

## The question

Provisioning today is the moment a phone is set up. The wish is bigger: treat the
repository like dotfiles. Change a file on the laptop, and the phone follows —
at runtime, possibly from far away, possibly on behalf of an agent that was told
"add Molly to Social". Add an editor on the phone. Do all of it without weakening
what GrapheneOS is, and without forking it.

The short answer is that most of this is possible on stock GrapheneOS, and that
the launcher contract in [launcher.md](../architecture/launcher.md) is already
the prototype: push a file, reload, read the state back. What follows is that
pattern generalised, plus one privilege tier that the table in
[boundaries.md](../architecture/boundaries.md) does not have a column for yet.

The prototype has one known limit, and it must not be generalised along with the
rest. **A clean reload report proves that the document was *accepted*, not that it
*took effect*.** Measured across six zones with Andashi Home 0.3.0: the launcher
accepts `home.dock.enabled: true`, echoes it back unchanged, and draws nothing,
because the renderer went away with the clock. The report cannot tell "applied"
from "parsed and dropped". That is andashi/home#47; a shape for it exists — a map
from key to effect, and an `inert-key` diagnostic on the existing channel — and is
not built. Since fe39f71 the chain prints diagnostics even on success, where it
used to discard them. For any state channel this document proposes, the rule
follows: a read-back that confuses acceptance with effect is worse than none,
because it manufactures trust that nothing covers. Every provider below owes a
per-key answer to "did this do anything".

## What already holds

The chain is convergent. It reads the device, compares with `config/`, and
writes only the difference. "Change the configuration after the fact" is therefore
not a new capability — it is `provision/run.sh`, again. Everything below adds
convenience around that fact; none of it replaces it.

Two smaller pieces of runtime behaviour exist already. Obtainium runs in all six
zones and the launcher no longer carries a version pin (provisioning#5), so app
updates arrive in each zone on their own, without waiting for the host. And the
catalog is a template: the generators honour `CONFIG_DIR`, so a private catalog
can live outside this repository. That is the split "repository as dotfiles"
needs — the distribution here, the personal configuration elsewhere.

## Three layers of the configuration surface

Every field in `config/` needs a specific privilege to apply. Sorting them by that
privilege decides what can move to the device and what cannot.

**Layer A — state owned by our own apps.** Launcher layout, dock, wallpaper,
theme, checklists. An unprivileged app can apply these at runtime; the launcher
does it today. Nothing about GrapheneOS is touched.

**Layer B — system state.** Profiles, installing into other users, `INTERNET`
revocation, appops, secure settings, the VPN slot, the HOME role. This stays with
the shell, which means adb from a host.

**Layer C — device or profile owner, or the OS build.** Background operation per
profile, the three-running-users limit, pre-granted signature permissions. Out of
scope, for the reasons in [0004](../decisions/0004-adb-from-a-host.md) and
[0010](../decisions/0010-no-custom-build.md).

For one afternoon this layer looked smaller than the table in boundaries.md
says, and it is not. On the emulator, `pm set-user-restriction --user 11
no_run_in_background 1` flipped GrapheneOS's "Allow running in background"
toggle to off and `0` flipped it back — inverse, immediate, both directions, with
the toggle screenshot to prove the mapping. It was reported as a shell
capability. It ran as **root**. Rechecked with only the identity swapped, same
user, same device:

```
shell (uid 2000): SecurityException: You need MANAGE_USERS permission to: setUserRestriction
root  (uid 0):    set
```

Production GrapheneOS has no `adb root`. **Background operation stays in Layer
C**, boundaries.md's "no" in the shell column was right for the reason it gives —
the shell holds no `MANAGE_USERS` — and [0003](../decisions/0003-cloud-owns-the-third-slot.md)
keeps its weakest link. What the detour did establish, and what stands: the
toggle *is* `no_run_in_background`; a freshly created user carries only `no_sms`
and `no_outgoing_calls`, so background operation is *allowed* by default and the
manual "Cloud: on" step is a null step; and the write to
`/data/system/users/N.xml` is delayed, so whoever sets it and reboots at once
loses it. Any future setter, owner or otherwise, must wait for or force that write
before reporting success, or it is idempotent in appearance and inert in fact —
the proxy-success shape [provisioning.md](../architecture/provisioning.md) warns
about.

One rule for every measurement in this document follows from the mistake: **the
identity a command ran under is part of the result.** Every root-dependent line
below is now marked.

### The tier between A and B: `development` permissions

Android has a protection level `development`. Permissions with that flag can be
granted to an app once by the owner over adb (`pm grant`), persist across reboots,
and can be revoked the same way. `WRITE_SECURE_SETTINGS` carries it, and it covers
the global and secure namespaces. `READ_LOGS` and `DUMP` carry it too. Whether
`INTERACT_ACROSS_USERS` does must be read from the AOSP manifest, not assumed.
Installation, user creation and permission revocation do not carry it and stay in
Layer B.

**Measured on the GrapheneOS emulator, 2026-09-21.** An ordinary app in
`/data/app` that declares `WRITE_SECURE_SETTINGS` — Shizuku served as the test
object — received it from `pm grant`, confirmed by read-back rather than exit
code, and still held it after a real reboot. Its protection level on GrapheneOS
reads `signature|privileged|development|installer|role`; the `development` flag
is why the shell may grant it. (`pm grant` exits 0 for permissions an app never
declared, so read-back is the only proof.)

The grant is **per user**. Granted in user 0, it read `granted=false` for Work and
every zone. A configuration agent therefore needs the grant in every zone
separately, each one an adb operation from the host, and a zone without the grant
simply has no agent. For this model that is a feature rather than an obstacle:
the privilege follows the zone boundary instead of punching through it. The other
half of the same fact is that a grant, once given, stays until revoked.

An app granted this tier once, per profile, could converge `30-settings`, most of
`40-theming` and the settings half of `35-vpn` on the device itself. It is
narrower and more permanent than Shizuku, which is broad and volatile — the
opposite trade. It would be a fourth column in the capability table.

## One delivery path, not five

An earlier draft of this idea had each profile *fetch* its configuration: over
the tailnet where the profile runs Tailscale, from a signed "mailbox" on the
internet elsewhere, adb-only for Anon. That is correct in principle — trust would
come from the signature, not the server — and it is too many paths. Every
profile has its own network, half of them cannot reach the laptop at all, and a
mailbox is a service to run and a second key hierarchy to keep.

The simpler observation: **the laptop already sees every profile through adb**,
whatever VPN each profile runs, because adb is system-level. The delivery path is
therefore the one the launcher step uses today — `content write` into a
shell-gated ingest provider, per profile — carrying more than the launcher file.

Consequences:

- No mailbox, no server, no bundle encryption, no second key hierarchy. The adb
  keys are the only keys that matter for delivery.
- The on-device app **needs no `INTERNET` permission**. It never fetches; it is
  written to. On GrapheneOS, an app without network that nevertheless configures
  the phone is the strongest statement available.
- A stopped profile receives nothing, because nothing runs in it. It converges
  when it next starts, or when the chain starts it briefly, as `99-finalize`
  already does. Convergence is eventual, and that is the right promise for
  dotfiles.

### Two walkthroughs

*Ops, `runtime: stopped`.* The laptop changes the Ops wallpaper and adds an app
at 10:00. Nothing happens on the phone: the Ops instance of the app has no running
process, and no channel exists between profiles. At 14:30 the user switches to
Ops; the launcher starts, the app receives the pending bundle the laptop wrote
during its last window (or the chain starts Ops itself during the next window and
writes it then). Wallpaper and dock apply within seconds. A notification offers
the new app; the APK was already verified against the pinned hash and signer, and
the standard install dialog finishes it. State is written back; `andashi status`
later shows "Ops: converged 14:31". Leaving Ops stops it again.

*Cloud, `runtime: always`.* Same change. Cloud is running, so the write during the
laptop's window lands immediately and the app applies it on the spot.

*A Layer B change* — revoking `INTERNET` from an app in Ops — cannot be done by
the app. The chain does it in the window, starting and stopping Ops as today.
The three-slot rule from [0003](../decisions/0003-cloud-owns-the-third-slot.md)
is unchanged.

## The door: how the laptop gets in

Three stages, each a convenience layer over the previous one. A per-device setting
such as `remote: usb | lan | tailnet` would pick the highest one allowed.

**Cable.** Plugging in is the gesture. No wireless debugging at all. The laptop was
authorised once with "always allow"; after that, `andashi apply` at the desk is:
plug in, done. GrapheneOS's USB-C port control at its default denies new USB data
connections while the phone is locked, so a locked phone yields nothing.

**Local network.** Same Wi-Fi, no cable. mDNS lets the laptop find the phone and
its port. The consent is a notification: the laptop rings a *doorbell* in the Home
instance of the app, which accepts only a signed message from a paired laptop and
can do exactly one thing — show "Laptop wants to apply 3 changes to Cloud and
Ops. Allow?". One tap enables wireless debugging (`adb_wifi_enabled`, a global
setting, writable with the development tier from the owner profile). The laptop
applies, writes "done" into the provider, and the app closes the door again. A
30-minute fallback closes it regardless. The tile shows the last run.

**Tailnet.** From anywhere. Requires Tailscale in Home, which is the case here and
optional elsewhere. Tailscale carries no multicast, so mDNS does not work, and the
port has to reach the laptop some other way — see below, this is the open end of
this stage.

The doorbell is a deliberate, tiny exception to "the phone never listens": bound
to one interface, one message type, one action, signature-checked. An attacker on
the same Wi-Fi can ring, not enter.

**What the emulator answered.** `adb_wifi_enabled` lives in `Settings.Global`,
initial value 0. A purpose-built test APK that does nothing but call
`Settings.Global.putInt("adb_wifi_enabled", 1)` was run twice: without the
permission it threw `SecurityException: must have one of
[WRITE_SECURE_SETTINGS]`, and after `pm grant` of that one permission, confirmed
by read-back, the call returned true and the shell independently read the value
as 1. Developer options were off throughout (`development_settings_enabled` null
in both namespaces). An ordinary app that merely *holds* the permission writes the
setting; that is a property of the permission model, not of the emulator.

**The port cannot be read from a system property.** Not "unset" — denied by
SELinux, even for the shell:

```
avc: denied { read } for name="u:object_r:adbd_prop:s0"
     scontext=u:r:shell:s0 tcontext=u:object_r:adbd_prop:s0 permissive=0
```

`service.adb.tls.port` comes back empty, and an app in `untrusted_app` is at least
as constrained. The documented way to find the port is mDNS,
`_adb-tls-connect._tcp`, and this document now assumes exactly that. For the
tailnet stage that leaves three candidates, none verified: the Home instance
browses the service locally through `NsdManager` and puts the port in the
doorbell reply; the laptop fixes the port with `adb tcpip` after a first
connection, which holds until reboot; or the tailnet stage is simply not offered
and the cable or the local network is the answer from afar too.

**The emulator's limit, stated plainly.** Its adbd already speaks TCP on 5555.
After the app set the flag, still only 5555 listened, no TLS listener appeared,
`dumpsys nsd` was empty, and the same test APK browsing
`_adb-tls-connect._tcp` through `NsdManager` for twelve seconds found nothing —
no service, no error. The reading, and not a sharper one: on the emulator the
flag alone does not bring up the wireless-debugging path, so there is nothing to
announce. Whether on hardware the flag is enough, or the Settings toggle does
more than write this one value, is **not answered** — and that question is
bigger than discoverability. If the flag alone is not the trigger, the tailnet
stage lacks its trigger, not just its port. Both, and whether a key authorised
over USB is accepted wirelessly without a pairing code, are hardware
measurements.

## Pairing a laptop

Two things are paired, and they are not the same thing.

1. **The adb authorisation**, Android's own. First cable contact shows the key
   fingerprint and "always allow". Device-wide, one dialog, all profiles. Not
   replaceable, and correctly so.
2. **The laptop's public key for the doorbell**, ours. Kept in
   `config/laptops.json` with a name, written over adb into the Home instance
   only — nothing else needs it, because the other profiles' providers trust the
   shell uid exactly as the launcher's does today.

First laptop: cable, dialog, and the provisioning run writes its own key. On the
QR-code path below, the key travels inside the QR code.

Additional laptop: `andashi pair` on it creates a key and the `laptops.json`
entry; cable once for the dialog; the command then writes its own key. Commit.
The first laptop sees the addition as a diff. Copying one adb key to two laptops
is legitimate for one person with two machines and merges their identities.

Removal is asymmetric, and that is Android's boundary, not ours: an entry removed
from `laptops.json` can no longer ring; the adb authorisation itself can only be
revoked for *all* keys at once, from developer options, after which each remaining
laptop needs the cable once more. Android's default of revoking authorisations
unused for seven days is worth keeping — an unused laptop loses access on its own,
and a cable brings it back. Turning that off would be one more line in
`settings.json`.

## The companion app: what it sees

The app runs inside two walls, and that is the point.

- **The profile wall.** One instance per profile, each aware only of its own
  profile. There is no central instance; the Home one cannot reach Social. Work
  gets an instance without the launcher part.
- **The sandbox wall.** Inside its profile it sees its own files and the
  launcher's, because both are ours and may expose a signature-protected
  interface to each other. It cannot look into Signal, Bitwarden or Aegis.

| Within its own profile | Can | Cannot |
|---|---|---|
| Own and launcher state | apply, read back | — |
| Public package state | list apps, versions, permission status (`checkPermission`) | read app data |
| Installing | offer the standard install dialog for a verified APK | install silently |
| Settings | deep-link to the right screen; with the development tier, write global and secure settings | revoke another app's permissions |
| Other profiles | — | anything |
| While stopped | — | run |

The verification it can do without any privilege is the one nothing does today
after a run: prove that `INTERNET` really is revoked for every app declared
`net:false`.

Third-party app settings stay out of scope. They would need per-app adapters over
export formats, which does not scale. The distribution owns the *shell* of the
phone, not the inside of every app; that is a boundary to state, not a gap to hide.

## Setup as a temporary device owner

A second path for day one, next to the cable-and-chain path that exists.

A device owner is a role, not a user: one app in the owner profile holds it. With
it, the app can create, start and stop users, install silently into users it
created, set background operation, set always-on VPN with lockdown without the
consent appop, and set permission policy. It is the only shape in which an app
can do everything the chain does — plus the manual items in
[0008](../decisions/0008-some-things-stay-manual.md) that no shell tier reaches.

The role is granted only on a fresh device without accounts or extra users: either
one adb command over a cable, or Android's built-in enrolment — tap the welcome
screen six times, scan a QR code, the device downloads the app and makes it device
owner. No cable, no developer options, no laptop. That QR code would be the
distribution's install medium.

The path: the app shows what will be built, builds it, walks the user through the
two things it cannot do (PINs, Google logins) with deep links, and then **resigns
the role**. What remains is the ordinary app with the development tier in each
profile, on an unmanaged device.

What it costs:

- A real Android app against the device-policy APIs, maintained per Android
  release, next to nine bash scripts. The logic would exist twice. The chain
  would keep a role anyway: after the app provisions, `DRY_RUN=1 provision/run.sh`
  must report nothing to change. Two implementations, one checking the other.
- The moment the app holds the role and downloads from the network is the moment
  of greatest power. App and bundle must be signed, and the key must be in the QR
  code, or a forged QR code provisions a stranger's phone.
- A permanently held role is rejected for the same reasons as in 0004: the app
  would become the phone's root of trust, reachable from the network, and the
  device would read "managed by your organisation". Temporary only.

Three unknowns, each about an afternoon on the emulator. What they have
answered so far:

**QR enrolment: no, on the emulator.** The build finishes the wizard itself on
first boot and disables `app.grapheneos.setupwizard`; the shell may not re-enable
it (`Shell cannot change component state`), root may. On the real welcome screen
that came up — "Welcome to GrapheneOS", language, accessibility, emergency call —
six taps on the title, the logo and the centre of the screen changed nothing:
focus stayed on `WelcomeActivity`, and logcat showed nothing about provisioning
or QR. `com.android.managedprovisioning` is installed, so the machinery exists;
this entry into it does not. The plausible reading is that GrapheneOS writes its
own wizard and does not carry the AOSP gesture. The screen was reached by an
unusual route, so hardware has the last word.

If that holds, the consequence is blunt: **the role is granted over adb, and adb
needs USB debugging, which needs developer options.** The temporary device owner
then no longer removes the one step this path was meant to remove; day one starts
exactly like the cable path. What it still buys is the shorter manual list —
background operation and VPN lockdown set by the app rather than by hand — and
that has to be weighed against maintaining a second implementation.

**Device owner plus Work: they coexist, in one order only.** On the fresh device
a managed profile is created without any device owner (flags `1020`; the
provisioned device's Work shows `1030`, the extra bit being Shelter as profile
owner). With the profile already there, setting the owner is refused for good:

```
IllegalStateException: Not allowed to set the device owner because
  there are already several users on the device.
```

Owner first, then the profile, is refused too — but by a restriction, not a rule:

```
Error: Cannot add user: no_add_managed_profile is enabled. (code 10)
```

Setting the owner attaches `no_add_managed_profile` to user 0 as a *base*
restriction. It was cleared with `pm set-user-restriction --user 0
no_add_managed_profile 0` — **as root** — after which the managed profile was
created and both read back side by side. (`set-user-restriction` returns
silently; the reverse probe, setting it back to 1, brought the refusal back and
proved the effect.) So the two *can* coexist, but the route that got there does
not exist on hardware. The owner app cannot open it either: as device owner in
user 0, `clearUserRestriction("no_add_managed_profile")` returned without an
exception and changed nothing — it only clears what the same admin set as
policy, and this one arrives as a base restriction when the owner is set. **An
owner blocks Work for as long as it exists.** Work waits until the role is
resigned. [0002](../decisions/0002-work-as-managed-profile.md) stands.

One more identity finding, the other way round this time: `dpm
set-device-owner` succeeded as shell and was refused as root with "there are
already some accounts on the device" while `dumpsys account` showed none — the
check is `hasIncompatibleAccountsOrNonAdb`, and root fails its second half.
Setting a restriction needs root; setting the owner needs the shell.

Three side findings about the role itself: a device-owner app cannot be
uninstalled (`DELETE_FAILED_DEVICE_POLICY_MANAGER`); an admin without
`android:testOnly` cannot be removed by the shell (`Attempt to remove non-test
admin`), so a production app must resign *itself* through
`clearDeviceOwnerApp`, and if it breaks first, only a factory reset remains; and
a testOnly build needs `adb install -t` or the install fails silently.

**Restrictions after resignation, first attempt: base restrictions only.** With the owner set, `no_wallpaper` and `no_config_vpn` were placed on
Work and `always_on_vpn_lockdown` read 1 there. After the admin was removed,
the profile survived, both restrictions and the lockdown value were unchanged,
and the app could be uninstalled again. Then the control: `pm
set-user-restriction --user 10 no_outgoing_calls 1` succeeded *without* any
owner — **as root**, like every restriction write in this series. The
restrictions that survived were base restrictions placed by root and never bound
to the role, so their survival proves nothing about the role. What the path
actually needs is whether a restriction the owner sets as *policy* survives
resignation, and that was measured next.

**Policy restrictions after resignation: they do not survive.** Fresh throwaway
instance, an admin with a driver activity, identity recorded at every step. The
owner (set as shell) created a secondary user through `createAndManageUser` from
user 0, which made its admin profile owner there. The activity had to run in the
foreground user for each step — `Can't resume non-current user` — so
`am switch-user` preceded every call. `addUserRestriction("no_run_in_background")`
in user 10 read back as the distinction this document asked for:

```
Restrictions:               no_sms, no_outgoing_calls
Device policy restrictions: no_run_in_background
Effective restrictions:     no_sms, no_run_in_background, no_outgoing_calls
```

On disk under `device_policy_local_restrictions`; the toggle read
`checked=false`. Then `clearProfileOwner` in user 10 — and the status line of
that same call already said `no_run_in_background effective=false`. After
`clearDeviceOwnerApp` in user 0: owner gone, the user survived, device policy
restrictions none, toggle `checked=true`. A reboot, read back as shell, changed
nothing. The policy restriction is bound to the role and leaves with it,
immediately, not at reboot. What survives is the *user* the owner created, not
the policy.

**Where this leaves the path: empty.** No QR entry, so it does not save the
cable or the developer-options step. Its one remaining argument — the
background-operation toggle — does not survive the resignation, so "become owner
briefly, set it, resign" does not work. And while the role exists it blocks
Work. What remains manual, PINs and Google logins, no owner reaches. The
temporary device owner contributes nothing the cable path cannot do, at the
price of a second implementation and a role that must resign itself or force a
factory reset. **Not worth building.** The measurements stay here so the argument
is not rebuilt, and in case hardware disagrees about the QR entry — which would
change the first sentence of this paragraph and none of the others.

## Agents and the editor

LLM agents never touch the phone. They edit `config/`, run `make check` and a dry
run, and commit. A laptop-side `andashi` CLI wrapping the chain — `app add molly
--zone social`, `theme set`, `diff`, `apply`, `status` — is the surface for humans
and agents alike, and a skill for Claude Code or OpenCode is a description of that
CLI. Their feedback loop is the check and the dry run; their limit is the door on
the phone.

Two things belong with that:

- **A risk class per configuration field.** Cosmetic changes apply without
  asking. Structural changes — apps, network, profiles — are named in the doorbell
  prompt and need the tap.
- **Invariants as tests.** "Anon never gets Play", "no second background profile"
  belong in `make check`, so an agent cannot violate them by accident.

The on-device editor is the same app: a form generated from the schema, applying
Layer A fields directly and writing everything else back as a commit for the
laptop to pick up. No bidirectional sync; conflicts are git's.

Two audiences fall out of this. People with a laptop: the repository is the
source, the door is the path. People without one: the editor is the source, the
app is the path. Same schema, same application, two inputs. Neither needs a server.

## Prior art

This is a configuration profile — `.mobileconfig` — for GrapheneOS: a signed,
declarative bundle, installed with a confirmation, applied by something the user
trusts, visible and removable. Apple's Declarative Device Management goes further
and is closer still: the device receives a desired state, converges on its own and
reports status. Its vocabulary — declaration, activation, status channel — is
worth borrowing rather than reinventing.

The differences are the point. Apple has the OS on its side; Android has that only
for enterprise, so the door exists here and not there. Apple's key belongs to the
organisation; this one belongs to the user, which is the difference between MDM
and dotfiles and the reason there is no server. And this goes further than a
profile ever did: the home screen and the theme are part of the statement, and so
are six zones with their own networks.

## If any of this is adopted

- [0004](../decisions/0004-adb-from-a-host.md) would get a supplement, not a
  reversal: adb stays the privileged core, and the companion app is exactly the
  "permissionless checklist" that decision already describes, plus the development
  tier.
- [0008](../decisions/0008-some-things-stay-manual.md) could shrink, if the
  temporary device owner survives its three measurements.
- [boundaries.md](../architecture/boundaries.md) would gain the development column.

## Measurements

Done, on the GrapheneOS emulator, 2026-09-21 and after:

- `pm grant` of `WRITE_SECURE_SETTINGS` to an ordinary app: granted, read back,
  survives a reboot, **per user**. Details above.
- `adb_wifi_enabled`: global, written by an ordinary app holding only that
  permission, with developer options off, against a control run without it. The
  port is not readable from a property (SELinux). `NsdManager` on the device sees
  no `_adb-tls-connect._tcp`, because the emulator brings up no wireless path
  from the flag alone.

- QR enrolment: the six-tap gesture does nothing on GrapheneOS's welcome screen,
  reached with root on a throwaway instance. Details above.
- Device owner and managed profile coexist, owner first, after clearing
  `no_add_managed_profile` — as root, which hardware does not have. Profile first
  refuses the owner for good.
- Base restrictions placed as root, and the always-on VPN lockdown value, survive
  the owner's removal. Says nothing about policy-bound restrictions.
- `no_run_in_background` *is* GrapheneOS's "Allow running in background" toggle,
  both directions. Setting it needs `MANAGE_USERS`: root can, the shell cannot.
  Allowed by default on a fresh user. Survives a reboot once the delayed write has
  landed.

- A device owner places `no_run_in_background` as policy on a user it created,
  and the policy leaves with the role, immediately. The user survives.
- The owner cannot clear `no_add_managed_profile` itself; Work waits until the
  role is resigned.
- `dpm set-device-owner` needs the shell and is refused as root.

Open, on the emulator:

1. The chain with selective steps: only the steps whose inputs changed, and what a
   dock-only change then costs in seconds.

Open, hardware only:

- Whether `adb_wifi_enabled` alone brings up wireless debugging, or the Settings
  toggle does more. This decides whether the tailnet stage has a trigger at all.
- If it does: whether a TLS port appears, and how the laptop finds it on the local
  network and over the tailnet.
- Whether a key authorised over USB connects wirelessly without a pairing code.
- Whether the six-tap QR enrolment exists on a real device's welcome screen.
