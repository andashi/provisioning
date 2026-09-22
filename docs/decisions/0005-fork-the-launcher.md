# 0005 — Fork the launcher instead of automating its UI

**Status:** accepted (2026-09-19)

## Context

A launcher keeps its preferences in `/data/user/N/<pkg>`, owned by the app's own
uid. Nothing on the host can read that, so the home screens were configured by
driving the settings UI with uiautomator: 688 lines of script, about 27 minutes per
run, an unlocked screen required in every zone, and no way to read back a single
value.

That layer produced its own class of bugs — a step would report a setting as
applied while the screen showed something else, because the script could type but
never verify. It was also the last part of the chain that needed a human-visible
screen, which kept a full run from being unattended.

Two other launchers were evaluated. Neither exposes a configuration interface; both
would have needed the same UI automation.

## Decision

Maintain a fork, [Andashi Home](https://github.com/andashi/home), whose only
required addition is a machine interface: a shell-gated ingest provider for a
config file, a reload broadcast, and a state provider that serves the effective
configuration back for verification. Drop the other launchers from the catalog
entirely, so no path exists that needs UI automation.

The contract is [../architecture/launcher.md](../architecture/launcher.md).

## Consequences

- The home screen became convergent state: push, reload, verify by read-back.
- A full chain run went from about 41 minutes to about 9, and needs no screen at
  all.
- **We now maintain a launcher.** Self-signing is accepted; upstream contribution
  is secondary and, given the licence, not free of friction.
- Two repositories must stay compatible. That is handled by capability flags in
  `theming.json` and a pinned release rather than by hope — see
  [0007](0007-no-apk-binaries-in-git.md).
- Anything the launcher cannot yet report back is a reason to change the launcher,
  not to accept a blind write.
