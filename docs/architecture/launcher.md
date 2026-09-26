# The launcher contract

The home screen is not configured by this repository. It configures **itself**,
from a file this repository delivers. The launcher is
[Andashi Home](https://github.com/andashi/home) (`org.andashi.home`), a fork of
Kvaesitso maintained for exactly this purpose.

This document describes the interface between the two repositories. It is the only
cross-repository contract in the project, so it is versioned, pinned and verified
rather than assumed.

## Why the launcher had to change

A launcher keeps its preferences in `/data/user/N/<pkg>`, owned by the app's own
uid. Nothing on the host can read that. The previous approach drove the settings
UI with uiautomator: it took roughly 27 minutes per run, needed an unlocked screen
in every zone, and could never verify what it had set — the definition of
[set-once and unverifiable](provisioning.md#two-kinds-of-state).

The fork adds three things, and they are the whole contract:

1. a **write-only ingest provider** that accepts a config file and wallpapers,
2. a **reload broadcast** that makes convergence deterministic for scripts,
3. a **state provider** that serves the launcher's effective configuration back.

With those, the home screen became ordinary convergent state.

## The flow

`provision/45-launcher-config.sh`, once per non-managed profile:

```
content write  →  content://org.andashi.home.config-ingest/wallpapers/<name>
content write  →  content://org.andashi.home.config-ingest/launcher.json
am broadcast   →  org.andashi.home.action.RELOAD_CONFIG   (per user, sent to the
                  component de.mm20.launcher2.config.service.ReloadConfigReceiver)
content query  →  content://org.andashi.home.state/diagnostics   until configSha256 matches
content query  →  content://org.andashi.home.state/config        compare field by field
```

Both providers are exported but gated to shell and root
(`WRITE_SECURE_SETTINGS` plus a uid check). The ingest provider writes atomically
into the launcher's per-user external files directory.

**Why `content write` and not `adb push`.** The adb shell only sees user 0's
storage. Every secondary user's path is "Permission denied", adb root included.
A draft of this step pushed files anyway and would have converged Home while
silently leaving five zones untouched — a textbook proxy success.

**Why an explicit broadcast.** The launcher also watches the file, which is the
right behaviour interactively. A script needs a defined moment, so it sends the
broadcast to the component directly. The preceding `content write` has already
started the app's process; a freshly installed, never-launched app would otherwise
not receive even an explicit broadcast.

**Why two queries.** `diagnostics` answers *did you load exactly my file* — it
carries the sha256 of the config the launcher last read plus success or error
detail. A matching sha with `success: false` is a failure with an explanation from
the launcher itself, so it is surfaced, not retried away. `config` then answers
*and did it mean what I meant*: the launcher serves its fully populated effective
state, and **every value the file wrote must be what comes back**. A key the file
left out is the device's to keep.

That is one rule for every section, and it used to be four sections compared
whole plus `search` carved out. Whole-section equality broke every time the
contract grew: the read-back is fully populated with defaults by design, so a
release that adds one key to a section makes the section differ from a file that
never claimed to set it. It happened twice in one day (andashi/home#181 adding
`icons.size`, `adaptify` and `badges`; #189 adding `home.searchBar.fixed`,
`home.lockRotation` and `appearance.systemBars`), which is what turned a carve-out
into a rule.

Objects are walked; anything else is a leaf compared whole, arrays included, so a
swallowed favourite or a flipped `locked` is still one mismatch and not a list of
them. What it gives up is noticing that the contract grew — which was never drift
and never ours to report. The failures that matter are caught elsewhere and more
precisely: the launcher's own diagnostics for a key it ignores, and
`config/check-schema.sh` for a key the contract no longer has.

Failure is per profile and strict: the step attempts every zone, then fails if any
one of them did not converge. A locked profile is reported, never unlocked.

One race is tolerated deliberately. Right after `am start-user -w`, the user is
unlocked but its external storage and package resolution land a moment later; the
provider answers "External files directory unavailable" or cannot be found at all.
Exactly those two messages are retried, bounded to about 30 seconds. Anything else
fails immediately.

**A build with a different signer leaves a trap behind.** Not the debug variant,
which installs as `org.andashi.home.debug` and coexists: the case that bites is a
release build made without the keystore, which keeps the release application id
and falls back to the debug key ([andashi/home#137](https://github.com/andashi/home/issues/137)).
Installing that means uninstall and install, and the per-user external directory
survives that with the ownership of the install that made it. The new build then cannot write into its
own directory, and every upload into that zone fails with a null file
descriptor over `IOException: Permission denied`. It is not a race and retrying
never helps; the step says so and prints the remedy. The user has to be running
for it, because `pm clear` on a stopped user prints `Success` and does nothing:

```bash
adb -s <serial> shell am start-user -w <uid>
adb -s <serial> shell pm clear --user <uid> org.andashi.home
```

The step will not do that by itself. `pm clear` also destroys whatever was
arranged on the device, and protecting that is the reason the push guard exists.

## The config document

Schema version 2, one file per non-managed profile, generated into
`config/launcher/<zone>.json` and checked in:

```json
{
  "schemaVersion": 2,
  "icons":      { "themed": true, "enforceThemed": true, "pack": "app.lawnchair.lawnicons" },
  "appearance": { "glass":     { "blur": 24, "tint": 0.12, "radius": 28,
                                 "contrast": "medium", "wallpaperBlur": false,
                                 "searchWallpaperBlur": true },
                  "wallpaper": { "image": "cloud.jpg", "target": "both" } },
  "home":       { "searchBar": { "position": "bottom" },
                  "favorites": [],
                  "widgets":   { "enabled": true },
                  "grid":      { "columns": 4, "locked": false, "labels": true,
                                 "layouts": { "phone": { "items": [ { "id": "favorites",
                                                                     "widget": "favorites" } ] },
                                              "fold":  { "items": [ { "id": "favorites",
                                                                     "widget": "favorites" } ] } } } }
}
```

Two properties of this document are worth stating, because the read-back check
depends on both.

**A geometry the device does not honour comes back changed, silently.** The
launcher stores what it can apply and serves that; nothing reports the
difference, and our read-back ignores geometry by design, so the file can claim
a shape the screen never had. Two things cause it and they look identical from
here - the grid's row count, and a widget's own maximum size. One push tells
them apart: move the item down and keep its size. An item at `y 1` with `h 6`
cannot survive on a six-row grid, so if it comes back unchanged the limit was
the widget, not the grid. Measured that way on 2026-09-25: the favorites widget
maxes out at six cells tall, which is why the Fold column is `h 6` and not the
`h 7` it was first declared as.

**We write less than we read.** Grid items carry no geometry: rows come from the
screen, so "bottom row, full width" is not something a host can compute for a
device it cannot see. The launcher places the item and writes the coordinates
back, which is why the comparison matches grid items by `id` and `widget` and
leaves where they sit to the device.

**We write more than we would need to.** Every glass field is spelled out,
although each one is optional. The launcher serves a *complete* glass block back,
defaults filled in, and the check compares the whole `appearance` section - an
omitted field would come back as a difference. Writing them also means the look
is decided here rather than moving whenever the launcher retunes its defaults.

A **managed profile gets no file**: Work has no home screen of its own, its apps
appear badged in Home's launcher. That skip is deliberate, not a failure.

## Generation

`config/gen-launcher.sh` builds these files from `theming.json`, `apps.json`,
`profiles.json` and `features.json`. `make check` regenerates into a temporary
directory and diffs, so a hand-edited or stale file fails the check.

Per-profile values win over the launcher defaults, the same precedence
`40-theming.sh` uses. Human-facing labels are mapped here and only here: widget
names to the fork's widget ids, favorite labels to package names from the catalog.

The glass values are the one exception to "per-profile wins as a whole": they
merge **field by field**, `all_profiles.glass` first and the zone's own object on
top. Three transparency values were always written together, so replacing the
whole object was harmless; with six fields it is a trap, because a zone that
only wants a darker tint would silently reset blur, radius and contrast.

**Resolution failures are fatal.** A favorite that matches no catalog entry or
several, an unknown widget, a glass value outside the bounds the launcher
enforces (blur and radius 0..64dp, tint 0..1, contrast `low|medium|high`) —
generation stops with an error instead of writing a file that describes a home
screen which cannot exist. The bounds are duplicated here on purpose: the
launcher would reject the document with `invalid-glass`, and a rejected document
takes the wallpaper and favorites of that zone with it, in every zone at once.
Files for profiles that no longer exist, became managed, or lost their feature
flag are pruned, so nothing stale gets pushed.

**A zone with nothing pinned declares no widget at all.** The pin list and the
widget are separate in the contract: `home.favorites` is the list, and whether the
widget is on the grid is whether a grid item for it exists. Declaring it
unconditionally gave every zone a full-width empty card, so it is declared only
where something is pinned — and the row is placed explicitly in the bottom row,
above the search bar, because an item without coordinates goes to the first free
cell, which is the top.

Up to 0.6.0 that emptiness held on a **fresh** profile only from the second run:
the launcher wrote its own favorites row the first time the zone was opened, after
our push, so the read-back agreed with us while the screen did not
([andashi/home#92](https://github.com/andashi/home/issues/92): a layout equal to
the stored state produced no mutation, and nothing marked the grid initialised).
Measured on emulator-5558 with 0.5.0. Since 0.6.1 a config that names
`home.grid.layouts` marks the grid initialised, and an empty zone is empty from the
first run — measured on emulator-5558 from `profiles-ready`: Cloud opened for the
first time after the push, both layouts read back empty, no card on screen.

**Search writes three keys.** The first is derived rather than chosen: `search.contacts` (0.6.0+)
is `true` only in a zone where the catalog grants the launcher `READ_CONTACTS`
(`perms.grant` with `perms.only_profiles` in `apps.json`) — today that is Home. So
contact search never exists without the permission, and a zone without it does not
show "Contacts permission is required — Grant" under every query, an invitation to
exactly the grant the catalog withholds. Home is the only zone with a contacts
source (DAVx5, Signal, the dialer); a zone that gains one goes into
`perms.only_profiles`, and search follows. The launcher has no network in any zone,
so what it reads stays on the phone either way. `search.barPosition: top` (the release
with andashi/home#107) puts the bar at the top of open search while the home screen keeps
it at the bottom: the thumb reaches it there, and in search the keyboard owns the
bottom anyway, so field and best match sit together at the top. Chosen from screen
recordings of three variants (provisioning#9); `search.reversed` stays unwritten,
because with a top bar it would put the best match at the far end. `search.actions`
(andashi/home#106) keeps only the built-in recognisers — Call, Message, Email,
Contact, Alarm, Timer, Calendar, Website, which appear when a query looks like a
number, an address or a time — and drops the web search chips in every zone. Web
search, YouTube and Google were seeded into existing installs, and only an explicit
list replaces them, so the list is always written (`all_profiles.search_actions` in
`theming.json`, overridable per zone; provisioning#8). The other `search` keys are left to the device, and the read-back compares only the keys the generator wrote,
because the launcher serves all thirteen.

**Nothing on the launcher's side enforces the permission.** Measured on
emulator-5560 with 0.7.2: a config that sets `search.contacts: true` in Anon, the
zone the catalog denies `READ_CONTACTS`, is accepted, applied and served back as
`true` without a diagnostic. The derivation above is therefore the only thing
standing between a zone and a permanent "Contacts permission is required - Grant"
banner under every query, and a guarantee that lives in one generator branch is
one hand edit or one pull away from being lost. So `make check` asserts it against
the generated files instead of trusting the code that wrote them. Reported as
[andashi/home#140](https://github.com/andashi/home/issues/140), which asks for a
diagnostic rather than a clamp - the same question is open for the other
permission-gated providers.

## Editing on the device

The grid is not locked (`home.grid.locked: false`), so a zone can be rearranged by
hand and the launcher writes the arrangement back into its own copy of the file.
That makes the device a second author, and the step therefore **pulls before it
pushes**: it compares the sha256 the device reports against the one recorded from
the last run and refuses to overwrite an arrangement it has not seen.

```bash
CONFIG_DIR=/path/to/your/config provision/45-launcher-config.sh --pull
config/gen-launcher.sh && git diff
```

**`--pull` writes into the source, not into the generated files.** It updates
`theming.json` — the file a person edits — and never this repository's template,
which demonstrates mechanisms and is diffed against the generator by `make check`.
Writing into `config/launcher/<zone>.json` would put the arrangement exactly where
the next generation rebuilds over it, which is the defect this exists to close
([provisioning#11](https://github.com/andashi/provisioning/issues/11)).

Three things travel, and each one differently:

| What | Where it lands | How |
|---|---|---|
| the grid arrangement | `per_profile.<zone>.layouts` | **verbatim**, the launcher's own block, copied unread |
| favourites | `per_profile.<zone>.favorites` | package names translated back to catalog labels |
| glass values | `per_profile.<zone>.glass` | only the fields that differ from `all_profiles.glass` |

The grid block is opaque here on purpose. The launcher is the only component that
understands grid geometry, so a representation of our own would be a second truth
to keep in step; carried through unread, a grid feature it gains later passes
through without this repository learning anything about it. An overlay file that
merged over `theming.json` was considered and rejected for the reason ricing
already knows: your dotfiles are the truth, and nothing should merge invisibly on
top of them.

A favourite whose package the catalog does not know has no label to become, so
that zone's list is left alone and the missing app is named — writing the raw
package would produce a file that fails its own generation later.

**The wallpaper and the palette are not pulled.** The launcher reports the image
*name* it applied while `theming.json` holds a repo path with an `{aspect}`
placeholder, so the reverse is a guess; the palette is not in `launcher.json` at
all, it is a system setting `40-theming.sh` writes.

**What comes back is the effective config, not the file.** The state provider
serves `config` and `diagnostics`, and the app's per-user directory is unreachable
from the shell, so the launcher's own file — where write-back preserves comments
and touches only keys that are already there — is something no one here will ever
see. For the grid that costs nothing, because items are explicit. For anything
scalar it means "somebody set this to the default" and "nobody touched it" are the
same bytes, which is why the round trip stays narrow rather than becoming *pull
everything back*.

**A pulled fold layout can make phones complain** (andashi/home#90): a phone
validates a `fold` layout against its own row count, six, while the Fold has
seven. A file pulled from the Fold whose bottom row is row 6 is applied cleanly by
the Fold and reported as `grid-overflow` by every phone that reads the same file.
Nothing generated here hits this today, because the generator writes no geometry
at all — the warning becomes reachable the moment the first Fold arrangement is
pulled and shared.

## The schema is checked, not assumed

The launcher publishes a JSON Schema for `launcher.json` as a release asset. A
copy lives in `config/schema/`, with `config/schema/FROM` naming the release it
came from, and `make schema` refreshes it. `make check` validates every generated
config against it.

This closes a gap that the rest of the chain does not cover. `make check` already
proves the files match the generator, and the read-back proves the device agrees
— but the read-back needs a device, and it compares whole sections, so a key the
contract has removed shows up at best as "the section differs". When schema 1
became schema 2 and `home.dock` disappeared, nothing structural would have caught
a generator that kept writing it; it was caught because the same person changed
both in the same week.

It is deliberately not a full validator. It checks the part that matters here —
keys the contract does not have, values outside an `enum` or `const`, and basic
types — and leaves patterns, ranges and required fields to the launcher, which
reports them per zone in its own words. `oneOf` passes when any branch does.

## Version coupling

The launcher entry in `theming.json` declares what that build can do:

```json
"andashi-home": { "pkg": "org.andashi.home", "config": true, "wallpaper": true, "glass": true, ... }
```

`config: false` makes the whole step skip itself. `wallpaper: false` suppresses
the `appearance.wallpaper` key during generation — because a release that does not
understand the key would not serve it back, and the read-back comparison would
fail on a difference that is really a version mismatch. `glass: false` does the
same for `appearance.glass` and `home.grid.labels`, both new in 0.5.0, and keeps
emitting the `appearance.transparency` block that came before them. The flags
exist so the two repositories can move independently without lying to each other.

**Against 0.5.0 the flag has to be true.** The key did not merely change meaning,
it changed sides: `transparency` is now inert and `glass` is what the launcher
serves back. A run with `glass: false` against 0.5.0 therefore fails twice over,
and the first of the two is the one that says why — `45-launcher-config.sh` treats
the launcher's `inert-key` diagnostic on `appearance.transparency` as a failure
with the launcher's own sentence, rather than letting it pass as a warning and
reporting a read-back difference in `appearance` a moment later. That is a named
key, not a rule: a key can be inert in one release and still be the right thing
to keep writing - `home.dock.enabled` was kept through two releases while it
drew nothing, and then schema 2 removed it and the dock came back as a grid
item instead of a key.

The launcher is **not** pinned. `release_tag` exists for holding a version
deliberately — while debugging, or to sit out a bad release — but a release that
does not reach the phones is not a release
([decision 0012](../decisions/0012-every-zone-updates-itself.md)). The price is
that a contract change arrives before this side is ready for it; the flag above is
how that window is survived, and the signer pin still holds either way. See
[catalog.md](catalog.md).

## Wallpapers belong to the launcher

Wallpapers used to be applied by a small helper APK of our own. That helper is
gone: the launcher applies `appearance.wallpaper` itself on reload, and
`40-theming.sh` no longer touches wallpapers at all.

One platform behaviour shapes this and is worth knowing before debugging it:
**`WallpaperManagerService` computes the crop only for the current user.** A
wallpaper set for a background profile is recorded but never rendered, and an
implementation that compares ids will report success for a screen that is black.
The launcher therefore re-applies on its first `onResume` in the foreground, and
exposes a diagnostic for the pending case. Provisioning verifies the record per
user; the visible result is confirmed once the zone has been in the foreground.
