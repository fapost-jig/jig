---
id: adr-20261117-an-upgrade-is-built-in-jigs-own-tree-and-merges-itself
type: adr
status: accepted
date: 2026-11-17
domains:
  - install
  - config
  - housekeeping
paths:
  - scripts/lib/upgrade.sh
  - scripts/lib/owntree.sh
  - scripts/lib/config.sh
  - scripts/lib/status.sh
  - docs/upgrading.mdx
summary: Why a copy-mode upgrade is built, committed and shipped in Jig's own tree without touching the person's checkout, and merges its own pull request on green CI at any agent.git unless the personal upgrade.merge is human.
---
# A copy-mode upgrade is built, committed and shipped in Jig's own tree, and merges its own pull request on green CI unless `upgrade.merge` is `human`

## Context

After every Jig release the owner opened and merged `jig/upgrade-<version>` by hand in each of
their projects: they run `agent.git: pr`, and only `merge` let an upgrade merge itself. Three
more cases came in on 2026-11-17:

- **lure**: the main checkout was on a task branch with uncommitted work, and the upgrade refused
  (`upgrade-blocked`: uncommitted changes, a started task on HEAD). An upgrade that cuts its branch
  in the person's checkout must take that checkout away from them, so it has to refuse.
- **telescope** (`agent.git` unset): the checkout still stood on `jig/upgrade-0.41.0`, pushed with
  no pull request, and `jig upgrade` to 0.46.0 staged onto that old branch, because "a run already
  on a `jig/upgrade-*` branch stays there" (adr-20260926) never compared the version.
