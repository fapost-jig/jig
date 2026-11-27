---
id: convention-parity
type: convention
status: active
domains: []
paths:
  - tests/lib/parity.sh
  - tests/parity.t.sh
  - "tests/parity/**"
summary: "How to check a port against the recordings with tests/lib/parity.sh: recording first, the <JIG_HOME>/ port form, what is compared, the report, exit codes, and the intended-differences list."
reviewed_at: 2026-11-27
---
# Checking a port against the recordings: `tests/lib/parity.sh check`

How a port of a command (TypeScript, Go, any program) is proven against what the bash Jig did. The
decisions behind it are in `adr-20261127-ports-are-checked-by-replaying-recordings-in-place`; what it
reads is `conventions/recordings.md`.

## Practice

**Record, then check, on one machine, with the same checkout.** A recording does not name the revision
it was taken from, and its world's `JIG_HOME` is rebuilt from `--home` (default: this checkout).
Recordings stay out of git, so take them again before a check:

```
JIG_TEST_JOBS=3 JIG_RECORD=<dir> tests/run.sh <file>::<test> ...
tests/lib/parity.sh check --recordings <dir> --port '<JIG_HOME>/scripts/jig-next-ts' --name ts \
  --command <word> [--report <out>]
```

- `--port` is the program run with the recorded arguments. A path beginning with the literal
  `<JIG_HOME>/` is taken inside each call's world `JIG_HOME`, the release copy the bash call ran from;
  that is the form to use for anything that names its own checkout (`--version`), and
  `--port '<JIG_HOME>/scripts/jig'` is the self-check of the harness: it must give no difference.
- A program that needs something the recording lacks gets it with `--port-env NAME=VALUE` (the built
  Go binary needs `JIG_NEXT_ROOT`). Build a compiled port before the check, never inside a replay: the
  replay's `HOME` is the test's directory, and a build cache there would be a change of the call.
- Select with `--command <word>` (the call's first argument) and `<file>::<test>` / `<file>::` filters.
- Calls replay one at a time, at the paths they were recorded on; a path that exists is an `ERROR`, never
  overwritten. Do not run a check while the test run that recorded it is still going, nor two checks of
  one recording at once: nothing refuses the second, and the first removes the `JIG_HOME` it built under it.
- A `JIG_HOME` that already exists as a framework copy is used as it is, not built from `--home`; the
  report's `note` line names it. An existing fixture cache (`<CACHE>`) is used as it is too.
- `--report` takes an absent or empty directory and refuses any other.

**Format.** The check reads `jig-recording 2` and refuses any other `FORMAT` (exit 2). A view of a
changed file is named by its `norm/files/` name, `files/_T_/repo/a` for `<T>/repo/a`, in the report,
the `--report` file names and the `view` field of the intended list.

**What is compared**: the exit code, `norm/stdout`, `norm/stderr`, `norm/changes`, `norm/git.after` and
`norm/files/**` both ways, byte for byte, after the replay's `tree.before` and `norm/git.before` matched
the recording's. A stream the recorded call sent to a file inside its world (found as the one changed
file whose new content is its old content plus the stream) is sent to the same file again.

**The report** is one line per call — `ok`, `DIFF <views>`, `intended <view: entry line — reason>`,
`skip <reason>`, `ERROR <reason>` — then `stale` lines and the summary
`parity: N calls selected: a equal, b intended, c differ, d skipped, e errors; s stale entries`. With
`--report <out>` each call with a difference or error keeps `<out>/<file>/<test>/<NNNN>/` with one
`<view>.diff` per view and the replay's call directory.

**Exit**: `0` everything compared is equal or intended, with at least one call compared; `1` a
difference, a replay error, a stale entry, or nothing compared (skips alone prove nothing); `2` usage,
including a list entry without a reason.

**Skipped, never passed**: `concurrent=yes`, `recorder_error`, `stdin=tty`, `clock=real`, a fifo or
socket in the tree.

**Intended differences** live in `tests/parity/intended.tsv`, one list for every port: five TAB-separated
fields `port calls view lines reason` (format in the file's header). An entry is as narrow as the
difference: a port name rather than `*`, a call glob rather than `*/*/*`, a `lines` pattern every
changed line must match rather than `-`. Its reason says why the new behaviour is the right one, not
that it differs. An entry that covers nothing in a run that compared its calls is stale and fails the
run: remove it with the change that made it unnecessary. The count of intended differences in the
summary is the measure the spec uses to judge whether normalised recordings still prove parity.

## Example

```
$ tests/lib/parity.sh check --recordings /tmp/rec --port '<JIG_HOME>/scripts/jig-next-ts' --name ts
ok       dispatcher/test_version_prints_semver/0001
ok       dispatcher/test_version_rejects_an_unknown_option/0001

parity: 2 calls selected: 2 equal, 0 intended, 0 differ, 0 skipped, 0 errors; 0 stale entries
```

## Rationale

Replaying at the recorded paths keeps every input byte as it was, the paths inside the world's files
included, so nothing is rewritten and nothing has to be trusted besides the recorder. Running the port
under the recorder gives both sides the same views from the same code. A difference is either the
port's or the list's, with its reason, and a list that cannot go stale keeps that count honest.

**Known limits.** The world's `JIG_HOME` is built by a copy of `tests/run.sh`'s `_run_release_home`:
a change to one is made in the other, or the self-check differs. Restoring a world is one
`git update-index` and one `git checkout-index` per call, but the recorder's two
snapshots still cost about 2–3 s per call on a world of a few hundred files: check a slice, not the
whole suite.
