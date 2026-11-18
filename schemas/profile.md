# Profile manifest

`profiles/<name>/profile.yaml`, one per profile, beside that profile's `verify.sh`;
installed into a project as `.ai/profiles/<name>/profile.yaml` (ADR-0003).
Reference: `domains/verify`, ADR-0013, ADR-0041. Read with `profile_get` and
`_profiles_list_lines` from `scripts/lib/profiles.sh`. Every key is optional; what an
absent key means is decided by its reader, not by this file.

| Key | Shape | Meaning |
|---|---|---|
| `name` | scalar | the profile's own name. Read by no script: the directory under `profiles/` is the identity everything resolves (`profiles_dir`), so a `name` that disagrees with its directory changes no behaviour. It is here for the person reading the file |
| `description` | scalar | one line on what the profile checks and which tools it reaches for. Read by no script either |
| `detect` | `always`, or an inline list of globs | how `profiles_detect` recognises a project of this stack — see **Detection** |
| `requires` | inline list of profile names | profiles this one builds on. Detection closes over it, and `profiles_check_requires` warns when an active profile's requirement is not active — see **Requires** |
| `extends` | one profile name | the profile this one builds on: a layer over a base. Listing the layer in `profiles:` brings its base with it — see **Stacks**. A scalar, never a list |
| `scope` | inline list of capabilities | which parts of the verify scope protocol this profile's `verify.sh` understands: `changed` (ADR-0013), `map` (ADR-0041), `explain`, `environment` — see **Scope** |
| `covers` | inline list of `<profile>:<check>` | checks of other profiles this profile's own checks replace: `laravel` declares `covers: [php:tests]`, because `php artisan test` runs the suite php's PHPUnit or Pest would — see **Covers** |
| `checks` | inline list of check names | the checks of this profile by role, which another profile can take over by name, and the index of its check table. Every stock profile that runs checks lists its roles — see **Covers**, **Check table** and **Stock checks** |
| `checks.<role>.<field>` | words | the command and arguments of the check `<role>`, which `checks` must list; fields `command`, `full`, `narrowed` — see **Check table** |

## Grammar

The same flat YAML subset as `.ai/config.yaml` (`schemas/config.md`), but a plain file
rather than a frontmatter block, so it is read by `profile_get` rather than by `cfg` or
`fm_get`.

- One `key: value` per line, no nesting. The key is anchored at column 0: an indented
  key is invisible to the reader.
- Two shapes only: a scalar, and an inline list `key: [a, b]`. There are no block lists.
- `#` starts a comment, to the end of the line. The grammar has no escape, so a value
  cannot contain `#`.
- A list item may be quoted with `"`; the quotes are stripped. Globs are written bare —
  the reader never lets the shell expand them.
- When a key is set on more than one line, the first one is read and the rest are ignored.

## Detection

`detect` answers one question: is this project written in that stack? `profiles_detect`
reads it from every profile directory and returns the names that matched, which a first
`jig init` turns into the project's `profiles` list (adr-20260918-init-activates-detected-profiles).

- A list of globs matches when **at least one** glob matches a path in the project.
  Unlike a verify-map glob, which is matched against a path string, a `detect` glob is
  matched against the real tree: the path has to exist.
- `**` and `*` both match across `/`, and both collapse to a single `*` in the
  `find -path` pattern the glob is compiled to. `scripts/**/*.sh` and `scripts/*.sh` are
  therefore the same glob, and both match a `.sh` file at any depth under `scripts/`.
  Depth cannot be expressed here — write the manifest file you are actually looking for
  (`go.mod`, `composer.json`) rather than a glob you expect to be shallow.
- Detection does not look inside `.git`, `.ai`, `node_modules`, `vendor`, `.venv`,
  `venv` or `.dart_tool`. A `.sh` file vendored into someone else's dependency is not
  what the project is written in.
- `always` means detected in every project. `generic` carries it, and is in the result
  before any manifest is read at all; in any other profile it would mean the same thing.

## Requires

A profile pulled in by detection pulls in everything it requires, even when that
profile's own globs matched nothing — `laravel` matches `artisan` and brings in `php`,
whose `composer.json` may be absent. The closure runs until a full pass adds nothing new.

