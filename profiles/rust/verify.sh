#!/usr/bin/env bash
# Verification for the rust profile. Called by `jig verify` from the
# repository root. Exit 0 = pass, 1 = fail, 2 = skip (no check could run).
# Prints one line per check: "rust: <check>: pass|fail|skip (<note>)", the check
# being its role and tool: `style (cargo fmt)`, `lint (cargo clippy)`,
# `tests (cargo test)` (`checks:` in profile.yaml). Each command line comes from
# the profile's check table through jp_check_cmd (schemas/profile.md, Check
# table): `narrowed` with the `-p <crate>` words of a narrowed run, `full` for
# the full crate set, which includes every fallback to it.
#
# Tools come from PATH only (adr-20260918-profiles-narrow-per-check-with-project-tools D2): cargo is the stack toolchain, and
# fmt/clippy are its own subcommands (`rustup component add`), never a
# project-local binary. `cargo fmt --version` and `cargo clippy --version`
# gate their checks: a missing rustup component fails that probe, not a
# missing cargo.
#
# Narrowing (ADR-0041, adr-20260918-profiles-narrow-per-check-with-project-tools; D4 rust row): a changed path is mapped to
# the crate that owns it — the nearest ancestor directory (starting at the
# path's own directory) whose Cargo.toml declares a [package]. fmt, clippy
# and test narrow identically, each with one `-p <crate>` per crate the
# change touched. A changed member Cargo.toml narrows to the crate it
# declares; the root workspace manifest (a Cargo.toml with no [package] of
# its own), Cargo.lock, .cargo/** and a rust-toolchain* pin file always run
# the full set, and so does any path outside every crate — this includes a
# changed file whose only ancestor Cargo.toml is a pure workspace manifest.
# Dependents of a changed crate are not tested locally: CI, not this
# profile, covers the rest of the workspace (ADR-0041), so the note names
# only the crates that were changed (`scope: crates a,b`), never their
# dependents.
set -eu
set -o pipefail

# shellcheck source=../../scripts/lib/profile.sh
. "$(dirname "$0")/../../scripts/lib/profile.sh"

jp_begin rust

FMT_LABEL="style (cargo fmt)"
CLIPPY_LABEL="lint (cargo clippy)"
TEST_LABEL="tests (cargo test)"

if [ "${JIG_VERIFY_EXPLAIN:-}" != 1 ] && ! jp_have cargo; then
  # A check another profile took over, or a layer dropped, says so, not that
  # cargo is missing: jp_covered is asked before the tool is.
  jp_covered style "$FMT_LABEL" || jp_skip "$FMT_LABEL" "cargo not found on PATH"
  jp_covered lint "$CLIPPY_LABEL" || jp_skip "$CLIPPY_LABEL" "cargo not found on PATH"
  jp_covered tests "$TEST_LABEL" || jp_skip "$TEST_LABEL" "cargo not found on PATH"
  jp_end
fi

# Files whose change can alter the result of every crate's checks.
RUST_ALL_GLOBS="Cargo.lock .cargo/* rust-toolchain*"

# _rust_has_package <cargo-toml> — the manifest exists and declares
# `[package]`: a member crate manifest, not a pure workspace root.
_rust_has_package() {
  [ -f "$1" ] || return 1
  grep -q '^\[package\]' "$1"
}

# _rust_crate_name <cargo-toml> — the `name = "..."` line inside that
# manifest's own [package] section (never [workspace.package] or another
# table).
_rust_crate_name() {
  awk '
    /^\[package\]/ { insec = 1; next }
    /^\[/          { insec = 0 }
    insec && /^[[:space:]]*name[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, "")
      gsub(/^"|"[[:space:]]*$/, "")
      print
      exit
    }
  ' "$1"
}

# _rust_crate_dir <path> — the nearest ancestor directory (starting at
# <path>'s own directory, so a changed Cargo.toml can name its own crate)
# whose Cargo.toml declares [package]; nothing when no ancestor does, i.e.
# <path> is outside every crate. Not inlined into a `$( )`: bash 3.2
# misparses a `case`/loop written there (conventions/shell.md).
_rust_crate_dir() {
  local d
  d=$(dirname "$1")
  while :; do
    if _rust_has_package "$d/Cargo.toml"; then
      printf '%s\n' "$d"
      return 0
    fi
    if [ "$d" = "." ]; then
      return 1
    fi
    d=$(dirname "$d")
  done
}

# _rust_builtin <path> — the narrowing a changed path forces on its own,
# before the project's map has a say: ALL for the lockfile, `.cargo/`
# config or a toolchain pin, or when the path is outside every crate
# (including a pure workspace root manifest); otherwise the name of the
# crate that owns it.
_rust_builtin() {
  local f="$1" dir crate
  if jp_is_doc "$f"; then return 0; fi
  if jp_path_matches "$f" "$RUST_ALL_GLOBS"; then
    printf 'ALL\n'
    return 0
  fi
  if dir=$(_rust_crate_dir "$f"); then
    crate=$(_rust_crate_name "$dir/Cargo.toml")
    if [ -n "$crate" ]; then
      printf '%s\n' "$crate"
      return 0
    fi
  fi
  printf 'ALL\n'
  return 0
}

