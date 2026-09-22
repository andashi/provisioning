# 0003 — Cloud is the only secondary profile that runs in the background

**Status:** accepted (2026-09-14)

## Context

GrapheneOS runs exactly three users at once, the owner included. The limit is the
build-time resource `config_multiuserMaxRunningUsers`; there is no runtime switch,
and the request to raise it was closed upstream.

When a fourth user starts, Android evicts whichever has been in the background
longest — silently. Measured on the emulator, starting Lab evicted Cloud, the one
zone that has to keep running.

## Decision

Slot 1 is Home and cannot be given away. **Slot 2 is Cloud**, the only secondary
zone with background operation enabled, because the car key and work notifications
live there. Slot 3 rotates on its own between Gadgets, Ops, Lab and Anon, each of
which stops when it is left.

## Consequences

- Cloud is never evicted, as long as the rule holds.
- **One wrong toggle breaks it.** Enabling background operation for a second
  secondary profile fills all three slots permanently, and the next profile switch
  kicks Cloud out — with no error message. You notice it standing in front of the
  car.
- The toggle cannot be set or checked by provisioning
  (see [0008](0008-some-things-stay-manual.md)), so this rule lives in the manual
  checklist and in people's heads. That is the weakest link in the model.
- Two zones can never be used in parallel. From a security standpoint that is a
  feature, not a loss.
