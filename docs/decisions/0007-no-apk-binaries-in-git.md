# 0007 — No APK binaries in git, pin hashes and signers

**Status:** accepted (2026-09)

## Context

Provisioning installs about fifty apps, most of them fetched from upstream release
pages. Two risks come with that: the repository turns into hundreds of megabytes of
binaries that git will carry forever, and an upstream account takeover or a
substituted release goes unnoticed because nobody compares what actually arrived.

## Decision

APK binaries are ignored. Two things are checked in and they are the trust anchor:

```
apks/SHA256SUMS              one hash per APK
apks/certs/<package>.cert    pinned SHA-256 fingerprint of the signer certificate
```

Adding an app means downloading from the upstream's own release page, pinning it
with `apks/pin.sh`, and committing hash and certificate. `apks/verify.sh` compares
binaries against those pins, so it runs locally (`make apks`) — CI has no binaries
and can only check that the pins and the catalog still describe the same apps.
A release that matters is pinned by tag (`release_tag`) rather than followed as
"latest".

## Consequences

- A changed signer is a failed build, not a surprise on a phone.
- The repository stays small enough to read; the binaries are reproducible from
  `fetch.sh`.
- Pinning is work per app, and a pinned tag has to be bumped deliberately. For our
  own launcher that is a feature: the bump is the moment to re-verify.
- A missing APK degrades gracefully — the app lands in the generated `MANUAL.md`
  by name instead of failing an install.
