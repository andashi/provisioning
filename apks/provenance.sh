#!/usr/bin/env bash
# Where does each pinned signer fingerprint actually come from?
#
#   ./provenance.sh              check every pinned cert, write certs/PROVENANCE.tsv
#   SKIP_FDROID=1 ./provenance.sh   without the 60 MB main F-Droid index
#
# certs/<pkg>.cert is trust on first use: the first download defines the truth.
# That is fine against a later takeover and useless against a first download
# that was already wrong. This script asks other people whether they see the
# same signer.
#
# Three kinds of witness, and the kind decides what a mismatch means:
#
#   upstream  - ships the DEVELOPER's own binary (IzzyOnDroid, Guardian Project,
#               a vendor's own F-Droid repo). Same signer expected. A mismatch
#               here is an alarm and fails this script.
#   rebuild   - builds from source and signs with its OWN key (f-droid.org).
#               A match proves the pin (upstream and F-Droid agree, which only
#               happens for reproducible builds); a mismatch proves nothing and
#               is reported as "inconclusive".
#   curated   - a third party that inspected APKs from official channels
#               (privacyguides/verified-apps). A match corroborates. A mismatch
#               usually means they only looked at a different channel, so it is
#               recorded and never raises an alarm.
#
# A witness that is also our download source proves nothing - it would be
# comparing the source against itself. Those are marked "=source".
set -uo pipefail
cd "$(dirname "$0")"
: "${CAT:=../config/apps.json}"
: "${OUT:=certs/PROVENANCE.tsv}"

