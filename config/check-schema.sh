#!/usr/bin/env bash
# Checks the generated launcher configs against the JSON Schema the launcher
# publishes with each release (config/schema/launcher.schema.json, refreshed by
# `make schema`).
#
# Why this exists: the generator can keep writing a key the contract removed,
# and nothing here would notice. `make check` proves the files match the
# generator, and the read-back proves the device agrees - but the read-back runs
# only against a device, and it compares whole sections, so a key the launcher
# has dropped comes back as "the section differs" at best. When schema 1 became
# schema 2 and `home.dock` disappeared, the only thing standing between the
# generator and six zones of silently ignored configuration was that somebody
# changed the generator in the same week (2026-09-26, andashi/home
# e2e/l4-provisioning-config.sh).
#
# This is NOT a full JSON Schema validator. It implements the part that catches
# that: unknown keys where the schema closes the object, values outside an enum
# or const, and the basic types. `oneOf` passes when any branch passes. Patterns,
# ranges and required are left to the launcher, which reports them per zone with
# its own words.
set -euo pipefail
cd "$(dirname "$0")"
: "${CONFIG_DIR:=$PWD}"
: "${SCHEMA:=$PWD/schema/launcher.schema.json}"
: "${OUT_DIR:=$CONFIG_DIR/launcher}"

[ -f "$SCHEMA" ] || { echo "check-schema: $SCHEMA missing - run 'make schema'" >&2; exit 1; }

fail=0
for f in "$OUT_DIR"/*.json; do
  [ -e "$f" ] || continue
  errors="$(jq -r --slurpfile s "$SCHEMA" '
    def typeok($inst; $t):
      if   $t == "integer" then ($inst|type) == "number" and ($inst|floor) == $inst
      elif $t == "number"  then ($inst|type) == "number"
      else ($inst|type) == $t end;

    def validate($inst; $sch; $path):
      if ($sch|type) != "object" then []
      elif ($sch|has("oneOf")) then
        ([ $sch.oneOf[] | validate($inst; .; $path) ]) as $tries
        | if any($tries[]; length == 0) then []
          else ["\($path): \($inst|tojson) matches none of the accepted forms"] end
      elif ($sch|has("const")) then
        if $inst == $sch.const then [] else ["\($path): expected \($sch.const|tojson)"] end
      elif ($sch|has("enum")) then
        if ($sch.enum | index($inst)) != null then []
        else ["\($path): \($inst|tojson) is not one of \($sch.enum | map(tojson) | join(", "))"] end
      elif ($sch|has("type")) and (typeok($inst; $sch.type) | not) then
        ["\($path): expected \($sch.type), got \($inst|type)"]
      elif ($sch.type == "object") and (($inst|type) == "object") then
        [ $inst | keys[] | . as $k
          | if (($sch.properties // {}) | has($k))
              then validate($inst[$k]; $sch.properties[$k]; "\($path).\($k)")[]
            # has(), not //: jq treats FALSE as empty, so `additionalProperties
            # // true` turns a closed object into an open one and this check
            # into a no-op. Found by the negative test below rather than by
            # reading, which is the only reason it is not still silent.
            elif (if ($sch|has("additionalProperties")) then $sch.additionalProperties else true end) == false
              then "\($path).\($k): not a key of this contract"
            else empty end ]
      elif ($sch.type == "array") and (($inst|type) == "array") then
        [ range(0; $inst|length) as $i
          | validate($inst[$i]; ($sch.items // {}); "\($path)[\($i)]")[] ]
      else [] end;

    validate(.; $s[0]; "") | .[]
  ' "$f")" || { echo "check-schema: could not read $f" >&2; exit 1; }
  if [ -n "$errors" ]; then
    printf '%s:\n' "$(basename "$f")"
    printf '%s\n' "$errors" | sed 's/^/  /'
    fail=1
  fi
done

if [ "$fail" = "1" ]; then
  echo "the generated configs do not match $(basename "$SCHEMA")" >&2
  exit 1
fi
echo "ok: configs match the launcher schema"
