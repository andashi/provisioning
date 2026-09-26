# Does the launcher's effective config say what our file said?
#
# Called with --argjson eff <effective config> and --slurpfile want <file>,
# and prints the mismatching paths, comma separated, or nothing.
#
# It lives in its own file because provision/45-launcher-config.sh is not
# the only thing that needs it: lib/readback-compare.test.sh runs it against
# cases no device produces on demand - a swallowed favorite, a whole section
# missing, a release that added keys to every section at once. This logic was
# wrong twice on 2026-09-26, and both times a case would have said so.
def canon:
  # v1 -> v2 shape first, so a file we still generate as v1 can be compared
  # against a launcher that has already migrated it. That transition is the
  # normal state for a while: the contract is merged upstream but not in a
  # release, and 0.3.1 rejects a v2 document outright
  # ("unsupported-schema-version", measured 2026-09-22).
  (if (.home.dock.favorites // null) != null
     then .home.favorites = .home.dock.favorites else . end)
  | del(.home.dock)
  | del(.home.widgets.widgets)
  | (if ((.home.favorites // null) | type) == "array" then
     .home.favorites |= map(
       if type == "string" then { packageName: ., profile: "personal" }
       else { packageName: .packageName, profile: (.profile // "personal") }
       end)
   else . end)
  # Geometry is the DEVICE's to decide: the generator omits x/y/w/h, the
  # launcher places the item and writes the coordinates back (schema v2).
  # So compare what we declared - which items exist, in which layout, as
  # which widget - and leave where they sit to the device. Everything else
  # in the grid stays ours: a different column count, a flipped `locked`
  # or a swallowed item all remain mismatches.
  | (if ((.home.grid.layouts // null) | type) == "object" then
       .home.grid.layouts |= with_entries(
         .value.items |= map({ id: .id, widget: .widget, profile: (.profile // "personal"),
           # NOT geometry, so these are checked: they decide how the item
           # looks. An absent one is not unmanaged - the launcher stores
           # false/true/true and serves them back (andashi/home ADR 0002) -
           # so the same defaults are filled in on both sides, and a file
           # that omits them still compares equal while one that sets them
           # differently is verified. has() and not //, because false is a
           # value here.
           borderless:  (if has("borderless")  then .borderless  else false end),
           background:  (if has("background")  then .background  else true  end),
           themeColors: (if has("themeColors") then .themeColors else true  end) }))
     else . end);
# A grid only exists on one side while the generator still emits v1 - the
# launcher migrates and invents one. Comparing that would report a
# difference for something we never declared, so the grid is only compared
# when BOTH sides have one.
def drop_grid_if_one_sided($other):
  if (.home.grid // null) == null or ($other.home.grid // null) == null
    then del(.home.grid) else . end;
($want[0] | canon) as $w0
| ($eff | canon) as $e0
| ($w0 | drop_grid_if_one_sided($e0)) as $w
| ($e0 | drop_grid_if_one_sided($w0)) as $e
# ONE rule for every section: every value the file wrote must be what the
# launcher serves, and a key the file left out is the device's to keep.
# Objects are walked; anything else - a scalar, or an array like favorites
# or a layout's items - is a leaf and compared whole, so a swallowed
# favorite or a flipped `locked` is still reported.
#
# This replaces comparing schemaVersion, icons, appearance and home as
# whole sections, which broke every time the contract GREW. The read-back
# is fully populated with defaults - that is the launcher's contract,
# not an accident - so a release that adds one key to a section makes the
# whole section differ from a file that never claimed to set it. It
# happened twice in one day (andashi/home#181 adding icons.size, adaptify
# and badges; #189 adding home.searchBar.fixed, home.lockRotation and
# appearance.systemBars), and the search section had already been carved
# out for exactly this reason. One rule, no carve-outs.
#
# What this gives up: noticing that the contract grew. That is not drift
# and never was ours to report - a key we never wrote saying something we
# never asked for is the device being itself. What catches the real
# version-coupling failures is elsewhere and sharper: the launcher's
# own diagnostics for a key it ignores, and config/check-schema.sh for a
# key the contract no longer has.
# Walk objects, stop at anything else. NOT jq's paths(type != "object"):
# that also descends INTO arrays, so one swallowed favorite is reported as
# the array plus every field of the element that is no longer there -
# "home.favorites, home.favorites.0.packageName, home.favorites.0.profile"
# for a list that simply differs. An array is one value we declared.
| def written_leaves($p):
    if type == "object"
      then (to_entries[] | .key as $k | (.value | written_leaves($p + [$k])))
      else $p end;
  ( [ $w | written_leaves([]) ] as $leaves
    | [ $leaves[] as $p
        | select(($e | getpath($p)) != ($w | getpath($p)))
        | $p | map(tostring) | join(".") ] )
| join(", ")
