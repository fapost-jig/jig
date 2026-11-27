# Roadmap — Stack migration

Destination: Jig 1.0 runs with no bash except the installer and the compatibility path for a user's
own `verify.sh`, its full test suite takes 10 minutes or less on Windows, and a project on 0.51.2
reaches it through `jig upgrade` with no manual steps, open tasks included.

Epic: epic/stack-migration

## Phase 0 — Ready

Goal: the decision is on record and the epic can take ported code. Done when: the ADR is accepted, a
pull request into the epic runs no tests while a person can run the suite on Windows by hand, and
the bash tests can control time.

- [x] `stack-adr` — ADR superseding ADR-0002: the language is chosen by the pilot, and the decisions of this spec that do not depend on it are accepted
- [x] `epic-ci-skip` — CI skips pull requests into the epic, and a person can run the suite on Windows on any branch through `workflow_dispatch`
- [x] `bash-clock-seam` — `JIG_NOW` in bash: every reading of the clock goes through one place a test can set, so recordings do not depend on the day they were taken

## Phase 1 — Scaffold

Goal: anything can be ported and proven against bash. Done when: a trivial command written in the
new code passes against its recordings, locally and on the manual Windows run.

- [x] `stack-recorder` — Recorder — running the bash tests in record mode keeps, for every `jig` call, arguments, environment, file trees before and after, output, exit code and stub logs, normalised (after: `bash-clock-seam` — time must be controlled before anything is recorded)
- [x] `parity-check` — Parity check — a ported command is run against its recordings and the differences are reported, with a list of intended differences (after: Recorder — it reads what the recorder wrote)
- [x] `ts-skeleton` — TypeScript skeleton — runtime choice, `jig-next`, core and CLI split, the process executor, the storage module reading today's files, zod schemas, the invariant test, the bundle into `jig.mjs` with the dependency rules checked
- [x] `go-skeleton` — Go skeleton — the same pieces in Go, enough to port the pilot
- [x] `recorder-windows` — Recorder on Windows — path-safe placeholders, no inherited secrets in snapshots, no lost recorder errors (findings of `stack-recorder`)
- [x] `ts-skeleton-revision` — TypeScript skeleton level with Go — storage raises the clone revision, test install under a lock, real revision in --json errors, stricter boundary scan (findings of `ts-skeleton`)
- [x] `oracle-at-baseline` — Invariant oracle at 0.51.2 — both skeletons check against the bash libraries of the pinned baseline, not the epic checkout (findings of `go-skeleton`)
- [x] `pilot-ci-runtimes` — Pinned runtimes in CI — Node and Go versions fixed for the next/ tests before the manual Windows run (finding of `ts-skeleton`)
- [x] `trivial-port` — A trivial command on both skeletons — `jig --version` in `jig-next-ts` and `jig-next-go` passes its recordings through `tests/lib/parity.sh`, checked by a test in `jig verify`, not only a demonstration (after: `parity-check`, both skeletons)
- [ ] `windows-phase1-run` — The manual Windows run — workflow_dispatch on the epic: the bash suite recorded, `trivial-port` checked against those recordings, and the next/ts and next/go tests, all on Windows Git Bash; the run is linked in the roadmap (after: `trivial-port`, `pilot-ci-runtimes`)

## Phase 2 — Pilot and the language

Goal: the language is chosen on numbers. Done when: the comparison is written and the owner has
chosen, or the work is stopped by the gate.

- [ ] `pilot-context-ts` — `jig context` in TypeScript — passes its recordings and its own in-process tests (after: Parity check — it is proven against the recordings; TypeScript skeleton — it runs on it)
- [ ] `pilot-context-go` — `jig context` in Go — the same, in Go (after: Parity check — the same proof; Go skeleton — it runs on it)
- [ ] `pilot-comparison` — The comparison and the choice — Windows test time with `git` counted, hook start time, code size and review rounds, what lies in the project; the gate of 3× decides whether to go on (after: both pilots — it compares them)

