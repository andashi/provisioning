#!/usr/bin/env bash
# Cases for what bin/pr-gate does with the merged branch: delete it, but never
# while an open pull request still builds on it - deleting the base closes
# that pull request for good. delete_merged_branch is taken from the gate
# itself; gh is a function answering from a small model of the repository.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
t() { if eval "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1)); else printf '  FAIL  %s\n' "$1"; sed 's/^/        | /' "$tmp/out"; fail=$((fail+1)); fi; }
eval "$(sed -n '/^delete_merged_branch() {/,/^}/p' "$root/bin/pr-gate")"
declare -F delete_merged_branch >/dev/null || { echo "delete_merged_branch not found in bin/pr-gate" >&2; exit 1; }
REPO=andashi/provisioning

# The model: $tmp/base/<n> holds each open PR's base; $tmp/branches the
# branches that exist. HEADREPO is where the merged PR's head lives.
gh() {
  case "$1 $2" in
    "pr view")
      case "$*" in
        *headRefName*) echo layer-1;;
        *headRepository*) echo "${HEADREPO:-andashi/provisioning}";;
        *baseRefName*) cat "$tmp/base/$3";;
      esac;;
    "pr list")
      [ "${LIST_FAILS:-0}" = 1 ] && return 1
      for f in "$tmp"/base/*; do [ -f "$f" ] && [ "$(cat "$f")" = layer-1 ] && basename "$f"; done; return 0;;
    "pr edit")
      [ "${EDIT_NOOP:-0}" = 1 ] && return 0          # says nothing, changes nothing
      echo main > "$tmp/base/$3";;
    "api -X")
      echo "DELETE $4" >> "$tmp/log"; sed -i "\|^${4##*/}$|d" "$tmp/branches";;
    *) echo "unexpected gh $*" >&2; return 97;;
  esac
}
fresh() { rm -rf "$tmp/base"; mkdir -p "$tmp/base"; printf 'main\nlayer-1\nlayer-2\n' > "$tmp/branches"; : > "$tmp/log"; }
run() { delete_merged_branch 27 abcdef > "$tmp/out" 2>&1; }
has() { grep -qx "$1" "$tmp/branches"; }

fresh; run
t "nothing builds on it: deleted"                        '! has layer-1 && grep -q "deleted branch layer-1" "$tmp/out"'
fresh; echo layer-1 > "$tmp/base/28"; echo main > "$tmp/base/40"; run
t "the PR above is moved to main first"                  '[ "$(cat "$tmp/base/28")" = main ] && grep -q "retargeted #28 from layer-1 to main" "$tmp/out"'
t "... then the branch goes"                             '! has layer-1'
t "... and an unrelated PR is not touched"               '! grep -q "#40" "$tmp/out"'
fresh; echo layer-1 > "$tmp/base/28"; EDIT_NOOP=1 run
t "a retarget that did not take: branch kept, PR named"  'has layer-1 && grep -q "#28 still build on layer-1 - branch kept" "$tmp/out" && [ ! -s "$tmp/log" ]'
fresh; echo layer-1 > "$tmp/base/28"; LIST_FAILS=1 run
t "the dependents cannot be listed: branch kept"         'has layer-1 && grep -q "could not list" "$tmp/out"'
fresh; HEADREPO=someone/fork run
t "a fork's branch: nothing deleted here"                'has layer-1 && grep -q "lives in someone/fork" "$tmp/out"'

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
