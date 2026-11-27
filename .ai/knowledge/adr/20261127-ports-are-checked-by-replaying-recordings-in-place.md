---
id: adr-20261127-ports-are-checked-by-replaying-recordings-in-place
type: adr
status: accepted
date: 2026-11-27
domains: []
paths:
  - tests/lib/parity.sh
  - "tests/parity/**"
summary: Why tests/lib/parity.sh replays each recorded call at its original paths under the recorder itself, what counts as equal, and why intended differences are one committed list whose stale entries fail.
reviewed_at: 2026-11-27
---
# A port is checked by replaying each recorded call in place, under the recorder itself, against a committed list of intended differences

## Context

The stack migration proves every port against what the bash code did
(`adr-20261126-jig-1-0-is-rewritten-off-bash-and-the-pilot-picks-the-language`, Parity: "equality is
by meaning after normalisation, with a written list of intended differences, each with its reason").
The recorder (`adr-20261126-bash-tests-are-recorded-for-parity`, `conventions/recordings.md`) keeps,
for every outermost `jig` call of the bash tests, the raw call and its normalised views. Something has
to run a port on those calls and say where it differs. Three facts shape it:

- every path in a recording is absolute and points into the test's directory, `$RESULTS/test.XXXXXX`,
  which `tests/run.sh` removed after the test — and those paths are also inside the files of the world
  (stub scripts name their log files, linked worktrees name their git directories);
- the world's `JIG_HOME` is the run's release copy, `$RESULTS/home`, which is in no tree;
- the comparison is only as good as the normaliser, and there is one: the recorder's.

## Decision

- **Replay in place.** `tests/lib/parity.sh check` recreates the recorded world at its original
  paths — `<T>` and every `<T>.*` from `tree.before`, files from `store.git` — so `argv`, `cwd`, `env`,
  `stdin` and the contents of the world are the recorded bytes, unchanged. A path that exists is never
  reused or overwritten: the call is a replay error. Calls replay one at a time, and the tool removes
  only what it created.
- **The world's `JIG_HOME`** is built once per run at its original path as a release copy of the
  checkout under test (`--home`), as `tests/run.sh` builds it. A framework copy already at that path
  (it holds `scripts/jig`: a test run that is still going, or a check of the suite from inside a test)
  is used as it is and never removed, and the report says so with a `note` line, because the check then
  runs against that copy and not against `--home`. Any other existing path is a replay error. The
  fixture cache `<CACHE>` is the same kind of shared path: an existing one is used as it is, an absent
  one is made empty for the call, so that the recorder finds the directory it names, and removed after it.
- **The report goes into a directory of its own**: `--report` refuses a directory that holds anything,
  and nothing in it is replaced.
- **The port runs under the recorder.** A bash shim that `exec`s the port is recorded by
  `recorder.sh record` into a replay directory with the recorded environment (`env -i` plus `env`),
  so the port's views are made by the same snapshot and the same normaliser as the recording. The
  recorder is not changed for it.
- **The restore is checked before outputs are compared**: the replay's `tree.before` and
  `norm/git.before` must equal the recording's, and a call the recorder did not record is an error,
  never a pass.
- **Equal means** the same exit code and byte-equal `norm/stdout`, `norm/stderr`, `norm/changes`,
  `norm/git.after` and `norm/files/**` (both ways). The inputs (`argv`, `cwd`, `env`) are not compared.
  Commit ids are numbered by first appearance on both sides, which is the convention's "numbered
  against `shas`" as long as `git.before` matches.
- **Intended differences** are one committed file for every port, `tests/parity/intended.tsv`: port,
  call glob, view, a pattern every changed line must match, and a reason that may not be empty. The
  report names the entry behind each intended difference and counts them. An entry that matched
  compared calls but covered no difference is stale and fails the run.
- **Nothing proven is not a pass**: a skipped call (`concurrent=yes`, `recorder_error`, `stdin=tty`,
  `clock=real`, a fifo or socket in the tree) is counted apart, and a run that compared no call exits 1.

## Alternatives

- Relocating the world under a fresh directory and rewriting paths through `subst` — the paths are
  also inside files (stubs, worktree links, `.ai/scripts` links), so every file of the world would have
  to be rewritten, and the rewriting would be a second normaliser to trust.
- A snapshot and normaliser of parity-check's own — two implementations of the same views drift, and
  a difference between them would read as a difference of the port.
- A `--exec` option in the recorder instead of the shim — changes a tool whose format is frozen for
  something a three-line script does.
- One list of intended differences per port — a difference is nearly always the same in both
  languages, and the pilot compares them fairer when one list judges both.
- Letting stale entries pass with a warning — the list then only grows, and its count, which the spec
  uses to test whether normalised recordings still prove parity, stops meaning anything.

## Consequences

- Recordings are taken again before a check: a recording does not name the revision it came from, and
  a `--home` that moved on can show a difference that is not the port's.
- A check cannot run while the recorded world's paths exist. Two checks of one recording at once are
  not refused — the second takes the first's `JIG_HOME` for a live copy, and the first's cleanup removes
  it under the second — so a person or an agent never starts them together.
- Restoring a world is one `git update-index` and one `git checkout-index` per call (a `.git` path
  component is written under a reserved name and renamed back); the recorder's two snapshots remain the
  larger cost, about 2–3 s per call on a world of a few hundred files.
- The check reads `jig-recording 2` only, and names the view of a changed file by its NTFS-safe
  `norm/files/` name (`files/_T_/repo/a`); a recording of another format is refused and taken again.
  A change of the format moves the check with it, in the same task.
