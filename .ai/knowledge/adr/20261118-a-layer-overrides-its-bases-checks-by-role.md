---
id: adr-20261118-a-layer-overrides-its-bases-checks-by-role
type: adr
status: accepted
date: 2026-11-18
domains:
  - verify
paths:
  - scripts/lib/verify.sh
  - scripts/lib/profiles.sh
  - scripts/lib/profile.sh
  - schemas/profile.md
summary: "Why a layer's checks.<role>.<field> rows resolve to the nearest owner of the role down the extends chain, why jig verify merges them top-down into the base's JIG_VERIFY_CHECKS, why drop: true is answered by jp_covered with scope: wording, how --explain names the layer, and what a layer's table is refused for."
---
# A layer overrides its base's checks by role: rows resolve down the `extends` chain, `jig verify` merges them top-down, and `drop: true` stands a check down

This refines adr-20261117-a-profile-declares-its-checks-in-a-table (the reserved `drop` and the
rule that a row's role is in the profile's own `checks:`) and
adr-20261117-profiles-lists-top-layers-and-jig-resolves-the-stack (its bullet that a layer's
`checks.*` rows are refused until this lands). Neither is superseded.

## Context

A project layer exists so it can change one stock check in a few lines
(`.ai/specs/profile-layers/`, Phase 3): a `warehouse` over `laravel` that runs the suite with
`--parallel --functional` and `--compact <files>`. The check table gave every check a role and its
command and arguments as data; the stack gave a layer its base. What was missing is what a layer's
own rows mean, who reads them, and how the person sees which layer changed what. The danger
throughout is an override that silently does nothing (failure mode 4 of the spec).

## Decision

- **D1. A row addresses a role, not a profile.** A layer's `checks.<role>.<field>` belongs to the
  first profile of its chain (itself, then its bases by `extends`) whose own `checks:` lists the
  role. If that is the layer itself, it is the layer's own row; otherwise it overrides that base's
  check. A layer therefore cannot override a base's role that has the same name as one of its own.
  A pure layer (no `verify.sh`) runs no check of its own, so a non-empty `checks:` on it is an
  error: a role there would shadow the base's and the override would go nowhere.
- **D2. Fields.** `command`, `full` and `narrowed` mean what they mean in a base; an unwritten
  field is inherited, `[]` erases. `drop: true` removes the check; any other value, and `drop`
  beside another field of the same role in one layer, is an error.
- **D3. `jig verify` merges; the base reads a finished table.** `profiles_check_merged` is the one
  producer of `JIG_VERIFY_CHECKS`: the base's own rows, overlaid field by field by the layers above
  it in this run's stack, the top layer winning. A dropped role is a `<role> drop <layer>` row and
  has no other rows. Only layers in the run's stack count (`--profile laravel` gets none of
  `warehouse`'s overrides). No stock `verify.sh` changes.
- **D4. A drop is answered by `jp_covered`.** Besides `JIG_VERIFY_COVERED`, `jp_covered` reads the
  drop row and prints `skip (scope: dropped by <layer>, <profile>:<role>)`; `jp_check_cmd` prints
  the same skip and returns 1 as a safety net. The words start `scope:` because a drop, like a
  cover, is a decision and not a missing tool, and `jig verify` reads that wording from any skipped
  profile.
- **D5. The layer is named.** Before a base's output, in a real run and under `--explain`,
  `jig verify` prints `verify: <base>:<role>: <fields> from <layer>` for every overridden check. A
  drop is named by the check's own skip line.
- **D6. A layer's table is linted before anything runs.** Besides the grammar of the check table:
  a role no profile of the chain lists, a base with no check table of its own (its `verify.sh`
  does not read one), a `narrowed` for a role the base never narrows, a non-empty `checks:` on a
  pure layer, a bad `drop`, a field or a second `drop` over a role a layer below already dropped
  (it would never be read), and two layers on different branches over one base touching the same
  role. Any of them is `FAIL <layer>: profile.yaml:<line>: <reason>` (`PLAN <layer>: error (...)`)
  and the run is refused, as for a stack that does not resolve.
- **D7. Covers.** A cover whose covering profile has the same role dropped does not hold, and
  `jig verify` says in words that the lower profile runs the check again. An override aimed at a
  check another profile covers in this run is warned about: it has no effect.
- **D7a. A profile whose every check is dropped is named.** When every role a profile lists is
  dropped by layers, `jig verify` says so in words, decided from the merged table it wrote, never
  from the profile's output: `verify: every check of <p> was dropped by <layers>; nothing verified
  it`. Only the words change; the run's exit code is what it was without the drop wording.
- **D8. One base, one run.** A base runs once, so two top layers over it share its merged table;
  different roles merge, the same role is the error of D6.

**Against D5 of the check-table ADR** ("no existing `jp_*` function changes meaning"):
`jp_covered`'s contract stays "0 and a printed skip: this check is not this profile's to run in
this run", with the same signature and return codes. A drop is a second reason under that
contract. Every stock check already asks `jp_covered` first, before looking for its tool, which is
why a dropped check says "dropped by" rather than "no phpstan".

## Alternatives

- **The profile in the key** (`checks.laravel.tests.full`). It breaks when a role moves down the
  chain, which the next item does to `tests` when `laravel` builds on `php`.
- **An override reaches every base of the chain with that role.** One line would change checks
  only one of which runs; "nearest owner" is what a person reads off the chain.
- **Drop through `JIG_VERIFY_COVERED`.** No library change, but the skip would say "covered by
  warehouse": that the work runs elsewhere, when it runs nowhere.
- **A new `jp_dropped`.** A second call before every check of twelve stock profiles, unknown to
  every kept copy; the same meaning as `jp_covered`.
- **Drop in `jp_check_cmd` only.** It is asked after the tool is looked for; kept as a safety net.
- **Drop worded without `scope:`.** Every run where the rest narrowed away would ask for a
  person's action.
- **A bad layer table fails only its base.** The rest would pass with the layer's plan wrong; a
  stack error already refuses the run.
- **First layer wins when two branches touch one role.** The other override would be ignored in
  silence.
- **The layer as a fourth column of the rows, printed by the profile.** It changes `jp_run` and
  `jp_plan` output, an interface, for something only `jig verify`, which merged, needs to know.

## Consequences

- A project layer is a few lines over a stock profile, and the base keeps receiving upgrades. A
  base role renamed by an upgrade fails the layer's lint loudly instead of ignoring the override.
- `drop: true`, role addressing without a profile and the `scope: dropped by` wording are a
  contract once released; before the release this is one revert.
- `laravel` is beside `php` (`requires`), not over it, so today a layer over `laravel` reaches only
  `laravel:tests`. For `laravel` to override `php:tests` when it builds on `php`, it must stop
  listing `tests` itself (D1); that and the fate of `covers` are that task's decision.
- A `verify.sh` that asks neither `jp_covered` nor `jp_check_cmd` (an old kept copy) runs a dropped
  check: the safe direction.
- Layer tables are linted by `jig verify` only; `jig doctor` and `jig upgrade` do not read them.
