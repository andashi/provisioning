# App catalog and trust

[`config/apps.json`](../../config/apps.json) declares which app belongs in which
zone, what it may do there, and where it comes from. It is the second half of the
zone model: [zones.md](zones.md) says what a zone is for, the catalog says what
lives in it.

## An entry

```json
{
  "id": "andashi-home",
  "label": "Andashi Home",
  "pkg": "org.andashi.home",
  "pkg_status": "verified",
  "source": "obtainium",
  "upstream": "https://github.com/andashi/home",
  "release_tag": "v0.2.1",
  "profiles": ["home", "cloud", "gadgets", "ops", "lab", "anon"],
  "net": false,
  "perms": { "grant": [], "revoke": [], "appops": {} },
  "scopes": {},
  "notes": "…"
}
```

- **`profiles`** places the app in zones. This is the declaration the whole model
  rests on: an app exists in a zone or it does not.
- **`net: false`** revokes `android.permission.INTERNET` — the GrapheneOS network
  toggle, applied by `20-permissions.sh`. It is the sharpest tool in the catalog
  and the reason a launcher, a keyboard or a note app can be installed without
  granting it a network at all.
- **`appwidget_bind: true`** gives the app the bind-widget grant in every zone it
  lives in (`appwidget grantbind`, applied and read back by `20-permissions.sh`).
  It is what "always allow" in the system's bind dialog records — per package, per
  Android user, dropped on uninstall — so the widgets a zone's `home.grid` declares
  appear without asking. Only the launcher carries it. Without it nothing breaks:
  each widget cell offers an Allow action instead.
- **`source`** says how the binary is obtained, and it is also a statement about
  what can be automated: of 50 entries, 22 come from Obtainium and GitHub
  releases, 22 need sandboxed Play and a Google login (manual by design), the rest
  from Accrescent, F-Droid, the GrapheneOS store, or the system image.
- **`role: "updater"`** marks the one app that keeps the others current: the
  [andashi updater](https://github.com/andashi/updater). With such an entry,
  `10-apps.sh` installs it before any other app and into every zone it is placed
  in, makes it its own installer of record, puts it on the device-idle allowlist,
  and allows it to install and to notify in each zone — every one of those read
  back. Every app with a source the lock covers (`obtainium`, `fdroid`,
  `torproject`, `direct`) is then installed with `-i <updater>`, and one that
  runs the right build under another installer (installed before the updater
  existed, by hand, or by an adb install that named nobody) is installed again,
  same build, naming the updater. Without the entry nothing of this happens and
  apps are installed as before. See [lib/updater.sh](../../lib/updater.sh) for
  what was measured, and why every install names a user: `adb install` without
  `--user` installs for every user on the device, a replace included.
- **`pkg_status`** marks package names that have not yet been checked against a
  real APK; `provision/05-verify-catalog.sh` verifies them with aapt2 and can
  correct them.

## No binaries in git

Only two things are checked in, and together they are the trust anchor:

```
apks/SHA256SUMS                 one hash per APK
apks/certs/<package>.cert       pinned SHA-256 fingerprint of the signer certificate
```

The APKs themselves are ignored. A changed signer — a repository takeover, a
slipped-in release — shows up as a mismatch the next time the binary is fetched
and checked, without the repository carrying hundreds of megabytes.

Adding an app means: download from the upstream's own release page (not a mirror),
check the origin, `apks/pin.sh <file>`, commit `certs/` and `SHA256SUMS`.

**Where that check runs matters.** `apks/verify.sh` compares the binaries against
the pins, so it only works where the binaries are: locally, via `make apks`,
before a pin is committed. In CI there are no binaries, and `verify.sh` exits 0
with a warning when it finds none — a green light for work not done. CI therefore
checks the invariant it actually can: that every pinned certificate and every
hashed file still corresponds to an app in the catalog.

That split was wrong here for a while. The workflow file had a YAML error that
made it unparseable, so it never ran at all — and because the repository had no
remote until 2026-09-20, nothing ever said so.

**Pinning a release.** `fetch.sh` normally follows `/releases/latest`.
`release_tag` overrides it, for two reasons: a release we ship deliberately (the
launcher — bump the tag on purpose, and the signer check still applies), and
upstreams whose `latest` is useless, for example when every release is marked
prerelease and `latest` returns something years old with a different package name.
Switching versions means touching the tag and nothing else.

## One inventory, two architectures

```
apks/universal/   runs on both                (the majority)
apks/arm64-v8a/   the Fold only
apks/x86_64/      the emulator only
```

`fetch.sh` inspects the `lib/<abi>/` directories inside a downloaded APK and files
it accordingly; an APK containing both architectures is kept once, as universal.

`apk_for_pkg` in `lib/common.sh` reads the connected device's ABI
(`ro.product.cpu.abi`) and searches `apks/<device-abi>/`, then `apks/universal/`,
then the flat legacy directory. Nothing has to be configured: arm64 on the Fold,
x86_64 on the emulator. `APK_ABI` overrides the detection deliberately.

An app that ships only one architecture simply is not found on the other — it then
lands in `MANUAL.md` instead of producing a failing install. That is not a defect
in the catalog; the app runs fine on the device it was built for.

## Generated from the same source

Three sets of files are generated from the catalog and checked in, with `make check`
enforcing that they are in sync:

- **`config/obtainium.json`** — an import file for Obtainium, so the apps that
  update themselves are set up in one import per profile rather than app by app.
- **`config/launcher/<zone>.json`** — the home screen per zone, which also
  resolves favorites against this catalog. See [launcher.md](launcher.md).
- **`config/updater/<zone>.json`** — the andashi updater's config per zone
  (`config/gen-updater.sh`): every app of the zone whose source the lock covers
  (`obtainium`, `fdroid`, `torproject`, `direct`) with its pinned signer, the
  zone's `net: false` apps, and where the lock lives. A managed app without a pin
  fails generation: the updater could never verify it, and a config that names an
  app it cannot update would report work it will not do.

`config/distribution.json` says where this distribution's phones look for updates:
the lock URL and its heartbeat, and **`allowedHosts`**, the only hosts a phone may
fetch from. That list is a decision, not a summary of the lock. `make check`
(`config/check-hosts.sh`) refuses a lock with a URL on any other host — or over
http, or with a user or port in the address — so the daily lock refresh, which
commits without a person, can never widen where a phone connects. A new source
that needs a new host is a one-line pull request to that list. A fork points
`lock.url` at its own lock; nothing else needs to change.

Everything the catalog cannot install ends up in the generated `MANUAL.md`, by
name, from the queue that `10-apps.sh` writes during the run — so the list
describes the run that actually happened, not a guess made in advance.