Activation of `requires` is separate and is not closed over: `.ai/config.yaml` lists exactly
the profiles the project activates, and a profile that is only required is not run. (`extends` is
closed over, below.) `profiles_check_requires` warns on stderr when a profile of the stack
requires one that is not in it, and is advisory — it never fails a command. The
two read different trees: detection reads the profiles shipped with the framework, the
warning reads the copies installed under `.ai/profiles/`, so a manifest the project
edited can make them disagree.

`requires` is the older key and stays as it is for now: it closes detection and warns. A profile
that is built on another says `extends` (below); which of the two a stock profile such as
`laravel` uses is decided when it is converted.

## Stacks

`extends: <name>` makes a profile a **layer** over one **base**: a project's own `warehouse`
over `laravel`, `laravel` over `php`. `profiles:` in `.ai/config.yaml` lists the top layers, and
the **stack** is that list closed over `extends`. A profile is *reached* when it is in the
stack. `profiles_stack_v` in `scripts/lib/profiles.sh` is the one function that resolves it;
`jig verify`, `jig upgrade`, `jig init`, the worktree carry and lock lists and the ship notice
all read the stack from it and none re-derives it. `profiles_reached` answers "reached" from it
for `jig doctor` and `jig status`, which name an installed profile the stack does not reach; when
the stack does not resolve, doctor names that reason and nothing is called unreached.

- **Shape.** The value is one profile name, valid as a directory name. A list
  (`extends: [a, b]`), `generic` (always first, never a base) and anything that is not a name are
  errors. The chain is linear: a base may extend another, and ends at a profile with no `extends`.
  The `detect` of a base reached this way is not asked: the layer called it.
- **Order.** A layer always comes before its base; otherwise the order is the order the names
  were first met in `profiles:`. `[generic, laravel, php]` with `laravel` over `php` runs
  `generic laravel php`, as does `[generic, php, laravel]`; two layers over one base run before
  it. A list that names both a layer and its base is allowed: the base runs once.
- **Where `extends` is read.** For a stock profile from the source (`jig upgrade`, `jig init`: the
  release being installed decides), and from the installed copy in `jig verify`: what runs is
  what is there. For a project's own profile always from `.ai/profiles/<name>/`.
- **Errors.** A base that is not installed (or, for upgrade and init, neither shipped nor under
  `.ai/profiles/`), a cycle, a list or a bad name in `extends`, and a name clash (below) are
  errors, never warnings: `jig verify` refuses before running any profile
  (`FAIL <layer>: ...`; `--explain` prints `PLAN <layer>: error (...)`) and `jig upgrade`
  refuses before placing a file, in link mode too. `profiles_stack_v` itself never dies: it
  returns 1 and sets `PROFILES_STACK_ERROR` (`<layer>: <reason>`) and `PROFILES_STACK_LAYER`.
- **Stock and the project's own.** A profile is *stock* when it exists in the source's
  `profiles/`, the manifest tracks `.ai/profiles/<name>/`, or `.ai/profiles/<name>` is a symlink
  (link mode). A profile is the *project's own* when `.ai/profiles/<name>/` is a real directory the
  manifest does not track and at least one of its files differs from (or is absent in) the
  source's copy; a byte-identical untracked directory is a stock install that was interrupted,
  and the next `jig upgrade` finishes it. A project's own profile in the stack that carries a
  stock name is a **name clash**, one error naming both; only the stack is checked, so a name a
  release newly ships breaks no project that did not activate it. Without a source checkout
  `jig verify` cannot see a clash with a stock name it has not installed; `upgrade` and `init`
  always can.
- **Pure layer.** A profile with `extends` and no `verify.sh` is not a broken install: `jig verify`
  does not run it or count it, and prints `<layer> is a layer over <base>; its checks run in its
  bases`. A profile with neither stays `SKIP <name>: no verify.sh`.
- **Check overrides.** A layer's `checks.<role>.<field>` lines change a check of its base
  (**Layer overrides**, below). A pure layer lists no `checks:` of its own.
- **Install.** `jig upgrade` installs, updates and keeps every profile of the stack, bases
  included, and still never edits `profiles:`; a first `jig init` writes only the top layers of
  what it detects (adr-20261117-profiles-lists-top-layers-and-jig-resolves-the-stack).

## Scope

`jig verify` computes the changed-file list once and hands it to profiles through
environment variables. A profile receives them only if `scope` declares the capability:

