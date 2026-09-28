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
#   1. TEMPORARY, and ANSWERED BY THE SCRIPT rather than by a person. Two
#      launcher defects made a declared widget unverifiable: #219 (a missing
#      provider reported only on the first reload) and #224 (an already-bound
#      widget whose provider was briefly unavailable at first composition -
#      an app mid-update - cached null and showed "loading failed" for good).
#      Both shipped in 0.10.0. So the question "is it in the release we
#      install" is one this script can answer by looking at the inventory,
#      and a question a script can answer is not a question to print.
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

# The newest launcher APK on this host is what the next run installs, because
# the launcher is deliberately unpinned (decision 0012). release_tag would
# override that, which is exactly when this matters again.
: "${APKS_DIR:=$PWD/../apks}"
WIDGET_SAFE_FROM="0.10.0"
launcher_version() {
  local pkg tag newest
  pkg="$(jq -r --arg k "$(jq -r .launcher "$CONFIG_DIR/theming.json")" '.launchers[$k].pkg' "$CONFIG_DIR/theming.json")"
  tag="$(jq -r --arg p "$pkg" '[.apps[]|select(.pkg==$p)|.release_tag//empty][0] // empty' "$CONFIG_DIR/apps.json")"
  [ -n "$tag" ] && { printf '%s' "${tag#v}"; return 0; }
  newest="$(ls "$APKS_DIR"/*/"$pkg"-*.apk 2>/dev/null | sed "s|.*/$pkg-||; s|\.apk$||" | sort -V | tail -1)"
  [ -n "$newest" ] && printf '%s' "$newest"
}

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
  # `|| true` with the emptiness checked on the next line, not as a shrug:
  # launcher_version returns non-zero for "no APK here", which is an answer,
  # and under set -e the assignment alone killed the script mid-message. The
  # tripwire against invisible states was exiting invisibly.
  have="$(launcher_version || true)"
  if [ -z "$have" ]; then
    echo "  1. UNKNOWN: no launcher APK in $APKS_DIR, so this script cannot tell" >&2
    echo "     whether the build you will install carries andashi/home#219 and" >&2
    echo "     #224. Without them a declared widget can be absent or permanently" >&2
    echo "     broken while the report says success. Run apks/fetch.sh." >&2
  elif [ "$(printf '%s\n%s\n' "$WIDGET_SAFE_FROM" "$have" | sort -V | head -1)" != "$WIDGET_SAFE_FROM" ]; then
    echo "  1. The build you would install is $have, older than $WIDGET_SAFE_FROM." >&2
    echo "     Before andashi/home#219 a missing provider is reported only on the" >&2
    echo "     FIRST reload, so a re-run reports success for a widget that is" >&2
    echo "     absent; before #224 an already-bound widget whose provider was" >&2
    echo "     briefly unavailable shows \"loading failed\" for good. Upgrade, or" >&2
    echo "     know that the run proves less than it says." >&2
  else
    echo "  1. Answered: the build you would install is $have, which carries" >&2
    echo "     andashi/home#219 and #224. That half is settled." >&2
  fi
  echo "  2. Does anything here prove the widget is actually BOUND? Nothing does," >&2
  echo "     and no release will change it: the reload report is a configuration" >&2
  echo "     report, not a capability one, so a refused bind is silent by design." >&2
  echo "     A converged run stops being proof that the screen matches the file." >&2
  exit 1
fi
echo "ok: no AppWidget providers declared (see check-appwidgets.sh)"
