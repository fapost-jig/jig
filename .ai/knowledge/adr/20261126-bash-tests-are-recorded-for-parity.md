---
id: adr-20261126-bash-tests-are-recorded-for-parity
type: adr
status: accepted
date: 2026-11-26
domains: []
paths:
  - tests/lib/recorder.sh
  - tests/run.sh
  - scripts/jig
summary: Why the bash tests are recorded through an env-gated hook in scripts/jig, outermost calls only, on a pinned JIG_NOW, and why the recordings stay out of git until the first bash test is deleted.
reviewed_at: 2026-11-27
---
# The bash tests are recorded through a hook in the dispatcher, on a pinned clock, and kept outside git for now

## Context

The stack migration proves each port against what the bash code did
(`adr-20261126-jig-1-0-is-rewritten-off-bash-and-the-pilot-picks-the-language`, Parity): for every
`jig` call in the bash tests, its arguments, environment, file trees before and after, output, exit
code and stub logs. Tests reach jig four ways — the `jig` helper and `"$JIG_BIN"`, the copies a test
installs into a project (`jig_installed`, `.ai/scripts/jig`), and a global `jig` on `PATH`. That ADR
left open where the recordings live and how large they are.

## Decision

- **The hook is in `scripts/jig`**, right after it resolves itself: when `JIG_RECORDER` is set and
  `JIG_RECORDING` is not, it hands the call to the recorder (`exec "$BASH" "$JIG_RECORDER" record …`).
  It catches every way in, installed copies included, and does nothing without the variable. The
  recorder is test tooling (`tests/lib/recorder.sh`) and is never installed.
- **Only the outermost call is recorded**: jig's calls to itself and the hooks it runs see
  `JIG_RECORDING` and pass through.
- **A record run pins `JIG_NOW`** to the time it starts, unless it is set; the normaliser replaces
  that known instant, never a pattern of dates.
- **Recordings are not committed, for now.** They are taken again with one command and are
  deterministic after normalisation. Measured: 106 MB for the 121 `queue::` tests (560 calls), 694 MB
  for `queue::` and `verify::` together (1065 calls; the blob store 21 MB of it, the rest the raw tree
  lists of each call) — several gigabytes for the suite. Keeping them is decided when the first bash
  test is deleted, because after that a recording cannot be taken again; the tree lists would then
  move into the blob store first.
- **The format is `jig-recording 1`**, written down in `conventions/recordings.md`; a change raises the
  number. It is `jig-recording 2` since task `recorder-windows`: names under `norm/files/` carry no
  byte NTFS forbids.

## Alternatives

- A wrapper around `JIG_BIN` in `tests/run.sh` — misses the installed copies, which are what many
  tests drive.
- The hook inserted only into the release copy `tests/run.sh` builds per run — the code under test
  would no longer be the code in the repository, and the hook would have no test of its own.
- Recording every nested call — compares implementation details a port need not repeat.
- Pinning git's commit dates as well — would make commit ids stable but changes the history tests
  build; ids are numbered by the normaliser instead.
- Committing the recordings now — gigabytes for a contract that may still change before the first
  port passes.

## Consequences

- A record run is several times slower (×3.8 on `queue::`, about ×3 on `queue::` and `verify::` together); a test with a wall-clock budget may need
  a look before it is recorded.
- `scripts/jig` carries test-only lines until cut-over, when the bash code goes and the hook with it.
- A main fix carried into the epic means its tests are recorded again.
- The findings of task `stack-recorder` on Windows and secrets were closed by task
  `recorder-windows`: `norm/files/` names map `<>:"\|?*` to `_`, and the runner unsets inherited
  variables named like a secret before every test, so a stub that logs its environment cannot put one
  in a tree.