## Phase 3 — The leaves

Goal: the commands nothing else calls are ported. Done when: each passes its recordings and its
bash tests are deleted.

- [ ] `replay-gaps` — Replay what the recorder cannot yet — calls that touch paths outside the recorded trees (a linked repository beside the test), directory modes (an unwritable runtime/), and the two process-count tests whose replay fails on tree.before; bash must match its own recordings for every recorded call before Phase 3 ports rely on them (found by `pilot-context-go`)
- [ ] fog: the exact set of leaf commands — `knowledge`, `queue`, `spec`, `config`, `doctor` are the expected ones; the call graph decides when the tasks are filed

## Phase 4 — Verify, profiles and the middle

Goal: the commands in the middle of the graph are ported, and `jig verify` runs no bash for the
stock profiles. Done when: each passes its recordings, and a user's `verify.sh` still runs.

- [ ] `jig verify` with the compatibility path for a user's `verify.sh` (after: The comparison and the choice — the language must be fixed)
- [ ] The 13 stock profiles as modules — one task each, in parallel (after: `jig verify` — it calls them)
- [ ] fog: `status`, `land`, `upgrade`, `housekeeping`, `pr` and the shared code under them — split once the leaves show how much shared code has already moved

## Phase 5 — Task

Goal: `jig task`, the largest command, is ported. Done when: it passes its recordings, and the owner
has shipped tasks on this repository with `jig-next`.

- [ ] fog: `jig task` — 10k lines of bash; cut into tasks by subcommand once Phase 4 has moved the code it shares
- [ ] `review-without-loops` — Review that converges — P0–P2 fixed inside the task before ship and never a stop for a P2; P3 dismissed, not fixed; "matters when X" findings become conditions on roadmap item X, not ledger entries; a re-review reads the ledger of resolved findings and never records one that undoes a resolution unless it is P0/P1 with the reason; a task filed from findings files no findings task of its own; the autopilot decides leftovers itself and reports, never waits (owner, 2026-11-27; an intended difference from 0.51.2)

## Phase 6 — Cut-over

Goal: the new code is Jig. Done when: no bash is left outside the installer and the compatibility
path, the suite runs on Windows in 10 minutes or less, and the owner has upgraded two projects.

- [ ] The launcher and the files in a project are the new code, and the bash code and its tests are gone (after: Phase 5 — every command must be ported first)
- [ ] The installer places the runtime, the machine-wide install is in versioned directories switched atomically, and rollback to 0.51.2 is documented
- [ ] `jig upgrade` to 1.0 lists the branches left on 0.51.2, and `jig upgrade --branches` brings the open ones over
- [ ] A pull request to Jig UI's spec says what 1.0 changes for it, with the shape of the hosted service from `research.md`
- [ ] The owner's trial on two projects, one on the staging flow with open tasks (after: the three items above — it tries the finished cut-over)

## Waves

1. `stack-adr`; `epic-ci-skip`; `bash-clock-seam`
2. Recorder; TypeScript skeleton; Go skeleton
3. Parity check
4. `jig context` in TypeScript; `jig context` in Go
5. The comparison and the choice
6. `jig verify` with the compatibility path for a user's `verify.sh`
7. The 13 stock profiles as modules

<!--
Rules (jig-idea §8):
- An item is a finished slice that makes the product noticeably better, never a layer.
- A dependency without a one-line reason is not a dependency.
- A `task-id` appears when the item's task is filed; `[x]` is set when that task is closed.
- `fog:` items are not split or sized; they become real items once the fog lifts.
- No dates, no point estimates: order is the priority.
- `jig spec list` counts checkbox lines only: `[x]` done, a leading backticked task id
  followed by a dash (`—` or `-`) filed, a leading `fog:` fog. Keep waves as a numbered list.
- A wave entry names an item by its title (the text before its first ` — `) or its task id,
  entries separated by `;` — `jig spec plan` reports an entry that names no item or several.
-->
