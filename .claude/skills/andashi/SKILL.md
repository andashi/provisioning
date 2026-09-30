---
name: andashi
description: Change what an andashi phone runs - put an app into a zone, take it out, change a zone's look - by editing the catalog through bin/andashi and committing. Use for any request like "add X to Lab", "remove Y from Home", "make Cloud's glass darker". Never touches the phone.
---

# Changing the phone through the catalog

The phone is described by the catalog in `CONFIG_DIR` (this repository's
`config/` is a template; a real phone has its own catalog). You change the
catalog. A person applies it to the phone. You never call `adb`, never run
`provision/*.sh`, never run `andashi apply`: the door to the phone is the
person's, and a change they have not seen is a change they cannot refuse.

## The loop

1. **Edit** with the commands below, not by hand-editing JSON. They put the
   change exactly where it belongs, run the same checks as `make check`, and
   take the change back if a check refuses it.
2. **Check**: `make check` for the template, or the command's own output
   ("catalog checks pass") for a private catalog.
3. **Review** your own diff: `git diff` in the catalog. One request, one small
   diff; nothing else changed.
4. **Commit** with a message that says what changed and why, and no AI
   attribution (AGENTS.md; a hook rejects it).
5. **Tell the person** what to run: `andashi diff`, then `andashi apply`.

## Commands

```bash
bin/andashi app add <id> --zone <zone>        # place a catalog app in a zone
bin/andashi app rm  <id> --zone <zone>        # take it out; apply removes it there
bin/andashi theme set <key> <value> --zone <zone>   # e.g. glass.tint 0.3
bin/andashi theme set <key> <value>                 # all zones (all_profiles)
```

- `<id>` is the `id` field in `apps.json` (`jq -r '.apps[].id' config/apps.json`).
  An app that is not in the catalog needs its own entry first - package name,
  source, `net` - and that is a decision for the person, not a command.
- Zones: `jq -r '.profiles[].key' config/profiles.json`. `current` needs a
  phone and is refused here.
- Values that parse as JSON are JSON (`0.3`, `true`); anything else is a string.

## What the checks refuse, and why

- A sandboxed-Play app in a zone whose `play` is `none` (Home, Anon, Ops).
- A second zone besides Home with `runtime: always` - Android runs three users.
- An app with `net: false` that grants itself `INTERNET`.
- A launcher key the generator or the launcher's schema does not know.

A refusal is an answer. Report it with the check's own sentence; do not work
around it by editing the file directly.

## Example: "put Bitwarden into Lab"

```bash
bin/andashi app add bitwarden --zone lab
git diff -- config/apps.json          # one list gained "lab"
git commit -am "Bitwarden in Lab, so test accounts come from the vault"
```
Then: "Run `andashi diff` and `andashi apply --zone lab` when the phone is connected."
