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
- **`source`** says how the binary is obtained, and it is also a statement about
  what can be automated: of 50 entries, 22 come from Obtainium and GitHub
  releases, 22 need sandboxed Play and a Google login (manual by design), the rest
  from Accrescent, F-Droid, the GrapheneOS store, or the system image.
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

Two files are generated from the catalog and checked in, with `make check`
enforcing that they are in sync:

- **`config/obtainium.json`** — an import file for Obtainium, so the apps that
  update themselves are set up in one import per profile rather than app by app.
- **`config/launcher/<zone>.json`** — the home screen per zone, which also
  resolves favorites against this catalog. See [launcher.md](launcher.md).

Everything the catalog cannot install ends up in the generated `MANUAL.md`, by
name, from the queue that `10-apps.sh` writes during the run — so the list
describes the run that actually happened, not a guess made in advance.