c(){ [ -t 1 ] && printf '\033[%sm%s\033[0m\n' "$1" "$2" || printf '%s\n' "$2"; }
ok(){ c '1;32' " + $*"; }; warn(){ c '1;33' " ! $*" >&2; }
bad(){ c '1;31' " x $*" >&2; }; log(){ c '1;34' ":: $*"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# name|kind|catalog-source-it-equals|index URL
WITNESSES=(
  "izzyondroid|upstream||https://apt.izzysoft.de/fdroid/repo/index-v1.json"
  "guardianproject|upstream||https://guardianproject.info/fdroid/repo/index-v1.json"
  "bitwarden|upstream||https://mobileapp.bitwarden.com/fdroid/repo/index-v1.json"
  "molly|upstream||https://molly.im/fdroid/repo/index-v1.json"
  "fdroid|rebuild|fdroid|https://f-droid.org/repo/index-v1.json"
  "privacyguides|curated||https://raw.githubusercontent.com/privacyguides/verified-apps/main/data.yml"
)

# Fingerprints the vendor publishes on its own website. Not fetchable as an
# index, so they are written down here WITH the page that states them - check
# the page when you change a line. Several comma-separated fingerprints are
# allowed where a vendor documents more than one of its own keys: Signal names
# the current certificate and the older 1024-bit one, and a build signed with
# the old key is still Signal's, not a forgery.
declare -A PUBLISHED=(
  [org.thoughtcrime.securesms]="4be4f6cd5be844083e900279dc822af65a547fecc26aba7ff1f5203a45518cd8,29f34e5f27f211b424bc5bf9d67162c0eafba2da35af35c16416fc446276ba26|https://signal.org/android/apk/"
  [im.molly.app]="6aa80fdf4a8cc13737cfb434fc0cde486f09cf8fcda21a67bea5ee1ca2700886|https://github.com/mollyim/mollyim-android"
)

log "fetching witness indexes"
for w in "${WITNESSES[@]}"; do
  IFS='|' read -r name kind equals url <<<"$w"
  [ "$name" = "fdroid" ] && [ "${SKIP_FDROID:-0}" = "1" ] && { warn "fdroid skipped"; continue; }
  if curl -fsSL --max-time 300 "$url" -o "$WORK/$name.json"; then
    if [ "$kind" = "curated" ]; then
      # data.yml lists every certificate a third party has SEEN for a package,
      # one entry per distribution channel - so a package legitimately carries
      # several, e.g. the upstream build and F-Droid's rebuild.
      awk '
        /^  - package: /   { pkg=$3; next }
        /fingerprint:/     { if (match($0, /[0-9A-F]{2}(:[0-9A-F]{2}){31}/)) {
                               fp=substr($0, RSTART, RLENGTH); gsub(/:/,"",fp)
                               print pkg "\t" tolower(fp) } ; next }
        /^ +[0-9A-F]{2}(:[0-9A-F]{2}){31}$/ { fp=$0; gsub(/[: ]/,"",fp)
                               print pkg "\t" tolower(fp) }
      ' "$WORK/$name.json" > "$WORK/$name.tsv" 2>/dev/null \
        || { warn "$name: not parseable"; rm -f "$WORK/$name.tsv"; continue; }
    else
      jq -r '.packages | to_entries[] | "\(.key)\t\(.value[0].signer // "-")"' "$WORK/$name.json" \
        | tr 'A-Z' 'a-z' > "$WORK/$name.tsv" 2>/dev/null \
        || { warn "$name: index unreadable"; rm -f "$WORK/$name.tsv"; continue; }
    fi
    ok "$name: $(cut -f1 "$WORK/$name.tsv" | sort -u | wc -l) packages"
  else
    warn "$name: index not reachable - treated as no witness"
  fi
done

printf 'package\tverdict\tevidence\n' > "$OUT"
confirmed=0; tofu=0; alarm=0
for f in certs/*.cert; do
  [ -e "$f" ] || continue
  pkg="$(basename "$f" .cert)"
  pin="$(tr -d '[:space:]' < "$f" | tr 'A-Z' 'a-z')"
  src="$(jq -r --arg p "$pkg" '[.apps[]|select(.pkg==$p)|.source][0] // "own-build"' "$CAT")"
  evidence=(); verdict="tofu-only"

  # A fingerprint the vendor publishes itself outranks any repo below: it says
  # which keys are the vendor's own, and a repo shipping a DIFFERENT one of
  # those keys is then a different build of the same app, not an attack.
  published_ok=0; declare -a vendor_keys=()
  if [ -n "${PUBLISHED[$pkg]:-}" ]; then
    IFS='|' read -r want page <<<"${PUBLISHED[$pkg]}"
    IFS=',' read -r -a vendor_keys <<<"$want"
    for k in "${vendor_keys[@]}"; do [ "$k" = "$pin" ] && published_ok=1; done
    if [ "$published_ok" = 1 ]; then evidence+=("published:$page"); verdict="confirmed"
    else evidence+=("PUBLISHED-MISMATCH:$page"); verdict="CONTRADICTED"; fi
  fi

  for w in "${WITNESSES[@]}"; do
    IFS='|' read -r name kind equals url <<<"$w"
    [ -f "$WORK/$name.tsv" ] || continue
    mapfile -t seen_all < <(awk -F'\t' -v p="$pkg" '$1==p{print $2}' "$WORK/$name.tsv")
    [ "${#seen_all[@]}" -eq 0 ] && continue
    seen=""
    for cand in "${seen_all[@]}"; do [ "$cand" = "$pin" ] && seen="$cand"; done
    [ -z "$seen" ] && seen="${seen_all[0]}"
    if [ -n "$equals" ] && [ "$equals" = "$src" ]; then
      evidence+=("$name:=source"); continue      # comparing the source with itself
    fi
    if [ "$seen" = "$pin" ]; then
      evidence+=("$name:match"); [ "$verdict" = "tofu-only" ] && verdict="confirmed"
    elif [ "$kind" = "curated" ]; then
      # Knowing a DIFFERENT certificate is normal here (they may only have
      # looked at the F-Droid build, as with AusweisApp). It is never an alarm,
      # it simply is not corroboration of our binary.
      evidence+=("$name:other-channel-only")
    elif [ "$kind" = "upstream" ]; then
      # "upstream" is a property of the repo, not of every package in it: the
      # Guardian Project ships Tor's own builds AND a Signal build signed with
      # Signal's older certificate. So a mismatch is only an alarm while no
      # vendor-published key explains it.
      other=""
      for k in "${vendor_keys[@]:-}"; do [ "$k" = "$seen" ] && other="vendor-key"; done
      if [ -n "$other" ]; then evidence+=("$name:other-vendor-key")
      elif [ "$published_ok" = 1 ]; then evidence+=("$name:foreign-build")
      else evidence+=("$name:MISMATCH"); verdict="CONTRADICTED"; fi
    else
      evidence+=("$name:inconclusive")           # rebuilt and signed by the repo
    fi
  done

  printf '%s\t%s\t%s\n' "$pkg" "$verdict" "$(IFS=,; echo "${evidence[*]:-none}")" >> "$OUT"
  case "$verdict" in
    confirmed)    confirmed=$((confirmed+1)); ok "$pkg: $verdict ($(IFS=,; echo "${evidence[*]}"))" ;;
    CONTRADICTED) alarm=$((alarm+1)); bad "$pkg: $verdict ($(IFS=,; echo "${evidence[*]}"))" ;;
    *)            tofu=$((tofu+1)) ;;
  esac
done

printf '\n'
log "$confirmed confirmed, $tofu on trust-on-first-use only, $alarm contradicted -> $OUT"
[ "$alarm" -eq 0 ] || { bad "a witness that ships the developer's own binary disagrees - do not ignore this"; exit 1; }
exit 0
