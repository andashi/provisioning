# 0006 — The launcher owns the wallpaper

**Status:** accepted (2026-09-19), supersedes the helper APK of 2026-09-14

## Context

Setting a wallpaper per profile is not scriptable from the shell: the adb shell
only sees user 0's storage, and `WallpaperManager` is not reachable from a shell
command. The first answer was a small helper APK of our own, installed into every
zone, which accepted an image through a content provider and applied it.

It worked, and it cost: a second app to build, sign, pin and install everywhere,
for one property. Once the launcher had a config interface anyway
([0005](0005-fork-the-launcher.md)), the helper was a duplicate of a mechanism
that already existed.

## Decision

The wallpaper is part of the launcher's configuration. Provisioning uploads the
image through the same ingest provider and names it in `launcher.json`; the
launcher applies it on reload and reports it back. The helper APK, its signing key,
its catalog entry and the wallpaper block in `40-theming.sh` are deleted.

## Consequences

- One mechanism instead of two, and the wallpaper is verified like everything else.
- A platform behaviour became our problem: `WallpaperManagerService` computes the
  crop only for the **current** user. A wallpaper set for a background profile is
  recorded but never rendered — and an implementation that compares ids reports
  success for a screen that is black. The launcher re-applies on its first
  foreground resume and exposes a diagnostic for the pending case.
- Wallpaper support is therefore version-coupled. The `wallpaper: true` flag in
  `theming.json` gates whether the key is emitted at all, so an older release does
  not fail the read-back on a key it never understood.
