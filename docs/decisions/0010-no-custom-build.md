# 0010 — No custom OS build to lift the three-profile limit

**Status:** accepted (2026-09-14)

## Context

The sharpest constraint in the model is that only three users run at once, and it
forces the slot discipline in [0003](0003-cloud-owns-the-third-slot.md). The value
behind it, `config_multiuserMaxRunningUsers`, is a build-time resource. We build
the emulator image from source anyway, so raising it is a one-line patch away.

## Decision

Do not patch it for real hardware. The distribution runs on stock GrapheneOS
releases.

## Consequences

- Verified Boot keeps GrapheneOS's own keys, official OTAs keep working, and there
  is no update server to run and no build to maintain for every upstream release.
  That is a permanent cost avoided, on a device used daily.
- The slot discipline stays, with the fragile toggle it depends on.
- The patch can still be tried on the emulator, where a custom build costs
  nothing — as a measurement, not as a plan.
- If this is ever reopened, the question is not "does the patch work" but "who
  keeps a signed build current for years".
