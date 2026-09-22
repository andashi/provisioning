# 0008 — PINs, background operation and notification forwarding stay manual

**Status:** accepted (2026-09-17)

## Context

Three properties resisted automation, and each was at some point claimed as
automated before it was actually verified:

- **Profile PINs.** `locksettings set-password --user N` exists, is unreliable for
  secondary profiles, and would write credentials into the shell history.
- **"Run in background".** Not a setting but the UserManager restriction
  `no_run_in_background`, writable only by a device or profile owner. GrapheneOS
  ships secondary users with it already set; the Settings toggle clears it, and
  whether a profile owner may clear a system base restriction is unverified.
- **Notification forwarding.** `send_censored_notifications_to_current_user` can
  be neither read nor written over adb — on any profile, adb root included.

The last one had been documented as automated. It was not. That is the reason this
decision exists as a decision rather than as a footnote.

## Decision

These three stay manual and are written into the generated `MANUAL.md`
by `90-manual.sh`. They are not retried, not worked around with a device owner, and
not advertised as automated.

## Consequences

- The chain finishes unattended, and what it cannot do is stated plainly instead of
  silently skipped.
- The most fragile rule in the whole model — exactly one background secondary
  profile ([0003](0003-cloud-owns-the-third-slot.md)) — depends on a human doing it
  right and nothing verifying it afterwards.
- That gap is the strongest argument for a permissionless on-device companion that
  *checks* the end state, which is the one app shape
  [0004](0004-adb-from-a-host.md) keeps open.
- If a future claim of automation appears here, it needs a read-back that proves
  it, not a successful-looking command.
