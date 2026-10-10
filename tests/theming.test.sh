#!/usr/bin/env bash
# Cases for what 40-theming.sh records: a zone whose theme took is cleared
# from the host's pending list; a zone where any part failed - a setting, the
# HOME role, the keyboard - keeps it pending and fails the step. Run whole
# against a fake adb that answers settings, roles and IMEs from files.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
dev=fake-theming
cleanup() { rm -rf "$tmp" "$root/.provision-state/pending/$dev"; }
trap cleanup EXIT; cleanup; mkdir -p "$tmp/bin"
pass=0; fail=0
t() { if eval "$2"; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
      else printf '  FAIL  %s\n' "$1"; sed 's/^/        | /' "$tmp/out"; fail=$((fail+1)); fi; }

# The fake device: FAKE/settings ("uid ns key=value"), FAKE/roles ("uid role pkg").
# FAKE_DENY names what refuses to change: a settings key, "home", "ime".
cat > "$tmp/bin/adb" <<'FAKE'
#!/usr/bin/env bash
D="$FAKE"; [ "$1" = -s ] && shift 2
[ "$1" = devices ] && { printf 'List of devices attached\nfake\tdevice\n'; exit 0; }
[ "$1" = shell ] || exit 97; shift; set -- $*
deny() { case " ${FAKE_DENY:-} " in *" $1 "*) return 0;; esac; return 1; }
case "$1 $2" in
  "am get-current-user") echo 0;;
  "pm list") case "$3" in
      users) printf 'Users:\n\tUserInfo{0:Owner:c13} running\n';;
      packages) printf 'package:org.andashi.home\npackage:helium314.keyboard\n';;
    esac;;
  "settings --user")
    u="$3"; op="$4"; ns="$5"; k="$6"
    if [ "$op" = get ]; then awk -v p="$u $ns $k=" 'index($0,p)==1{print substr($0,length(p)+1)}' "$D/settings" 2>/dev/null
    else deny "$k" && exit 1; grep -v "^$u $ns $k=" "$D/settings" > "$D/s.new" 2>/dev/null; echo "$u $ns $k=$7" >> "$D/s.new"; mv "$D/s.new" "$D/settings"; fi;;
  "cmd role")
    if [ "$3" = get-role-holders ]; then awk -v u="$5" -v r="$6" '$1==u && $2==r {print $3}' "$D/roles" 2>/dev/null
    else deny home || echo "$5 $6 $7" >> "$D/roles"; fi;;
  "ime list") echo "helium314.keyboard/.LatinIME";;
  "ime enable") :;;
  "ime set") deny ime && exit 1; echo "0 secure default_input_method=$5" >> "$D/settings";;
  "cmd uimode"|"am force-stop"|"am start-user") :;;
  *) echo "fake adb: unexpected: $*" >&2; exit 97;;
esac
FAKE
chmod +x "$tmp/bin/adb"

export ADB="$tmp/bin/adb" ADB_SERIAL="$dev" FAKE="$tmp/dev" CONFIG_DIR="$tmp/config" DRY_RUN=0
fresh() {
  rm -rf "${tmp:?}/dev" "${CONFIG_DIR:?}" "$root/.provision-state/pending/$dev"; mkdir -p "$tmp/dev" "$CONFIG_DIR"
  echo '{"profiles": [{"key": "home", "label": "Home", "create": false, "user_id": 0}]}' > "$CONFIG_DIR/profiles.json"
  echo '{"features": {}}' > "$CONFIG_DIR/features.json"
  cat > "$CONFIG_DIR/theming.json" <<'JSON'
{"launcher": "andashi-home", "launchers": {"andashi-home": {"pkg": "org.andashi.home"}},
 "keyboard_pkg": "helium314.keyboard", "global": {"window_animation_scale": "0.7"},
 "all_profiles": {"night": "2"}, "per_profile": {"home": {}}}
JSON
  # A theme that is owed from an earlier run.
  mkdir -p "$root/.provision-state/pending"; echo "home theme" > "$root/.provision-state/pending/$dev"
}
run() { "$root/provision/40-theming.sh" > "$tmp/out" 2>&1; }
owed() { grep -qx "home theme" "$root/.provision-state/pending/$dev" 2>/dev/null; }

fresh; run
t "everything took: success, and the owed theme is cleared" '[ $? = 0 ] && ! owed'
fresh; FAKE_DENY=ui_night_mode run
t "a setting refused: the step fails, naming the zone"      '[ $? != 0 ] && grep -q "theming did not fully take in: Home" "$tmp/out"'
t "... and the theme stays owed"                            'owed'
fresh; FAKE_DENY=home run
t "the HOME role refused: fails, stays owed"                '[ $? != 0 ] && owed && grep -q "HOME role could not be set" "$tmp/out"'
fresh; FAKE_DENY=ime run
t "the keyboard refused: fails, stays owed"                 '[ $? != 0 ] && owed && grep -q "IME could not be set" "$tmp/out"'
fresh; FAKE_DENY=window_animation_scale run
t "a device-wide setting refused: fails, named as such"     '[ $? != 0 ] && grep -q "device-wide animation scales" "$tmp/out"'
t "... and every zone keeps its theme owed, so the next apply retries it" 'owed'

printf '\n  %d ok, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
