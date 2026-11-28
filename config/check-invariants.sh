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
#   4. A package appears in the catalog once.
#   5. An app that needs the private tailnet sits only in zones whose one
#      VPN slot is Tailscale (docs/architecture/zones.md).
#   6. A zone that names a browser has that browser placed in it. Anon's links
#      open in Tor Browser only because Tor Browser is there; take it out and
#      they land in Vanadium, outside Tor, without a word.
#   7. At most one app carries "role": "updater", its source is one the lock
#      covers, and it is placed in every zone (but a managed profile) that
#      holds an app it is to keep current. Two would be named as installer by
#      turns; one with no lock entry could never be installed from the lock;
#      a zone without it keeps its apps on whatever the last provisioning
#      run left - while Obtainium's import, emptied for the updater, no
#      longer offers them either.
#   8. An app's `upstream` names the same repository its lock entry downloads
#      from. GitHub serves a renamed or transferred repository through a 301
#      for as long as it pleases, so a catalog pointing at a dead name keeps
#      working - fetch.sh and gen-obtainium.sh both follow the redirect - until
#      the day it stops, and then nothing says why. The lock already records
#      where the bytes really came from, because refresh-lock.sh wrote down the
#      URL the API answered with. Comparing the two needs no network and names
#      the live repository for free. It found both of its first two cases:
#      Helium314/HeliBoard -> HeliBorg/HeliBoard, and, unnoticed until the rule
#      existed, Governikus/AusweisApp2 -> Governikus/AusweisApp.
#      The key is host + owner + name, lower-cased: without the host a GitHub
#      upstream would match a Codeberg download of the same name, and without
#      the lower-casing a repository spelled in a different case would be
#      reported as a move when both forges treat it as one repository.
#
# 4-6 lived inline in the Makefile, where `andashi app rm` could not reach
# them: removing Tor Browser from Anon passed every check the command ran.
# One file now serves both.
#
# Cases: check-invariants.test.sh, one per rule that must fail.
set -euo pipefail
cd "$(dirname "$0")"
: "${CONFIG_DIR:=$PWD}"
P="$CONFIG_DIR/profiles.json"; A="$CONFIG_DIR/apps.json"
# The lock is the repository's, not the catalog copy's: CONFIG_DIR may be a
# temporary tree (bin/andashi, the cases) with no apks/ beside it, while $PWD
# here is always the real config/ because of the cd above.
: "${LOCK_FILE:=$PWD/../apks/lock.json}"
[ -f "$P" ] && [ -f "$A" ] || { echo "check-invariants: profiles.json or apps.json missing in $CONFIG_DIR" >&2; exit 1; }
# Fail closed: a missing lock means rule 8 cannot be answered, which is not
# the same as it holding.
[ -f "$LOCK_FILE" ] || { echo "check-invariants: lock file missing: $LOCK_FILE" >&2; exit 1; }

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

# 4
dupes="$(jq -r '.apps[].pkg' "$A" | sort | uniq -d | tr '\n' ' ')"
[ -z "$dupes" ] || bad="${bad}packages in the catalog more than once: $dupes"$'\n'
# 5
unreachable="$(jq -r -n --slurpfile a "$A" --slurpfile p "$P" '
  ($p[0].profiles | INDEX(.key)) as $z | $a[0].apps[] | select(.needs? == "tailnet") | . as $app
  | (.profiles // [])[] | . as $k | ($z[$k].vpn // "") as $vpn
  | select(($vpn | startswith("tailscale")) | not)
  | "  \($app.label) is in \($k), whose VPN slot is \($vpn)"')"
[ -z "$unreachable" ] || bad="${bad}apps that need the private tailnet, in zones that cannot reach it:"$'\n'"$unreachable"$'\n'"  a zone has ONE always-on VPN slot - see docs/architecture/zones.md"$'\n'
# 6
stray="$(jq -r -n --slurpfile a "$A" --slurpfile p "$P" '
  $p[0].profiles[] | select(.browser) | . as $z
  | select([ $a[0].apps[] | select(.pkg == $z.browser) | (.profiles // [])[] | select(. == $z.key) ] | length == 0)
  | "  \($z.label): browser \($z.browser) is not placed in this zone"')"
[ -z "$stray" ] || bad="${bad}zone browsers the catalog does not install there:"$'\n'"$stray"$'\n'

# 7
updater="$(jq -r -n --slurpfile a "$A" --slurpfile p "$P" '
  def covered: . == "obtainium" or . == "fdroid" or . == "torproject" or . == "direct";
  [ $a[0].apps[] | select(.role == "updater") ] as $u
  | if ($u | length) == 0 then empty
    elif ($u | length) > 1 then "  more than one app with role updater: \([$u[].pkg] | join(", "))"
    else $u[0] as $up
      | (if ($up.source | covered) then empty else "  the updater \($up.pkg) has source \($up.source), which the lock does not cover" end),
        ( [ $p[0].profiles[] | select((.type // "") != "managed") | .key ] as $zones
          | $zones[] as $z
          | select(($up.profiles // []) | index($z) | not)
          | [ $a[0].apps[] | select(.pkg != $up.pkg) | select(.source | covered) | select((.profiles // []) | index($z)) | .label ] as $need
          | select($need | length > 0)
          | "  \($z) holds \($need | join(", ")) but not the updater \($up.pkg)" )
    end')"
[ -z "$updater" ] || bad="${bad}the updater does not cover the catalog:"$'
'"$updater"$'
'

# 8
moved="$(jq -r -n --slurpfile a "$A" --slurpfile l "$LOCK_FILE" '
  # The key carries the forge HOST as well as owner/name: the same owner and
  # name exist on both forges (comaps/comaps is on Codeberg), and without the
  # host a GitHub upstream would compare equal to a Codeberg download.
  # Lower-cased because GitHub and Codeberg both treat owner and repository
  # as case-insensitive, so heliborg/heliboard and HeliBorg/HeliBoard are one
  # repository and must not be reported as two.
  def key: capture("https://(?<h>github[.]com|codeberg[.]org)/(?<o>[^/]+)/(?<r>[^/?#]+)")
           | "\(.h)/\(.o)/\(.r)" | ascii_downcase;
  ($l[0].entries | INDEX(.pkg)) as $lock
  | $a[0].apps[] | select(.source == "obtainium") | select((.upstream // "") != "")
  | . as $app | (.upstream | key? // empty) as $want
  | ($lock[$app.pkg].urls // []) | map(key? // empty) | select(length > 0) as $have
  | select($have | index($want) | not)
  | "  \($app.label): catalog says \($want), the lock downloads from \($have | unique | join(", "))"')"
[ -z "$moved" ] || bad="${bad}upstreams the lock disagrees with (a repository that moved):"$'\n'"$moved"$'\n'"  GitHub redirects a renamed repository until it does not - name the live one"$'\n'

if [ -n "$bad" ]; then printf '%s' "$bad" >&2; exit 1; fi
echo "ok: catalog invariants (Play-free zones, one always-on zone, net: false, unique packages, tailnet, zone browsers, updater, live upstreams)"
