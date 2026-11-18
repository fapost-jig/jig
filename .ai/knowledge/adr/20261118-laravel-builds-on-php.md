---
id: adr-20261118-laravel-builds-on-php
type: adr
status: accepted
date: 2026-11-18
domains:
  - verify
paths:
  - "profiles/laravel/**"
  - profiles/php/verify.sh
  - scripts/lib/verify.sh
  - scripts/lib/profiles.sh
  - schemas/profile.md
  - schemas/verify-map.md
summary: Why laravel is a pure layer over php overriding php:tests with artisan test, why the Phase 1 covers fix is retired while the covers mechanism stays, why a cover resolves a role down the extends chain and a pure layer's map follows the tests, and why the framework globs moved to php.
---
# `laravel` is a pure layer over `php`: it overrides `php:tests` with `php artisan test`, a cover reaches a role down the `extends` chain, and a pure layer's map follows the tests

This refines adr-20261107-a-profile-covers-a-check-of-another and
adr-20261118-a-layer-overrides-its-bases-checks-by-role, and settles what
adr-20261117-profiles-lists-top-layers-and-jig-resolves-the-stack left to this step (`requires`).
None of them is superseded. The check-table ADR (adr-20261117-a-profile-declares-its-checks-in-a-table,
D6) expected "an ADR that supersedes adr-20261107"; this one refines it instead, because the
`covers` mechanism stays (below), and a superseded ADR would hide its reasons from `jig context`.

## Context

`laravel` stood beside `php` (`requires: [php]`) with its own `verify.sh`: a copy of php's
narrowing that differed in four globs, run as `php artisan test`, and `covers: [php:tests]` (the
Phase 1 fix of `.ai/specs/profile-layers/`) so the suite ran once. Layers now exist: a profile can
`extend` another and override a check of its base by role. The roadmap's Phase 3 asks for
`laravel` built on `php`, its copied narrowing removed and the Phase 1 fix retired.

Three things a plain `extends: php` would break in silence: a project profile with
`covers: [laravel:tests]` (released since v0.41.0) names a profile that no longer runs, so the
cover is dropped and the suite runs twice; `.ai/verify/laravel.map` belongs to a profile that no
longer reads maps, so its narrowing stops; and php's narrowing lacks `routes/ config/ database/
bootstrap/`, so `config/auth.php` would select only `AuthTest`.

## Decision

- **`laravel` is a pure layer.** `extends: php`, `detect: [artisan]`, `carry: [.env]` and one
  row, `checks.tests.command: php artisan test`, which overrides `php:tests` (rows address the
  nearest owner of the role). No `verify.sh`, no `checks:`, no `scope:`, no `requires`, no
  `covers`. The suite runs once by construction: php runs once and has one `tests`.
- **The Phase 1 fix is retired; the `covers` mechanism stays.** Stock `laravel` no longer declares
  `covers: [php:tests]`. `covers`, `jp_covered` and `JIG_VERIFY_COVERED` stay: they are released,
  `drop` is answered through `jp_covered`, and a project profile with a `tests` role of its own
  cannot override a base's `tests` (a layer's own role shadows the base's), so a cover is its only
  way to replace them.
- **A cover addresses a role down the chain.** `X covers L:R` resolves as a layer's row does: to
  the first profile of `L`'s `extends` chain in this run's stack that is no pure layer and lists
  `R`. `covers: [laravel:tests]` covers `php:tests`; the skip says
  `scope: covered by myapp, php:tests`. A pure layer of the stack whose chain names no `R` is
  warned about. The "override has no effect" warning is not printed for the layers on the chain
  from the profile the cover names down to the base: that cover replaced them on purpose.
- **A pure layer's map follows the tests.** `.ai/verify/<layer>.map` of a pure layer is read for
  the profile that owns `tests` in its chain, topmost layer first, before that profile's own map,
  and handed on with it through covers. A Laravel project reads `laravel.map` then `php.map`, as
  before.
- **The framework globs move to php.** `routes/* config/* database/* bootstrap/*` join php's
  "can affect any test" list, worded without naming a framework; `php/verify.sh` still names
  neither laravel nor artisan.
- **The label stays the runner's.** `php: tests (phpunit)` — `artisan test` wraps that runner —
  and `verify: php:tests: command from laravel` names the command, in a run and in a preview.
- **`requires` stays as it is.** No stock profile uses it any more; a profile built on another
  uses `extends`.
- **A kept old `profile.yaml` is loud.** When a profile has no `verify.sh` and no `extends` but
  the stock copy now extends a base, `jig verify` fails it (`FAIL <p>: profile.yaml has no
  extends, but the stock <p> now extends <base> …`), so a hand-edited `laravel/profile.yaml`
  kept by `jig upgrade` never runs phpunit in place of `artisan test` unnoticed. Without the source
  at hand (a copy-mode project running its own jig), a profile the manifest tracks with neither a
  `verify.sh` nor an `extends` fails the same way: its checks run nowhere, so it is no longer only a
  `SKIP … no verify.sh`. An untracked profile in that state stays the broken install it was.

## Alternatives

- **Retire `covers` altogether**, as the roadmap's words read. It breaks a released contract,
  `drop` and the one way a profile with its own tests replaces a base's.
- **Supersede adr-20261107 and restate the mechanism.** A long restatement, and the superseded
  record of a living mechanism drops out of `jig context`.
- **Migrate `covers: [laravel:tests]` and `laravel.map` by hand** (a warning and an upgrading
  note). Until the person acts, the suite runs twice or the map is ignored; upgrade never edits a
  project's files.
- **The four globs as data**: a table field (`checks.tests.full_on`), a map shipped by laravel, or
  php asking for `artisan`. A new contract for one stock case, a map whose full-set reason reads
  "not narrowable", or the base knowing the layer above it (rejected in adr-20261107). Dropping
  them loses coverage in silence.
- **A label taken from the table.** A new field for words the `from laravel` line already says.
- **Overrides only where the layer's `detect` matches**, for a laravel listed by hand without an
  `artisan`. A new layer rule for a rare case that already fails loudly (`php artisan test` cannot
  open `artisan`).

## Consequences

- A Laravel project runs the same checks, each once; its output names `php`, not `laravel`, and
  the role `laravel:tests` is gone (a renamed stock check: changelog). Rows, covers and maps
  written against `laravel` keep working.
- `profiles: [laravel]` without `php`, and `--profile laravel`, now run php's static, style and
  manifest checks; `jig init` writes `[generic, laravel]`.
- A plain PHP project runs its full set when a `.php` file under those four directories changes.
- Rolling back after a release needs a migration: projects initialised since list no `php`, and
  upgrade would delete it as unreached.
- Covers through a chain and layer maps are a contract once released.