| Value | What the profile's `verify.sh` promises to honour |
|---|---|
| `changed` | `JIG_VERIFY_SCOPE=changed` and `JIG_VERIFY_FILES`, a file of changed paths (ADR-0013) |
| `map` | additionally `JIG_VERIFY_MAPPED`, the project's verify map applied to those paths (`schemas/verify-map.md`, ADR-0041). It means nothing without `changed`, which is checked first |
| | A `map` profile also receives `JIG_VERIFY_MAPPED_ALL` (the same decisions for every tracked file that is not a test or a document, for a profile that narrows by caller), `JIG_VERIFY_BASE` (the ref the changed list was taken against, empty for `HEAD`) and `JIG_VERIFY_FULL_RUN` (`local` or `ci`) |
| `explain` | `JIG_VERIFY_EXPLAIN=1` asks for a plan instead of checks. The profile prints one `PLAN <profile>: <check>: full\|filtered\|skip\|conditional (<reason>)` line per check, runs no project tool and exits 0. `conditional` names what remains unknown and whether the full set is possible |
| `environment` | `JIG_RUN_EXEC`, the command prefix that reaches the environment the project runs in (`docker compose exec -T -w /app app`), set only when `jig verify` decided the checks run there. The profile promises that every project command goes through `jp_run`, `jp_version`, `jp_exec` or `jp_have` — never a bare `command -v`, a host's absolute path or a shell function — so the prefix reaches all of them (adr-20261001-checks-run-where-the-project-runs) |

Support is declared, never inferred. (`JIG_VERIFY_COVERED` is declared per check, under
`checks`, rather than in `scope` — see **Covers**.) A profile that does not declare a capability is run
with those variables explicitly unset — not merely left as the caller's environment had
them — and the result line says the scope was ignored, so `pass` never quietly means
something different per profile.

For `--explain`, a profile without the `explain` capability is not run at all. Jig prints
`unknown` and exits 2 if any selected profile is unknown. A declared profile that exits
nonzero or prints no valid plan line makes the preview fail with exit 1. A real `jig verify`
always unsets `JIG_VERIFY_EXPLAIN`, even if its caller exported it. The preview never takes
the clone's verification run record and never treats a plan as a verification result.

Under an environment (`run.exec`, `schemas/config.md`), a profile without the `environment`
capability is not run at all — running it would put its checks on the host. Its result is
`skip (not adapted to run in <where>; …)`, counted like a skip for a missing tool, and in
`--explain` it is `unknown`. Without an environment, `JIG_RUN_EXEC` is unset for every
profile, so `jp_run` and `jp_version` behave exactly as they did before the capability
existed.

## Covers

Two profiles can run the same work: a Laravel project activates `laravel` and the `php` it
requires, and `php artisan test` runs the PHPUnit or Pest suite `php` would run itself. The
profile **above** says so; the profile below only names its check (adr-20261107-a-profile-covers-a-check-of-another):

```yaml
# profiles/laravel/profile.yaml
covers: [php:tests]
# profiles/php/profile.yaml
checks: [tests]
```

A check is named by its role, never by its tool: `tests` is phpunit or pest, whichever the
project has. `jig verify` decides once, before any profile starts, which covers hold in this
run. `<upper> covers <lower>:<check>` holds when:

- both profiles start in this run — the gates the run itself applies: a `verify.sh`, `explain`
  in a preview, `environment` under one. A profile that never starts covers nothing;
- the upper profile applies to the project: its `detect` is `always`, absent (a project's own
  profile, activated by name), or matches. `laravel` without an `artisan` covers nothing, and
  php keeps its tests;
- the lower profile lists the check under `checks`. Otherwise `jig verify` warns —
  `profile 'upper' covers 'lower:tests', but 'lower' names no check 'tests' (checks:), so it still runs` —
  and the check runs: support is declared, never inferred, as for `scope`;
- in a narrowed run where the lower profile has its own map, the profile that ends up running the
  check declares `map` too, so the map can follow the tests (below). If it does not, it warns and the lower profile
  keeps its tests.

When several profiles cover the same check, the first in run order takes it. Covers chain: with
`myapp` declaring `covers: [laravel:tests]` over `laravel`'s `covers: [php:tests]`, php's tests
are myapp's, and php's skip names myapp. A chain that comes back to where it started runs
the check nowhere, so its covers are dropped with a warning and every profile in it keeps its
check.

