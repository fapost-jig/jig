# Release trains — tasks merge on a reduced CI, the full matrix guards the way into main

Summary: Tasks merge into an open release train on a CI reduced to their change, in ten minutes or less,
and only the train's pull request into main runs the full matrix.

Depth: normal, with the independent failure hunt — the option changes the release flow and where
a task lands, and a mistake reaches main and every project that installs Jig.

## Idea

The owner, 2026-11-15:

> вернемся к вопросу формирования релиза (релизной ветки) ведь если мы создаем релизную ветку, и в
> нее пушим все текущие задачи, то мы можем и сиай настроить так, чтобы он проверял только
> изменения. Это позволит ускорить мерж задач. И тогда полный сиай будет только на пр в мейн

(If we create a release branch and push all current tasks into it, CI can be set up to check only
the changes. That speeds up merging tasks, and the full CI runs only on the pull request into
main.)

> моя идея уменьшить время выпуска новых задач. Да, мы должны поддержать это опционально, оно точно
> не должно сломать стейджинг флоу, но при этом не исключено, что даже со стейджинг флоу можно
> планировать релиз. Но так же как по мне есть проблема, если одна из задач меняет семвершен, как
> тогда расходиться?

(The aim is to cut the time it takes a new task to come out. It must be optional and must not
break the staging flow, though a release might be planned with the staging flow too. And if one of
the tasks changes the semver level, how do the tasks part ways?)

## Goal and problem

- Who is worse off without this, and how: the owner and the agents shipping tasks. A task's pull
  request takes 15–40 minutes to merge (the last 25 pull requests, measured 2026-11-15), although
  every pull request already runs only the tests its change reaches
  (adr-20261110-a-pull-request-runs-the-tests-its-change-reaches). The time goes to macOS — in
  `gate-hooks`, a selected run of 40 minutes, macOS shards of 4–9 minutes started 15–32 minutes in,
  waiting for runners — and to ten Windows shards of 11–16 minutes when platform behaviour is
  touched. Dropping those platforms from a task's pull request into main is not safe today: main
  would go red on macOS, and CI tags only a green main (ADR-0034).
- What is true when the work is done: in a project that turns trains on, a task's pull request
  merges into the open train in 10 minutes or less under ordinary load, main never receives a
  change the full matrix has not passed, and the time from a task's merge to the tag that releases
  it is no worse than today.

## Stress test

- Hidden assumptions — "this holds only if …":
  - The reduced tier is safe only if the full matrix still runs often enough on the train that a
    fault is found while few tasks sit on top of it: the nightly run on the train is what keeps
    the culprit findable.
  - "One open train" is enough only while a task above the train's level is rare; at 0.x a
    breaking change is a minor release, so most work fits a minor train.
  - The queue watcher (spec `queue-watch`) needs no change only if `jig task start` and
    `jig task ship` alone decide where a task goes.
- The main trade-off: time from a pull request to its merge against time from a merge to its
  release — work waits in the train, and the full matrix is still paid at every sync, every night
  and at the final pull request.
- The weakest point: faults the reduced tier cannot see (macOS, Windows, tests the verify map does
  not select) pile up in the train until the nightly run or the final pull request, where no
  single task's pull request ever ran the failing test.
- Failure modes — cause, what breaks, the signal that shows it (from the independent hunt, ranked):
  1. Faults pile up unseen in the train — the final pull request fails with many tasks merged and
     no culprit — failures in files no recent task touched; a halt lasting days.
  2. The queue watcher keeps merging onto a red train, because a red nightly does not gate merges —
     the fix is buried in fresh changes — the train's nightly red several days while merges rise.
  3. A wrong level, or no train that fits — a breaking change rides a patch train, or a ship names
     a train that does not exist — reverts inside a train; tasks parked on a level refusal.
  4. A hotfix moves main past the train's `notes_through` and takes the version the train planned —
     the final pull request is refused again and again — repeated "main moved past" refusals.
  5. Dependencies and consolidation stuck at the train's edge — a task cut without the work it
     needs; `needs consolidation` grows — cherry-picks across trains.
  6. Syncs of main into the train run the reduced tier — a large merge lands Linux-only — the
     train's nightly red the night after a sync.
  7. The option set per person splits the team between bases — pull requests into different bases
     for one queue — branches with different merge bases.
  8. Installed projects misread the tier signal — a train's final pull request runs selected tests
     only — it takes as long as a task's pull request.
  9. Less time saved than expected — merge-to-tag grows — the time from a task's merge to its tag.
