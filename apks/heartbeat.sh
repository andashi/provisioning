#!/usr/bin/env bash
# Writes the lock heartbeat: one parentless commit holding heartbeat.json,
# {checked, lockSha256, mainCommit}, force-pushed to its branch. Run by the
# lock refresh for a commit whose lock it has just confirmed
# (.github/workflows/lock-refresh.yml).
#
#   apks/heartbeat.sh <commit> <target>        target: the branch the lock is on
#
# The branch is lock-heartbeat for main, lock-heartbeat-<target> for any
# other target, so a test run never overwrites the heartbeat phones read.
# The commit is built from objects in this repository with commit-tree: it is
# pushed with this checkout's credentials, and the work tree is not touched.
# REMOTE (default origin) and NOW (default the clock) exist for the cases.
set -euo pipefail
commit="${1:?usage: heartbeat.sh <commit> <target>}"; target="${2:?usage: heartbeat.sh <commit> <target>}"
: "${REMOTE:=origin}"
git cat-file -e "$commit^{commit}" 2>/dev/null || { echo "heartbeat: $commit is not a commit here" >&2; exit 1; }
git cat-file -e "$commit:apks/lock.json" 2>/dev/null || { echo "heartbeat: $commit has no apks/lock.json" >&2; exit 1; }
branch=lock-heartbeat
[ "$target" = main ] || branch="lock-heartbeat-$target"

full="$(git rev-parse "$commit^{commit}")"
sha="$(git cat-file blob "$commit:apks/lock.json" | sha256sum | cut -d' ' -f1)"
now="${NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
file="$(mktemp)"; trap 'rm -f "$file"' EXIT
jq -n --arg checked "$now" --arg sha "$sha" --arg commit "$full" \
  '{checked: $checked, lockSha256: $sha, mainCommit: $commit}' > "$file"
blob="$(git hash-object -w "$file")"
tree="$(printf '100644 blob %s\theartbeat.json\n' "$blob" | git mktree)"
hb="$(GIT_AUTHOR_NAME="andashi lock refresh" GIT_AUTHOR_EMAIL=lock-refresh@users.noreply.github.com \
      GIT_COMMITTER_NAME="andashi lock refresh" GIT_COMMITTER_EMAIL=lock-refresh@users.noreply.github.com \
      git commit-tree "$tree" -m "Lock heartbeat ${now%%T*}")"
git push -q --force "$REMOTE" "$hb:refs/heads/$branch"
echo "heartbeat on $branch for ${full:0:12}, lock ${sha:0:12}"
