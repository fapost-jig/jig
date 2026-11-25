---
id: adr-20261118-main-tests-what-changed-since-a-full-pull-request-run
type: adr
status: accepted
date: 2026-11-18
domains:
  - verify
paths:
  - .github/workflows/ci.yml
  - .github/scripts/ci-reuse.sh
  - .github/scripts/ci-scope.sh
  - .github/scripts/ci-ok.sh
  - .github/scripts/ci-outputs.sh
summary: Why a push to main whose pull request was behind main tests only what changed since the tree that pull request's whole-suite run tested, how that tree is proved from a record in its plan artifact, why release reads whole (decided in ci-outputs.sh), and the risk left.
reviewed_at: 2026-11-19
---
# A push to main tests what changed since the tree a pull request tested in full

## Context

Exact reuse (adr-20261027-main-is-not-retested-when-a-pull-request-tested-its-tree) needs the merged
pull request to have been up to date with `main`: only then is the tree `main` holds the tree its run
tested. A pull request's run takes 20 to 30 minutes, and other pull requests merge meanwhile, so the
branch is usually behind when it lands, the merge is a tree nobody ran, and `main` runs the whole
suite again. Of the last 21 green push runs on `main`, 7 ran the whole suite after their own pull
request had already run it (changes to `common.sh`, `bootstrap.sh`, `.github/`, a `JIG_VERSION`
bump), 18 shares and about 30 minutes each, only because the pull request was behind.

What the pull request's run did test is not lost: it was a merge `M = merge(B, P)` of main's tip `B`
and the pull request's head `P`. GitHub forgets `B` and `refs/pull/N/merge` after the merge, but the
`scope` job knows both at run time.

## Decision

- **A pull request's run records what it tested.** The `scope` job of a pull-request run writes
  `tested` into the `plan` artifact: `base=<HEAD^1>`, `head=<HEAD^2>`, `tree=<HEAD^{tree}>` of the
  merge commit it checked out. Without both parents there is no file.
