---
id: adr-20261126-jig-1-0-is-rewritten-off-bash-and-the-pilot-picks-the-language
type: adr
status: accepted
date: 2026-11-26
domains:
  - core
  - scripts
paths:
  - "scripts/**"
  - "tests/**"
  - install.sh
  - install.ps1
  - "profiles/**"
  - "adapters/**"
  - "hooks/**"
  - "next/**"
summary: Why Jig 1.0 leaves bash for TypeScript or Go chosen by a measured pilot, which decisions of the stack-migration spec hold whatever the language, and why the remaining bash keeps ADR-0002's rules until cut-over.
supersedes: adr-0002-shell-implementation-zero-dependencies
reviewed_at: 2026-11-26
---
# Jig 1.0 is rewritten off bash on an epic, and a measured pilot picks TypeScript or Go

## Context

Jig is about 58k lines of bash under `scripts/lib/` and about 96k lines of tests. ADR-0002 chose bash
3.2 with `git` as the only dependency so that no language runtime had to be installed and every file could be
read by a person or an agent. That choice now costs more than it saves:

- Speed. In CI run 44709464527 (2026-11-20) the Windows shards took 30–42 minutes, the macOS shards
  21–24 and the Ubuntu shards 7–12. One test ran 14 s on Linux, 25 s on macOS and 153 s on Windows,
  because Git Bash pays for every process the test and the code spawn. A user on Windows pays the
  same spawn cost on every command.
- Capability. There is no YAML or JSON parser, so state and settings are flat scalars read with
  `sed`; bash 3.2 has no associative arrays; `LC_ALL` restored by bash 5.3 in its own shell crashes
  with exit 139.
- Cost over time. The longer the move waits, the larger the rewrite.

ADR-0002's reasons are weighed against that. A language runtime requirement is real, but the installer can
place one. Readability is partly traded: the sources stay readable in Jig's own repository, while a
project carries the bundled file a release builds from them. The owner proposed the move on
2026-11-20, and the owner's colleagues asked on 2026-11-23 whether Go or Rust should be considered
beside TypeScript. The shape, the stress test and the failure hunt are in the spec
`.ai/specs/stack-migration/` (`spec.md`, `research.md`, `roadmap.md`).

## Decision

### Accepted now, whatever the language

- **Rewrite on an epic.** Jig 1.0 is written on the epic `epic/stack-migration`, command by command,
  from the leaves of the call graph to `task`, which goes last. The language is chosen by a pilot:
  `jig context` is written in both TypeScript and Go and the two are compared on Windows test time
  with `git` counted, hook start time, code size and review rounds, and what lies in the project.
- **The pilot is a gate.** Unless the pilot command's tests run at least 3× faster on Windows with
  `git` counted, and a hook starts no noticeably slower on macOS, the work stops and is reconsidered
  before more is ported.
- **In the project.** Jig stays whole in `.ai/scripts/` (ADR-0003); paths, hooks and `profile.sh`
  keep their names, so the hooks that ADR-0024 forbids Jig to rewire keep working. A release ships
  one bundled file there; its name and form wait for the language. There is one Jig per machine, and
  Jig UI stays an independent project that reads `jig … --json`.
- **Structure.** The core is functions and the CLI a thin wrapper over them; there are no port
  interfaces until a second implementation exists.
- **One executor.** Every `git`, `gh` and `glab` call goes through one executor: no shell, a hidden
  window on Windows, `git -c core.fsmonitor=false -C <dir>`. Tests replace it with recorded answers;
  a small set of integration tests runs the real `git`.
- **One storage module.** Every read and write of `.ai/workspace/` state goes through it, and a lint
  rule forbids direct access elsewhere.
- **Schemas.** State files and `--json` answers are described by schemas validated on read, with
  committed JSON Schemas; the library waits for the language. Today's files are read with every value
  a string (failsafe semantics), keeping comments and line numbers. Errors carry a closed code that is
  stable in `--json`.
  *Amendment, decided by the owner on 2026-11-26:* `state`, `config.yaml`, `config.local.yaml` and
  `profile.yaml` are read by line readers reproducing 0.51.2 exactly; a YAML library reads only
  knowledge frontmatter, its differences from bash's `fm_get`/`fm_list` listed as intended. Reason:
  rollback to 0.51.2 must stay safe — a YAML parser, even in failsafe mode, reads `{selection}` in
  `profile.yaml`, `: ` inside a `state` value and `a#b` differently from bash. This covers both
  skeletons, TypeScript and Go, and replaces the failsafe reading of those files above.
- **Formats do not change in 1.0**, `profile.yaml` included. A test holds the invariant "1.0 writes
  only what every bash release it upgrades from reads". Which bash releases 1.0 upgrades from is
  fixed by the cut-over task of `jig upgrade` (Phase 6), not by this ADR.
- **Dependencies.** Ready libraries are used instead of our own code. They are pure-language only, no
  native modules; licences MIT, Apache-2.0, BSD or ISC; maintained; a lockfile and a vulnerability
  check in CI. Security fixes ship as patch releases.
- **Parity.** A recorder captures, for every `jig` call in the bash tests, the arguments, the
  environment, the file trees before and after, stdout, stderr, the exit code and the stub logs.
  `JIG_NOW` is added to bash before recording. The 18 test files that call library functions are
  ported by hand. Equality is by meaning after normalisation, with a written list of intended
  differences, each with its reason; sorting is byte order; non-UTF-8 names are handled as bytes. A
  command's bash tests are deleted only once its port passes.
