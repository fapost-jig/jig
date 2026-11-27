# Stack migration — Jig 1.0 leaves bash

Summary: Jig's ~58k lines of bash are rewritten, command by command on an epic, in TypeScript or Go
— chosen by measuring one pilot command in both — so that tests run in-process in minutes on every
OS and features stop fighting bash 3.2, while installed projects keep their layout, their file
formats and their open tasks.

Depth: deep, with the independent failure hunt — the change replaces the whole implementation and
everything copied into other people's projects; a mistake reaches every project that upgrades, and
taking it back costs a second migration.

## Idea

The owner, 2026-11-20:

> виндос тесты идут уже по 40 мин, а мак почти 30. я больше чем уверен, если мы поменяем стек с
> шела на тайпскрипт, мы ускорим релиз и это нам развяжет руки на новые фичи, которые сейчас
> реально медленные или делаются через обходные пути

(Windows tests take 40 minutes, macOS almost 30. Moving the stack from shell to TypeScript would
speed up releases and free our hands for features that are slow today or done through workarounds.)

> просто чем дальше мы откладываем переезд, тем дольше потом будет переписывать

(The longer the move is put off, the longer the rewrite.)

> мы можем брать один скрипт, переписывать, запускать тесты старые, писать новые, проверять что
> они совпадают. Удалять старые. И так по каждому скрипту.

(Take one script, rewrite it, run the old tests, write new ones, check they agree, delete the old
ones; and so for every script.)

> я не буду ничего деплоить в прод, пока мы полность не сменим стек, это будет отдельная ветка, на
> которой сиай не будет ничего делать. Все тесты локально

(Nothing ships until the stack is fully switched; a separate branch on which CI does nothing; all
tests run locally.)

The owner's colleagues, 2026-11-23:

> а что если уйти и от тайпскарипта, а взять и написать скрипт на голенг или раст?

(What if we skip TypeScript too and write it in Go or Rust?)

## Goal and problem

- Who is worse off without this, and how: the owner and the agents shipping Jig — the full test
  suite takes ~40 minutes per Windows shard (ten shards) and ~20–30 per macOS shard; the same test
  ran 14 s on Linux, 25 s on macOS and 153 s on Windows (CI run 44709464527, 2026-11-20), because
  Git Bash pays for every process a test and the code spawn. Features are slow to build or need
  workarounds: no YAML or JSON parser (flat-scalar formats read with `sed`), bash 3.2 limits, a
  locale crash (exit 139). Users on Windows — the audience Jig aims at — pay the same spawn cost on
  every command.
- What is true when the work is done: no bash is left in Jig except the installer and the
  compatibility path for a user's own `verify.sh`; the full test suite runs on Windows in 10 minutes
  or less; a project on 0.51.2 reaches 1.0 through `jig upgrade` with no manual steps, open tasks
  and the staging flow included.

## Stress test

- Hidden assumptions — "this holds only if …":
  - The speed-up holds only if tests stop spawning processes, not merely bash: even native Rust
    tools by the author of ai-factory run their CI 3–6× slower on Windows than on Linux (ai-workspace
    8m42s vs 1m22s, HLV 2m25s vs 48s), so `git`, `gh` and `glab` sit behind one executor that tests
    replace with recorded answers.
  - Parity against recordings holds only if the recordings carry what the bash tests actually
    assert: the logs of the `gh`/`glab`/`git` stubs (stub_gh is used 164 times, stub_tool 107,
    stub_glab 27), and a controllable clock — there is none today.
  - "No manual steps" holds only if 1.0 writes nothing 0.51.2 cannot read.
- The main trade-off: the whole stack is paid for once, with main frozen, against a stack that keeps
  costing time on every task and every CI run; nothing reaches users until the last command is
  ported.
- The weakest point: the language is chosen only after the pilot, so the decisions written for
  TypeScript (runtime, `jig.mjs`, profiles as modules, zod, `yaml`) may have to be rewritten for Go.
- Failure modes — cause, what breaks, the signal that shows it (independent failure hunt,
  2026-11-23; each is answered by a decision below):
  - The recorded oracle misses stub logs, function-level tests and time → a port passes and calls
    `gh` wrongly → the first real forge call fails.
  - Byte parity fights bash incidentals (~1000 awk/sed pipelines, `LC_ALL=C` sorting, non-UTF-8
    names) → quirks ported or normalisation loosened until it proves nothing → diffs dominated by
    order and whitespace.
  - A thin per-project launcher → CI in installed projects, colleagues' clones and `profile.sh`
    lose Jig → exit 127 right after the upgrade.
  - Branches cut before the upgrade carry the bash copy → conflicts and two versions on one state.
  - A real YAML parser reads old files differently (`yes`, `0.10`, tabs) → settings silently change.
  - One machine-wide install, one-way migration → no way back.
  - Port used for real only at the end, `task` last, Windows unseen → a burst of faults at cut-over.
  - The freeze leaks, the recordings go stale → fixed bugs reproduced faithfully.
  - Node start and many module files on every hook → hooks and `jig status` slower than bash.
  - Committed `.claude`/`.codex` hooks point at `.ai/scripts/…`; ADR-0024 forbids Jig editing them.
  - A private Node fails to install (proxy, antivirus, glibc < 2.28, musl).
  - `--json` drift breaks Jig UI (key order, numbers vs strings, escaping).
  - Ports for a future cloud add indirection and still leak local assumptions.
