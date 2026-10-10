# apks/

APK binaries are **not** checked in (see `.gitignore`). Only these land in git:

- `SHA256SUMS` — hash per APK
- `certs/<package-name>.cert` — pinned SHA-256 fingerprint of the signer certificate

That way a signer change (repo takeover, a slipped-in release) shows up the next time the
binary is fetched and checked, without bloating the repo.

## Flow for a new app

1. Download the APK **from the official source** (upstream's GitHub release, not a mirror).
2. Check the origin — release page, ideally a published fingerprint, otherwise AppVerifier
   on the device at first install.
3. Pin it: `./pin.sh signal-7.x.apk`
4. Commit `certs/` + `SHA256SUMS`.
5. `./verify.sh` — locally, where the binaries are. CI has none and only checks that the
   pins still match the catalog.

## Where a pin comes from

`certs/<pkg>.cert` is trust on first use: the first download defines the truth. That is
solid against a later takeover and worth nothing against a first download that was already
wrong. `./provenance.sh` asks other distributors whether they see the same signer and
writes `certs/PROVENANCE.tsv`.

Two kinds of witness, and the difference decides what a mismatch means:

| Kind | Who | A match says | A mismatch says |
|---|---|---|---|
| `upstream` | IzzyOnDroid, Guardian Project, a vendor's own F-Droid repo | the developer's own binary carries this signer - the pin is corroborated | alarm: someone ships a different binary under this package name |
| `rebuild` | f-droid.org | upstream and F-Droid agree, which only happens for reproducible builds - strong | nothing at all: F-Droid built from source and signed with its own key |
| `curated` | privacyguides/verified-apps | a third party inspected an APK from an official channel and saw the same certificate | they only looked at another channel - recorded, never an alarm |

Two rules keep the result honest:

- **A witness that is also our source proves nothing.** Open Camera and Shelter come from
  F-Droid, so "F-Droid agrees" compares the source with itself. Marked `=source`.
- **A fingerprint the vendor publishes outranks every repo.** Signal names its current
  certificate *and* the older 1024-bit one; the Guardian Project ships a Signal build
  signed with that older key. That is Signal's key, not a forgery, so it is recorded as
  `other-vendor-key` instead of raising an alarm. Vendor-published fingerprints live in
  the `PUBLISHED` map of the script, each with the page that states it.

State as of 2026-09-20: **21 of 23 pins corroborated**, two left.

`org.andashi.home` is our own build signed with our own key - it is on that list by
definition, and nobody else can corroborate it.

`com.governikus.ausweisapp2` is the one that deserves attention. It is the eID app, the
highest-value target in this catalog, and its pin still rests on a single download.
privacyguides/verified-apps does list the package, but the certificate it records
(`4cf98001…`) is F-Droid's rebuild, not the binary from Governikus' own GitHub release
that we install. Governikus publishes a GPG key for its Maven SDK artifacts and, as far as
this audit could find, no fingerprint for the APK signing certificate. Until that changes,
AppVerifier on the device at first install is the remaining check.

```bash
make provenance                 # all witnesses (downloads ~75 MB of indexes)
SKIP_FDROID=1 ./provenance.sh   # without the 60 MB main index
```

`make apks` does **not** run it. The audit needs the network and 75 MB of indexes; the
local check has to stay fast and offline, or people stop running it. What `verify.sh` does
instead is the part that can be answered locally: does `PROVENANCE.tsv` still describe the
pins that are actually here? A certificate pinned after the last audit, or one with no row
at all, is a trust anchor nobody has asked a second party about, and it says so:

```
! pinned after the last audit: com.example.app - run ./provenance.sh
```

That is a warning, not a failure - a stale snapshot does not make the inventory wrong.
`PROVENANCE_STRICT=1 make apks` turns both cases into a failure, for use as a release gate.

It exits non-zero when an upstream-signed witness disagrees and no vendor-published key
explains it. That case has not occurred yet; when it does, it is not a formality.

## File naming

`<package-name>-<version>.apk`, e.g. `org.thoughtcrime.securesms-7.21.2.apk`.
`provision/10-apps.sh` finds the APK via the prefix and takes the highest version via `sort -V`.

## ABI: emulator vs. device

`fetch.sh` prefers universal APKs, because they run on both architectures. Where those
don't exist, `APK_ABI` decides:

```bash
./fetch.sh                  # arm64-v8a (default) - the Pixel Fold
APK_ABI=x86_64 ./fetch.sh   # for the emulator
```

Apps that ship **exclusively** arm64 can't be installed in the x86_64 emulator —
`INSTALL_FAILED_NO_MATCHING_ABIS`. Observed with ChatterUI 0.9.0
(only `lib/arm64-v8a/`). That's not a bug in the catalog: the app runs fine on the device.
The emulator simply can't check this one install path.

## Tag pinning (`release_tag`)

`fetch.sh` normally pulls `/releases/latest`. Two reasons to pin instead: a release we
ship deliberately (Andashi Home, `"release_tag": "v0.1.0"`, bumped on purpose), and
upstreams that make `latest` useless (Lawnchair, while it was in the catalog, had marked
**everything** as prerelease since 2022; `latest` returned a 2019 APK with a different
package name, which the aapt2 check would have caught). fetch.sh then fetches exactly that
release. When switching versions, touch only the tag in the catalog, nothing else.

The tag decides what gets **installed**, not just what gets downloaded. It used to do only
the latter: `apk_for_pkg` took the highest version in the directory, so pinning the catalog
back to an older release after a regression downloaded that release and then installed the
newer one still lying around. Rolling back silently did not roll back. `--prune` leaves a
pinned version alone for the same reason - it is never "superseded".

## Housekeeping

Nothing ever deleted old versions: every APK stays, `SHA256SUMS` lists all of them, and Tor
Browser alone is ~106 MB per version and ABI.

```bash
./fetch.sh --prune              # keep the newest per app and ABI (and any pinned release)
```

Every run, with or without `--prune`, also warns about one state that pruning cannot fix:

```
! digital.ventral.ips: universal has 1.2, arm64-v8a has 1.1 - apk_for_pkg picks by directory, not by version
```

Both files are the newest in their own directory, so neither is superseded - but the
device-ABI directory is searched first, so the older copy wins on the device. That happens
when an app changes its packaging (ABI-specific to universal or back), and it needs a human
to delete the obsolete one.

## A vendor's own download directory: `source: direct`

Some vendors publish the Android APK nowhere `fetch.sh` has an API for. Yubico's GitHub
releases carry no APK; `developers.yubico.com` lists each one next to a detached GPG
signature. The catalog entry names the directory, the file name and the key:

```json
"source": "direct",
"download": {
  "index": "https://developers.yubico.com/yubioath-flutter/Releases/",
  "file": "yubico-authenticator-{version}-android.apk",
  "gpg": "20EE325B86A81BCBD3E56798F04367096FBA95E8"
}
```

`fetch.sh` takes the highest `{version}` the listing offers, downloads the file and
`<file>.sig`, and keeps the APK only if the signature verifies against `keys/<id>.asc` -
a committed key that must be exactly the key named in `gpg`, so a key file carrying a
second key is refused rather than trusted. A directory listing without a signature to
check is no source: the fields are all required. The APK's signer is then pinned like
any other (`certs/<pkg>.cert`), and `lock.sh` proves the vendor URL by its bytes.

The key in `keys/yubioath.asc` is on Yubico's published list of release signing keys
(`developers.yubico.com/Software_Projects/Software_Signing.html`). F-Droid also builds
the app, but signs it with its own key; the vendor's file carries Yubico's.

## What can NOT be automated

- **sandboxed Play** (the work stack behind `microsoft_365` or `google_workspace`, plus
  the vendor apps of your own devices in Gadgets) — needs
  Play Services in the profile and a Google login. Manual by design, see MANUAL.md.
- **Accrescent / GrapheneOS App Store** — bootstrap runs through the respective store app.

## Directory structure: one inventory for device AND emulator

```
apks/
  universal/    APKs that run on both architectures
  arm64-v8a/    only for the Fold
  x86_64/       only for the emulator
  certs/        pinned signer fingerprints, per package
  SHA256SUMS    across all subdirectories
```

How many files sit in each of them is a property of the machine, not of the
repository: the binaries are not in git (ADR 0007), so every checkout starts
empty and fills up with whatever `fetch.sh` has been asked for. `SHA256SUMS`
and `certs/` are the parts that are supposed to be the same everywhere.

`fetch.sh` reads the contained `lib/<abi>/` directories after the download and sorts it
in itself. An APK with arm64 **and** x86_64 counts as universal and is kept only once —
that covers the large majority and saves the duplicates.

`apk_for_pkg` in `lib/common.sh` determines the ABI of the connected device via
`getprop ro.product.cpu.abi` and searches in this order:

```
apks/<device-abi>/ → apks/universal/ → apks/ (flat legacy inventory)
```

That way nobody needs to set an environment variable anymore: arm64 applies on the Fold,
x86_64 on the emulator. `APK_ABI` overrides the detection if you deliberately want something else.

### When there's nothing for an architecture

Some apps ship only one variant — observed with ChatterUI, which builds exclusively for
arm64. Then `apk_for_pkg` finds nothing on the emulator and the app cleanly lands in
MANUAL.md, instead of attempting an install doomed to fail. That's not a bug in the
catalog: it runs fine on the device.
