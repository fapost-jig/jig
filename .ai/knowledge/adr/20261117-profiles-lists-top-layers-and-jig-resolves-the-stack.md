---
id: adr-20261117-profiles-lists-top-layers-and-jig-resolves-the-stack
type: adr
status: accepted
date: 2026-11-17
domains:
  - verify
  - install
paths:
  - scripts/lib/profiles.sh
  - scripts/lib/verify.sh
  - scripts/lib/upgrade.sh
  - scripts/lib/init.sh
  - schemas/profile.md
summary: "Why a profile may extend one other (extends), why profiles: lists the top layers and Jig resolves the stack in one place (layer before base, errors not warnings, pure layers, stock versus project names), and how this refines the rule that upgrade never edits profiles:."
---
# `profiles:` lists the top layers, and Jig resolves their stack (`extends`)

## Context

A profile can only stand on its own. A project's own profile over a stock one (a warehouse
profile over `laravel`) cannot say so: `profiles:` is the whole list, `jig upgrade` installs
exactly what it names, and a base the list omits is deleted as an orphan of the manifest. The
spec `.ai/specs/profile-layers/` aims at layers, and this is the step that makes a layer a
thing the framework resolves: one key, one resolver, and a decision on what the list means.

Two earlier statements stood in the way. `adr-20260918-init-activates-detected-profiles` says
`upgrade` never activates a profile, and `schemas/profile.md` §Requires said activation "is not
closed over". Both are about choices a person made, and stay true for them; neither can mean
that a layer works without its base.

## Decision

- **`extends: <one name>` in `profile.yaml`.** A scalar: one base, a linear chain, like `FROM`.
  A list, `generic` (always first, never a base) and a value that is not a profile name are
  errors. `detect` of a base reached through `extends` is not asked: the layer called it.
- **`profiles:` lists the top layers; the stack is that list closed over `extends`**, and
  `profiles_stack_v` is the one place that closes it. `verify`, `upgrade`, `init`, carry and
  lock, and the ship notice read the stack from it. It runs in the caller's shell, never in
  `$( )`, never dies, and returns 1 with `PROFILES_STACK_ERROR` naming the layer and the base.
- **Order: a layer before its base, otherwise the order names were first met** (each listed
  name, then its chain down, repeats dropped; then names are taken one at a time, each the first
  all of whose layers are out). A list that names both a layer and its base is allowed and runs
  the base once, so lists written today keep their order and `covers` resolves as before.
- **A missing base, a cycle and a name clash are errors, not warnings.** `jig verify` refuses
  before running any profile (`FAIL <layer>: ...`, in `--explain` `PLAN <layer>: error (...)`),
  `jig upgrade` before placing a file, in link mode too; a layer that ran without its base would
  pass for work it did not do.
- **Stock and project.** A profile is stock when it exists in the source's `profiles/`, the
  manifest tracks `.ai/profiles/<name>/`, or it is a symlink (link mode). A profile is the
  project's when it is a real directory the manifest does not track and at least one file
  differs from the source's copy: a byte-identical untracked directory is a stock install that
  an upgrade interrupted (copy mode writes the manifest once, at the end) and the next run
  finishes it. A project profile under a stock name, in the stack, is one error naming both.
  Only the stack is checked, so a release that ships a new stock name breaks no project that
  did not activate the profile.
- **A pure layer is not a broken install.** A profile with `extends` and no `verify.sh` is not
  run, not counted and not skipped as `no verify.sh`; `jig verify` says
  `<layer> is a layer over <base>; its checks run in its bases`. A profile with neither stays a
  broken install.
- **Upgrade installs the bases.** This refines adr-20260918: `upgrade` still never edits
  `profiles:`, but turning a layer on turns its stack on, so a base is installed, kept current
  and never deleted while a layer reaches it. A first `jig init` writes only the top layers of
  what it detects.
- **Until "A layer overrides a check" lands, a layer's `checks.*` rows are refused** by `jig
  verify`, so an override is not silently ignored.
- **`requires` is unchanged.** It keeps closing detection and warning; its fate is decided by
  the task that makes `laravel` build on `php`. For `extends` the §Requires statement that
  activation is not closed over no longer holds; for `requires` it does.

## Alternatives

- **`extends` as a list.** Diamonds; the next task would have to say whose override wins when two
  bases touch one role. No case with two bases exists.
- **Make `requires` strict instead of adding a key.** `requires` means "needed beside", not "on
  top of"; strictness would silently change existing projects.
- **Plain walk order, or bases first.** A plain walk puts a shared base before the second layer
  over it; bases first reorders `[generic, laravel, php]` and with it who wins a `covers`.
- **Write the resolved stack into `profiles:`.** A list written by a machine again, a project
  layer beside its base, and a violation of the rule that a choice made is never edited.
- **A separate directory for project layers.** Moves every project profile to avoid a collision
  that a name rule closes.
- **Check every directory under `.ai/profiles/` for a clash, not the stack.** A new stock name
  would then break projects that never activated it.
- **Warn on a missing base and keep running.** The layer would work partly and pass.
- **Die inside the resolver, or call it in `$( )`.** `verify` would die with no `FAIL` line, and
  carry, lock and the ship notice would fail commands that never fail today.

## Consequences

- A project layer needs only `extends: laravel` and a `profiles:` entry; upgrade keeps the
  base in place.
- Rolling this back after a release would make upgrade delete bases that layers rely on, so it
  would need a migration note ("list the bases in `profiles:` before upgrading"); the shape
  `extends: <one name>` becomes a contract.
- Without a source checkout, `jig verify` cannot see a clash with a stock name it has not
  installed; `upgrade` and `init` always can.
- The next tasks build on `profiles_stack_v --edges`: the check table merge ("A layer overrides
  a check") and naming profiles nothing reaches.
