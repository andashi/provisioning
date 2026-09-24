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
state, which is compared field by field against the file that was written.

Failure is per profile and strict: the step attempts every zone, then fails if any
one of them did not converge. A locked profile is reported, never unlocked.

One race is tolerated deliberately. Right after `am start-user -w`, the user is
unlocked but its external storage and package resolution land a moment later; the
provider answers "External files directory unavailable" or cannot be found at all.
Exactly those two messages are retried, bounded to about 30 seconds. Anything else
fails immediately.

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

On a **fresh** profile that emptiness only holds from the second run. The launcher
writes its own favorites row the first time the zone is opened, which is after our
push, so the read-back agrees with us while the screen does not
([andashi/home#92](https://github.com/andashi/home/issues/92): a layout equal to
the stored state produces no mutation, and nothing then marks the grid
initialised). Measured on emulator-5558 with 0.5.0.

## Editing on the device

The grid is not locked (`home.grid.locked: false`), so a zone can be rearranged by
hand and the launcher writes the arrangement back into its own copy of the file.
That makes the device a second author, and the step therefore **pulls before it
pushes**: it compares the sha256 the device reports against the one recorded from
the last run and refuses to overwrite an arrangement it has not seen.

```bash
CONFIG_DIR=/path/to/your/config provision/45-launcher-config.sh --pull
```

`--pull` writes the effective config of every zone into the catalog the chain was
pointed at, never into this repository's template — the template demonstrates
mechanisms and is diffed against the generator by `make check`.

**A pulled fold layout can make phones complain** (andashi/home#90): a phone
validates a `fold` layout against its own row count, six, while the Fold has
seven. A file pulled from the Fold whose bottom row is row 6 is applied cleanly by
the Fold and reported as `grid-overflow` by every phone that reads the same file.
Nothing generated here hits this today, because the generator writes no geometry
at all — the warning becomes reachable the moment the first Fold arrangement is
pulled and shared.

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
to keep writing, which is how `home.dock.enabled` survived the clock removal.

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
