---
id: adr-20261117-a-profile-declares-its-checks-in-a-table
type: adr
status: accepted
date: 2026-11-17
domains:
  - verify
paths:
  - scripts/lib/verify.sh
  - scripts/lib/profile.sh
  - scripts/lib/profiles.sh
  - "profiles/**"
  - schemas/profile.md
summary: "Why a profile declares a check's command and arguments as dotted checks.<role>.<field> lines indexed by its checks list, why a value is blank-separated plain words with an explicit [] and a whole-word {selection} token for where a narrowed run's selection goes, why jig verify lints the table and hands the rows down as JIG_VERIFY_CHECKS, why a missing row fails the check, and what the word grammar cannot express."
---
# A profile declares its checks in a table (`checks.<role>.<field>`), `{selection}` says where a narrowed run's selection goes, and `jig verify` lints the table and hands it down

This extends adr-20261107-a-profile-covers-a-check-of-another and does not supersede it: `covers`
and `checks: [tests]` stay as they are, and the table is built on the same `checks` list.

## Context

Adr-20261107 gave a profile the names of its checks. It did not give it the checks themselves:
what a check runs, and with which arguments, is code in each `verify.sh`, so a project layer that
wants to change one argument of a stock check has to replace the whole profile
(`.ai/specs/profile-layers/`, Phase 3). That asks for the command and the arguments as data, in a
shape the flat reader of `profile.yaml` can hold (`schemas/profile.md`): one `key: value` per line,
no nesting, a key at column 0, the first line setting a key winning, and an unknown key ignored in
silence.

Two facts decided the shape. The narrowed arguments of the stock profiles do not share one form: the
selection goes at the end (php tests, phpstan, pint, `go test`), in the middle (`cargo clippy
--all-targets <crates> -- -D warnings`), before the goal (`mvn <modules> test`), after a flag
(`dotnet format --include <files>`), or replaces the full run's target (`go vet ./...` becomes `go vet
<packages>`). And the command is often not a literal: the tool is chosen on the fly (phpunit or pest, a
wrapper or `mvn`, `pnpm` or `npm`), and what the selection is — paths, packages, `-p <crate>`, tasks —
is decided by the profile's own narrowing code.

## Decision

**D1. The table is dotted keys in `profile.yaml`; its index is `checks`.** `checks.<role>.<field>:
<value>`, a role `[a-z0-9_-]+` (the alphabet `covers` already checks), a role listed in the existing
`checks: [..]`. The reader cannot list keys, so the list is the index; `checks: [tests]` with no
table line stays valid. The fields are `command` (absent: the profile chooses its own), `full`
(the arguments of a full run, and of a narrowed run that falls back to the full set; absent: none) and
`narrowed` (the arguments of a narrowed run, with `{selection}`; absent: the check does not narrow by
selection). `drop` is reserved for a layer that removes a check and is refused by the linter until it
is implemented, so it never silently does nothing. (Implemented, with a layer's rows naming a base's role, by
adr-20261118-a-layer-overrides-its-bases-checks-by-role.)

**D2. A value is plain words.** Split on blanks, never globbed, the grammar of `run.exec`; no quotes
`"` `'`, `$`, backtick or backslash; `#` starts a comment. `[]` is an explicit empty list of words and
is not the same as an absent key, so a later layer can erase the base's arguments; `command: []` and
an empty value are errors. **The limit, stated plainly: an argument that contains a space or a quote
cannot be written in the table.** Such an argument is built in the profile's `verify.sh`, in code,
where the selection is built anyway.

**D3. `{selection}` is the one token.** A whole word, exactly once in `narrowed`, never in `full` or
`command`, never part of a word. It expands to the words the profile's own narrowing chose, one
argument per word, in that place; an item with a blank in it stays one argument, because the command
is built as an array, not a string. Which words to select stays code (`jp_select`, `_php_builtin`
and the like); the table says only where they go. Every form above is written with it.

**D4. `jig verify` lints the table and hands it down.** `profiles_check_table` reads the installed
`profile.yaml` line by line and reports the first problem as `<line>: <reason>` — a role not in
`checks`, a bad role, an unknown field, a key set twice, an indented `checks.` key (invisible to
the reader), a forbidden character, an empty value, `command: []`, a misplaced `{selection}`. The
profile then fails (`RESULT <p>: fail (profile.yaml:<line>: <reason>)`, `PLAN <p>: error (…)` under
`--explain`) without running, the precedent of a broken verify map. For a profile with rows,
`jig verify` writes `<role> <field> <value>` rows, tab-separated, plus a `<role> listed` row for every
role in `checks`, to a temporary file and exports its path as `JIG_VERIFY_CHECKS`; for every other
profile it unsets the variable, so a caller's own value never reaches it. The rows are the declaration
of support — `checks: [tests]` alone, released before the table, is not one, so php, laravel, node and
python as released never see the variable: `scope` has no new word, for the reason adr-20261107 gives for `JIG_VERIFY_COVERED`.

