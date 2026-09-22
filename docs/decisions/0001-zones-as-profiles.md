# 0001 — Six profiles as network zones

**Status:** accepted (2026-09-14)

## Context

A phone carries private life, a company's data, household devices, administrative
access and anonymous browsing on one piece of hardware. Android offers per-app
permissions, work profiles and Private Space, but each of those answers "what may
this app do?" — never "what else can this app reach if it turns out to be
hostile?".

Network engineering answered that question decades ago with segments. GrapheneOS
gives the primitives: up to 32 user profiles, encrypted at rest, one VPN slot each,
and a per-app INTERNET permission that can actually be revoked.

## Decision

Model the phone as a segmented network. Each profile is a zone with a declared
purpose, its own VPN, its own app set and its own color. Apps are placed by the
question "which zone may this damage?" rather than "do I want this app?".

The model lives in `config/profiles.json` and is applied, not described.

## Consequences

- The boundaries are enforced by the platform, not by discipline. One VPN per
  user means Tailscale and a filtering VPN can never collide.
- Switching zones costs a deliberate action, and only three zones can run at once
  (see [0003](0003-cloud-owns-the-third-slot.md)). That friction is the point, but
  it is real friction.
- A stopped zone has its keys evicted — data survives, but is sealed.
- Everything about the model that cannot be scripted becomes visible, because the
  declaration is the source of truth and the gap shows up as a manual item.
