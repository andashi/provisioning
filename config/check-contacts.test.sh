#!/usr/bin/env bash
# Cases for check-contacts.sh: the rule that search.contacts may only be true
# where the catalog grants the launcher READ_CONTACTS. The launcher enforces
# nothing here (andashi/home#140), so this check is the guarantee - and a
# guarantee without a case where it must fail is a guess.
set -uo pipefail
cd "$(dirname "$0")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp theming.json apps.json "$tmp/"; mkdir -p "$tmp/launcher"
pass=0; fail=0

t() {   # $1=name $2=expected fragment ("" = must pass)
  local out rc
  out="$(CONFIG_DIR="$tmp" ./check-contacts.sh 2>&1)"; rc=$?
  if [ -z "$2" ]; then
    if [ "$rc" = 0 ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
    else printf '  FAIL  %s\n        expected a pass, got: %s\n' "$1" "$out"; fail=$((fail+1)); fi
  else
    if [ "$rc" != 0 ] && printf '%s' "$out" | grep -qF "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
    else printf '  FAIL  %s\n        expected [%s], rc=%s, got: %s\n' "$1" "$2" "$rc" "$out"; fail=$((fail+1)); fi
  fi
}

# Home has the permission in the template, Anon does not.
cp launcher/home.json "$tmp/launcher/home.json"
cp launcher/anon.json "$tmp/launcher/anon.json"
t "the real configs pass" ""

jq '.search.contacts = true' launcher/anon.json > "$tmp/launcher/anon.json"
t "contact search in a zone without the grant" "  anon"

cp launcher/anon.json "$tmp/launcher/anon.json"
jq '(.apps[] | select(.pkg == "org.andashi.home") | .perms.only_profiles) = ["cloud"]' apps.json > "$tmp/apps.json"
t "the grant moved away from the zone that uses it" "  home"

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
