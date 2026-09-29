#!/usr/bin/env bash
# Cases for the catalog-editing commands of bin/andashi (app add|rm, theme
# set). They are what an agent is told to use instead of editing JSON, so
# they must put the change exactly where it belongs, touch nothing else, and
# refuse what the catalog's checks refuse - without a phone.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
t() { if eval "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi; }
fresh() {
  rm -rf "$tmp/config"; cp -r "$ROOT/config" "$tmp/config"; rm -f "$tmp/config/launcher/.generated.sha256"
  # The template's one open invariant violation (Azure in Play-free Ops) is
  # taken out, so each case is about the command, not about that decision.
  jq --indent 2 '(.apps[] | select(.id == "azure") | .profiles) -= ["ops"]' "$ROOT/config/apps.json" > "$tmp/config/apps.json"
  cp "$tmp/config/apps.json" "$tmp/apps.before"; cp "$tmp/config/theming.json" "$tmp/theming.before"
}
a() { CONFIG_DIR="$tmp/config" ADB=/bin/false "$ROOT/bin/andashi" "$@" > "$tmp/out" 2>&1; }
profiles_of() { jq -r --arg id "$1" '.apps[] | select(.id == $id) | .profiles | join(",")' "$tmp/config/apps.json"; }

fresh
a app add signal --zone lab
t "app add places the app"                 '[ $? = 0 ] && profiles_of signal | grep -q lab'
t "... and changes nothing but that list"  '[ "$(jq -S "del(.apps[] | select(.id == \"signal\") | .profiles)" "$tmp/apps.before")" = "$(jq -S "del(.apps[] | select(.id == \"signal\") | .profiles)" "$tmp/config/apps.json")" ]'
t "... and the generated launcher follows" 'grep -q "catalog checks pass" "$tmp/out"'
a app add signal --zone lab
t "adding twice does not duplicate"        '[ "$(profiles_of signal | tr , "\n" | grep -c "^lab$")" = 1 ]'
a app rm signal --zone lab
t "app rm takes it out again"              '! profiles_of signal | grep -q lab && diff -q "$tmp/apps.before" "$tmp/config/apps.json" >/dev/null'
a app add nosuchapp --zone lab
t "an unknown app refuses"                 '[ $? != 0 ] && grep -q "no app .nosuchapp." "$tmp/out"'
a app add signal --zone lap
t "an unknown zone refuses"                '[ $? != 0 ] && grep -q "not a zone" "$tmp/out"'
a app add signal --zone current
t "current needs a phone, and says so"     '[ $? != 0 ] && grep -q "current. needs a phone" "$tmp/out"'
fresh
id="$(jq -r '.apps[] | select(.source == "play-sandboxed") | .id' "$tmp/config/apps.json" | head -1)"
a app add "$id" --zone anon
t "a Play app into Anon is refused by the invariants" '[ $? != 0 ]'
t "... and apps.json is as it was"            'diff -q "$tmp/apps.before" "$tmp/config/apps.json" >/dev/null'

fresh
a theme set glass.tint 0.3 --zone lab
t "theme set writes per_profile, as a number" '[ $? = 0 ] && [ "$(jq -c .per_profile.lab.glass.tint "$tmp/config/theming.json")" = 0.3 ]'
t "... and regenerates lab's launcher file"   '[ "$(jq -c .appearance.glass.tint "$tmp/config/launcher/lab.json")" = 0.3 ]'
t "... and leaves home's alone"               'diff -q "$ROOT/config/launcher/home.json" "$tmp/config/launcher/home.json" >/dev/null'
a theme set glass.contrast high
t "without --zone it sets all_profiles, strings stay strings" '[ "$(jq -c .all_profiles.glass.contrast "$tmp/config/theming.json")" = "\"high\"" ]'
a theme set glass.nosuchkey 1 --zone lab
t "a glass key that does not exist is refused" '[ $? != 0 ] && ! grep -q "catalog checks pass" "$tmp/out"'
t "... and theming.json is as it was before it" '[ "$(jq -c .per_profile.lab.glass "$tmp/config/theming.json")" = "{\"tint\":0.3}" ]'

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
