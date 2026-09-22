#!/usr/bin/env bash
# Generates config/launcher/<profile>.json - one launcher config per
# non-managed profile - from theming.json + apps.json + profiles.json +
# features.json. Schema v1 is the fork's public config contract
# (Kvaesitso ADR 0002/0003): provisioning pushes the file into the app's
# per-user files dir, the launcher converges to it and serves its effective
# state back for verification (provision/45-launcher-config.sh).
#
# Launcher defaults come from theming.json (.launchers[$GEN_LAUNCHER_KEY]),
# per_profile WINS over them - same rule as 40-theming.sh. appearance.wallpaper
# is emitted only when the launcher entry has wallpaper: true (a release that
# applies it); otherwise the read-back verification would fail on the key. Managed profiles
# (Work) get no file: they have no home screen of their own.
#
# Resolution failures are FATAL, not warnings: a favorite that does not
# resolve to exactly one catalog entry, or an unknown widget name, means the
# checked-in file would describe a home screen that cannot exist - generation
# must fail loudly instead.
set -euo pipefail
cd "$(dirname "$0")"
# The catalog does not have to live in this repository. lib/common.sh has
# documented CONFIG_DIR for the chain all along; the generators ignored it,
# which was harmless while the catalog WAS the repository and became a trap the
# moment it turned into a template: the chain would read a private catalog while
# the generators kept reading the template beside them, and the two would drift
# without anyone being told.
: "${CONFIG_DIR:=$PWD}"
for f in theming.json apps.json profiles.json features.json; do
  [ -f "$CONFIG_DIR/$f" ] || { echo "gen-launcher: $CONFIG_DIR/$f missing" >&2; exit 1; }
done
# Generated configs belong with the catalog they are derived from, not with the
# template, so the default follows CONFIG_DIR. `make check` overrides it to
# generate into a temp dir and diff against the tracked files.
: "${OUT_DIR:=$CONFIG_DIR/launcher}"
# Which launcher entry supplies the defaults. Overridable to generate for a
# different identity without touching theming.json.
: "${GEN_LAUNCHER_KEY:=andashi-home}"

jq -e --arg k "$GEN_LAUNCHER_KEY" '.launchers | has($k)' "$CONFIG_DIR/theming.json" >/dev/null \
  || { echo "theming.json: no launcher entry '$GEN_LAUNCHER_KEY'" >&2; exit 1; }

mkdir -p "$OUT_DIR"

