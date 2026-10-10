#!/usr/bin/env bash
# Generates config/obtainium.json (import file) from the app catalog.
# Apps with source=obtainium and a set upstream URL, plus source=fdroid,
# source=torproject and source=direct.
# fdroid apps get an f-droid.org URL instead of their upstream: Obtainium
# tracks them through the F-Droid repo, and for Shelter the GitHub releases
# carry no APK at all. Without this they would never be updated on device.
# torproject is a split path, and deliberately so: provisioning fetches the APK
# from dist.torproject.org because that is the only place with a detached GPG
# signature to check, while the DEVICE updates through the Guardian Project
# F-Droid repo, which apks/provenance.sh confirms ships the same signing
# certificate. Same key means the update installs over ours instead of failing
# with a signature mismatch. Without an entry here, Tor Browser would be
# installed once and never updated - the worst outcome for the Anon zone.
# direct apps (a vendor's own download directory) are tracked on that same
# directory, which Obtainium reads as an HTML source; the filter keeps it to
# the Android file among the desktop builds listed next to it.
#
# With the andashi updater in the catalog (an app with "role": "updater") the
# import is EMPTY: every app it would list is one the updater keeps current,
# and an Obtainium that also tracks it offers "Update this app?", whose one
# tap moves the installer of record to Obtainium and leaves the updater unable
# to update it silently (andashi/updater design §13, measured 2026-10-02).
# Obtainium stays for what a person adds by hand. The same catalog change
# makes 10-apps.sh name the updater as installer, so the apps are not left
# without one in between.
#
# WARNING: Obtainium's import schema isn't documented with versioning.
# Before the first real import, cross-check once against a REAL export
# (Obtainium -> Settings -> Export) and adjust the mapping here if needed.
set -euo pipefail
cd "$(dirname "$0")"
# Same as gen-launcher.sh: the catalog may live outside this repository
# (lib/common.sh, CONFIG_DIR). The import list is derived from the catalog, so
# it is written next to the catalog it describes.
: "${CONFIG_DIR:=$PWD}"
[ -f "$CONFIG_DIR/apps.json" ] || { echo "gen-obtainium: $CONFIG_DIR/apps.json missing" >&2; exit 1; }
# Overridable so `make check` can generate to a temp file and diff it against
# the tracked one, instead of writing over it.
: "${OUT:=$CONFIG_DIR/obtainium.json}"

jq '([.apps[] | select(.role == "updater")] | length > 0) as $updater
| {
  apps: if $updater then [] else [
    .apps[]
    | select((.source == "obtainium" and (.upstream // "") != "") or .source == "fdroid" or .source == "torproject" or .source == "direct")
    | {
        id: .pkg,
        url: (if .source == "fdroid" then "https://f-droid.org/packages/" + .pkg
              elif .source == "torproject" then "https://guardianproject.info/fdroid/repo/" + .pkg
              elif .source == "direct" then .download.index
              else .upstream end),
        author: (if .source == "fdroid" then "F-Droid"
                 elif .source == "torproject" then "Guardian Project"
                 else (.upstream | capture("(?:github\\.com|codeberg\\.org|gitlab\\.com)/(?<a>[^/]+)/").a? // "unknown") end),
        name: .label,
        preferredApkIndex: 0,
        additionalSettings: ({versionDetection: true,
                              apkFilterRegEx: (if .source == "direct"
                                               then .download.file | gsub("[.]"; "\\.") | sub("[{]version[}]"; ".+") | "^" + . + "$"
                                               else "" end)} | tojson),
        lastUpdateCheck: null,
        pinned: false
      }
  ] end
}' "$CONFIG_DIR/apps.json" > "$OUT"

echo "$OUT: $(jq '.apps|length' "$OUT") apps"
jq -e '[.apps[] | select(.role == "updater")] | length > 0' "$CONFIG_DIR/apps.json" >/dev/null \
  && echo "  (empty on purpose: the andashi updater keeps these apps current)"
jq -r '.apps[] | "  \(.name)  ->  \(.url)"' "$OUT"
