---
id: adr-20261119-a-gate-takes-an-answer
type: adr
status: accepted
date: 2026-11-19
domains:
  - task
  - skills
  - scripts
paths:
  - scripts/lib/task.sh
  - scripts/lib/status.sh
  - schemas/json.md
  - schemas/state.md
  - "skills/jig-task/**"
  - "skills/jig-autopilot/**"
  - docs/reading-jig-as-data.mdx
summary: Why a person at a T3/T4 gate approves or answers (jig task gate <id> answered --answer), why an answer is not approval and the gate returns to waiting when the design changes, why the design carries a fixed Gate questions section parsed as data, and why an answer at a stopped attended run's gate answers the run.
---
# A person at a T3/T4 gate either approves the design or answers it; an answer is not an approval, the design carries its questions as data, and an answer at a stopped attended run's gate is its stop's answer

## Context

A design at its gate reached the person as a card saying only that it waited. What the agent needed
decided was somewhere in `design.md`, and the one thing the person could record without the agent's
session was `jig task gate <id> approved`. Neither "change this" nor a choice between the options the
agent saw could be written down, so with several tasks waiting the person had cards they could
neither read nor answer. A stopped autopilot run had already solved the same problem
(adr-20261114-a-waiting-run-holds-no-slot): its question is data on the `autopilot-stopped` item and
`jig task autopilot <id> answer` records the person's words. The owner approved this design at the
gate of task `gate-answers` (2026-11-19), with its three questions settled as recommended.

## Decision

- **The design states what it needs decided.** A T3/T4 `design.md` has a `## Gate questions` section:
  `### <question>`, optional context lines, `- <option>` lines and a `Recommended: <text>` line, 0–5
  questions. The heading and `Recommended:` are fixed English tokens, like `## Goal` in `task.md`,
  because designs are written in the reader's language and a marker in one language breaks every
  other project. The design is written as if every recommendation were taken, so an approval means
  "take your recommendations". Jig parses the section into `questions` (`null` when the section is
  missing, `[]` when it holds no question); a malformed section never fails a read, and `jig task
  artifact write <id> design` only warns when the section is missing or holds more than five.
- **A second decision at the gate: `answered`.** `jig task gate <id> answered --answer <text>
  [--revision <n>] [--json]` records `gate: answered`, `gate_design` (the hash of the design that was
  answered) and `gate_by: human` under one revision claim, and appends `<utc> <hash> <by> <text>` to
  the task's append-only `gate-answers` journal. The answer is one line with no tab, the contract of
  `autopilot answer`. It is refused for an approved, unchanged design and for `--by agent`, and
  otherwise with `approved`'s codes and its one guard (`_task_gate_check`, which now takes the
  decision), so the `answer-gate` action beside `approve-gate` offers only what the command accepts
  (adr-20261015-one-table-of-what-a-person-may-do).
- **`answered` is not approval.** The gate is `answered` while the design is the one answered; when
  the design changes it is `waiting` again, never `changed`, which means "moved after an approval".
  The route's record of the gate (adr-20261004-a-route-stage-is-proven-by-its-record) is still only
  `approved` with a matching hash. An answered gate is no attention item; a waiting one shows the
  last answer beside the new questions.
- **An answer at a stopped attended run's gate answers the run.** When the task's attended run is
  `stopped` at a waiting gate, `approved` and `answered` also write the run's `answer` journal line
  and `autopilot_answered`, so the run is listed under `resume` and resumed on a free slot. Such a
  task is shown as the gate item, with the run's `stopped_at`, instead of `autopilot-stopped`: one
  card for one situation, whose actions already answer the run. The card of an unattended or a
  phase run is unchanged (an unattended run's gate is the agent's; a phase run's stops are one
  item for its coordinator), and an unattended run refuses a human decision as before; a phase
  run's attended stop is answered by a decision at the gate, as `autopilot answer` from any
  session answers it, and its coordinator resumes it.
- **`jig queue next` is not changed.** An attended task with no run is picked up by the session
  waiting at its gate, or by a new session in the task's worktree through `jig-task` §1, which
  reads the recorded answer; a started task is still never advised
  (adr-20261022-the-next-task-is-advised-from-the-queue).

## Alternatives

- **`changes` as the decision word**: an answer is as often a choice between options as a request
  for changes; `answered` follows `autopilot answer` and is a state value, as `approved` is.
- **Questions as prose the board shows whole**: no options and no recommendation to act on, which is
  what the person lacked.
- **A separate questions file**: the person reads `design.md` at the gate, and a second file drifts
  from it.
- **The script appending the answer to `task.md`**: `task.md` is prose; the journal is data, and the
  agent records the decision in `task.md` when it takes the answer, as for any gate decision.
- **A multi-line answer**: longer design comments fit, but the journal would need an encoding and
  the contract would differ from the stop's answer; it can be added later without breaking it.
- **Advising tasks with an answered gate in `queue next`**: an amendment of the advice ADR for a case
  the waiting session already closes.

## Consequences

- `jig task list --json` `gate` gains `questions`, `answer` and the state `answered`; `gate-waiting`
  and `gate-changed` items gain `questions`, `answer` and `stopped_at`; the actions table gains
  `answer-gate`. Jig UI reads them.
- `approve` on a stopped attended run now also answers the run, which before left it stopped.
- A design rewritten in several writes is `waiting` after the first one, as a first draft already
  was.
- Rolling back reads `gate: answered` as not approved, so such a task returns to `waiting`.

This amends adr-20260924-the-status-page-keeps-the-readers-place (the gate's states) and
adr-20261114-a-waiting-run-holds-no-slot (a run stopped at its gate is answered at the gate).