# Non-managed profiles whose feature (if any) is enabled - mirrors
# lib/common.sh profile_keys() + the managed-profile skip of the launcher steps.
profile_keys() {
  jq -r --slurpfile feat "$CONFIG_DIR/features.json" '
    .profiles[]
    | select((.type // "") != "managed")
    | (.feature // "") as $f
    | if $f == "" then .key
      elif ($feat[0].features | has($f)) | not
        then error("profiles.json references unknown feature \"\($f)\"")
      elif $feat[0].features[$f].enabled then .key
      else empty end
  ' "$CONFIG_DIR/profiles.json"
}

# One config document for profile $1 on stdout. All mappings live here so the
# schema is defined in exactly one place.
gen_profile() {   # $1=profile-key
  jq -S -e --arg key "$1" --arg lkey "$GEN_LAUNCHER_KEY" --slurpfile apps "$CONFIG_DIR/apps.json" '
    . as $t
    | ($t.launchers[$lkey]) as $l
    | ($t.per_profile[$key] // {}) as $p

    # Transparency: per-profile object wins as a whole; `elevated` in
    # theming.json maps to `elevatedSurface` in the config schema.
    | ($p.transparency // $l.transparency // {}) as $tr

    # Wallpaper: the per-profile image path (with or without {aspect}) becomes
    # an upload name, its basename. 45-launcher-config.sh uploads the resolved
    # file under that name before it writes the config; the launcher applies
    # it on reload and reports it in the read-back.
    | ($p.wallpaper // null) as $wpath
    | (if $wpath == null or ($l.wallpaper // false) != true then null
       else { image: ($wpath | split("/") | last), target: "both" } end) as $wallpaper

    # Widgets: per_profile WINS over the launcher default. Andashi Home only
    # has one built-in widget left, `apps` (the favorites widget); everything
    # else is a standard Android AppWidget, which this config cannot place yet.
    # The clock, weather, calendar, music and notes widgets were removed from
    # the launcher (ADR 0008), so naming one here is an error, not a no-op:
    # silently dropping it would leave a home screen that does not match the
    # dotfiles.
    | (if $p | has("widgets") then $p.widgets else ($l.widgets // []) end) as $wraw
    | ([ $wraw[] | ascii_downcase
         | if . == "apps" then "apps"
           else error("profile \($key): unknown widget \"\(.)\" (known: apps)")
           end
       ]) as $widgets

    # Favorites: labels/ids -> package names. Exact label or id first, then a
    # unique case-insensitive partial match. Ambiguous or unresolved entries
    # abort the whole generation - loudly, via jq error().
    | ($apps[0].apps) as $catalog
    | ([ ($p.favorites // [])[] | . as $f
         | ([ $catalog[] | select(.label == $f or .id == $f) ]) as $exact
         | if ($exact | length) == 1 then $exact[0].pkg
           elif ($exact | length) > 1
             then error("profile \($key): favorite \"\($f)\" matches multiple catalog entries exactly")
           else ([ $catalog[] | select(.label | ascii_downcase | contains($f | ascii_downcase)) ]) as $part
             | if ($part | length) == 1 then $part[0].pkg
               elif ($part | length) == 0
                 then error("profile \($key): favorite \"\($f)\" does not resolve to any catalog app")
               else error("profile \($key): favorite \"\($f)\" is ambiguous: \([$part[].label] | join(", "))")
               end
           end
       ]
       # The schema wants objects, not bare package names
       # (core/config/.../LauncherConfig.kt: `data class Favorite(packageName,
       # profile = Personal)`). A string here makes the launcher reject the
       # WHOLE document with decode-failed - wallpaper and transparency of that
       # zone go with it - so this was never a dock-only defect.
       #
       # `profile` is deliberately NOT written. It carries a Kotlin default,
       # and kotlinx.serialization does not encode defaults: the launcher
       # accepts `profile: "personal"` but reports the favorite back WITHOUT
       # the key, so the read-back in 45-launcher-config.sh then fails on a
       # difference that is not one. Measured 2026-09-21 on emulator-5558,
       # Andashi Home 0.3.0, three favorites in Home:
       #   + reload converged (diagnostics sha256 match)
       #   ! Home: effective config differs in: home
       # Writing only what the launcher will echo back keeps that check strict
       # and meaningful. A non-default profile (work/private) WOULD be
       # serialized back, so this stays correct when that feature arrives.
       | map({ packageName: . })) as $favs

    | {
        schemaVersion: 1,
        icons: {
          themed: true,
          enforceThemed: true,
          pack: "app.lawnchair.lawnicons"
        },
        appearance: ({
          transparency: {
            name: "fold-glass",
            background: ($tr.background // 0.4),
            surface: ($tr.surface // 0.4),
            elevatedSurface: ($tr.elevated // 0.4)
          }
        } + (if $wallpaper == null then {} else { wallpaper: $wallpaper } end)),
        home: {
          searchBar: { position: "bottom" },
          dock: { enabled: true, favorites: $favs },
          widgets: (if ($widgets | length) == 0
                    then { enabled: false, widgets: [] }
                    else { enabled: true, widgets: $widgets } end)
        }
      }
  ' "$CONFIG_DIR/theming.json"
}

GENERATED=()
while read -r key; do
  [ -z "$key" ] && continue
  tmp="$OUT_DIR/.$key.json.tmp"
  # Atomic write: jq either completes the document or fails (unknown widget or
  # unresolved favorite exits non-zero) - a half-written file must never land
  # under the real name.
  if gen_profile "$key" > "$tmp"; then
    mv "$tmp" "$OUT_DIR/$key.json"
    GENERATED+=("$key.json")
  else
    rc=$?
    rm -f "$tmp"
    echo "generation failed for profile '$key'" >&2
    exit "$rc"
  fi
done < <(profile_keys)

# Prune files for profiles that no longer exist (or became managed / lost
# their feature): a stale file would keep getting pushed by
# 45-launcher-config.sh for a profile the model no longer describes.
for f in "$OUT_DIR"/*.json; do
  [ -e "$f" ] || continue
  base="$(basename "$f")"
  keep=0
  for g in ${GENERATED[@]+"${GENERATED[@]}"}; do
    [ "$base" = "$g" ] && { keep=1; break; }
  done
  [ "$keep" = "1" ] || { rm -f "$f"; echo "pruned stale $f"; }
done

echo "$OUT_DIR: ${#GENERATED[@]} profile configs (launcher defaults: $GEN_LAUNCHER_KEY)"
for g in ${GENERATED[@]+"${GENERATED[@]}"}; do echo "  $g"; done
