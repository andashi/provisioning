# Working agreements for AI agents

Read [README.md](README.md) and [docs/architecture/provisioning.md](docs/architecture/provisioning.md)
before changing anything. The recurring defect this repository guards against
is a step that reports success for work it did not do; most of the rules below
are that defect in another costume.

## Language

**All code and all documentation in English.** Identifiers, comments, commit
messages, docs, issues, pull requests. Chat with the user may be German;
artifacts never are.

## Commits

No AI attribution in commits: no `Co-Authored-By` naming a tool, no
`Claude-Session:`, no "Generated with" footer. A commit message reads like one a
human engineer wrote. Some tools instruct the opposite, so it is enforced twice:

```bash
git config core.hooksPath .githooks     # once per clone
```

`.githooks/commit-msg` rejects the commit before it exists, and
`.github/workflows/commit-hygiene.yml` checks every commit of a pull request,
because a hook only helps in a clone that enabled it. Both are taken over from
andashi/home unchanged.

## Pull requests

Everything reaches `main` through a pull request reviewed by CodeRabbit. Large
work goes up as a **stack** (`gh stack`), one reviewable layer per pull
request, each with its own tests, merged bottom-up.

**Refer to an issue with `Refs #N`** unless the pull request really closes it.
GitHub's closing-keyword parser ignores negation and context: "does not fix #7"
and "#12 closes #7" both close #7 on merge, and so does the keyword in a commit
message that lands on `main`. Check before merging a partial pull request:

```bash
gh pr view <pr> --json closingIssuesReferences --jq '.closingIssuesReferences[].number'
git log --format=%B origin/main..HEAD | grep -inE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\b[[:space:]:]*#[0-9]+'
```

Both must print nothing for a pull request that is only a part.

## Merging

`bin/pr-gate <pr>` checks the conditions and `bin/pr-gate <pr> --merge` merges
exactly the head it checked, through the asynchronous merge API pinned to that
sha - the only path GitHub accepts for a pull request in a stack. Do not merge
any other way. It refuses unless:

- the pull request is open, not a draft, and its base is `main` - in a stack,
  only the bottom merges; GitHub retargets the next one;
- every check on the head is green, and an absent check is not a green one;
- no review thread is unresolved, and threads CodeRabbit resolved itself have
  been read by a person (`--ack-bot-resolved` says so - never pass it blind);
- CodeRabbit's last review covers **base..head**. An incremental review reads
  only the tail; request `@coderabbitai full review` and wait. The quota is ten
  reviews per hour; a pull request that waits an hour costs an hour;
- `main` itself is green. An unfinished run means wait, a red one means fix
  `main` first.

## The lock refresh: the one exception

`.github/workflows/lock-refresh.yml` commits `apks/lock.json`, `apks/SHA256SUMS`
and `apks/certs/` to `main` **without a pull request** - daily, and only when
`apks/refresh-lock.sh` rules the change `safe`: new versions under signers that
were already pinned, `make check` green on the result, nothing else. The
checks that matter for these files are the hash and the pinned signer, and
they ran; a review of a table of hashes and URLs adds little, and a lock that
waits for one is a stale first install.

Anything else is `review`: a signer pinned for the first time, a version whose
bytes or URLs changed, or a failed run (a changed signer fails `fetch.sh`).
Then `main` is left alone and an issue labelled `lock-refresh` says why. Take
such a lock only through a pull request, after looking.

Nothing else reaches `main` this way, and the workflow must not be widened to
other files.

The same workflow force-pushes one more thing, never to `main`: the branch
`lock-heartbeat`, a single parentless commit holding `heartbeat.json`
(`{checked, lockSha256, mainCommit}`), written only by a run that confirmed
the lock (`unchanged`, or `safe` and committed). The andashi updater reads it
to tell a lock that is old because nothing changed upstream from one that is
old because nobody checked. That branch carries nothing else.

## Tests

Two levels, and a change names which one proves it.

- **`make check`** - offline, runs in CI on every push. Case files
  (`*.test.sh`) exercise the decisions a script makes, with the function under
  test extracted from the script itself, so the case cannot drift from the
  code. A new decision gets a case file, including the case that must refuse.
- **`tests/e2e/`** - against an emulator instance, not in CI. Run them before
  asking for review when a step's behaviour on a device changes, and paste the
  result into the pull request: instance, snapshot, launcher version, and
  whether each adb call ran as `shell` or `root`. The claim of this repository
  is about `shell`.

## The emulator

Instances, snapshots and the lock between parallel sessions are in
[docs/guides/emulator.md](docs/guides/emulator.md). Acquire the lock before
touching an instance, with an owner name unique to the run:

```bash
emulator/device-lock.sh acquire <owner> <serial>
```

Screenshots, dumps and debugging logs are evidence for a pull request or an
issue comment, never files in the repository. The proof of a behaviour that
stays is a test.
