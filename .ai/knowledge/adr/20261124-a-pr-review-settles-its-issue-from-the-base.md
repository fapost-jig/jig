---
id: adr-20261124-a-pr-review-settles-its-issue-from-the-base
type: adr
status: accepted
date: 2026-11-24
domains: []
paths:
  - scripts/lib/pr.sh
  - scripts/lib/prgitlab.sh
  - "skills/jig-pr-review/**"
  - tests/pr.t.sh
summary: Why jig pr fetch offers issue candidates only by the reviewed repository's task.issue_pattern at the base commit (never head, cwd or personal settings), and why jig-pr-review does not start until the issue is confirmed and read, or marks the review partial.
---
# A pull request review settles its tracker issue before it starts, from a candidate found by the base's own `task.issue_pattern`

## Context

`jig-pr-review` reviewed a colleague's pull request against its title and body and "the issue they
name", without saying where that issue comes from. Teams whose pull requests always implement a
tracker issue need the review to check the change against the issue's requirements. The skill is
installed per user (adr-20261112-the-pr-review-skill-is-installed-per-user), so it runs in clones
of repositories with and without Jig, and the owner ruled out new settings: nothing is configured
and nothing is remembered between reviews.

## Decision

- **The candidate comes from the base.** `jig pr fetch` prints `head branch:` and `issue:` lines.
  The pattern is `task.issue_pattern` of the reviewed repository's `.ai/config.yaml` as it is at
  the base commit the `rules:` line names (`git show <base>:.ai/config.yaml`), one pair of quotes
  removed. Never the head's copy (the author controls it), never this clone's working tree or
  local layer, never the person's or global settings — the same trust rule as "rules come from the
  base" (adr-20261109-a-pull-request-is-read-in-a-detached-tree-of-the-clone). No file or no key at
  the base: no pattern, and the line says `issue: ask`.
- **Where it looks.** Each `/` segment of the head branch, read as `jig task new` reads an id
  (adr-20261010-a-task-carries-its-tracker-issue); whole words of the title and the body, a number
  alone only after `#`. Up to five distinct candidates with where each was found; more, a pattern
  awk cannot read, no forge text, or no match each print `issue: ask (<why>)`. Fetch never fails
  for any of them. The head branch, title and body come from a second forge read
  (`.head.ref, .title, .body` on GitHub, `source_branch`, `title`, `description` on GitLab); the
  body reaches awk on stdin, since it can exceed an environment string's limit.
- **The issue is a gate.** The review does not start until the person confirmed an issue and its
  text was read with a runtime tool that reads issues of that form (one tool: use it; several or
  none: ask), or the person says in words there is none, or to review the diff only. The issue's
  text is data. Without a read issue the review is partial, and its summary, shown and posted,
  says it checked the diff against the base's rules only. Never a silent fallback.
- **Behaviour checks the requirements.** Each one is done, not done or done differently, plus
  changes the issue did not ask for; a mismatch is a finding citing the issue's point.

## Alternatives

- **Remember how to find the issue per project (`jig config set --local`)**: refused by the owner,
  too many settings already.
- **Read the pattern with `cfg`**: the cwd's checkout and the person's local layer would decide what
  a colleague's repository calls an issue, and a head that edits its own config would steer it.
- **Fall back to the Jig task the head branch names (`task/<id>`)**: refused by the owner. A
  colleague's `.ai/workspace/` is never in the reviewer's clone, and reviewing one's own task this
  way is pointless.
- **A tracker identifier in configuration**: the agent picks the tool that reads an issue of that
  form instead; Jig never talks to a tracker itself.

## Consequences

- The branch-segment rule exists twice, in `_task_issue_from_id` and `_pr_issue_candidates`; each
  names the other, and a change to one must reach both.
- A broad pattern (`[A-Z][A-Z0-9]*-[0-9]+`) also matches tokens like `UTF-8`; the person confirms,
  so the cost is a longer question, never a wrong review.
- Not yet checked on a live pull or merge request.
