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
# It guards TWO defects that fire on the same condition and have different
# answers, which is why the message asks two questions rather than giving one
# instruction.
#
#   1. The silence above is TEMPORARY. andashi/home#219 makes every reload
#      re-report a missing provider; it is merged and lands in an ordinary
#      release. When it is in the release we install, that half is answered.
#
#   2. The bind is PERMANENT, by their design and with our agreement. If the
#      provider resolves but Android refuses the bind, the grid records it and
#      the cell shows "could not load" - and the reload report stays silent,
#      because it is a CONFIGURATION report, not a capability one. It says what
#      the device is configured to do; binding is the grid's act. The same rule
#      keeps a missing permission and an uninstalled favorite's app out of it.
#      So no release fixes this, and "has it shipped" is the wrong question.
#      The right one is whether anything here proves a declared widget is on
#      the screen - and today nothing does. The chain grants the bind
#      permission per zone (20-permissions.sh, appwidget_bind), so a refusal
#      would be surprising; it would also be invisible.
#
# The honest summary for whoever trips this: a converged run proves the file
# reached the device and the launcher agreed with it. For a built-in favorites
# widget that is the whole story. For an AppWidget it is not, and no amount of
# reading the report will make it one.
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
  echo "  Two questions, and they have different answers:" >&2
  echo "  1. Is andashi/home#219 in the release we install? Before it, a missing" >&2
  echo "     provider is reported only on the FIRST reload, so a re-run or a" >&2
  echo "     second device reports success for a widget that is absent. That" >&2
  echo "     half is temporary and retires with the release." >&2
  echo "  2. Does anything here prove the widget is actually BOUND? Nothing does," >&2
  echo "     and no release will change it: the reload report is a configuration" >&2
  echo "     report, not a capability one, so a refused bind is silent by design." >&2
  echo "     A converged run stops being proof that the screen matches the file." >&2
  exit 1
fi
echo "ok: no AppWidget providers declared (see check-appwidgets.sh)"