# _rust_known_crates — every crate name a member Cargo.toml in the project
# declares, one per line. Used to validate a crate name coming from the
# project's map (D5): a name no member Cargo.toml declares is a hollow
# filter, same as a test path that does not exist.
_rust_known_crates() {
  local f
  while IFS= read -r f; do
    case "$f" in
      Cargo.toml | */Cargo.toml) ;;
      *) continue ;;
    esac
    _rust_has_package "$f" || continue
    _rust_crate_name "$f"
  done < <(jp_files)
  return 0
}

# _rust_first_unknown <crate>... — the first crate name no member Cargo.toml
# declares; nothing when every one is known. Mirrors jp_first_missing, but
# against crate names instead of paths.
_rust_first_unknown() {
  local known="" name
  known=$(_rust_known_crates)
  for name in "$@"; do
    if ! jp_has_line "$name" "$known"; then
      printf '%s\n' "$name"
      return 0
    fi
  done
  return 1
}

# _rust_scope — fmt, clippy and test narrow identically (D4 rust row), so
# this is computed once per check rather than three separate copies of the
# same map/builtin logic. On return 0, $RUST_NOTE is the verdict suffix
# (empty for an unscoped run) and $RUST_ARGS holds the `-p <crate>` pairs to
# pass, one token per line (empty for a full run — the caller then runs
# cargo with no extra flags). On return 1 nothing changed maps to this
# check at all; $RUST_SKIP_REASON says why. $RUST_FULL_WHY is non-empty when
# a narrowed run lands on the full crate set, and says why.
#
# Under `verify.full_run: ci` an ALL beside crates is dropped (jp_select), so
# the crates run and the full set is left to CI, for fmt, clippy and test alike.
RUST_NOTE=""
RUST_ARGS=""
RUST_SKIP_REASON=""
RUST_FULL_WHY=""
_rust_scope() {
  RUST_NOTE=""
  RUST_ARGS=""
  RUST_SKIP_REASON=""
  RUST_FULL_WHY=""
  jp_scoped || return 0
  local sel crates missing c select_note=""
  jp_select _rust_builtin
  sel=$JP_SELECTION
  select_note=$JP_SELECTION_NOTE
  if [ -z "$sel" ]; then
    RUST_SKIP_REASON="scope: no changed file affects this check"
    return 1
  fi
  if [ "$sel" = ALL ]; then
    RUST_FULL_WHY="full (root manifest, lockfile, toolchain pin or a file outside any crate changed)"
    RUST_NOTE=", scope: $RUST_FULL_WHY"
    return 0
  fi
  crates="$sel"
  local IFS
  IFS='
'
  set -f
  # shellcheck disable=SC2086
  set -- $crates
  set +f
  if missing=$(_rust_first_unknown "$@"); then
    RUST_FULL_WHY="crate '$missing' not declared"
    RUST_NOTE=", scope: $RUST_FULL_WHY, ran full set"
    return 0
  fi
  RUST_NOTE=", scope: crates $(printf '%s,' "$@" | sed 's/,$//')$select_note"
  for c in "$@"; do
    RUST_ARGS="$RUST_ARGS-p
$c
"
  done
  return 0
}

