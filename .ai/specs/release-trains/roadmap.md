# Roadmap — Release trains

Destination: with trains on, a task's pull request merges in 10 minutes or less, main receives
nothing the full matrix has not passed, and the time from a task's merge to its tag does not grow.

## Phase 1 — A task goes to the train

Goal: a project that turns trains on cuts and ships its tasks into one open train, guarded by the
train's gates. Done when: in a project with trains on, `jig task start` cuts from the open train,
and `jig task ship` refuses a task above the train's level and any task onto a red train.

- [ ] release-trains-config — the project key, its question in `jig-setup`, and `jig doctor` saying the option has no effect under `git.flow: staging`
- [ ] task-level — a task's level in its state, set at analysis and shown at release planning
- [ ] start-cuts-from-train — `jig task start` cuts from the open train, and the next train is cut when one ships (after: `release-trains-config` — the key is what turns it on)
- [ ] ship-train-gates — `jig task ship` into a train refuses a level above the train's, a version raise, and a red last full run (after: `task-level` — the gate reads the level; after: `release-trains-config` — the gate applies only with trains on)

## Phase 2 — CI by tier

Goal: CI runs the reduced tier for work into the train and the full matrix on the way into main.
Done when: this repository's task pull requests into the train run Linux with the selected tests
plus the Windows smoke, and both success numbers are measured on a real train.

- [ ] ci-tier-signal — a command naming the tier a pull request needs: task into train, sync, train into main, direct (after: `release-trains-config` — the tier depends on trains being on)
- [ ] repo-ci-uses-tier — this repository's `ci.yml` runs by tier, nightly on the open train, and the success numbers are measured (after: `ci-tier-signal` — it reads the signal)
- [ ] docs-ci-recipe — the recipe for installed projects' CI in `docs/` (after: `ci-tier-signal` — it describes the signal)

## Phase 3 — Release from the train

Goal: a release is the train's last pull request. Done when: a train ships into main through
`jig-release`, with notes written after the final sync and `notes_through` naming the train's commit.

- [ ] release-from-train — `jig-release` and the notes task on the train, the train's pull request into main (after: `start-cuts-from-train` — the train must exist)
- [ ] fog: trains under the staging flow — rests on how a task of an epic passes through staging, a question held by the unfiled task `epic-in-staging-flow`

## Waves

1. release-trains-config; task-level
2. start-cuts-from-train; ship-train-gates; ci-tier-signal
3. repo-ci-uses-tier; docs-ci-recipe; release-from-train

<!--
Rules (jig-idea §8):
- An item is a finished slice that makes the product noticeably better, never a layer.
- A dependency without a one-line reason is not a dependency.
- A `task-id` appears when the item's task is filed; `[x]` is set when that task is closed.
- `fog:` items are not split or sized; they become real items once the fog lifts.
- No dates, no point estimates: order is the priority.
- `jig spec list` counts checkbox lines only: `[x]` done, a leading backticked task id
  followed by a dash (`—` or `-`) filed, a leading `fog:` fog. Keep waves as a numbered list.
- A wave entry names an item by its title (the text before its first ` — `) or its task id,
  entries separated by `;` — `jig spec plan` reports an entry that names no item or several.
-->
