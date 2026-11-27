---
id: convention-ci-gating
type: convention
status: active
domains: []
paths:
  - ".github/workflows/**"
  - .github/scripts/ci-untested-base.sh
  - .github/scripts/ci-epic-tests.sh
summary: Why the branch rules require only the ci-ok job, why a matrix job's name can never be a required check, and how a throwaway probe branch answers a routing question in a minute instead of 25.
reviewed_at: 2026-11-27
---
# CI gating

How this repository's branch rules and its workflow stay compatible. The practice is one
rule, and the rationale is the pull request it cost.

## Practice

| Rule | Rationale |
|---|---|
| The branch rules require exactly one status check, `ci-ok`: a job that needs every other job, runs with `always()`, and fails when a job failed, was cancelled, or was skipped although `scope` and the event required it to run (`.github/scripts/ci-ok.sh`). A new job joins its `needs` list, its result is passed to the script, and the script learns what decides whether it runs; the branch rule stays as it is. | A rule listing jobs by hand drifts from the workflow, and the drift is only visible as a merge button that is wrong in one direction or the other. |
| A matrix job's name is never a required check. | `test` is named `${{ matrix.os }} ${{ matrix.shard }} (${{ needs.scope.outputs.suite }})` and `test-windows` `windows-latest (Git Bash) ${{ matrix.shard }} (…)`, and the number of shares changes from run to run with the work selected (adr-20261110-a-pull-request-runs-the-tests-its-change-reaches), so the job names move and `ci-ok` stays — which is the reason the rule names one check (adr-20261016-the-suite-runs-in-shares-on-every-platform). When `scope` skips such a job, GitHub never expands the expression: it reports one skipped check named after the expression (`matrix.os`, when `test` was named by the platform alone), and the contexts `ubuntu-latest` and `macos-latest` are never sent. A rule naming them leaves the pull request at "Expected — waiting for status to be reported" with a green suite behind it and no way to merge — which is what happened to #86, hours after the rule was changed to name them. |
| A skipped job passes only when something decided it should not run. | Skipping is how `scope` answers that the change needed no run, and how a job says it does not apply to this event; GitHub reads a skipped required check as successful. A skip nobody decided — a broken `if`, a runner that never started — looks identical, and the one required check would stay green over nothing. `ci-ok.sh` recomputes from `scope`'s outputs and the event which jobs had to run; its conditions are a deliberate second copy of each job's `if:`, because a verdict reading the same expression would agree with it when it is wrong. |
| *Inert since 2026-11-25: no pull request runs Windows shards, so `ci-reuse.sh` always answers `test` and `main` tests every push in full; the rule stays for the day a pull request runs every platform again.* A push to `main` whose tree a pull request's run of the whole suite already tested — the branch was up to date with `main`, and its run passed every platform, Windows Git Bash shares included, every test share named `… (all)` — skips `test`, `test-windows` and `smoke-windows` and goes on to `release`. `scope` publishes it as `reuse` (`.github/scripts/ci-reuse.sh`); `ci-ok.sh` expects those skips only then, and refuses `reuse` on any other event. A branch that was behind `main` when its run went still counts: the run records the merge it tested (`tested` in its `plan` artifact), `ci-reuse.sh` checks the record by recomputing the merge, and `main` then runs only the tests of what differs from that tree (`narrow`), the knowledge check always among them. `scope`'s outputs are decided in `.github/scripts/ci-outputs.sh`; `whole` says the proof is the whole suite (it ran, a pull request's run of it was reused, or it narrowed from one), and `release` reads `whole`, not `suite`. | The pull request's run already tested the merge, and testing the same tree again doubled the wait for every release tag; a lagging branch is the usual case, not the exception. The arguments and residual risk are adr-20261027-main-is-not-retested-when-a-pull-request-tested-its-tree and adr-20261118-main-tests-what-changed-since-a-full-pull-request-run. |
| A push to `epic/**` is measured like a pull request: from the commit of the branch's last successful run, and from `git merge-base origin/main HEAD` when there is none (empty only if that fails, which runs everything). Neither a pull request nor a push to `epic/**` runs the Windows shards (`.github/scripts/ci-windows.sh`), and a pull request whose scope is `full` runs the whole suite on Linux alone (`ci-matrix.sh` given the event); `selected` pull requests keep Linux and macOS. `main`, the nightly run and a dispatch run every platform, and a release is tagged only on a whole run of `main`, so a Windows- or macOS-only break shows as a red `main`, not on the pull request. Off `main` the matrices of `test` and `test-windows` carry `max-parallel` (6 and 5). An epic that holds nothing beyond its base (`ci-push-base.sh` says `empty`) is `light` with Windows skipped. `ci-ok.sh` reads scope's `windows` output for what to expect, and is also given the ref: `windows=false` on any run but a pull request and a push to `epic/**` is refused, so the skipped shards of a `main` push, the nightly run or a dispatch cannot read as decided. | An epic's first push has no green run, and the empty base ran nineteen jobs for a spec-only commit, holding the organisation's small concurrent-job limit, which every run of the repository shares. Reasons and price: the 2026-11-17 and 2026-11-25 amendments of adr-20260924-windows-runs-on-a-pull-request-that-touches-platform-behaviour and adr-20261016-the-suite-runs-in-shares-on-every-platform. |
| A pull request whose base is exactly a branch listed in `.github/scripts/ci-untested-base.sh` (today `epic/stack-migration`) is `light` whatever it changes: `scope` asks that script before `ci-scope.sh`, so only `knowledge`, `changelog` and `ci-ok` run and the required check still reports. Its tests run locally, on the push that merges it into the epic, and by a manual `workflow_dispatch`, which has a concurrency group of its own (`ci-dispatch-<run_id>`) so that a push to the same branch never cancels it. A retargeted pull request keeps the light run's green `ci-ok` until something re-runs it. | Skipping the workflow with `branches-ignore` would leave `ci-ok` waiting forever, as #86 did; a light scope is a decision `ci-ok.sh` already accepts. The stack migration ports code beside the bash one, and every pull request into its epic would otherwise run the bash suite for changes it cannot reach (the 2026-11-26 amendment of adr-20261110-a-pull-request-runs-the-tests-its-change-reaches). |
| A push to a branch listed in `.github/scripts/ci-epic-tests.sh` (today `epic/stack-migration`), and a `workflow_dispatch` on it whose `tests` input is empty, run that epic's own suites (`suite: selected`), never the whole bash suite: for the stack migration the new stack's tests, the parity check of the ported commands and the recorder. A light push stays light; `main` is never listed. A dispatch's `tests` input may ask for `all` or name `tests/run.sh` filters on any branch, and it reaches the `scope` script through env only. | The epic changes no bash, so rerunning its ~370 test files proved nothing new and cost ~45 minutes on Windows. The whole bash suite runs on `main` and once before the epic lands (stack-migration spec, owner decision 2026-11-27). |
| `red-main` is the one job outside `ci-ok`'s `needs`: it needs `ci-ok` and `release`, runs with `always()` on main's push and nightly runs only, and keeps one open issue labelled `red-main` while main is red — opened by the first red run, commented on by each further one, closed by the next green run whose `suite` is `all` (a light run tested nothing, a selected one tested part of it, and a narrowed one tested the difference from a tree a pull request ran in full, which releases through `whole` but does not close the issue; all leave it open). It names the failed tests from the shares' reports and the commits since the last green nightly run. The rules are `.github/scripts/red-main.sh`. | A red main is invisible to anyone not looking at Actions: after #318 it failed three times and 0.36.0 was never tagged while the documentation described it. An issue is GitHub's own notification, needs no secret, and gathers the repeats in one thread. It decides nothing about a merge, so it never joins `ci-ok`. |

## Example

The check that decides it, in `.github/workflows/ci.yml`:

```yaml
  ci-ok:
    needs: [scope, knowledge, test, test-windows, smoke-windows, changelog, epic-pr]
    if: always()
```

Its step passes `scope`'s outputs, the event and each `needs.<job>.result` to
`.github/scripts/ci-ok.sh`, which fails on a failed or cancelled job and on a skip the scope
did not decide, an empty list included.

## Probing the workflow itself

This section is a practice, not a rule the workflow enforces, and nothing in the repository
holds a copy of a probe: the branch is deleted as soon as it has answered, so a reader
cannot check one out. What is written down is how to build the next one.

A change to the workflow's own routing — a new output, a new `if:`, a job that must skip —
cannot be answered locally: nothing on a developer's machine evaluates a GitHub expression.
Waiting for the real suite to answer costs what the suite costs, and on Windows that is
about 25 minutes for a question worth seconds.

The practice is a throwaway branch carrying a trimmed `ci.yml`: the job being changed, plus
stand-in jobs on `ubuntu-latest` that carry the real `if:` expression and do nothing but
`echo`. A decision script is copied to `$RUNNER_TEMP` first, so the job can
`git checkout --detach` a historical commit and ask the script what it would have said about
a change that already happened. Run it with `gh workflow run ci.yml --ref <branch>`, read
which stand-in ran and which skipped, and delete the branch.

Two probes have paid for it, and both are history now. One answered in 29 seconds, instead
of 25 minutes, whether `jig_section_write` kept a CRLF file's endings under Git Bash. The
other asked the Windows signal (`ci-windows-scope.sh`, removed since) about the diff of #93 and about an ordinary change, and
got the routing
`adr-20260924-windows-runs-on-a-pull-request-that-touches-platform-behaviour` predicts — a
minute for the answer the real runner takes 25 to give.

## Rationale

A branch rule lives in GitHub's settings, not in the repository, so nothing tests it and no
review sees it change. Keeping the rule down to one name moves the whole decision into the
workflow, where a change to it is reviewed with the code — and where the reason a merge is
blocked can be read in a log rather than guessed from the settings page.