- Other shapes considered, and why this one: Rust — rejected, Jig is bound by spawning `git`, not by
  CPU, and a 58k-line port in Rust costs the most agent rounds; ai-factory's shape (TypeScript with
  the old bash tests under a Node wrapper) — rejected, Windows still needs bash and the CI pain
  stays; removing forks from bash hot paths only — not chosen, it keeps every bash 3.2 limit the
  features fight.

## Scope and non-goals

- In scope: every command of `jig`, its hooks, the 13 stock profiles, the test suite, the
  installer's runtime step, `jig upgrade` from 0.51.2 to 1.0 including open branches, the docs for
  rollback.
- Not doing: changing the formats of `state`, `config.yaml`, the journal or `profile.yaml` (a spec
  of its own after 1.0, perhaps onto SQLite); an MCP server; the hosted or self-hosted service; any
  new feature on main while the epic is open.

## Decisions

- The language is chosen by measurement: the pilot command `jig context` is written in TypeScript
  and in Go, and the one that does better wins on — Windows test time, hook start time, code size
  and review rounds, what lies in the project. The scaffold before it (recorder, parity check) does
  not depend on the language. Rejected: Rust, because Jig waits on `git`, not on CPU, and its port
  costs the most; choosing now, because both sides of the comparison are real and only the pilot
  gives numbers (owner and colleagues, 2026-11-23).
- Readable source in the installed project weighs in the choice: a user, or their agent, can read
  `jig.mjs` to understand a failure and file an issue, which a binary does not allow. So the bundle
  is never minified. TypeScript is chosen if it passes the pilot's gate; Go wins only if TypeScript
  misses the gate and Go passes it, or Go's numbers are better by a margin the comparison states and
  the owner accepts. The 3× gate stays the test of whether to port at all (owner, 2026-11-27).
- The decisions below are written for TypeScript; if Go wins, the runtime, the in-project file, the
  profiles-as-modules and the schema library are decided again before Phase 3.
- Runtime (TypeScript): Node LTS (24, at least 22), `.ts` run directly by type stripping with no
  build step in development; the system Node when it is new enough, otherwise one the installer
  places in Jig's own directory; unsupported platforms named at install. Rejected: Bun, less mature
  on Windows and less common.
- Dependencies: ready libraries are used wherever they exist instead of writing our own (owner,
  2026-11-23). Rules: pure JS/TS only, no native modules (a native module cannot be bundled into one
  file and breaks when Node changes, as better-sqlite3 does in aif-handoff); licences MIT,
  Apache-2.0, BSD or ISC; a lockfile and a vulnerability check in CI; maintained packages. Security
  fixes to Node or a dependency ship as patch releases. Rejected: zero dependencies and a minimal
  set — a parser of our own is the workaround this spec exists to end.
- In the project: Jig stays whole in `.ai/scripts/` (ADR-0003); a release bundles the sources and
  dependencies into one `jig.mjs`; paths, hooks and `profile.sh` keep their names. Rejected: a thin
  launcher with Jig installed per machine, because CI in installed projects, colleagues' clones,
  the profiles and the committed hooks all call `.ai/scripts/…` (ADR-0024 forbids rewiring them).
- One Jig per machine, as many projects as the developer needs; Jig UI registers them as today and
  reads `jig … --json`. Jig and Jig UI stay independent projects. Rejected: Jig UI importing Jig's
  core as a package.
- Core and CLI: the core is functions, the CLI a thin wrapper over them; no port interfaces for a
  future service until a second implementation exists. Rejected: storage and git ports now, because
  the service is still an idea in Jig UI's spec and the ports would leak local assumptions (mkdir
  locks, atomic rename) anyway.
- One executor for external processes: every `git`, `gh` and `glab` call goes through it, with
  `shell: false`, a hidden window on Windows and `git -c core.fsmonitor=false -C <dir>`; tests
  replace it with recorded answers, and a small set of integration tests runs the real `git`.
- One storage module: every read and write of `.ai/workspace/` state (tasks, queue, journal, forge
  cache, config) goes through it, and a lint rule forbids direct access elsewhere, so a later move to
  a database changes one module.
- Schemas: zod describes every state file and every `--json` answer; validation on read, the types
  and committed JSON Schemas come from it — the contract Jig UI can check.
- Reading today's files: the flat files — `state`, `config.yaml`, `config.local.yaml`,
  `profile.yaml` — are read by a line reader that reproduces bash exactly, so 1.0 reads what 0.51.2
  reads and a rollback stays safe; the `yaml` library with its failsafe schema reads only knowledge
  frontmatter, with `parseDocument` keeping comments and giving line numbers, and its differences
  from bash's `fm_get`/`fm_list` listed as intended (owner, 2026-11-26, at the `ts-skeleton` gate).
  Rejected: the `yaml` failsafe reader everywhere — it reads `{selection}` in `profile.yaml`, `: `
  inside a `state` value and `a#b` differently from bash, which silently changes settings.
