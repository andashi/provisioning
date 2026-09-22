# 0012 — Every zone updates itself, and the launcher is not pinned

**Status:** accepted (2026-09-21), see [provisioning#5](https://github.com/andashi/provisioning/issues/5)

## Context

Obtainium lived in Home and Ops. Four zones had no update client at all, which
sounded worse than it was: an APK is installed once per device, so a zone that
updates a package updates it for every zone that has it. Measured against the
catalog, exactly three apps of forty lived *only* in zones without an updater —
RethinkDNS in Cloud, Gadgets and Work, Orbot and Molly in Anon.

Three apps, and they are the wrong three to leave stale: a DNS filter, a Tor
client and a messenger.

The launcher carried `release_tag: v0.3.0`. The pin existed because the launcher
is the one app whose machine interface this chain depends on — `45-launcher-config.sh`
pushes a config and verifies the read-back, and a release can change that contract.
0.3.0 did exactly that: the clock keys disappeared and `home.dock.enabled` became
inert.

## Decision

Obtainium goes into **all six zones**, and it comes from the project's own GitHub
release rather than Accrescent — a zone with no store had no way to bootstrap its
own updater.

**Accrescent follows, into all six zones as well** (2026-09-22). The first version
of this decision kept it in Home and Ops, on the argument that a second store
client buys little when both channels carry the same signer and Android enforces
continuity anyway. That argument answered the wrong question. It was about
updating; the requirement is *installing*, interactively, standing in a zone,
without the host and without waiting for the next run. The chain can put any
already-installed package into a zone with `pm install-existing`, so it covers
everything the catalog declares — and nothing a person decides on the spot. Its
client now comes from the project's GitHub release too, which is what
accrescent.app links to for bootstrapping.

The launcher **loses its pin**. `release_tag` stays in the mechanism for holding a
version deliberately, while debugging or to sit out a bad release.

Updating alone would not have justified six zones; two would have closed the gap.
Installing did: adding an app to a zone can only happen from inside that zone, and
a phone where four zones can never gain an app is not finished, it is stuck.

## Consequences

- Two permissions per zone, twice over now that Accrescent joins Obtainium:
  `INTERNET`, and permission to install packages — the latter in Anon, the zone
  whose whole purpose is distrust. Two installers per zone is the price of being
  able to install anything anywhere without a cable, and it was paid knowingly.
- **Version control in those zones is given up.** The inventory report at the end
  of `10-apps.sh` names the drift instead of preventing it.
- **Signer control is not given up.** Android enforces signature continuity: an
  update installs only if it carries the same signer as what is already there. The
  first install still comes from the host against a pinned signer with a provenance
  record behind it, and Obtainium cannot slip a differently-signed build past that.
  This is the reason the decision is defensible at all.
- A release now reaches the phones by itself. 0.3.0 alone closed eight security
  issues; holding them back to protect a config key from going quiet was the wrong
  trade. The contract is defended by
  [andashi/home#47](https://github.com/andashi/home/issues/47) instead, where the
  build reports which keys it still serves.
- **Untested:** Obtainium in Anon reaches GitHub through Orbot. Tor is slow and
  sometimes blocked. Nobody should claim that zone updates itself until someone
  has watched it do so — it is on the list for the first hardware run.
- Molly and Orbot are also distributed through Accrescent, with a server-side
  pinned developer key rather than trust in a release page. For the two apps that
  matter in Anon that would be the better source, and it would need the same
  bootstrap that Obtainium just got. Not decided.