**D5. One new library function, `jp_check_cmd`.** `jp_check_cmd <role> <label> full|narrowed
<default-cmd>... [-- <selection>...]` sets `JP_CMD` to the table's `command` words or the default,
plus the mode's argument words with `{selection}` replaced. It never leaves `JP_CMD` empty and
sets a global, so it is called as a command, never inside `$( )`. No existing `jp_*` function changes
meaning (the library is a distributed interface). A profile reads `JIG_VERIFY_CHECKS` through it and
never `profile.yaml`: when a later layer merges tables, what `jig verify` writes changes and no
profile or library does.

**D6. A missing row is loud.** When the role is not in the table, or `narrowed` mode finds no
`narrowed` field, the function prints the check's fail line (a PLAN skip line under `--explain`, which is no verdict)
and returns 1. A fail, not a skip: a skip beside another check that passed would leave the profile
`pass` with this check unrun, and `jig verify` refuses only a run where nothing passed. This is a
profile.yaml kept by `upgrade` (keep-modified) beside a newer `verify.sh`: a different command in
silence is the worse answer. `covers` stays (a relation between profiles with no stack between them);
whether `laravel` built on `php` with an override retires it is Phase 3's decision, in an ADR that
supersedes adr-20261107. (Decided by adr-20261118-laravel-builds-on-php, which refines rather than
supersedes it: the stock use is retired, the mechanism stays.)

## Alternatives

- **A separate `checks.tsv` beside `profile.yaml`.** It would allow blanks inside an argument, but it
  is a new grammar and a new installed file in every profile (manifest, upgrade, drift), layers would
  need another file, and tabs are invisible to a person editing a layer. Dotted keys reuse the
  reader, `upgrade` and the presence check.
- **Block YAML** (nested `checks:` / `tests:` / `full:`). It needs a YAML parser in bash (ADR-0002),
  and half a YAML is a trap: an indented line is silently invisible to today's reader.
- **Inline-list values** (`[--parallel, --functional]`). The list is split on commas before the quotes
  come off, so an argument with a comma (`-Dtest=A,B`) cannot be written.
- **"The selection always goes last", without a token.** It expresses only the first form: clippy,
  maven, gradle, `go vet`, ruff and dart format are out.
- **Two fields, `before` and `after`, around the selection.** It expresses everything but cuts one
  command line into two keys, and a layer that changes the arguments touches both. The token reads as
  the command looks.
- **The table owns the whole command and Jig runs the check without `verify.sh`.** The on-the-fly tool
  choice and the narrowing logic are code; it would be rewritten in every profile.
- **The library reads `profile.yaml` next to `$0`.** Simpler now, but a layer of Phase 3 would not
  reach the base profile's `verify.sh` without changing the source, it breaks "`jig verify` decides
  and hands down", and it duplicates the reader in `profile.sh`.
- **A word in `scope` to declare support** (`scope: [..., table]`). Support is declared per check, and the
  rows are that declaration, as for `JIG_VERIFY_COVERED`.

## Consequences

- The grammar limit of D2 is permanent for the table: no quoted argument, none with a blank. A stock
  argument that needs one stays in code until the grammar changes.
- `jp_check_cmd` and the `checks.*` keys become a distributed interface once released: the function
  is never renamed or given another meaning, the keys will sit in project layers, and changing the
  shape is a breaking change for the changelog. Before the release it is one revert of one pull request:
  no stock profile uses the table yet.
- A typo in a table is a failed profile, not a no-op, and the message names the line.
- Stock profiles are not changed by this decision: they declare their checks in the item that follows
  (`php:tests (phpunit)` labels with it). Until then, a profile's `verify.sh` that never calls
  `jp_check_cmd` behaves as before.
- Phase 3 merges layers by changing what `jig verify` writes to the rows file; `drop` is implemented
  there, and the reservation keeps its name free.
- `jig verify` makes one temporary file per profile with a table and removes it with its other
  temporary files.
