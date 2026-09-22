# 0004 — The privileged core runs over adb from a host

**Status:** accepted (2026-09-16)

## Context

The obvious wish is an app: install one thing, tap through a wizard, done — no
computer, no cable, no shell. The question deserved a real answer rather than a
shrug, so every provisioning step was mapped onto the privilege tier it needs.

Creating users, installing into another user, revoking INTERNET, setting appops,
writing secure settings and assigning the HOME role are all `signature` or
`signature|privileged` permissions. A normal app holds none of them. Shizuku would
work — it *is* the shell tier — but its server must still be armed by ADB, does not
survive a reboot, and grants a broad shell bridge to whatever the user approves. A
device owner reaches furthest and makes the device managed.

## Decision

Ship the privileged core as this repository plus adb. No setup APK, no Shizuku in
the happy path, no device owner. Where a capability needs a device or profile
owner, it stays manual instead.

The full table and the reasoning are in
[../architecture/boundaries.md](../architecture/boundaries.md).

## Consequences

- Setup needs a computer and a cable, or wireless debugging over the tailnet.
- Nothing about the device becomes managed; every change stays reversible without
  a factory reset.
- The logic exists once, as nine bash steps, instead of twice.
- **The bottleneck is not adb.** Even a perfect on-device provisioner leaves the
  manual block untouched, because no privilege tier automates a Google login. The
  useful companion app is therefore a permissionless checklist that deep-links
  into settings and verifies the end state — not a provisioner.
