#!/usr/bin/env bash
# Generates config/updater/<zone>.json - the andashi updater's config for each
# zone, schema 1 (andashi/updater, docs/design.md §9.1) - from apps.json,
# profiles.json, features.json, distribution.json and the pinned signers in
# apks/certs/.
#
# managed  every app of the zone whose source the lock covers (obtainium,
#          fdroid, torproject, direct), with the signer pinned for it. The
#          updater keeps exactly these current; everything else in the zone is
#          some other installer's (Play, Accrescent, the OS) and is reported
#          as foreign. The updater itself is a catalog app like any other and
#          appears here through the same rule.
# lock     where the zone fetches the lock and its heartbeat, from
#          distribution.json - not this repository's URL written in here, so a
#          fork or a private catalog points its phones at its own lock.
# allowedHosts  the distribution's list, verbatim. config/check-hosts.sh
#          holds the lock to it; the lock never feeds it.
# checks.netFalse  every app of the zone declared net: false.
#
# Managed profiles (Work) get no file: the updater does not run there, and the
# code they share with Cloud is updated by Cloud's instance.
#
# A managed app without a pinned signer is FATAL: the updater would refuse it
# as unverifiable on every check, and a config that names an app it can never
# update is the success-for-work-not-done this repository exists to avoid.
set -euo pipefail
cd "$(dirname "$0")"
: "${CONFIG_DIR:=$PWD}"
: "${CERTS_DIR:=$PWD/../apks/certs}"
: "${OUT_DIR:=$CONFIG_DIR/updater}"
for f in apps.json profiles.json features.json distribution.json; do
  [ -f "$CONFIG_DIR/$f" ] || { echo "gen-updater: $CONFIG_DIR/$f missing" >&2; exit 1; }
done

# The pins, as one JSON object pkg -> fingerprint, read once.
pins="{}"
for c in "$CERTS_DIR"/*.cert; do
  [ -f "$c" ] || continue
  pins="$(jq -c --arg p "$(basename "$c" .cert)" --arg s "$(tr -d '[:space:]' < "$c")" '. + {($p): $s}' <<<"$pins")"
done

# Same zone selection as gen-launcher.sh: non-managed, feature (if any) on.
zones="$(jq -r --slurpfile feat "$CONFIG_DIR/features.json" '
  .profiles[]
  | select((.type // "") != "managed")
  | (.feature // "") as $f
  | if $f == "" then .key
    elif ($feat[0].features | has($f)) | not
      then error("profiles.json references unknown feature \"\($f)\"")
    elif ($feat[0].features[$f].enabled | type) != "boolean"
      then error("features.json: \($f).enabled is neither true nor false")
    elif $feat[0].features[$f].enabled then .key
    else empty end' "$CONFIG_DIR/profiles.json")"

gen_zone() {   # $1=zone
  jq -S -e --arg z "$1" --argjson pins "$pins" \
     --slurpfile feat "$CONFIG_DIR/features.json" --slurpfile dist "$CONFIG_DIR/distribution.json" '
    ($dist[0]) as $d
    | [ .apps[]
        | select((.profiles // []) | index($z))
        | select((.feature // "") as $f
                 | if $f == "" then true
                   elif ($feat[0].features | has($f)) | not
                     then error("apps.json: \(.id) references unknown feature \"\($f)\"")
                   elif ($feat[0].features[$f].enabled | type) != "boolean"
                     then error("features.json: \($f).enabled is neither true nor false")
                   else $feat[0].features[$f].enabled end) ] as $apps
    | {
        schemaVersion: 1,
        zone: $z,
        lock: {
          mode: "fetch",
          url: $d.lock.url,
          heartbeatUrl: $d.lock.heartbeatUrl,
          maxAgeDays: $d.lock.maxAgeDays,
          allowedHosts: $d.allowedHosts
        },
        schedule: $d.updater.schedule,
        policy: $d.updater.policy,
        managed: [ $apps[]
                   | select(.source == "obtainium" or .source == "fdroid" or .source == "torproject" or .source == "direct")
                   | {pkg, label,
                      signer: ($pins[.pkg] // error("\(.label) (\(.pkg)) is managed in \($z) but has no pinned signer in apks/certs - fetch it first"))} ]
                 | sort_by(.pkg),
        checks: { netFalse: [ $apps[] | select(.net == false) | .pkg ] | unique }
      }' "$CONFIG_DIR/apps.json"
}

mkdir -p "$OUT_DIR"
# Written to temp files first and moved only when every zone generated: a
# failure halfway must not leave half the directory new and half old.
stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
for z in $zones; do
  gen_zone "$z" > "$stage/$z.json" || { echo "gen-updater: $z could not be generated - nothing written" >&2; exit 1; }
done
# A zone that is gone (profile removed, feature switched off) loses its file.
for f in "$OUT_DIR"/*.json; do
  [ -f "$f" ] || continue
  [ -f "$stage/$(basename "$f")" ] || rm -f "$f"
done
for f in "$stage"/*.json; do mv "$f" "$OUT_DIR/"; done
for z in $zones; do
  printf '%s: %s managed, %s net:false\n' "$z" "$(jq '.managed | length' "$OUT_DIR/$z.json")" "$(jq '.checks.netFalse | length' "$OUT_DIR/$z.json")"
done