- **No mixed code.** The new implementation grows beside bash and calls only itself; shared code moves
  with the first command that needs it; `jig-next` lets ported commands be used early,
  read-only ones first. There is no
  dispatcher.
- **Workflow.** CI is off for pull requests into the epic and tests run locally; a manual Windows run
  (`workflow_dispatch`) follows every phase and precedes the final pull request. Main is frozen except
  urgent fixes, each carried into the epic at once with its recordings taken again.
- **Rollback.** `jig self-update --version <last bash release>` works because formats are kept, and the
  docs say so. The machine-wide install is laid out in versioned directories and switched
  atomically, so a process started on one version finishes on it.
- **Cut-over.** `jig upgrade` to 1.0 refuses nothing; it lists the branches and worktrees still on
  bash and those that may conflict. `jig upgrade --branches`, run by a person, merges the base into
  open task branches and the staging branch, and skips, naming why, a branch with work running in its
  worktree, uncommitted changes or a conflict. Skipped branches finish on bash under the invariant
  above.
- **Profiles** become code of the core with `profile.yaml` as their data, so `jig verify` starts no
  bash for the stock profiles; a user's `verify.sh` with `profile.sh` stays as a compatibility path.
- **Release.** 1.0 is released only when every command is ported and the owner has tried it on two
  projects, one of them on the staging flow with open tasks, by `jig-release` apart from the epic.

### Waiting for the pilot

For TypeScript the spec proposes Node LTS (24, at least 22) running `.ts` by type stripping with no
build step; the system Node or one the installer places in Jig's directory; a `jig.mjs` bundle;
profiles as modules; zod for schemas; the `yaml` library with its failsafe schema and `parseDocument`.
Bun is rejected. **None of this is accepted by this ADR.** If Go wins, the language runtime, the in-project
file, the form of profiles as code and the schema library are decided again. They are decided by the
ADR written with "The comparison and the choice" (Phase 2), before Phase 3.

### Until cut-over

Every line of bash in Jig keeps ADR-0002's rules: today's code on main and on the epic until Phase 6
removes it, and after 1.0 the installer and the `verify.sh` compatibility path. That means POSIX sh /
bash 3.2 with no bash 4 features; `git` the only mandatory dependency (`gh` and `glab` optional);
flat-scalar state readable with `sed`; the hand-rolled sh test runner; `shellcheck` before committing.
`.ai/knowledge/conventions/shell.md` stays in force. ADR-0002's Windows amendment (`install.ps1` with
`tests/install.t.ps1`, and `scripts/jig.cmd`) and ADR-0037 (Windows runs Jig through Git Bash) stay in
force for every bash release; they are revisited at cut-over, not by this ADR.

## Alternatives

- **Rust** — rejected: Jig waits on `git`, not on CPU, and a port of this size in Rust costs the most
  agent rounds.
- **Choosing the language now, without a pilot** — rejected: both sides are real, and only the pilot
  gives numbers.
- **ai-factory's shape** (TypeScript with the old bash tests run under a Node wrapper) — rejected:
  Windows still needs bash and the CI cost stays.
- **Keeping bash and removing forks from hot paths** — not chosen: it keeps every bash 3.2 limit the
  features fight.
- **A thin per-machine launcher instead of Jig whole in `.ai/scripts/`** — rejected: CI in installed
  projects, colleagues' clones, profiles and the committed hooks all call `.ai/scripts/…` (ADR-0024).
- **A dispatcher sending some commands to new code and the rest to bash** — rejected: two
  implementations of one state on one branch.
- **Merging main into the epic regularly** — rejected: the epic would chase a moving target.
- **Changing formats with the rewrite** — rejected: edited `profile.yaml` files would break again, and
  1.0 could no longer be rolled back.
- **Storage and git ports now, for a future service** — rejected: the service is still an idea, and
  the ports would leak local assumptions (mkdir locks, atomic rename) anyway.
- **Bun** — rejected: less mature on Windows and less common.
- **Zero dependencies or a hand-written parser** — rejected: a parser of our own is the workaround
  this rewrite exists to end. *Amended 2026-11-26 by the owner:* a line reader reproducing bash for
  the flat files is not such a parser — it is how 0.51.2 reads them, kept so a rollback stays safe;
  real YAML still goes through a library.
- **A YAML library in failsafe mode for every file of today** — rejected by the owner on 2026-11-26:
  it reads the flat files differently from 0.51.2.

## Consequences

- Features that bash made slow or impossible (real parsers, schemas, in-process tests) become
  ordinary work, and Windows runs lose most of their spawn cost once tests stop starting processes.
- The whole stack is paid for once. Main is frozen except for urgent fixes, and nothing reaches users
  until the last command is ported.
- Two kinds of rule coexist until cut-over: bash code follows ADR-0002's rules as restated above, and the new code
  follows the decisions above.
- Maintenance grows: a recorder, a written list of intended differences, a dependency policy, and the
  upgrade of open branches at cut-over.
- The weakest point is that the language is chosen after the pilot, so the decisions written for
  TypeScript may be rewritten for Go.
- Open questions left to later tasks: where the recordings live and how large they are; what follows
  if the pilot misses its gate in both languages; which commands are truly independent leaves, decided
  from the call graph when the tasks are filed.
