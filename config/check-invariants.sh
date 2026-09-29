#!/usr/bin/env bash
# Rules that must hold whoever edits the catalog - a person, a pull from the
# phone, or an agent using `andashi app add`. Each one is a sentence the rest
# of this repository relies on and nothing else enforces:
#
#   1. A zone whose profiles.json entry says play: none holds no app from
#      sandboxed Play. Home and Anon are Play-free by decision, not by habit,
#      and one `app add` is enough to break that without a word.
#   2. Besides Home and its managed profile, at most one zone runs always.
#      Android runs three users at once; Home and Work are two of them, so a
#      second always-on zone evicts the first every time it starts
#      (docs/decisions/0003-cloud-owns-the-third-slot.md).
#   3. An app declared net: false is never granted INTERNET through perms.
#      The zone model's strongest claim is a missing permission, and a grant
#      in the same entry would quietly undo it.
#
# Cases: check-invariants.test.sh, one per rule that must fail.
set -euo pipefail
cd "$(dirname "$0")"
: "${CONFIG_DIR:=$PWD}"
P="$CONFIG_DIR/profiles.json"; A="$CONFIG_DIR/apps.json"
[ -f "$P" ] && [ -f "$A" ] || { echo "check-invariants: profiles.json or apps.json missing in $CONFIG_DIR" >&2; exit 1; }

bad=""
# 1
play="$(jq -r -n --slurpfile p "$P" --slurpfile a "$A" '
  $p[0].profiles[] | select((.play // "") == "none") | .key as $z
  | $a[0].apps[] | select(.source == "play-sandboxed") | select((.profiles // []) | index($z))
  | "  \(.label) is in \($z), which has no Play"')"
[ -z "$play" ] || bad="${bad}sandboxed-Play apps in a Play-free zone:"$'\n'"$play"$'\n'
# 2
always="$(jq -r '[.profiles[] | select(.runtime == "always") | select(.create != false)
                  | select((.type // "") != "managed") | .key] | select(length > 1) | join(", ")' "$P")"
[ -z "$always" ] || bad="${bad}more than one zone besides Home runs always: $always"$'\n'"  Android runs three users; Home and Work hold two (decision 0003)"$'\n'
# 3
net="$(jq -r '.apps[] | select(.net == false)
              | select((.perms.grant // []) | index("android.permission.INTERNET"))
              | "  \(.label) is net: false and grants INTERNET"' "$A")"
[ -z "$net" ] || bad="${bad}net: false undone by a grant:"$'\n'"$net"$'\n'

if [ -n "$bad" ]; then printf '%s' "$bad" >&2; exit 1; fi
echo "ok: catalog invariants (Play-free zones, one always-on zone, net: false)"