- Errors carry a closed code (`dirty-tree`, `review-stale`, …) that is stable in `--json`; skills
  and Jig UI match the code, not the text.
- Formats do not change in 1.0, `profile.yaml` included; the invariant "1.0 writes only what 0.51.2
  reads" has a test. Rejected: changing the profile format with the rewrite, because edited
  `profile.yaml` files would break again, as they did in 0.48.0.
- Rollback: `jig self-update --version 0.51.2` works because formats are kept, and the docs say so;
  the machine-wide install is laid out in versioned directories and switched atomically, so a
  process started on one version finishes on it.
- Baseline: 0.51.2, the last bash release, is the version 1.0 stays compatible with, upgrades
  from and rolls back to; main is frozen, so it stays the last.
- Profiles: the 13 stock profiles become modules of the core, `profile.yaml` stays their data, and
  `jig verify` no longer starts bash on Windows; a user's own profile may supply a module; a user's
  `verify.sh` with `profile.sh` keeps working in 1.0 as a compatibility path. Rejected: profiles
  staying shell — the selection logic is ordinary code, and Windows would keep Git Bash for verify.
- Parity: a recorder captures, for every `jig` call inside the bash tests, the arguments, the
  environment, the file tree before and after, stdout, stderr, the exit code and the stub logs;
  `JIG_NOW` is added to bash before recording so time is controlled; the 18 test files that call
  library functions directly are ported by hand. Equality is by meaning after normalisation, with a
  written list of intended differences, each with its reason; sorting is byte order; non-UTF-8
  names go through `Buffer`. A command's bash tests are deleted only once its port passes, so a
  doubtful recording can be taken again.
- No mixed code: the new implementation grows beside the bash one and calls only itself; ports go
  from the leaves of the call graph to `task`, shared code moving with the first command that needs
  it; a separate `jig-next` lets the owner and agents use ported commands on this repository early,
  read-only ones first. Rejected: a dispatcher sending some commands to the new code and the rest to
  bash.
- Workflow: one epic branch; tasks reach it by pull request with CI switched off for pull requests
  into it; tests run locally; a manual Windows run (`workflow_dispatch`) after every phase and before
  the final pull request. Main is frozen: urgent fixes only, each carried into the epic at once with
  its recordings taken again. Rejected: merging main into the epic regularly — the epic would chase a
  moving target.
- The pilot is a gate: unless the pilot command's tests run at least 3× faster on Windows, with
  `git` counted, and a hook starts no noticeably slower on macOS, the work stops and is reconsidered
  before more is ported.
- Cut-over with open work: `jig upgrade` to 1.0 refuses nothing; it lists the branches and
  worktrees still on 0.51.2 and those that may conflict. `jig upgrade --branches`, run by a person,
  merges the base into each open task branch and the staging branch, and skips — naming why — a
  branch with work running in its worktree (bash reads a script incrementally, `upgrade.sh`), with
  uncommitted changes, or with a conflict. Skipped branches finish on 0.51.2 under the invariant
  above. Rejected: refusing the upgrade while tasks are open — in a large project that means never.
- Release: none until every command is ported and the owner has tried 1.0 on two projects, one of
  them on the staging flow with open tasks; the version is 1.0, released by `jig-release` apart from
  the epic.
- The epic: yes — no phase gives users anything on its own, and the size (seven phases) calls for
  one branch merged once.
- ADR-0002 is superseded by a new ADR written in Phase 0.

## Open questions

- Which commands and shared code are truly independent in Phases 3–4 — decided from the call graph
  when the tasks are filed.
- Where the recordings live and how large they are — whether they are committed to git.
- What follows if the pilot misses its gate in both languages.

## Set aside

- Spec `release-trains` — set aside until the migration ends: in-process tests would make most of
  it moot, and it would rebuild a CI the migration replaces.
- An MCP server over the core, with a narrow set of tools — after 1.0; HLV's 27 tools show what a
  wide one costs an agent's context.
- New file formats, perhaps SQLite through `node:sqlite` (never a native module) — a spec of its own
  after 1.0 (owner: "perhaps we will move to it").
- A hosted or self-hosted service showing a company's projects, task statuses and a shared queue —
  lives in Jig UI's spec; the shape ai-workspace uses is kept in `research.md`.
- A local daemon owning the state (ai-workspace, ai-factory swarm) — not taken: process lifecycle,
  tokens and version skew, while mkdir locks are enough today.
- unexplored: Windows performance of `profile.sh` for users who keep their own `verify.sh`.

## Assumptions left untested

- Node's type stripping is stable enough for the whole code base — taken at deep; the Phase 1
  scaffold tests it.
- Normalised recordings still prove parity — taken at deep; the pilot's count of intended
  differences tests it.
- GitHub runners and the people who use Jig have, or can get, Node 22 or later — the installer's
  runtime step in Phase 6 tests it.
