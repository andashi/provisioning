#!/usr/bin/env bash
# A tripwire, not a prohibition: it fires the first time a zone declares a real
# AppWidget instead of the launcher's built-in favorites widget.
#
# Why that moment matters. On Andashi Home 0.9.0 a grid item whose widget
# provider is missing is reported ONCE - the first reload of that file says
# `unknown-widget-provider`, and every reload afterwards says nothing, because
# the stored layout already matches the file and the provider is never looked
# up again (their DefaultConfigStore.kt:275 with ConfigDiffer.kt:338). So a
# re-run, or the same file on a second device, comes back clean for a widget
# that is not there - and this chain's whole claim is that a converged run
# means the screen matches the file.
#
# It cannot happen while every item is the built-in `favorites` const, which is
# why the launcher side left the fix (andashi/home#219) in the ordinary queue
# on our evidence. The exposure arrives with the feature: `--pull` copies the
# grid block verbatim, so the first pull from a device where somebody added an
# AppWidget puts a provider component into theming.json.
#
# When this fires, the question is not "how do I silence it" but: has #219
# shipped in the release we install? If yes, delete this check and say so in
# the commit. If no, the config is fine and the verification is weaker than it
# looks - which is worth knowing before the run that proves nothing.
set -euo pipefail
cd "$(dirname "$0")"
: "${CONFIG_DIR:=$PWD}"
: "${OUT_DIR:=$CONFIG_DIR/launcher}"

found=""
for f in "$OUT_DIR"/*.json; do
  [ -e "$f" ] || continue
  zone="$(basename "$f" .json)"
  while read -r w; do
    [ -n "$w" ] || continue
    found="$found  $zone: $w"$'\n'
  done < <(jq -r '[.home.grid.layouts[]?.items[]? | select(.widget != "favorites") | .widget] | unique[]' "$f")
done

if [ -n "$found" ]; then
  echo "a zone declares an AppWidget provider, not the built-in favorites widget:" >&2
  printf '%s' "$found" >&2
  echo "  On 0.9.0 a missing provider is reported only on the FIRST reload, so a" >&2
  echo "  re-run or a second device reports success for a widget that is absent." >&2
  echo "  Check whether andashi/home#219 is in the release we install; if it is," >&2
  echo "  this check has done its job and can go." >&2
  exit 1
fi
echo "ok: no AppWidget providers declared (see check-appwidgets.sh)"
