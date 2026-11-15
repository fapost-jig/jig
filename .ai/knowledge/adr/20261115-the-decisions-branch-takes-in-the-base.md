---
id: adr-20261115-the-decisions-branch-takes-in-the-base
type: adr
status: accepted
date: 2026-11-15
domains:
  - knowledge
paths:
  - scripts/lib/knowledge.sh
  - scripts/lib/owntree.sh
  - schemas/json.md
summary: Why a knowledge decision that needs what reached the base after the waiting decisions branch was cut merges the base into that branch instead of refusing not-on-branch, and why not-on-branch is left for a merge conflict
reviewed_at: 2026-11-15
---
# A decision that needs the base takes it into the decisions waiting

## Context

Knowledge decisions are committed on `knowledge/decisions[-N]` in Jig's own tree and judged on that
branch (adr-20261104-a-write-goes-in-jigs-own-tree). While the branch waits, each write goes on top,
so the branch never catches up with the base. A proposal, or a change to an accepted stub's source,
that reached `origin/<base>` after the branch was cut is not on it: the reads said `decidable: false,
reason: not-on-branch` and the write refused with that code
(adr-20261106-a-changed-link-is-dropped-by-reject). Nothing could decide that document until a
person merged the pull request that waited, and a page showing the buttons anyway gave a Keep that
did nothing.

## Decision

- **A decision that needs the base takes it in.** When an id of the call would be `not-on-branch`
  (the base holds it, the waiting tip does not), the write merges the base, as `jig_base_ref` reads
  it, into its tree (`ot_take_in_base`): `merge --no-commit --no-ff` on the branch the tree holds.
  The tree never lets go of the branch, so git still refuses a checkout of it for the length of the
  command and hooks see the real branch (adr-20261104-a-write-goes-in-jigs-own-tree). Validation
  reads the merged files, and `ot_commit` makes one merge commit: parents the tip and the base, the
  decisions message plus `Takes in origin/<base> at <sha>: <ids> reached it after <branch> was
  cut.` The branch keeps its name and its pull request.
- **What moves before the commit is only what origin holds.** A branch behind its tip on origin is
  fast-forwarded there inside the tree before the merge, and one only on origin is cut there, since
  a merge needs the branch it goes on. A refusal after that (a conflict, a check, a hook) leaves the
  branch at origin's tip: nothing is lost, as when a commit is refused after a fast-forward. A
  branch already at its tip moves only at the commit.
- **Only when needed.** A decision the branch already has what for goes on top as before; the
  branch does not take the base in on every write, and `spec/<id>` writes never do.
- **A conflict refuses with the old code.** When the merge conflicts it is aborted and the write
  refuses `not-on-branch`, naming the files; nothing was written. The remedy is the old one: merge
  or close the decisions waiting.
- **The reads stop promising a refusal that will not come.** What the base holds and the waiting
  tip does not reads `decidable: true, reason: null`. The reads never say `not-on-branch` now: a
  conflict is not predicted. `not-on-base` wins over a merge in a call that has both.
- Amends adr-20261104-a-write-goes-in-jigs-own-tree ("Otherwise the commit goes on top": unless a
  decision needs the base; "a branch that has to catch up is not moved until the commit": unless it
  takes the base in) and adr-20261106-a-changed-link-is-dropped-by-reject (`not-on-branch` is
  a write's conflict refusal, no longer a read's reason).

## Alternatives

- **Merge the base on every write once it moved.** Simpler, but a merge commit per click in the
  pull request, and `spec/<id>` writes would get them too.
- **Rebase the decisions branch onto the base.** Rewrites a pushed branch people review and needs a
  force push, which a write never does.
- **A new branch, `knowledge/decisions-N+1`, for such a decision.** Two pull requests into one base,
  conflicting on the same files, and the write's record names one branch.
- **Predict the conflict in the read** (`git merge-tree --write-tree`). It needs git 2.38 and runs on
  every `proposed --json`; the conflict is rare (both sides changed one knowledge document), and the
  write refuses it honestly.
- **Only the page hides the buttons on `not-on-branch`.** Explains the dead end without removing it.

## Consequences

- A person's waiting decisions can be asked for at any time; the pull request may carry a merge
  commit from the base, and shows only the decisions in its diff.
- The merge commit stages what came from the base, so a project's `pre-commit` hook, running in a
  tree with none of the project's dependencies, refuses it more often than a commit of knowledge
  alone: `commit-refused`, nothing written, and the remedy is to merge the waiting pull request.
- Squash detection (`ot_touched_equal`) counts paths from the merge-base of the branch and the base,
  which the merge moves to the base: only the decisions' paths remain, and a squash still reads gone.
