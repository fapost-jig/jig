---
id: adr-20261117-a-superseded-upgrade-branch-leaves-without-landing
type: adr
status: accepted
date: 2026-11-17
domains:
  - housekeeping
  - install
paths:
  - scripts/lib/housekeeping.sh
  - scripts/lib/common.sh
  - docs/upgrading.mdx
summary: Why housekeeping deletes an unmerged jig/upgrade-* branch the base has superseded when every commit on it is Jig's own upgrade commit, and closes its open pull request with a comment first at agent.git pr or above.
---
# Housekeeping deletes a superseded upgrade branch that never landed, when every commit on it is Jig's, and closes its pull request first at `pr` and above

## Context

Every Jig release leaves a `jig/upgrade-<v>` branch in each project, and the ones that were never
merged pile up: a newer upgrade lands on the base, and the older branch — local, on origin, often
with an open pull request — stays for good. adr-20261117-an-upgrade-is-built-in-jigs-own-tree-and-merges-itself
names them in a `note:` after a merge and left deleting them to a housekeeping task. The owner
decided on 2026-11-17 that housekeeping deletes them.

Until now a branch Jig made left only when its work landed (adr-20261007-a-merged-branch-leaves-with-its-work):
`git branch -d`, or a tip inside the head of a pull request the forge reported merged. A superseded
upgrade branch never lands: its commits are in neither the base nor a merged pull request. And
housekeeping, which runs at the start of every session of every contributor, only ever read the forge.

Some such branches carry a person's work: in one project `jig/upgrade-0.41.0` held a commit of the
person's on top of the upgrade.

## Decision

- **Superseded** — `jig_upgrade_superseded` (common.sh): the branch is named `jig/upgrade-<v>` or
  `jig/upgrade-<v>-<n>` with `<v>` a release version; the `jig.version` its manifest records has the
  release number `<v>`; and the base (`jig_base_ref` of the default branch) records a Jig strictly
  newer than `<v>`. A branch that landed is the existing sweep's, not this.
- **Only Jig's commits** — `jig_upgrade_commits_are_jigs` (common.sh), the rule the upgrade's own
  repeat already applies, moved from upgrade.sh so that one rule serves both: at least one commit
  above the base, and each has one parent, the subject `Upgrade Jig <from> -> <label>` with `<label>`
  the tip's `jig.version`, and touches only paths the manifest records at the base or the tip,
  `.ai/manifest` or `AGENTS.md`. A merge commit, an amended commit carrying a file of the person's,
  or any other commit makes the branch not Jig's.
- **Here**, at any `agent.git`, in the main checkout only, with the sweep's other conditions
  (`git.delete_merged_branches`, `jig_branch_deletable`, not kept, checked out nowhere): a branch that
  is superseded and only Jig's goes by `git update-ref -d refs/heads/<b> <tip>` at the tip that was
  checked, and the line `deleted superseded branch <b> (was <sha>)` — the sha restores it
  (`git branch <b> <sha>`) until git collects it. A superseded branch with any other commit is kept,
  local and origin, with a `kept branch` line that names the commit.
- **On origin**, only with the rights and conditions the sweep already needs there (`push` or above on
  `agent.git`, `autopilot.git` or `agent.git_staging`, `housekeeping.fetch`, an `ls-remote` answer):
  origin's copy is judged by its own commits, at the sha `ls-remote` reports and only when that is
  the commit fetched here. The forge is asked about this branch alone — its open pull requests as
  head and as base (`_hk_open_prs_of`) — since the run's list holds only the newest ones and a missing
  row is no evidence that none is open; deleting the head of an open pull request on GitHub closes it
  with no comment. Without that answer (no forge, a forge that failed) origin's copy stays, named, and
  so does one with a pull request stacked on it.
  It goes in the sweep's one lease push (`jig_branches_leave_origin`), so a branch pushed to after
  the check stays.
- **Its open pull request** is closed before the branch is deleted on origin, with a comment that
  says it was superseded and how to restore the branch — only at `pr` or above on the same three keys
  (closing a pull request is an act on it, not a push), and only while the pull request's head is the
  commit that was checked. GitHub `gh pr close <url> --comment`, never `--delete-branch`; GitLab
  `glab mr note` then `glab mr close`. A pull request that cannot be closed keeps the branch on
  origin. Below `pr` a branch with an open pull request stays on origin, named. Housekeeping's first
  write to the forge is this one.
- A dry run says `would …` and writes neither git nor the forge.

## Alternatives

- **Two phases, as trash (ADR-0006)**: move the tip to `refs/jig/superseded/<b>` and expire it after
  `housekeeping.trash_ttl`. A sturdier undo, but a new ref namespace, a new sweep and its tests, for
  branches whose content the base already has in a newer version. The sha in the line and the log,
  and the closed pull request's own "Restore branch", are undo enough.
- **Only name them** (the state after adr-20261117-an-upgrade-is-built-in-jigs-own-tree-and-merges-itself):
  rejected by the owner; the branches and pull requests pile up in every project.
- **Close pull requests at `push`, as origin's deletion**: a push right is not a right to act on a
  pull request.
- **Judge each commit by its own manifest and its parent's**: a second rule beside the upgrade's
  repeat would drift from it; the shared one reads the manifest at the base and the tip.

## Consequences

- A project's stale upgrade branches and their pull requests go on their own, at the next session
  start of someone with the rights; a branch with a person's commit is named every run until they
  delete it.
- Housekeeping now writes to the forge, at `pr` and above, once per superseded pull request.
- A person's `--amend` into the upgrade commit that touches only paths the manifest records, or
  `AGENTS.md`, passes the rule and the branch is deleted; the sha in the line and in
  `housekeeping.log` restores it until git collects it. Accepted: the rule is the one the upgrade's
  own repeat already trusts to merge.
- Housekeeping asks the forge two more questions per superseded branch on origin, and none for
  others.
- An upgrade that once placed a file outside its manifest leaves its branch named, not deleted:
  a false "not Jig's" is safe, a false "Jig's" is not.
- A local copy that is not superseded (its manifest disagrees with its name) does not protect
  origin's copy, which is judged on its own; one that is kept for a person's commit does.

## Amends

adr-20261007-a-merged-branch-leaves-with-its-work (landing is no longer the only ground for deleting
a `jig/upgrade-*` branch) and adr-20261117-an-upgrade-is-built-in-jigs-own-tree-and-merges-itself
(older upgrade branches are still never stood on by an upgrade, but housekeeping deletes and closes
the ones that hold only Jig's commits).
