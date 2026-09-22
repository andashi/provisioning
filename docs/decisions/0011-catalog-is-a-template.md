# 0011 — The catalog is a template, the real one lives outside

**Status:** accepted (2026-09-21)

## Context

`config/apps.json` was one person's device inventory. It named a car, a household
appliance brand, an audio system, a 3D printer, a fitness machine and an
employer's expense tool. As long as the repository was private that was merely
untidy. It went public on 2026-09-21, and for the few hours it was readable the
catalog was a precise personal profile: what its owner drives, what stands in his
kitchen, who he works for.

The second problem is older and bigger. A distribution that only runs for its
author is not a distribution. Anyone else cloning this repository would have got a
phone provisioned with someone else's life.

## Decision

`config/` in this repository is a **template**. An app earns a place in it by
demonstrating a mechanism, not by being in someone's life: Signal for a GitHub
release with a published fingerprint, Bitwarden for a vendor's own F-Droid repo,
CoMaps for Codeberg, Open Camera for F-Droid and its signer trade-off, Tor Browser
for an upstream GPG signature, ChatterUI for the arm64-only case that cannot
install on the emulator at all.

The real catalog lives outside the repository and is selected with `CONFIG_DIR`,
which `lib/common.sh` had documented for the chain all along. Since 12e2714 the
generators honour it too, and write their output next to the catalog they derive
from.

Products are still named where the name carries the technical point. Gadgets keeps
two vendor apps, because the zone is hardened the way it is *because of* apps from
manufacturers nobody wants on their home network — a template that shows the
filtering but not what it filters explains nothing. The work zone keeps the
Microsoft stack and gains a Google Workspace branch behind a switch, because a
managed profile with an employer's agent in it is the architecture's central
claim, and a claim with one example looks like a special case.

## Consequences

- Two catalogs to maintain. The template drifts from reality unless someone keeps
  it honest, and nothing enforces that.
- The template has to stay rich enough to demonstrate every mechanism. Deleting
  "one more app that is just an example" is how it stops teaching anything.
- The chain and the generators now agree on which catalog applies, structurally
  rather than by assumption. That mattered most at the launcher config, where
  `45-launcher-config.sh` verifies by read-back and would have confirmed a file
  generated from the wrong catalog.
- **Open:** the binary inventory is not separated. `fetch.sh` pins signers into
  `apks/certs/` and writes `apks/SHA256SUMS`, both tracked, so fetching a private
  app publishes its name through its trust files. `APKS_DIR` is overridable for
  reading only.
- The commit history still contains the thirteen removed entries. Whoever
  publishes this repository again should start from a fresh history rather than
  rewrite this one, as it was done once before.