- **`ci-reuse.sh` has a third answer, `narrow <commit> (<why>)`**, given when no run tested the
  pushed tree exactly. The candidate is a green run of the merged pull request (found as for exact
  reuse) whose shares all ran the whole suite on every platform, Windows included, never a selected
  run. Its `tested` record must be complete and name the run's own head; `base` must be an ancestor
  of the push's `before` commit (`main` only moves forward); and `git merge-tree --write-tree base
  head` must succeed and print exactly the recorded tree, which checks the record against this
  repository instead of trusting it. The commit printed is a local one holding that tree on top of
  `base` (the identity is given through the environment for that one command; nothing is configured
  or pushed). A missing artifact or record, a conflict, a different tree, a failed ancestry test or
  anything unmeasurable means the run does not count, and the answer is `test`. Exact reuse is tried
  first and wins; a recorded tree equal to the tree of `HEAD` (main moved while the run went, then
  merged nothing new) is exact reuse as well, answered before any narrowing, never a narrowing from
  an empty difference. The exact answer carries a marker, `suite: all` or `suite: selected`, saying
  which kind of run it reused.
- **`scope` measures the push from that commit.** `ci-scope.sh <commit>` selects the tests by what
  differs between the tested tree and `HEAD`, which is what other pull requests landed meanwhile:
  `light` still runs the knowledge check on every share, as the one filter
  (`knowledge::test_real_repository_knowledge_passes_with_no_failures`), with `suite=selected` and
  `reuse=false`: a knowledge document of the difference can break against the tested tree (a link to a
  file the pull request deleted), and a light push is checked for exactly that, so nothing of the
  merged tree goes unchecked; `selected` runs those tests with the new filters on every platform; `full` (the difference touches `.github/`,
  `common.sh`, `JIG_VERSION` and so on) runs the whole suite as before. The outputs are written once,
  after the decision, so the share planner sees the final suite and filters. The decision itself, from
  the scope line, the reuse line and the narrow scope line to `full`, `suite`, `whole` and `reuse`,
  lives in `.github/scripts/ci-outputs.sh`, with a table test of every combination
  (adr-0034-releases-are-tagged-by-ci rejects deciding a release in workflow shell, which only text
  checks can test).
- **`whole` is the new output for "the proof is the whole suite".** It is true when the suite is `all`,
  when a pull request's run of the whole suite was reused (a reuse of a run of selected tests is not
  whole), and for every narrow answer, light and selected ones included. `release` needs `whole == 'true'`
  instead of `suite == 'all'`, so a release pull request that fell behind `main` is tagged after
  the difference was tested, not at night. `red-main` still closes only on `suite == all`: a narrow
  run closes it only when the difference forced the whole suite, never on a selected one (conservative).
  `ci-ok.sh` needs no change: it checks `full`, `suite` and `reuse` consistency, and `release` is not
  among its needs.
- This amends adr-20261110-a-pull-request-runs-the-tests-its-change-reaches, which says a selected run
  never releases: a narrowed run may be `selected` and tag, because its proof is the pull request's
  whole-suite run on the recorded tree plus the tests of the difference on `HEAD`.
- Narrowing is refused while a `red-main` issue is open (or when that query fails), so a release onto
  a red main still runs the whole suite.
- **Why recording the tested tree in an artifact is acceptable now.** adr-20261027-main-is-not-retested-when-a-pull-request-tested-its-tree
  rejected it because the decision would rest on artifact retention and on something nothing in the
  repository could test. The record here is not trusted: `ci-reuse.sh` recomputes
  `git merge-tree --write-tree base head` and requires it to equal the recorded tree, and requires
  the record's head to be the run's own head and its base to be in main's history. An unreadable,
  incomplete or mismatched record, or a missing artifact, falls back to testing everything, so
  retention costs only a rerun, and the reading and the decision are tested in `tests/ci-reuse.t.sh`.

## Alternatives

- **Only exact reuse and selected reuse (as before).** Keeps the cheap cases and leaves the expensive
  one, a whole-suite rerun of a tree whose only news is a few unrelated merges.
- **Strict status checks** (a branch must be up to date to merge). Every lag becomes a new full pull-request
  run; at around 15 pull requests a day the queue grows faster than it drains. Worse than a rerun on `main`.
- **Release trains (spec `release-trains`).** A different branch scheme altogether; this decision
  neither replaces it nor prevents it.

## Consequences

- A pull request behind `main` costs `main` only the tests its difference reaches, usually none, instead
  of the whole suite; a release pull request that lagged is tagged when those finish.
- **Residual risk.** The argument is the one the verify map already rests on: a test that no file of
  the difference between the tested tree and `HEAD` reaches sees in `HEAD` the files it saw in the
  tested tree, where it passed. Two faults it cannot see, both a test `t` broken through a coupling
  the map has no line for. First, the *combination* of the pull request and what landed breaks `t`,
  though no changed file reaches it. Second, a change X that landed on `main` meanwhile breaks `t`
  by itself, and the pull request, a release among them, merges before any whole-suite run on X has
  failed: no `red-main` issue is open, so narrowing is not refused, the difference (X's files) does
  not reach `t`, the run is `selected` and green with `whole` true, and a release is tagged with `t`
  failing on `HEAD`, where the release push used to run the whole suite and fail. The window for
  both is from the merge until the next whole-suite run on `main` fails and opens `red-main`, at the
  latest the nightly run, within a day; after that narrowing is refused and a release runs the whole
  suite. So a release's proof is the whole suite on the tree the pull request recorded plus the
  tests the difference reaches on `HEAD`, not the whole suite on `HEAD`: `whole` is true only for
  the three cases above, and inside that window such a proof can tag a version with a test failing.
- The artifact is kept seven days; a pull request merged later gets the whole-suite rerun, as
  before.
- `git merge-tree --write-tree` needs git 2.38; `ubuntu-latest` has it. An older git makes the
  merge fail and the answer `test`.
- Reverting is the revert of the pull request: only this repository's CI is affected, and the worst
  outcome is an unverified combination on `main` until the nightly run.

> **Amendment (2026-11-25): inert while no pull request runs Windows.** Since the 2026-11-25
> amendments of adr-20260924-windows-runs-on-a-pull-request-that-touches-platform-behaviour and
> adr-20261110-a-pull-request-runs-the-tests-its-change-reaches, a pull request runs no Windows
> shards and a full-scope one runs Linux alone. `ci-reuse.sh` counts a run only when it passed a
> Linux, a macOS and a Windows share, so it always answers `test`: every push to `main` tests what
> its own scope says, on every platform, and the tag waits for that run. The mechanism is kept, not
> removed, for the day a pull request runs every platform again.