The lower profile receives `JIG_VERIFY_COVERED`, `<check>=<profile>` words, and asks it with
`jp_covered <check> <label>`, which prints the check's skip — `php: tests (phpunit): skip (scope: covered by
laravel, php:tests)`, or the `PLAN` line in a preview — and returns 0. Every other profile runs
with the variable unset. The reason starts `scope:`: the tools are fine and the work is another
profile's, so a run where everything else narrowed away is not read as a gap in coverage. A
`verify.sh` that never calls `jp_covered` — a profile a project edited before the key existed —
runs its check anyway: twice, the safe direction.

**The map follows the tests.** A map's decisions narrow its profile's tests
(`schemas/verify-map.md`), so when `<lower>:tests` is covered, `.ai/verify/<lower>.map` is read
for the profile that runs the tests after that profile's own map — along a chain, the nearest
profile's map first — first match wins across all of them, and the result line names every map. A
map is handed on only from a profile that declares `map`: one its profile never read is no decision. By covering `<lower>:tests` the
upper profile accepts the lower profile's filter vocabulary — `php` and `laravel` both take a test
file path. The lower profile still receives its own map for the checks it keeps.

`covers` and `checks` are the first step of profile layers (`.ai/specs/profile-layers/`): one
name, one way to drop a check. `covers` stays beside the check table below: it is a relation between
profiles with no stack between them, and the table does not replace it. A layer (`extends`,
**Stacks**) changes a check's arguments, or removes the check, with the table's own lines
(**Layer overrides**). Every check a stock profile lists in `checks` answers to `jp_covered`.

## Check table

A profile can declare what a check runs as data, one line per field, beside the `checks` list that
names its roles (adr-20261117-a-profile-declares-its-checks-in-a-table):

```yaml
checks: [tests, static, lint, manifest]
checks.static.full: analyse --no-progress
checks.static.narrowed: analyse --no-progress {selection}
checks.lint.narrowed: clippy --all-targets {selection} -- -D warnings
checks.manifest.command: composer
checks.manifest.full: validate --no-check-publish
```

The flat reader cannot list keys, so the roles are the `checks` list: a `checks.<role>.*` line whose
role it does not list is an error, and `checks: [tests]` with no table line stays valid, exactly as
the releases before the table wrote it. A role is `[a-z0-9_-]+`, the alphabet `covers` already
checks.

| Field | Meaning |
|---|---|
| `command` | the check's command. Absent: the profile's own `verify.sh` chooses it on the fly (phpunit or pest, a wrapper or `mvn`, `pnpm` or `npm`). A stock profile writes it only where the tool is a literal |
| `full` | the arguments of a full run — and of a narrowed run that falls back to the full set (an `ALL` decision, a filter that selects nothing, a config change). Absent: no arguments |
| `narrowed` | the arguments of a narrowed run, with exactly one `{selection}` word. Absent: the check does not narrow by selection |
| `drop` | a layer only: `true` removes the check of a base for this run. Any other value is an error, and so is `drop` beside another field of the same role (**Layer overrides**) |

**Values.** Plain words, split on blanks and never globbed — the grammar of `run.exec`. No quotes
(`"` `'`), no `$`, backtick or backslash. `#` starts a comment, as everywhere in this file. `[]` is
an explicit empty list of words and differs from an absent key: a later layer can erase the base's
arguments with it. `command: []` is an error, and an empty value (`checks.x.full:` with nothing
after it) is an error too: write `[]`. An inline list with items (`[a, b]`) is not a value. **The
limit of this grammar:** an argument that contains a space or a quote cannot be written in the table.
The profile's `verify.sh`, which builds the selection in code, is where such an argument goes.

**`{selection}`.** It stands for the words the profile's own narrowing logic chose, one argument
each, in exactly that place. It is a whole word, appears exactly once in `narrowed`, and never in
`full` or `command`; `--x={selection}` is refused. The selection is not always paths: it is packages
for `go`, `-p <crate>` for clippy, `-pl a,b -am` for maven, tasks for gradle. What to select stays
code (`jp_select`, `_php_builtin` and the like); the table says only where it goes. An item with a
blank in it stays one argument. Every form a stock profile needs is written the same way:

