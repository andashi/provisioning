# Where the privilege boundary runs

Could this distribution ship as an app, so that a phone sets itself up without a
computer? The question is worth answering precisely, because the answer decides the
shape of the whole project.

**Short answer:** the privileged core cannot be a normal APK. One specific app shape
could technically do all of it, at a price not worth paying. And the part that would
actually make setup easier is a different app than the question imagines.

## The capability table

Every provisioning step maps onto exactly one privilege tier.

| Step | Needs | Normal APK | shell (adb / Shizuku) | Profile owner | Device owner |
|---|---|---|---|---|---|
| `00-profiles` create/start/stop users | `CREATE_USERS` | no | **yes** | no | yes |
| `00-profiles` set profile owner | shell `dpm` | no | **yes** | — | — |
| `10-apps` install into another user | `INSTALL_PACKAGES` + `INTERACT_ACROSS_USERS_FULL` | no | **yes** | own profile | yes |
| `20-permissions` revoke INTERNET | `REVOKE_RUNTIME_PERMISSIONS` | no | **yes** | own profile | yes |
| `20-permissions` appops | `MANAGE_APP_OPS_MODES` | no | **yes** | no | no |
| `30-settings`, `35-vpn`, `40-theming` | `WRITE_SECURE_SETTINGS` | no | **yes** | no | no |
| `40-theming` HOME role | `MANAGE_ROLE_HOLDERS` | no | **yes** | no | no |
| `45-launcher-config` ingest provider | `WRITE_SECURE_SETTINGS` (provider gate) | no | **yes** | no | no |
| "Run in background" per profile | `no_run_in_background` restriction | no | **no** | yes | yes |

The shell column is read from AOSP's `packages/Shell/AndroidManifest.xml` rather
than assumed. It holds `CREATE_USERS`, `GRANT_RUNTIME_PERMISSIONS`,
`REVOKE_RUNTIME_PERMISSIONS`, `WRITE_SECURE_SETTINGS`, `MANAGE_APP_OPS_MODES`,
`INTERACT_ACROSS_USERS_FULL`, `INSTALL_PACKAGES` and `MANAGE_ROLE_HOLDERS`. It does
not hold `MANAGE_USERS` or `CONTROL_ALWAYS_ON_VPN`, and neither is needed here.

A normal app holds none of them — every one is `signature` or
`signature|privileged`. The answer is not "difficult", it is "structurally
impossible". It is the same wall one layer down that made the launcher a fork with
a shell-gated config interface ([launcher.md](launcher.md)).

**The boundary is sharp: adb covers everything except UserManager restrictions.**

## The three shapes

**A plain APK.** Dead on the first row of the table.

**A Shizuku-backed setup app.** Shizuku runs a server at shell uid 2000 and brokers
binder calls at that privilege, so it *is* the shell column — every command in
`provision/*.sh` is an `adb shell` command, which makes this provable rather than
speculative. It would work. What it costs:

- The bootstrap does not disappear, it moves: Shizuku's server must still be
  started by ADB, on-device via wireless debugging at best. "Step one: enable
  wireless debugging" is a worse first impression for a hardening distribution
  than "step one: plug in a cable".
- It does not survive a reboot, so it must be re-armed every time — good for
  security, bad for a setup wizard.
- It doubles the maintenance: nine bash steps become an Android app against hidden
  APIs, and the adb path has to stay anyway, because it is the only thing that
  works on a device that is not set up yet.
- The privilege is broader than the job. Bundling a general shell bridge into the
  happy path trains exactly the habit this distribution exists to discourage.

**A device owner.** Reaches furthest — it can set `no_run_in_background` and
`setAlwaysOnVpnPackage` without the consent appop. It is rejected for the reason
that predates it: a device owner makes the device managed, binds removal to a
factory reset, and contradicts the unmanaged-device approach.

A profile owner is the narrower variant and the table is honest about it: AOSP
documents `no_run_in_background` as settable by device owners **and** profile
owners, and `dpm set-profile-owner --user N` works from adb for an account-free
user. Two things keep it off the table anyway. The direction is wrong — GrapheneOS
ships secondary users with the restriction already set and the Settings toggle
*clears* it, and whether a profile owner may clear a base restriction set by the
system is unverified. And a profile owner on a full secondary user makes that user
managed, with the organisation notice and a wipe to undo it. That is a real cost
for one toggle, so the toggle stays manual.

## The bottleneck is not adb

Even a perfect on-device provisioner leaves the manual block untouched, and that
block is dominated by sandboxed Play and Google logins. No tier in the table
automates a Google login. **The ceiling on "make it simple" is set by the manual
half, not by adb-versus-APK.**

Which is where a small companion app would earn its place — and it needs no special
permissions at all:

- **A guided checklist on the device**, instead of reading a markdown file on a
  computer while tapping on a phone. Generated from the same `config/*.json`, so it
  cannot drift from what provisioning did.
- **Deep links into the right settings screen** per item, turning each step into a
  tap rather than a navigation puzzle.
- **Verification of the end state.** `PackageManager.checkPermission` is public API
  and needs no privilege, so a per-profile app can prove the core claim of the zone
  model: that INTERNET really is revoked for every app declared `net:false`.
  Nothing checks that today after a run.

## The answer

Ship the distribution as **this repository plus adb for the privileged core** —
there is no alternative that does not either make the device managed or normalise
an always-available shell bridge — **and, optionally, an on-device companion for
the manual half**, which is where the remaining friction actually lives.
