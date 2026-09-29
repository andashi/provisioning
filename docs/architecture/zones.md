# Zone model

A phone is treated as a segmented network. Every profile is a zone, and the
question when installing an app is never "do I want this app?" but "which zone is
this app allowed to do damage in?".

The model lives in [`config/profiles.json`](../../config/profiles.json). Everything
below is a reading of that file, not a separate plan.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Home (Owner, user 0)          trusted LAN        VPN: Tailscale private │
│  Signal · Immich · HA · Bitwarden · Cameras · Obtainium                  │
│  ── NO Play Services. Hard rule, not negotiable. ──                      │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │ Work (managed profile, parent = Home)  VPN: RethinkDNS lockdown    │  │
│  │ Teams · Outlook · Company Portal · Authenticator                  │  │
│  │ No home screen of its own - apps show badged in Home's launcher.   │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└───────────────┬──────────────────────────────────────────────────────────┘
                │ Inter Profile Sharing (feature flag, on by default)
   ┌────────────┼─────────────┬──────────────┬──────────────┐
   ▼            ▼             ▼              ▼              ▼
┌──────────┐ ┌──────────┐ ┌─────────┐ ┌───────────┐ ┌───────────────┐
│ Cloud    │ │ Gadgets  │ │ Ops     │ │ Lab       │ │ Anon          │
│ DMZ      │ │ IoT VLAN │ │ mgmt    │ │ guest     │ │ —             │
│ Rethink  │ │ Rethink! │ │ TS-biz  │ │ variable  │ │ Orbot         │
│ Play sb  │ │ Play sb  │ │ no GMS  │ │ variable  │ │ no GMS        │
│ always on│ │ on demand│ │ stopped │ │ wipe often│ │ stopped       │
└──────────┘ └──────────┘ └─────────┘ └───────────┘ └───────────────┘
```

## The zones

| Zone | Network analogue | Runtime | VPN | Lockdown | Play | Unlock |
|---|---|---|---|---|---|---|
| **Home** (user 0) | trusted LAN | always | Tailscale private | no | none | fingerprint + PIN |
| **Work** (in Home) | work container | always | RethinkDNS | **yes** | sandboxed, company account | inherits Home's lock |
| **Cloud** | DMZ | always | RethinkDNS monitor | no | sandboxed throwaway | PIN |
| **Gadgets** | IoT VLAN | on demand | RethinkDNS aggressive | **yes** | sandboxed throwaway | PIN |
| **Ops** | mgmt VLAN | stopped | Tailscale business | no | none | fingerprint + PIN |
| **Lab** | guest VLAN | on demand | as needed | no | as needed | PIN |
| **Anon** | — | stopped | Orbot | **yes** | none | password only, no fingerprint |

Lockdown means "block connections without VPN". For **Anon it is mandatory**:
without it, traffic leaves past Tor silently. For **Gadgets** it is what keeps the
IoT zone from bypassing its own filter. For Tailscale zones it is wrong — Tailscale
is not a full tunnel, and lockdown would break LAN access and split routing.

Lockdown keeps Anon's *traffic* on Tor; it does not decide which *app* a link opens
in. Vanadium is a system app present in every user, and without a choice it holds
the browser role — so a link from Molly or a typed address went to a clearnet
browser, fingerprint and all, through a tunnel that only hides the address. Anon
therefore names its browser (`"browser"` in `profiles.json`): `40-theming.sh` gives
Tor Browser the role and reads back where a plain `https` link resolves, and
`make check` refuses a zone browser the catalog does not place in that zone
(provisioning#10).

## Why the model holds

**One VPN slot per profile.** Android allows exactly one VPN app per user, so the
assignment is enforced by the platform rather than by discipline. Tailscale and
RethinkDNS can never interfere with each other because they never live in the same
profile.

**A stopped profile has its keys evicted.** It is encrypted at rest, not merely
"in the background". This is not an amnesia mode — data survives. Real amnesia
(Anon, Lab) is `pm clear` or `remove-user` plus a re-run of provisioning, both
scriptable.

**One bridge for files.** Inter Profile Sharing: you hand a photo or a link from
Home into another zone, one item at a time. One path that can be understood and
checked beats five convenient ones.

This used to say Immich — Home writes, every other zone reads — and that was never
implementable. Immich's server lives on the private tailnet, a zone has exactly one
always-on VPN slot, and only Home and Ops carry Tailscale; a zone whose slot is
RethinkDNS has no route to it. The bridge existed on the diagram and nowhere else.
Immich is Home-only now, the catalog says why in its entry, and `make check` refuses
a catalog that puts a tailnet-dependent app into a zone that cannot reach it.

**Cross-profile sharing is a feature flag, on by default.**
`inter_profile_sharing` in [`config/features.json`](../../config/features.json)
installs Inter Profile Sharing and grants it `INTERACT_ACROSS_USERS`, so a photo
can be handed from Home into another zone directly. This deliberately opens a
channel through boundaries that are otherwise closed. Turn the feature off for the
stricter model. Work does not need it: a managed profile has cross-profile intents
built in.

## Work is a container, not a zone

Work is a managed profile under Home, not a secondary user. The reason is narrow
and load-bearing: only managed profiles resolve contacts across the profile
boundary at ring time (`InCallController` branches on `isManagedProfile`), so
customer calls show names without company contacts being copied into Home.

The price is honest: a managed profile isolates more weakly than a secondary user.
It runs alongside its parent and the framework deliberately opens channels between
them. That is acceptable for apps the company already entrusts with all its data.

Its profile owner is Shelter (`net.typeblog.shelter`) — a local, open-source
stand-in for an MDM. It manages nothing; it exists so the profile is allowed to
exist at all.

## Every zone has a color

`provision/40-theming.sh` pins a Monet seed per profile from
[`config/theming.json`](../../config/theming.json) with `color_source=preset`, so
changing the wallpaper does not change the palette. Quick Settings, the keyboard
and the themed icons all carry it. You can see which zone you are typing in at any
moment.

| Zone | Seed | Style | Tone |
|---|---|---|---|
| Home | `D8DEE9` | MONOCHROMATIC | glass — deliberately colorless |
| Cloud | `4285F4` | TONAL_SPOT | blue |
| Gadgets | `F9AB00` | TONAL_SPOT | amber |
| Ops | `7C4DFF` | TONAL_SPOT | purple |
| Lab | `00BCD4` | TONAL_SPOT | turquoise |
| Anon | `9E9E9E` | MONOCHROMATIC | grey — deliberately no identity |

Home is colorless on purpose: color then means *you are not home*. A blue interface
during a banking login is, by definition, a warning sign. Anon is monochrome too
and is told apart from Home by its wallpaper and its context — stopped,
password-only. Work apps additionally carry the briefcase badge, so a work app in
the personal launcher is recognizable at a glance.

Each zone also has its own wallpaper (`themes/synthwave/{aspect}/<zone>.jpg`),
applied by the launcher rather than by provisioning — see
[launcher.md](launcher.md).

## The hard limit: three running profiles

GrapheneOS runs **exactly three users at once, the owner included**. The value is
the build-time resource `config_multiuserMaxRunningUsers`; there is no
`pm set-max-running-users`, and the request to raise it was closed upstream
(os-issue-tracker#4258). Up to 32 profiles may exist — only three may run.

Start a fourth and Android evicts whichever has been in the background longest.
Measured on the emulator (emu64x, 2026-09-14):

```
running:  0:Owner  11:Cloud  13:Ops
14:Lab starting  ->
running:  0:Owner           13:Ops  14:Lab      <- Cloud was evicted
```

That is, of all zones, the one that has to run permanently. Without a word.

### The slot allocation is therefore fixed

| Slot | Profile | "Run in background" |
|---|---|---|
| 1 | **Home** (user 0) | always runs, cannot be turned off |
| 2 | **Cloud** | **on** — the car key and Teams pings need it |
| 3 | Gadgets \| Ops \| Lab \| Anon | **off** — one at a time, rotating |

**Work does not compete for a slot.** It is a profile of Home, not a full user
(`UserInfo.FLAG_FULL`), and profiles of the current user are never stopped when
switching users: `startProfiles()` starts them unconditionally and only logs a
warning when their count would exceed the limit.

Slot 3 frees itself. A profile with background operation turned off stops on exit,
its keys leave RAM, and the next zone can have the slot. Cloud is never touched.

### The one misconfiguration that tips it over

Turning on "run in background" for a **second** secondary profile is enough. All
three slots are then permanently taken, and the next profile switch kicks Cloud
out — with the car key and the work notifications in it. There is no error
message. You notice it standing in front of the car.

**Rule: exactly one secondary profile may run in the background, and it is Cloud.**

### Consequences for everyday use

- **Profile switching goes through Home.** A profile with background operation
  cannot be left by switching away; it needs "End session" and the route via the
  owner lock screen. Ops to Gadgets therefore always goes via Home.
- **Never two zones at once.** Testing in Lab while working in Ops cannot happen.
  From a security standpoint that is a feature.

## What provisioning cannot set here

**"Run in background" is not a setting.** It is the UserManager restriction
`no_run_in_background` (inverted: set = not allowed), and restrictions can only be
written by a device or profile owner through DevicePolicyManager. `pm`,
`cmd user` and `cmd device_policy` offer no path, and a device owner would
contradict the unmanaged-device approach. The same holds for the per-profile
calling switch (`no_outgoing_calls`).

**Notification forwarding is manual.** `send_censored_notifications_to_current_user`
can be neither read nor written over adb, on any profile, adb root included. When
it is on, only the profile name, app name and time cross over — never content.

Both land in the generated `MANUAL.md`. See
[provisioning.md](provisioning.md#what-stays-manual).

## What the emulator cannot prove

Everything touching Google servers validates only on real hardware: sandboxed Play
install and login, Play Integrity behaviour of individual apps, the MAM broker,
FCM push. The emulator is a development target without the full baseline security
— which is exactly right for its job here.

What it does prove: profile creation, installs, permissions and appops, the
settings namespaces, `INTERNET` revocation, VPN slot assignment, and the launcher
configuration end to end.