- Other shapes considered, and why this one:
  - A release branch per version number, several open at once — rejected for v1: a number is not
    known until the notes are written (adr-20261112-release-notes-name-the-commit-they-describe),
    and parallel trains need cross-train syncs nobody asked for while Jig is at 0.x.
  - Taking a task back out of a train with a revert of its merge — rejected: merging it again
    later needs a revert of the revert, which is fragile.
  - A new object for the train — rejected: a release epic already carries a spec, a branch, a
    declared level and the hotfix-from-main rule (adr-20261002-a-release-is-a-spec-with-an-epic).

## Scope and non-goals

- In scope:
  - A project setting that turns trains on, written by `jig-setup` after a yes.
  - A level on each task; `jig task start` cutting from the open train; the train's gates in
    `jig task ship`; the next train cut when one ships.
  - A signal telling CI which tier a pull request needs, a docs recipe for installed projects, and
    this repository's CI as its first consumer.
  - `jig-release` and the notes task working on the train.
- Not doing:
  - Changing the staging flow. Under `git.flow: staging` the option has no effect and `jig doctor`
    says so.
  - Several trains open at once.
  - Any change to the direct flow when the option is off.

## Decisions

- **Trains are a project setting, off by default**, a key beside `git.flow`, written to
  `.ai/config.yaml` by `jig-setup` after a yes (adr-20261109-the-team-names-its-git-flow-and-the-agent-writes-it-after-a-yes)
  — rejected: a personal setting in `.ai/config.local.yaml`, because two people on one project
  would cut tasks from different bases.
- **A train is a release epic**: named by the day it was cut and carrying a level, never a version
  number; the number is chosen in the notes, which are the train's last pull request, written after
  the final sync of main — rejected: a new object; and a number at cut time, because a hotfix from
  main can take it.
- **One train is open at a time**, and when it ships the next one is cut automatically, so a task
  always has a train to go to.
- **A task has a level**, set by the agent at analysis and confirmed by a person when the release
  is planned. At 0.x "breaking" means minor.
- **`jig task ship` into a train refuses** a task whose level is above the train's, a task that
  raises the declared version (as today for an epic, adr-20261026-a-task-that-raises-the-version-is-a-release),
  and any task while the train's last full run is red, as `main-green-check` guards main. A task
  above the train's level waits on its branch; the ship says that a person raises the train's level
  — rejected: taking a task out of a train by reverting it.
- **CI tiers**: a task's pull request into the train and a push to the train run Linux with the
  selected tests plus the Windows install smoke; a sync of main into the train, the nightly run of
  the open train, and the train's pull request into main run the full matrix.
- **A red full matrix on the train's pull request into main halts the train**; the fix is an
  ordinary task into the same train.
- **A hotfix** is a patch release from main, as adr-20261002 already allows, synced into the open
  train.
- **A task merged into a train is consolidated as a task of an epic is today**; no new rule.
- **Success is measured both ways**: a task's pull request merges in 10 minutes or less, and the
  time from merge to tag does not grow.
- **For installed projects Jig provides the tier, not the CI**: a command that names the tier a
  pull request needs (task into train, sync, train into main, direct) and a recipe in `docs/`.

## Open questions

- How the train's "last full run is red" check is answered on GitLab — the ship gate depends on
  it outside GitHub.

## Set aside

- unexplored: GitHub's own merge queue as another road to the same goal.
- unexplored: fewer macOS shards on a pull request, without trains — the runner queue is the main
  delay, and this could be a task of its own now.
- unexplored: how a train is shown in `jig status` and Jig UI; Jig UI is another developer's, so
  Jig would deliver a contract only.

## Assumptions left untested

- The queue watcher needs no change, since `task start` and `task ship` decide where a task goes —
  taken at normal; the first watcher run with trains on would test it.
- GitHub first — taken at normal; the first installed project on GitLab would test it.
- A nightly full run on the train finds faults while few tasks sit on top of them — taken at
  normal; the halts measured in the first trains would test it.
