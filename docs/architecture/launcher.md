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

Schema version 1, one file per non-managed profile, generated into
`config/launcher/<zone>.json` and checked in:

```json
{
  "schemaVersion": 1,
  "icons":      { "themed": true, "enforceThemed": true, "pack": "app.lawnchair.lawnicons" },
  "appearance": { "transparency": { "name": "fold-glass", "background": 0.31,
                                    "surface": 0.31, "elevatedSurface": 0.31 },
                  "wallpaper":    { "image": "cloud.jpg", "target": "both" } },
  "home":       { "searchBar": { "position": "bottom" },
                  "dock":      { "enabled": true, "favorites": [] },
                  "widgets":   { "enabled": false, "widgets": [] },
                  "clock":     { "style": "digital1", "fillHeight": true } }
}
```

A **managed profile gets no file**: Work has no home screen of its own, its apps
appear badged in Home's launcher. That skip is deliberate, not a failure.

## Generation

`config/gen-launcher.sh` builds these files from `theming.json`, `apps.json`,
`profiles.json` and `features.json`. `make check` regenerates into a temporary
directory and diffs, so a hand-edited or stale file fails the check.

Per-profile values win over the launcher defaults, the same precedence
`40-theming.sh` uses. Human-facing labels are mapped here and only here: clock
style names to the fork's style ids, widget names to its widget ids, favorite
labels to package names from the catalog.

**Resolution failures are fatal.** A favorite that matches no catalog entry or
several, an unknown widget, an unknown clock style — generation stops with an
error instead of writing a file that describes a home screen which cannot exist.
Files for profiles that no longer exist, became managed, or lost their feature
flag are pruned, so nothing stale gets pushed.

## Version coupling

The launcher entry in `theming.json` declares what that build can do:

```json
"andashi-home": { "pkg": "org.andashi.home", "config": true, "wallpaper": true, ... }
```

`config: false` makes the whole step skip itself. `wallpaper: false` suppresses
the `appearance.wallpaper` key during generation — because a release that does not
understand the key would not serve it back, and the read-back comparison would
fail on a difference that is really a version mismatch. The flags exist so the two
repositories can move independently without lying to each other.

The release itself is pinned like every other app in the catalog: `release_tag`
plus a pinned signer certificate, checked against the binary by `make apks`. See
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