- **jig-ui**: the upgrade's pull request waited, and `jig upgrade --land` refused "switch to main",
  although 0.46.0 (#510) no longer refuses a third branch: the project ran its own 0.45.0 copy,
  and `--land` never handed itself to newer code.

adr-20261104 already gives Jig a tree of its own for writes that must not move a checkout.

## Decision

- **A personal key, `upgrade.merge`: `agent` (default) or `human`.** Local-only, as every git
  right (adr-20260921): a committed value would grant every contributor's upgrade a merge. A team
  that wants a person to look at upgrades has the forge's branch protection, which
  `jig_ship_merge` never overrides (`not merged: the forge refused`). Read by
  `jig_upgrade_merge`; an invalid value reads as `human`, so a mistake never merges.
- **`agent` is a right of the upgrade's own, at every `agent.git`, `none` and unset included.**
  Every ship step of the upgrade — the GitHub account check, push, pull request, merge and the
  deletion of its branch on origin — runs at the effective level `merge`, and the report and
  `--json` name the key it came from (`level_key`). The reason it may exceed `agent.git`:
  that level limits what the agent does, by its own judgement, in a person's checkout
  (ADR-0029); an upgrade is Jig's release — one reproducible commit, made outside that checkout,
  checked by CI and undone by one revert. `human` keeps the upgrade at `agent.git` exactly as
  before, and never merges, even at `merge` (it narrows `merge`, as `release.merge: human` does).
  The level is `agent.git`'s, never `autopilot.git`'s or `agent.git_staging`'s: a click in a page
  or a `jig upgrade` in a session is not a run.
- **The tree.** A real copy-mode run whose branch will reach origin (a first commit, a branch per
  task, an `origin`, an effective level of `push` or above) works in `<git-common-dir>/jig/tree`
  under the clone's owntree lock, through owntree's level-free public steps
  (`ot_lock_and_sweep`, `ot_tree_add`, `ot_close`), and is never a write: no record under
  `.ai/runtime/writes/`, no revision claim. In order: hand-off to newer code; only the line-ending
  stop remains (the tree is clean, holds no task and runs no `jig verify`); fetch the base; the
  tree detached at `origin/<base>`, never the checkout's branch; the install, self-check and
  staging with `JIG_PROJECT` on the tree, while the forge cache, the commit message file and the
  revision are written in the main checkout; the commit made detached, and `jig/upgrade-<to>`
  created at it only once it exists — a refused commit (a project's pre-commit hook, say) leaves
  no branch and no tree; the branch name free here and on origin (`ls-remote`, as a write's);
  push, pull request, an `open` line in the forge cache; then the tree removed and the lock given
  back **before** the merge waits for CI.
- **The merge** is `jig_ship_merge … any`, unchanged: at least one check, every one green within
  `agent.ci_timeout`, at the shipped commit, never `--admin` or `--auto`. `jig upgrade` can
  therefore run for that long; `jig status` shows `upgrade-pull-request-waiting` meanwhile.
  `not merged: <reason>` leaves the pull request open, and `--json` carries its code
  (`git.not_merged`).
- **After the merge** the forge cache says `merged`; the branch goes through `jig_branch_leave`
  with the merged head — here, and on origin at the effective level; then the base moves forward
  as `jig refresh` moves it (`jig_base_fast_forward`, common.sh, the one function both use):
  fast-forwarded where it is checked out, its ref moved where it is checked out nowhere, left where
  another worktree has it or a fast-forward would overwrite a change, and left where `jig verify`
  runs in the checkout on it. **No step after a merge switches a checkout.** A checkout on another
  branch takes the new Jig when it next merges the base, and the run says so in a `next:` line.
- **A repeat** finds an unmerged `jig/upgrade-<to>` of the same version, here or on origin. Under
  `agent` it carries it on — pushes it if origin lacks it, opens the pull request if none is open,
  waits and merges — only when every commit on it above the base is Jig's (one parent, the subject
  `Upgrade Jig <from> -> <to>`, only manifest paths, `.ai/manifest` or `AGENTS.md`), or when the
  person's own `agent.git` is `merge`. Otherwise it refuses `branch-has-other-commits` and sends
  nothing: Jig never publishes or merges a commit it did not write on a right the person did not
  give. Under `human` the refusal `not-merged` stays.
- **Older upgrade branches** (`jig/upgrade-<v>`, v older) are never stood on, deleted or closed:
  they may hold a person's commits. After a merge the run names them as superseded; deleting them
  is a separate housekeeping task.
- **The in-checkout path stays** where the tree cannot carry the upgrade: no origin, no commit,
  `git.branch_per_task: false`, `human` below `push`, and a project that gitignores a path the
  upgrade places — such a path cannot travel in a commit, so that run upgrades the checkout as
  before, says which paths, and reports `git.path: checkout`. There "already on a `jig/upgrade-*`
  branch" holds only for this version's branch. A dry run stays read-only on both paths.
- **`jig upgrade --land`** is handed to the machine's newer jig when the project's copy is older,
  by `_upgrade_handoff`'s rule and loop marker. It stays the step after a person's merge, after
  `human`, and for a base the merge could not move.
- **`jig status`** gains `upgrade-on-base`: this checkout is not on the base, its Jig is older than
  the machine's, and the base here already records the machine's version; it replaces
  `upgrade-available` there, whose `jig upgrade` would only answer "nothing changed". Local refs
  only, no network.
- **The staging flow** changes nothing: the upgrade's pull request goes into `git.base_branch`
  (adr-20261114), and the staging branch takes it as it takes any commit of the base.

## Alternatives

- **`agent` only at `pr` and `merge`.** Closer to adr-20260921, but every project on the default
  `none` keeps the busy-checkout refusal and the staged files the telescope case shows; the owner
  asked for zero configuration.
- **Return after the pull request and merge later** (a repeat, `--land`, or housekeeping). No call
  waits for CI, but "merges itself" becomes "merges whenever something runs next". The repeat
  above keeps this as the second way in.
- **`gh pr merge --auto`.** Only the promotion may (adr-20261112): the forge would merge with
  nobody watching Jig's conditions.
- **A tree and lock of the upgrade's own.** No contention with writes, but a second `--force`
  removal and a second sweep. One Jig tree per clone.
- **A project key.** Rejected as above.
- **The upgrade into the staging branch.** Every task cut from the base would stay on the old Jig
  until a promotion.
- **`git add -f` for gitignored framework paths.** It would commit files a project chose to keep
  out of git; the in-checkout path keeps what such a project had.
- **Merge a repeated branch whenever origin holds its tip.** That merges a person's push (a fix
  after red CI) on a right they did not give.

## Consequences

- An upgrade no longer refuses a dirty or occupied checkout, and needs no person in the usual case;
  the person's checkout is never switched, before or after the merge.
- `jig upgrade` can block up to `agent.ci_timeout` plus the two minutes `jig_ship_merge` gives a
  check to register; a program shows the waiting item meanwhile.
- A project with no CI gets `not merged: CI checked nothing`, and one that requires a review gets
  `not merged: the forge refused`: the pull request stays open, as before.
- A pre-commit hook that needs the project's dependencies refuses the upgrade in the bare tree;
  accepted for now, as for writes (adr-20261104). Amended 2026-11-18 (below): the run goes on in
  the checkout instead.
- While a write holds the lock the upgrade is refused `write-busy`, and the other way round.
- An agent that runs `jig upgrade` at `agent.git: none` now gets a commit, a push and a merge made
  for it: the one place that level no longer means "nothing leaves the machine". `upgrade.merge:
  human` takes it back.
- `--land`'s hand-off protects only from the first version that has it; a 0.45.0 project lands
  through the global `jig`.

## Amends

adr-20260921, adr-20260930, adr-20260926, adr-20261029, adr-20261104, adr-20261114, adr-20261007:
each carries an amendment of 2026-11-17 pointing here.

> **Amendment (2026-11-17).** An upgrade still never stands on an older upgrade branch, but
> housekeeping now deletes one that holds only Jig's commits, here and on origin, and closes its
> pull request at `pr` or above; the `note:` says so
> (adr-20261117-a-superseded-upgrade-branch-leaves-without-landing).

> **Amendment (2026-11-18, task upgrade-precommit-in-own-tree).** A pre-commit hook refusing the
> commit in the tree is no longer accepted as a refusal: it joins the cases where the in-checkout
> path stays. When the detached commit fails and the project has a pre-commit hook
> (`core.hooksPath` set, or an executable `hooks/pre-commit`), the run gives the tree and the lock
> back (`ot_close`; no branch exists yet), says so in a `note:` that does not quote the hook's
> output (a hook that caught a secret may print it), runs the checkout's preflight (a busy checkout
> ends in `upgrade-blocked`, nothing changed), cuts `jig/upgrade-<to>` there and installs again,
> since placement already happened in the tree. It then ships at `agent.git`, as the gitignored-path
> fall-back does and as 0.46.0 did: the reason the upgrade may exceed `agent.git` is that its commit
> is made outside the person's checkout, and here it is not. `--json` names why a run fell back,
> `git.fell_back`: `gitignored`, `pre-commit-hook` or `null`. Without a hook, a refused commit stays
> `commit-refused`. A hook that refuses in the checkout too leaves the branch with the change staged,
> which a repeat finishes (adr-20260926). Rejected: `--no-verify` or plumbing (hooks run, never
> skipped: `jig_ship_commit`, adr-20261104); bringing the project's dependencies into the tree (which
> directories a hook needs cannot be known, a copy can be large, running the project's setup is slow
> and not zero-config, and a formatter run by the hook could rewrite Jig's files away from the
> manifest's hashes). Writes (adr-20261104) keep their `commit-refused`.
