---
id: adr-20261118-jig-lives-in-its-own-organisation
type: adr
status: accepted
date: 2026-11-18
domains:
  - install
paths:
  - install.sh
  - install.ps1
  - docs/docs.json
  - scripts/lib/self-update.sh
  - scripts/lib/doctor.sh
  - README.md
summary: Why Jig and Jig UI moved to the fapost-jig organisation (one Actions job pool per organisation), which addresses name it, which keep fapost-lab as history, and why the old names must stay free.
---
# Jig and Jig UI live in their own GitHub organisation, fapost-jig, and every live address names it

## Context

Jig and Jig UI lived in the fapost-lab organisation next to its other projects. On GitHub's free
plan an organisation has one pool of 20 concurrent Actions jobs (5 on macOS) shared by all of its
repositories. A full run of Jig's CI is 18 jobs (10 Windows, 4 macOS and 4 Ubuntu shards) for about
half an hour, so on a busy day Jig held almost the whole pool and the other projects of fapost-lab
waited in the queue. Minutes were not the problem: the repositories are public, and Actions on
standard runners are free for public repositories.

On 2026-11-17 the owner moved both repositories to a new organisation, fapost-jig, with GitHub's
transfer. A transfer keeps issues, pull requests, tags, repository rulesets and collaborators, and
GitHub redirects the old addresses — `github.com/fapost-lab/jig`, `git` remotes and
`raw.githubusercontent.com/fapost-lab/jig/...` — to the new ones. Apps installed on the old
organisation (Mintlify, which builds the documentation site) do not move and were installed again.

## Decision

- **The home is `fapost-jig/jig`** (and `fapost-jig/jig-ui`). Every live address names it: the
  installers' default repository and their own download lines, the install hints `jig doctor` and
  `jig self-update` print, `README.md`, the documentation pages and `docs/docs.json`.
- **History keeps its old address.** References such as `fapost-lab/jig#365` in code comments,
  accepted ADRs (the install line in ADR-0037 included) and changelog entries say where a thing
  happened; the redirect still opens them.
- **The names `jig` and `jig-ui` stay free in fapost-lab.** A repository created there under
  either name ends the redirect for everything still pointing at the old address.

## Alternatives

- **Stay and cap CI** (fewer Windows shards, `max-parallel`). Rejected as the whole answer:
  `max-parallel` limits one run, not the pool, and several pull requests in flight still fill it.
  Trimming the matrix stays open as a separate question.
- **Rely on the redirect and change nothing.** Rejected: it holds only while nobody reuses the old
  names, and new installs would keep writing the old address into their clone's `origin`.
- **Rewrite `origin` of existing installs** in `jig self-update`. Not done: installs made before the
  move fetch through the redirect, which works; rewriting a person's remote is a change of its own.

## Consequences

- New installs clone from `fapost-jig/jig`; installs made earlier keep `fapost-lab/jig.git` as
  their `origin` and depend on the redirect until they are reinstalled.
- Jig's CI has its own pool of 20 jobs and no longer stalls fapost-lab's projects, and the reverse.
- Organisation-level settings, apps and secrets of fapost-jig are kept by hand, apart from
  fapost-lab's.

> **Amendment (2026-11-18).** The third alternative is taken after all, narrowly: `jig self-update`
> repoints `origin` when it is exactly the old address (`https://github.com/fapost-lab/jig[.git]`,
> `git@github.com:fapost-lab/jig[.git]` or its `ssh://` form) to `fapost-jig/jig`, keeping the
> transport, says so in one line, and leaves any other remote alone. People who installed Jig are
> not developers and will not change a remote themselves, and the redirect ends the day the old
> name is reused. The update that brings this change still runs the old code and fetches through
> the redirect; the repoint happens on the next `jig self-update` after it, so the release carrying
> it should ship soon after the move.
