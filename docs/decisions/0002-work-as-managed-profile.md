# 0002 — Work as a managed profile under Home

**Status:** accepted (2026-09-16)

## Context

The work zone was originally planned as an ordinary secondary user, like every
other zone — it isolates best that way. One everyday requirement broke that plan:
an incoming customer call should show a name, and the contacts that carry those
names live in the company's account.

Android resolves contacts across a profile boundary at ring time only for
**managed** profiles (`InCallController` branches on `isManagedProfile`). A
secondary user would leave every business call showing a bare number, unless
company contacts were copied into the private zone — which is exactly what the
zone model exists to prevent.

## Decision

Work is a managed profile under Home, not a secondary user. Its profile owner is
Shelter (`net.typeblog.shelter`), a local open-source stand-in for an MDM that
manages nothing and exists so the profile is allowed to exist.

`00-profiles.sh` installs that one package from the catalog itself rather than
relying on `10-apps.sh` having run first, because on a fresh device it has not.

## Consequences

- Business calls show names; no company contact is copied into Home.
- **Work isolates more weakly than a secondary user.** It runs alongside its
  parent and the framework deliberately opens channels between them. This is
  acceptable only because those apps already hold all the company's data.
- Work does not consume one of the three running slots — profiles of the current
  user are started unconditionally.
- Only one managed profile exists per device, so this slot is spent. A second
  "work-like" container would have to be an ordinary zone.
- Whether MAM policies behave inside it is untested; that needs real hardware with
  sandboxed Play.