```yaml
checks.tests.narrowed: {selection}                                      # at the end, after the command
checks.lint.narrowed: clippy --all-targets {selection} -- -D warnings   # in the middle
checks.tests.narrowed: {selection} test                                 # before the goal (maven)
checks.static.full: vet ./...                                           # go vet: the full target
checks.static.narrowed: vet {selection}                                 # ... replaced by the packages
checks.style.narrowed: format --verify-no-changes --include {selection} # after a flag
```

**Where a mistake shows.** The reader ignores an unknown key in silence, which for a table would be
an override that does nothing, so `jig verify` lints the profile's installed `profile.yaml` before it
runs the profile (`profiles_check_table`). The first problem fails that profile —
`RESULT <profile>: fail (profile.yaml:<line>: <reason>)`, and `PLAN <profile>: error (…)` under
`--explain` — and the profile does not run. It refuses: a role not in `checks`, a bad role, an unknown
field, a `drop` that is not for a role of a base, a key set twice, an indented `checks.` key (the reader cannot see it), a
forbidden character, a `narrowed` without exactly one `{selection}`, a `{selection}` anywhere else, an
empty value, `command: []`.

**Handed down.** `jig verify` writes the table's rows, `<role>`, `<field>`, `<value>` separated by
tabs, with one `<role> listed` row for every role in `checks`, to a temporary file and hands its path
to the profile as `JIG_VERIFY_CHECKS`. The rows are the declaration: a profile with no `checks.`
lines — `checks: [tests]` alone, as released before the table — runs with the variable unset — a caller's own value never reaches it — and `scope` has no new
word for it. The decision is `jig verify`'s and the profile only reads it, so the layers that
merge into a base's table change what `jig verify` writes and nothing in a profile. A role a layer
dropped has no `command`, `full` or `narrowed` rows, only `<role> drop <layer>`; `jp_covered` and
`jp_check_cmd` answer to it (**Layer overrides**).

**Reading it, from a `verify.sh`.** `jp_check_cmd <role> <label> full|narrowed <default-cmd>... [--
<selection>...]` sets `JP_CMD` to the table's `command` words (or `<default-cmd>`) and the mode's
argument words, with `{selection}` replaced:

```sh
jp_check_cmd tests "$label" narrowed "$test_bin" -- "$@" || continue
jp_run "$label" "$note" "${JP_CMD[@]}"
```

It returns 1, after printing the check's fail line (under `--explain`, a PLAN skip line), when the
table cannot answer — the role is not in it, or `narrowed` mode finds no `narrowed` field. A fail,
not a skip: a skip beside another check that passed would leave the profile `pass` with this check
unrun. The profile does not fall back to a command of its own:
that is the profile.yaml kept by `upgrade` beside a newer `verify.sh`, and a quiet different command is
the worse answer. The function sets a global, so call it as a command, never inside `$( )`.

## Layer overrides

A layer changes a check of its base with the same lines the base's table uses, without naming the
base (adr-20261118-a-layer-overrides-its-bases-checks-by-role). A project's `warehouse` over `laravel`:

```yaml
# .ai/profiles/warehouse/profile.yaml — a pure layer: no verify.sh
name: warehouse
extends: laravel
checks.tests.full: --parallel --functional
checks.tests.narrowed: --compact {selection}
```

```
$ jig verify --explain
verify: laravel:tests: full, narrowed from warehouse
verify: warehouse is a layer over laravel; its checks run in its bases
PLAN laravel: tests (artisan test): full (…)
```

A full run is `php artisan test --parallel --functional`, a narrowed one `php artisan test --compact
<files>`. Which files to select stays the code of `laravel/verify.sh`; the layer changes only the words
around them, and no stock `verify.sh` is edited for it.

- **Whose role it is.** The chain of a layer is the layer, then its base, then that one's base. A row
  `checks.<role>.<field>` belongs to the **first** profile of the chain whose `checks:` lists
  `<role>`. When that profile is the layer itself (it has a `verify.sh` and lists the role) the row
  is its own table, as always; otherwise the row overrides that base's check. The base is not named
  in the key, so a row survives a role moving down the chain: `checks.tests.full` of `warehouse`
  keeps working when `tests` moves from `laravel` to `php`.
- **A layer cannot override a base's role that has the same name as one of its own roles.** The own
  role wins and the base's is out of reach. A layer `top` with a `verify.sh` that lists `tests` and
  sits over `base`, which also lists `tests`, writes `checks.tests.full` for `top:tests`, never for
  `base:tests`. To change `base:tests` a layer needs a role with another name; there is no second
  syntax for addressing a profile.
