---
id: convention-recordings
type: convention
status: active
domains: []
paths:
  - tests/lib/recorder.sh
  - tests/recorder.t.sh
summary: "The jig-recording 1 format tests/run.sh writes under JIG_RECORD: call directories, raw fields, the blob store, git by meaning, and the normalisation parity-check must apply to a port's output."
---
# Recordings of the bash tests: format `jig-recording 1`

What `JIG_RECORD=<dir> tests/run.sh [filters]` writes, and what `parity-check` and every port read.
The writer is `tests/lib/recorder.sh`; the decisions behind it are in
`adr-20261126-bash-tests-are-recorded-for-parity`. A change to anything below raises the number in
`FORMAT` and is made in the recorder, its tests and this page together.

## Practice

**Layout.**

```
<dir>/FORMAT                       "jig-recording 1\n"; a run refuses a directory with another
<dir>/store.git/                   bare git repository: every file's content as a blob (`git cat-file blob <id>`)
<dir>/calls/<file>/<test>/<NNNN>/  one outermost jig call; <file> without .t.sh, NNNN from 0001 in call order
```

A test recorded again replaces its `calls/<file>/<test>/` whole. Only the outermost call is recorded
(the recorder runs jig with `JIG_RECORDING` set, and the hook in `scripts/jig` then does nothing), and
only a call whose working directory is the test's directory (`$JIG_TEST_TMP`) or one beside it.

**A call's directory.** Lists are records terminated by NUL; fields in a record are separated by TAB
and the path is always the last field, so it may hold TAB and newline. Names are raw bytes.

| File | Holds |
|---|---|
| `meta` | `key=value` lines: `format=1`, `test`, `seq`, `exit`, `streams=separate\|merged`, `stdin=none\|data\|tty`, `clock=pinned\|real`, `concurrent=yes\|no`, `entry` (the jig that was called, normalised), and `recorder_error=<steps>` when a step of recording failed (its diagnostics are then in `recorder.log`) |
| `argv` | the arguments after the program, raw |
| `cwd` | the absolute working directory, raw |
| `env` | `NAME=VALUE`: the recorded environment (below), raw |
| `stdin` | the bytes given on stdin, when `stdin=data` |
| `stdout`, `stderr` | the bytes the call wrote; with `streams=merged` (the caller sent both to one file) only `stdout`, in the order written |
| `tree.before`, `tree.after` | `type TAB mode TAB ref TAB path`: type `f`/`l`/`d`/`o`; mode `755`/`644` for `f`, else `-`; ref the blob id for `f`, the link target for `l`, else `-`; path starting `<T>` for `$JIG_TEST_TMP` (`<T>/repo/a`, `<T>.gh/calls`) |
| `git.before`, `git.after` | git by meaning, text: per git directory `[gitdir <path>]`, `HEAD ref: …` or `HEAD <sha>`, `ref <sha> <name>` lines, `config <key>=<value>` lines; per work tree `[worktree <path>]`, `branch <name>` or `(detached)`, `status <porcelain line>` lines |
| `changes` | `A\|M\|D\|T TAB path`: what the call changed, outside git's own files |
| `subst` | newline-terminated `placeholder TAB original` rows, in the order they are applied |
| `shas` | `N TAB sha`: the real commit ids behind `<sha:N>` |
| `norm/` | the normalised views: `argv`, `cwd`, `env`, `stdout`, `stderr`, `git.before`, `git.after`, `changes`, and `files/<normalised path>` for every file `changes` adds or modifies |

**The trees** cover `$JIG_TEST_TMP` and every `$JIG_TEST_TMP.*` beside it (stubs, their logs,
`.tmpdir`, clones), except the `$JIG_TEST_TMP.out*` capture files and the record directory. The logs
of the stubs are files in these trees: a line a stub logged during the call is in `changes` and
`norm/files/`. To replay, restore `tree.before` from the store, set the recorded environment exactly
(`env -i` plus `env`), and run with the recorded `PATH`, whose stub directories are in the tree; git
itself runs for real.

**git's own files** are left out of `changes` and compared through `git.*` instead: inside a git
directory, `objects/`, `logs/`, `refs/`, `packed-refs`, `index`, `HEAD`, `ORIG_HEAD`, `FETCH_HEAD`,
`MERGE_*`, `AUTO_MERGE`, `REBASE_*`, `rebase-*/`, `sequencer/`, `COMMIT_EDITMSG`, `config`,
`description`, `*.lock`, `rr-cache/`, `worktrees/`, `gc.log`, `shallow`. Everything else there
(`hooks/`, `info/`, Jig's own `jig/`) is a change like any other. `tree.*` keeps all of it raw.

**The environment** recorded is every variable whose name or value differs from the runner's own at
its start, plus always `PATH`, `LANG`, `LC_*`, `TZ` and `JIG_NOW`; never the recorder's own variables
(`JIG_RECORD*`, `JIG_RECORDER`, `JIG_RECORDING`) nor bash's (`_`, `SHLVL`, `PWD`, `OLDPWD`). A token
the developer's shell holds is the runner's and stays out; a fake token a test sets is in.

**Normalisation** (`tests/lib/recorder.sh normalise <call-dir> [<file>]`, stdin to stdout, the same
filter the `norm/` views were made with): run a port's output through it with the recorded call's
directory, and compare with `norm/`.

1. Literal replacement by `subst`, longest original first: `<JIG_HOME>`, `<ROOT>` (the checkout),
   `<T>`, `<CACHE>` (`JIG_TEST_CACHE`), `<PATH>` (the runner's whole `PATH`), `<RUN_HOST>`
   (`JIG_VERIFY_RUN_HOST`); each path in its given, `//`-folded and physical form.
2. The clock, when the call's `JIG_NOW` is seconds since the epoch (`clock=pinned`): `<NOW>`,
   `<NOW_UTC>` (`YYYY-MM-DDTHH:MM:SSZ`), `<TODAY>` (local `YYYY-MM-DD`), by the known value; and a whole
   number of as many digits in `(NOW, NOW+1000]` becomes `<NOW+k>` (the clone revision starts at
   `JIG_NOW` and counts up).
3. Commit ids: a 40-digit hexadecimal word becomes `<sha:N>`, numbered by first appearance in the
   order `git.before`, `git.after`, `stdout`, `stderr`, the changed files by path, then `argv`, `cwd`,
   `env`; a word of 7 or more hex digits that begins a known id takes its number. A port's output is
   numbered against `shas`; ids it alone produces take the next numbers.
4. A file holding a NUL is not normalised: its view is `binary <blob id>`.

Byte order (`LC_ALL=C`) everywhere.

**Known limits.** A call marked `concurrent=yes` ran beside another of the same test: its trees are
not its alone. The 18 test files that call library functions directly, `jig-session-hook`, and calls
under `env -i` are not recorded; the run's last line names the tests with no call.

## Example

```
JIG_TEST_JOBS=3 JIG_RECORD=/tmp/rec tests/run.sh queue::
# ... recorded: 560 calls in 121 tests; 0 tests with no call
tr '\0' '\n' < /tmp/rec/calls/queue/<test>/0001/argv
tests/lib/recorder.sh normalise /tmp/rec/calls/queue/<test>/0001 port.stdout \
  | diff /tmp/rec/calls/queue/<test>/0001/norm/stdout -
```

## Rationale

The raw files make a call replayable; the normalised views make two runs comparable by meaning: the
same scenario recorded twice, in other directories and on other clocks, gives `norm/` byte for byte
the same (`tests/recorder.t.sh`). Recording must never change a test's outcome, so jig writes a
stream that goes to a regular file itself, and the recorder takes what was added afterwards.
