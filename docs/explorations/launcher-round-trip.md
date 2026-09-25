# Getting a device edit back into the source

**Status:** decided 2026-09-25 — **neither shape** ([provisioning#11](https://github.com/andashi/provisioning/issues/11)).
The two below are kept because the record of a wrong premise is worth more than
a menu; what was actually decided is at the end.

The launcher writes every managed section back into its own `launcher.json` as
soon as somebody changes it on the device (andashi/home D2, no switch, present
keys only). Our guard then refuses the next push, `--pull` brings the file into
the catalog, and `gen-launcher.sh` rebuilds it from `theming.json` — which is
where the edit dies. Since `df5ec3b` the generator halts instead of overwriting
silently, so nothing is lost today; what is missing is the way back.

This is not "how do we store a config". Both shapes below work. The question is
**which file a person edits afterwards**, and that is a maintenance decision.

## What actually has to travel

Everything we write, because everything we write can now be changed on the
device. Today, per zone:

| Key | Source today | Has a source vocabulary? |
|---|---|---|
| `home.favorites` | `theming.json` → `per_profile.<zone>.favorites`, as catalog **labels** | yes |
| `icons.*`, `appearance.glass.*` | `theming.json` (glass values) and the generator | yes |
| `appearance.wallpaper` | `theming.json` → a repo path | yes |
| `home.searchBar.position`, `home.grid.columns/locked/labels` | the generator, one value for all zones | no, but trivially addable |
| `home.grid.layouts.*.items[].x/y/w/h` | the generator, hard-coded per form factor | **no** |

The last row is the hard one, and it is hard for a reason that is easy to miss:
**geometry is not a property of a zone, it is a property of a zone on a device.**
Commit `544df48` is the proof. The Fold's dock used to be a full-width bottom row
(`x 0, y 6, w 8, h 1`); with andashi/home#93 the cover became columns 4–7 of the
fold layout, a full-width row started crossing the fold, and the dock became a
right-edge column (`x 7, y 0, w 1, h 7`). The phone kept its bottom row. One
catalog, two form factors, two different arrangements — and a third when the row
count of the next device differs.

## Shape A — back into the source vocabulary

`--pull` translates what it finds into the words `theming.json` already uses and
writes that file. For favourites the translation exists and is the reverse of
what the generator does:

```jsonc
// config/theming.json, after somebody pinned Signal on the device
"per_profile": {
  "home": {
    "palette": "D8DEE9",
    "style": "MONOCHROMATIC",
    "wallpaper": "themes/synthwave/{aspect}/home.jpg",
    "favorites": ["Phone", "Vanadium", "Signal"]   // <- Signal arrived from the device
  }
}
```

The generator resolves labels to package names against the catalog; the pull
resolves package names back to labels. One source of truth, and the file a person
edits stays the file a person reads.

**What it costs.** A package the catalog does not know — an app installed by hand
on the device — has no label to translate into, so the pull either refuses or
writes a raw package name and the file starts speaking two vocabularies. And for
geometry there is nothing to translate into: giving `theming.json` an `x/y/w/h`
per layout means **this repository growing a second copy of the launcher's
schema**, maintained by us, drifting on its own schedule, with no test that keeps
the two in step. That is the argument that decides it. `theming.json` should
never learn what a grid cell is.

## Shape B — a per-zone overlay the generator merges

The pull writes a separate file that carries only what came from the device, and
the generator merges it over what it builds:

```jsonc
// config/launcher-overrides/pixel-fold/home.json
{
  "home": {
    "grid": {
      "layouts": {
        "fold": { "items": [ { "id": "favorites", "x": 7, "y": 0, "w": 1, "h": 7 } ] }
      }
    }
  }
}
```

`gen-launcher.sh` builds from `theming.json` as today, then applies the overlay —
keys the overlay names win, keys it omits stay generated. Nothing has to be
translated, so anything the launcher can write can come back.

**What it costs.** Two files can set the same key, and the overlay silently wins.
That is precisely the failure mode this repository keeps running into: a value
changed in the obvious place has no effect, and nothing says why. It needs a
counter-measure — `make check` listing which keys an overlay is shadowing, so the
shadowing is visible in every run rather than discovered.

Note the path above: `pixel-fold/`. Because geometry belongs to a device and not
to a zone, an overlay that is not device-scoped would carry a Fold's column into
a phone. That is not a complication of shape B, it is the truth shape A cannot
express at all.

## What I would do

**Split by whether a source vocabulary exists.**

- Favourites, wallpaper, palette, glass values → **shape A**. They are decisions
  about a zone, `theming.json` already says them in human words, and a round trip
  that lands there keeps one source of truth. A package the catalog does not know
  is a signal to add it to the catalog, so the pull refuses and says so.
- Grid geometry → **shape B**, device-scoped. It is the arrangement of one screen
  on one device, it changes when the launcher changes (`544df48`), and the
  alternative is maintaining a copy of somebody else's schema.

The cost of the split is that a person has two places to look. The cost of not
splitting is either a schema copy (A for everything) or a shadowing overlay for
values that have a perfectly good home already (B for everything).

## Still open

- Does the overlay need a per-device dimension from the start, or is one file per
  zone enough until a second device exists? The first real device is still ahead,
  and `544df48` shows the Fold and the phone already disagree.
- What `--pull` does when both would apply: an edit to a favourite and a moved
  widget arrive in the same file and would be split across two destinations.
- Whether `make check` should fail or merely report when an overlay shadows a
  generated key.

## What was decided, and why neither shape was taken

`per_profile.<zone>.layouts.{phone,fold}` in `theming.json`, holding the grid
block **exactly as `launcher.json` carries it**. The generator copies it through
instead of inventing it, `--pull` writes what the device had straight back into
that field, and there is no second file.

Two things collapsed when Dob looked at the premise rather than the options.

**The device dimension was speculative.** I scoped the overlay by device because
the Fold and a phone disagree — and they do, `544df48` shows it. But the
generator already emits one layout per *form factor*, `phone` and `fold`, which
is what that disagreement actually needs. A path like
`launcher-overrides/pixel-fold/home.json` only earns its keep with two devices of
the **same** form factor and different row counts. Nobody has that; there is not
even one device yet. I had designed for a fleet that does not exist, and
presented it as a choice instead of noticing.

**Shape A's fatal cost was in the translation, not in the file.** My objection
was that `theming.json` would grow a second copy of the launcher's schema — true
of a translated grid, false of a verbatim one. Carried through untouched, the
field is opaque here: a grid feature the launcher gains later passes through
without this repository learning anything about it, and there is nothing to keep
in step because nothing was copied.

What survives from the shapes above is the reasoning, not the structures: geometry
belongs to a device and not to a zone, and that is why it lives in per-form-factor
layouts rather than in one arrangement per zone. It just turns out to be data in a
file instead of a decision in a script.

The consequence to watch: a verbatim field means a malformed or stale block is
caught by the launcher at push time, not by `make check`. That is the price of not
having a schema here, and it is the right price — the alternative is the second
copy.
