#!/usr/bin/env bash
# Generates config/launcher/<profile>.json - one launcher config per
# non-managed profile - from theming.json + apps.json + profiles.json +
# features.json. Schema v2 is the fork's public config contract
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
# The grid items deliberately carry NO geometry. Rows are derived from the
# screen, not configured, so "bottom row, full width" is not something a host
# can compute - it would have to guess the row count of a device it cannot see.
# The schema allows geometry to be omitted once: the launcher places the item
# and writes the coordinates back. That is also why the read-back check in
# 45-launcher-config.sh compares grid items by id and widget and ignores where
# they sit.
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

    # Glass (Andashi Home 0.5.0+, launcher ADR 0004): all_profiles.glass first,
    # the glass object of the zone on top - FIELD BY FIELD, not as a whole. The old
    # transparency rule let a per-profile object win entirely, which was
    # harmless for three values that were always written together and is a trap
    # for five: a zone that wants a darker tint would silently reset blur,
    # radius and contrast to the fallbacks in this generator.
    | (($t.all_profiles.glass // {}) + ($p.glass // {})) as $g
    | (($l.glass // false) == true) as $glass_on

    # The launcher rejects an out-of-range value with `invalid-glass`, and a
    # rejected document takes the wallpaper and favorites of that zone with it.
    # The bounds are the ones the launcher enforces (ConfigValidator: blur and radius 0..64dp,
    # tint 0..1, contrast low|medium|high); checking them here turns six broken
    # zones into one failed generation.
    | (if $glass_on then
         ([ $g | keys[] | . as $k | select([ "blur", "tint", "radius", "contrast", "wallpaperBlur" ] | index($k) | not) ]) as $unknown
         | if ($unknown | length) > 0
             then error("profile \($key): unknown glass key(s): \($unknown | join(", "))")
           elif (($g.blur // 24) < 0 or ($g.blur // 24) > 64)
             then error("profile \($key): glass.blur \($g.blur) is not between 0 and 64dp")
           elif (($g.radius // 28) < 0 or ($g.radius // 28) > 64)
             then error("profile \($key): glass.radius \($g.radius) is not between 0 and 64dp")
           elif (($g.tint // 0.12) < 0 or ($g.tint // 0.12) > 1)
             then error("profile \($key): glass.tint \($g.tint) is not between 0 and 1")
           elif ([ "low", "medium", "high" ] | index($g.contrast // "medium")) == null
             then error("profile \($key): glass.contrast \"\($g.contrast)\" is not low, medium or high")
           else . end
       else . end)

    # The pre-0.5.0 shape, emitted only while glass is false - for a release
    # pinned on purpose. `elevated` maps to `elevatedSurface` in the schema.
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
        schemaVersion: 2,
        icons: {
          themed: true,
          enforceThemed: true,
          pack: "app.lawnchair.lawnicons"
        },
        # Every glass field is written, none left to the launcher: the read-back
        # serves a COMPLETE glass block (ConfigStateMapper: "defaults filled
        # in") and 45-launcher-config.sh compares the whole appearance section,
        # so an omitted field would come back as a difference. Writing them also
        # means the look is decided by this distribution and does not move when the
        # launcher retunes its defaults. wallpaperBlur goes through has():
        # `// true` would turn an explicit false back into true, the same trap
        # lib/common.sh documents for profile fields.
        appearance: ((if $glass_on then {
          glass: {
            blur: ($g.blur // 24),
            tint: ($g.tint // 0.12),
            radius: ($g.radius // 28),
            contrast: ($g.contrast // "medium"),
            wallpaperBlur: (if $g | has("wallpaperBlur") then $g.wallpaperBlur else true end)
          }
        } else {
          transparency: {
            name: "fold-glass",
            background: ($tr.background // 0.4),
            surface: ($tr.surface // 0.4),
            elevatedSurface: ($tr.elevated // 0.4)
          }
        } end) + (if $wallpaper == null then {} else { wallpaper: $wallpaper } end)),
        home: {
          searchBar: { position: "bottom" },
          # The one pin list, shared by search and the favorites widget.
          favorites: $favs,
          # Master switch for the grid. Off would mean no home surface at all,
          # since the dock became a grid item in v2.
          widgets: { enabled: true },
          grid: ({
            # The cover-width page; the fold layout is twice as wide and the
            # cover renders columns 0 until this number (launcher ADR 0001).
            columns: 4,
            # Editing on the device is wanted, so the launcher writes the
            # arranged geometry back. 45-launcher-config.sh pulls before it
            # pushes and refuses when the device changed in between.
            locked: false,
            layouts: {
              phone: { items: [ { id: "favorites", widget: "favorites" } ] },
              fold:  { items: [ { id: "favorites", widget: "favorites" } ] }
            }
          # Labels under the grid items, never on the dock. New in 0.5.0, so it
          # rides the same flag as glass - an older pinned release would report
          # it as an unknown key and never echo it back.
          } + (if $glass_on then { labels: true } else {} end))
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