- **Pure layers own no role.** A layer with no `verify.sh` runs no check of its own, so a non-empty
  `checks:` there is an error: the role would hide the base's and the override would go nowhere.
- **Fields.** `command`, `full` and `narrowed`, with the grammar of **Check table**: `[]` erases the
  base's words (`full: []`), `command: []` is an error. A field the layer does not write is the
  base's, so `checks.tests.full` alone keeps the base's `narrowed`. `drop: true` removes the check.
  `drop` accepts only the value `true` (`false`, an empty value or any other word is an error) and
  cannot stand beside another field of the same role in one layer. A field or a second `drop` over a
  role a layer below already dropped is refused: it would never be read.
- **Merging.** `jig verify` merges the tables of the chain and hands the base the result as its
  `JIG_VERIFY_CHECKS` (`profiles_check_merged`), the layer nearest the base first, the top layer
  winning field by field. Only the layers in the run's stack count: `--profile laravel` runs `laravel`
  without `warehouse`'s overrides, `--profile warehouse` with them.
- **Naming the layer.** Before a base's own output, in a run and under `--explain`, `jig verify`
  prints one line per overridden check: `verify: <base>:<role>: <field>[, <field>] from <layer>`,
  or `full from a; narrowed from b` when several layers set fields. A drop has no such line: the
  check's own line says `skip (scope: dropped by <layer>, <base>:<role>)`
  (`PLAN … skip (…)` under `--explain`). The reason starts with `scope:` because a dropped check is
  a decision of the project, like a cover, not a gap to fix. `jp_covered` and `jp_check_cmd` read the
  `<role> drop <layer>` row; a cover wins when both hold.
- **Errors.** `jig verify` lints every layer's table before any profile runs, after the errors of the
  stack: `FAIL <layer>: profile.yaml:<line>: <reason>`, `PLAN <layer>: error (profile.yaml:<line>:
  <reason>)` under `--explain`, exit 1, nothing runs (`profiles_check_layers`). It refuses: the
  grammar of **Check table** over the roles of the layer and its chain; a role in no `checks:` of the
  chain; a base that has no check table of its own (its `verify.sh` would not read one); `narrowed`
  for a check the base does not narrow; `drop` that is not exactly `true` or stands beside another
  field; a field or a `drop` over a role a lower layer of the chain dropped; and two layers on different branches over one base that change the same role — the base
  runs once, so one of them would be ignored. Different roles of one base merge: the base runs with
  the overrides of both layers.
- **Covers.** A drop lifts a cover: if the profile that `covers: [<lower>:<role>]` has its own
  `<role>` dropped in this run, nothing would run those tests, so the cover does not hold and the lower
  profile runs them. `jig verify` says so — `verify: laravel:tests is dropped by warehouse, so laravel
  no longer covers php:tests; php runs it` — in a run and under `--explain`. An override of a check
  that another profile covers in this run has no effect, and `jig verify` warns:
  `verify: warning: <layer> overrides <base>:<role>, but <runner> runs it in this run (covers), so the
  override has no effect`.
- **When every check is dropped.** A profile all of whose listed roles a layer dropped runs nothing.
  `jig verify` knows it from the merged table, not from the profile's output. Exit codes are as
  they were for any run where nothing passed: a run that ended in "install the project's tools"
  (a full run, which reads no output) still exits 3 but says `every check of <profile> was dropped
  by <layer>; nothing verified it` instead; a narrowed run whose skips all name a scope keeps its
  ending and exit code and gets that sentence as an extra line. Only the words change.
- **Old copies.** A `verify.sh` that calls neither `jp_covered` nor `jp_check_cmd` (a copy `upgrade`
  kept) does not hear a `drop` and runs the check — the safe direction.

## Stock checks

Every stock profile that runs checks lists them by role in `checks` and builds each command line
from its table through `jp_check_cmd`. A check's label is `<role> (<tool>)`: the role is the stable
name a layer or a `covers` aims at, and the tool is what this run chose, so a Pest project's tests
are still `php:tests`. Renaming a role is a breaking change for the changelog. Words that depend
on the tool chosen at run time (phpunit or pest, `npm test` or `bun run test`, jest's
`--findRelatedTests`, gradle's `check` or maven's `test`) stay in `verify.sh` as the default command;
the table holds the words every variant shares. `generic` runs no check of its own and has no table.

