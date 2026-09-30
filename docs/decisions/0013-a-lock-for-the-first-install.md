# 0013 — A lock for the first install

**Status:** accepted (2026-09-30)

## Context

Provisioning installs the APKs it finds in `apks/`, and until now the only way
to fill `apks/` was `apks/fetch.sh`: ask some forty upstreams for their latest
release, download it, read its package name with `aapt2`, read its signer with
`apksigner`, check Tor Browser's detached signature with `gpg`, and pin a signer
seen for the first time. That puts the Android build tools, a JDK and gpg on
every machine that wants to set up a phone, and it makes every person repeat -
at whatever moment they happen to run it - a trust decision that could be made
once. Two people provisioning on the same day could still install different
builds.

## Decision

`apks/lock.json` records, for every APK a phone gets, where to download exactly
those bytes and what they hash to. The maintainer writes it after `fetch.sh`
and `verify.sh` (`make lock`); everybody else downloads from it
(`make from-lock`), comparing SHA-256 and nothing else. `make check` refuses a
lock that no longer describes the inventory, so a `fetch.sh` without a new
lock fails in CI, not on somebody's first install.

Every URL in the lock is proven, not guessed: by the digest GitHub publishes, or
by downloading and hashing. Entries from upstreams that delete old builds carry
the archive URL as well (`archive.torproject.org`, `f-droid.org/archive`) -
the Tor Browser in the first lock was already gone from `dist.torproject.org`
the day it was written.

The lock names URLs, not files. Nothing is redistributed from this project;
each person's machine downloads from the upstream, as `fetch.sh` always did.
Offering the APKs ourselves would make every release of every app something
this project conveys, with each licence's obligations attached.

## Consequences

- A person's machine needs `adb`, `curl`, `jq` and `sha256sum`. Measured on the
  Fold emulator from the `clean` snapshot, with `aapt2`, `apksigner`, `gpg` and
  `java` removed from `PATH`: the full chain converged in 200 s, and all 21
  installed apps were compared with the inventory through the `versionCode` the
  lock carries (`tests/e2e/lock.sh`).
- Two machines provisioning from the same lock install the same builds.
- **The price:** the first install is as current as the last lock. A fix Signal
  ships tomorrow reaches a new phone when somebody runs `fetch.sh`,
  `verify.sh` and `lock.sh` and commits the result. After the first install
  nothing changes: every zone keeps updating itself through Obtainium
  ([0012](0012-every-zone-updates-itself.md)). The lock decides what a phone
  starts from, not what it gets afterwards.
- A lock can rot: an upstream may delete even the archived build. `from-lock.sh`
  then says which app it could not get and that nothing else was touched; the
  answer is a new lock, not a fallback to "whatever is latest".
- The trust decision is now the maintainer's, made once per lock. That is the
  point - but it means a signer change is caught on one machine, the
  maintainer's, and nowhere else.
