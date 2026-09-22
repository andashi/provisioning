# 0009 — A run counts only from the clean snapshot

**Status:** accepted (2026-09-19)

## Context

For a long time every run looked greener than it was, because every run happened on
a device where the failures had already been repaired by hand: the app was
installed, the wizard dismissed, the wallpaper set. Five defects hid behind that
for days, including a step that read a marker file on the *host* and therefore
claimed work was done that a device reset had undone.

It got worse before it got better: `emulator/run.sh start` passed two flags the
emulator silently refuses to honour together, so a run started "from clean" was in
fact a cold boot from whatever the overlay disk happened to hold.

## Decision

A full chain run only counts as verification when it starts from the `clean`
snapshot — first boot of the build, Owner only, nothing provisioned — and the
starting state is confirmed before the chain begins, not assumed.

This applies to that claim and no further. `profiles-ready` (clean plus
`00-profiles.sh`) is the everyday base, and a run from it is a *smaller* claim, not
a weaker one: it is script-produced rather than hand-repaired, so it says
everything about the chain downstream of profile creation and nothing about the
chain before it.

## Consequences

- Green means green. A verification run that cannot name its starting snapshot is
  not a verification run.
- **One instance per session does not replace this.** Separate instances stop two
  sessions from colliding on one device; they do nothing about what an earlier run
  left behind inside the same instance. Both problems were real, and they need
  different remedies — the device lock for one, a named starting snapshot for the
  other.
- Every step has to work on a device where nothing has been prepared — which is
  what exposed the ordering assumption in `00-profiles.sh` and the missing retry
  after `am start-user`.
- Snapshots are per instance and cost disk (~3.5 GB of RAM state each), and a
  changed `config/profiles.json` means `profiles-ready` has to be refreshed.
- Parallel sessions must not share an instance, hence the advisory device lock.
  It only works because everyone checks it first.
