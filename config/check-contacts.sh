#!/usr/bin/env bash
# search.contacts may be true only in a zone whose catalog entry grants the
# launcher READ_CONTACTS.
#
# The launcher does not enforce this: a config that asks for contact search in
# a zone without the permission is accepted, applied and served back as true,
# with no diagnostic (measured 2026-09-25 on emulator-5560, 0.7.3; reported as
# andashi/home#140). What stands between a zone and a permanent "Contacts
# permission is required - Grant" under every query is one branch of
# gen-launcher.sh deriving the key from perms.only_profiles. A guarantee that
# lives in one branch of one script is one hand edit or one pull away from
# being gone, so it is checked here against the generated files.
#
# It was inline in the Makefile, which made it the one check with no case of
# its own. See check-contacts.test.sh.
set -euo pipefail
cd "$(dirname "$0")"
: "${CONFIG_DIR:=$PWD}"
: "${OUT_DIR:=$CONFIG_DIR/launcher}"

pkg="$(jq -r --arg k "$(jq -r .launcher "$CONFIG_DIR/theming.json")" \
  '.launchers[$k].pkg' "$CONFIG_DIR/theming.json")"
[ -n "$pkg" ] && [ "$pkg" != "null" ] \
  || { echo "check-contacts: theming.json names no launcher package" >&2; exit 1; }

bad=""
for f in "$OUT_DIR"/*.json; do
  [ -e "$f" ] || continue
  zone="$(basename "$f" .json)"
  jq -e '.search.contacts == true' "$f" >/dev/null || continue
  jq -e --arg z "$zone" --arg p "$pkg" '
    [ .apps[]
      | select(.pkg == $p)
      | select((.perms.grant // []) | index("android.permission.READ_CONTACTS"))
      | select(((.perms.only_profiles // .profiles) | index($z)) != null)
    ] | length > 0' "$CONFIG_DIR/apps.json" >/dev/null || bad="$bad  $zone"$'\n'
done

if [ -n "$bad" ]; then
  echo "search.contacts is true in zones the catalog denies READ_CONTACTS:" >&2
  printf '%s' "$bad" >&2
  echo "  the launcher accepts it and shows a Grant banner under every query (andashi/home#140)" >&2
  exit 1
fi
echo "ok: contact search only where the permission is"