# _rust_mode [<arg>...] — the mode of the check table for a run: `narrowed`
# when `-p <crate>` words were selected, `full` for the full crate set (an
# empty selection, which is also every fallback to it).
_rust_mode() {
  if [ $# -eq 0 ]; then printf 'full\n'; else printf 'narrowed\n'; fi
}

# --- style: cargo fmt --------------------------------------------------------

# A check another profile took over (jp_covered) prints its own skip line and
# is left out of everything below, before any tool is looked for.
fmt_covered=0
clippy_covered=0
tests_covered=0
if jp_covered style "$FMT_LABEL"; then fmt_covered=1; fi
if jp_covered lint "$CLIPPY_LABEL"; then clippy_covered=1; fi
if jp_covered tests "$TEST_LABEL"; then tests_covered=1; fi

if [ "${JIG_VERIFY_EXPLAIN:-}" = 1 ]; then
  if ! jp_have cargo; then
    [ "$fmt_covered" = 1 ] || jp_plan "$FMT_LABEL" skip "cargo not found on PATH"
    [ "$clippy_covered" = 1 ] || jp_plan "$CLIPPY_LABEL" skip "cargo not found on PATH"
    [ "$tests_covered" = 1 ] || jp_plan "$TEST_LABEL" skip "cargo not found on PATH"
    exit 0
  fi
  if ! _rust_scope; then
    [ "$fmt_covered" = 1 ] || jp_plan "$FMT_LABEL" skip "$RUST_SKIP_REASON"
    [ "$clippy_covered" = 1 ] || jp_plan "$CLIPPY_LABEL" skip "$RUST_SKIP_REASON"
    [ "$tests_covered" = 1 ] || jp_plan "$TEST_LABEL" skip "$RUST_SKIP_REASON"
  else
    # The mode the check table is asked in: `narrowed` for a run with crates.
    explain_mode=full
    if [ -n "$RUST_ARGS" ]; then explain_mode=narrowed; fi
    if [ -n "$RUST_ARGS" ]; then
      scope_state=filtered
      scope_reason="crates $(printf '%s\n' "$RUST_ARGS" | paste -sd, -)"
    else
      scope_state=full
      scope_reason="full crate set"
    fi
    if [ -n "$RUST_FULL_WHY" ] && jp_ci_runs_full; then
      [ "$fmt_covered" = 1 ] || jp_plan "$FMT_LABEL" skip "scope: $RUST_FULL_WHY, full set left to CI"
      [ "$clippy_covered" = 1 ] || jp_plan "$CLIPPY_LABEL" skip "scope: $RUST_FULL_WHY, full set left to CI"
    else
      if [ "$fmt_covered" = 1 ]; then :
      elif jp_check_cmd style "$FMT_LABEL" "$explain_mode" cargo; then
        jp_plan "$FMT_LABEL" conditional "$scope_state if rustfmt is installed; otherwise skip; component probe not run$JP_SELECTION_NOTE"
      fi
      if [ "$clippy_covered" = 1 ]; then :
      elif jp_check_cmd lint "$CLIPPY_LABEL" "$explain_mode" cargo; then
        jp_plan "$CLIPPY_LABEL" conditional "$scope_state if clippy is installed; otherwise skip; component probe not run$JP_SELECTION_NOTE"
      fi
    fi
    if [ "$tests_covered" = 1 ]; then :
    elif [ -n "$RUST_FULL_WHY" ]; then
      if jp_ci_runs_full || jp_check_cmd tests "$TEST_LABEL" full cargo; then
        jp_plan_full "$TEST_LABEL" "full crate set"
      fi
    elif jp_check_cmd tests "$TEST_LABEL" "$explain_mode" cargo; then
      if [ -n "$RUST_ARGS" ]; then
        jp_plan "$TEST_LABEL" filtered "crates $(printf '%s\n' "$RUST_ARGS" | paste -sd, -)$JP_SELECTION_NOTE"
      else
        jp_plan "$TEST_LABEL" "$scope_state" "$scope_reason"
      fi
    fi
  fi
  exit 0
fi

if [ "$fmt_covered" = 1 ]; then
  :
elif jp_exec cargo fmt --version >/dev/null 2>&1; then
  v=$(jp_version cargo fmt --version)
  if _rust_scope; then
    IFS='
'
    set -f
    # shellcheck disable=SC2086
    set -- $RUST_ARGS
    set +f
    IFS=$' \t\n'
    if [ -z "$RUST_FULL_WHY" ] || ! jp_full_left_to_ci "$FMT_LABEL" "$RUST_FULL_WHY"; then
      if jp_check_cmd style "$FMT_LABEL" "$(_rust_mode "$@")" cargo -- "$@"; then
        jp_run "$FMT_LABEL" "$v$RUST_NOTE" "${JP_CMD[@]}"
      fi
    fi
  else
    jp_skip "$FMT_LABEL" "$RUST_SKIP_REASON"
  fi
else
  jp_skip "$FMT_LABEL" "rustfmt not installed"
fi

# --- lint: cargo clippy -------------------------------------------------------

if [ "$clippy_covered" = 1 ]; then
  :
elif jp_exec cargo clippy --version >/dev/null 2>&1; then
  v=$(jp_version cargo clippy --version)
  if _rust_scope; then
    IFS='
'
    set -f
    # shellcheck disable=SC2086
    set -- $RUST_ARGS
    set +f
    IFS=$' \t\n'
    if [ -z "$RUST_FULL_WHY" ] || ! jp_full_left_to_ci "$CLIPPY_LABEL" "$RUST_FULL_WHY"; then
      if jp_check_cmd lint "$CLIPPY_LABEL" "$(_rust_mode "$@")" cargo -- "$@"; then
        jp_run "$CLIPPY_LABEL" "$v$RUST_NOTE" "${JP_CMD[@]}"
      fi
    fi
  else
    jp_skip "$CLIPPY_LABEL" "$RUST_SKIP_REASON"
  fi
else
  jp_skip "$CLIPPY_LABEL" "clippy not installed"
fi

# --- tests: cargo test --------------------------------------------------------

if [ "$tests_covered" = 1 ]; then
  :
elif _rust_scope; then
  v=$(jp_version cargo --version)
  IFS='
'
  set -f
  # shellcheck disable=SC2086
  set -- $RUST_ARGS
  set +f
  IFS=$' \t\n'
  if [ -z "$RUST_FULL_WHY" ] || ! jp_full_left_to_ci "$TEST_LABEL" "$RUST_FULL_WHY"; then
    if jp_check_cmd tests "$TEST_LABEL" "$(_rust_mode "$@")" cargo -- "$@"; then
      jp_run "$TEST_LABEL" "$v$RUST_NOTE" "${JP_CMD[@]}"
    fi
  fi
else
  jp_skip "$TEST_LABEL" "$RUST_SKIP_REASON"
fi

jp_end