| Profile | Roles (tool) |
|---|---|
| `shell` | `lint` (shellcheck), `tests` (tests/run.sh) |
| `php` | `tests` (phpunit or pest), `static` (phpstan), `style` (pint), `manifest` (composer validate) |
| `laravel` | `tests` (artisan test) |
| `node` | `tests`, `lint`, `typecheck` (your scripts, run by npm, pnpm, yarn or bun; jest, vitest or eslint for a narrowed run) |
| `go` | `static` (go vet), `tests` (go test) |
| `python` | `lint` (ruff), `typecheck` (mypy), `tests` (pytest) |
| `rust` | `style` (cargo fmt), `lint` (cargo clippy), `tests` (cargo test) |
| `dotnet` | `style` (dotnet format), `tests` (dotnet test) |
| `jvm` | `tests` (gradle check or mvn test) |
| `ruby` | `lint` (rubocop), `tests` (rspec or minitest) |
| `dart` | `static` (dart or flutter analyze), `style` (dart format), `tests` (dart or flutter test) |
| `swift` | `build` (swift build), `tests` (swift test) |

Three checks run once per item and so always build a `narrowed` command line: shellcheck (one
script per call), `tests/run.sh` under a narrowed run (one filter per call) and a narrowed
`dotnet test` (one project per call). mypy's `--exclude` pattern for the project's virtualenv holds
a backslash, which the table cannot write: `verify.sh` appends it after a full run's command line.

## The reader is tolerant, and that is the design

`profile_get` looks up one key at a time, on demand. There is no list of known keys, no
schema check, and no command that validates a manifest. A key nobody asks for is never
asked for, so **an unknown key is ignored in silence**.

That is what makes a new key an additive change. Profiles are copied into the project
(ADR-0003) and `jig upgrade` keeps a project-modified manifest as `keep-modified`, so a
newer `jig` is guaranteed to meet manifests written before the key it now asks about
existed. Those manifests keep working untouched: the absent key reads as empty, each
reader already decides what empty means, and no profile needs migrating when this schema
grows. `scope` is the same principle made explicit one level up — ADR-0013 declares
support rather than inferring it precisely so that absence stays a valid answer.

The cost is paid in the other direction. A misspelled key is ignored just as silently:
`detects:` or `scopes:` raises no error and no warning, and the profile behaves as one
that declared nothing — never detected, or run unscoped. Nothing will tell you, and the
table above is the whole list of keys that mean anything.

The file's *presence* is checked, even though its contents are not: it is part of the
install manifest, so a profile directory missing its `profile.yaml` is reported as drift
by `jig status` and makes `jig verify` refuse the stale install (ADR-0017).

## `verifies`

Optional, and the profile's claim about the code rather than a setting. The one value is
`nothing`:

```yaml
verifies: nothing
```

It says this profile asserts nothing about the project — whatever it runs is a guard, which
may fail a run and may not pass one. `generic` carries it and nothing else does. A project in
which only such profiles are active is told that nothing verifies it, by `jig verify` and
again by `jig task ship`, and is **not** refused over it: there is nothing to install and
nothing to wait for. Where a profile that does claim something has all its checks skip — its
tools are missing — `jig verify` refuses instead, because something could have been checked
and was not (adr-20260925-one-test-run-per-clone-and-a-dead-run-is-not-a-pass).

**Absence means the profile verifies something**, which is the cautious default: a profile
written before this field existed keeps refusing rather than quietly becoming unverifiable.

**It is declared, never inferred, and in particular is not `detect: always` under another
name.** `detect` answers when a profile *applies*; `verifies` answers what it *asserts*. They
coincide in `generic` alone, and by accident: a secret scanner or a licence-header check is
exactly the profile that should apply everywhere **and** claim something about the code.
Reading the claim off `detect` would put such a profile in the wrong bucket, and the day its
tool went missing it would report that nothing checks the project and let the change ship
unverified.

**It cannot be computed from a run, and that is why it is declared.** A profile with no checks
and a profile whose checks could not run both produce the same thing: skips and exit 2. The
reason differs, but a check's reason is prose, and `cmd_verify` decides nothing from a
profile's prose (`domains/verify/RULES.md`). `jig task ship` settles it: it must say that
nothing verifies this project **without running anything at all**, so the answer has to be
data a file carries, not an outcome a run produces.
