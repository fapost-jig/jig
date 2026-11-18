#!/usr/bin/env bash
# Verification for the dotnet profile. Called by `jig verify` from the
# repository root. Exit 0 = pass, 1 = fail, 2 = skip (no check could run).
# Prints one line per check: "dotnet: <check>: pass|fail|skip (<note>)".
#
# Checks by role (`checks:` in profile.yaml), the tool in the label: style
# (`style (dotnet format)`) and tests (`tests (dotnet test)`). Every command
# line comes from the profile's check table through jp_check_cmd
# (schemas/profile.md, Check table); a fallback to the full set is a `full`
# command line.
#
# The `dotnet` CLI is the only tool (adr-20260918-profiles-narrow-per-check-with-project-tools): the stack toolchain, from
# PATH. dotnet itself resolves which project or solution to build or test;
# this profile never guesses among several root *.sln files, it only ever
# passes an explicit project path when narrowing names one (D4). With
# several .sln files at the root and no narrowing, `dotnet test` runs plain
# and dotnet reports the ambiguity itself.
#
# Narrowing (ADR-0041, adr-20260918-profiles-narrow-per-check-with-project-tools), per check: `dotnet format` lints the
# changed .cs/.fs/.vb files via `--include`; `dotnet test` runs the test
# project a changed path resolves to — the nearest ancestor directory that
# holds a *.csproj/*.fsproj, when that project references a test SDK
# (Microsoft.NET.Test.Sdk, or a PackageReference for xunit/NUnit/MSTest) —
# and runs the full suite, with a reason, for every other change. A solution
# file, a Directory.Build.props/targets, a Directory.Packages.props, a
# global.json or a nuget.config always sends both checks to their full run.
set -eu
set -o pipefail

# shellcheck source=../../scripts/lib/profile.sh
. "$(dirname "$0")/../../scripts/lib/profile.sh"

jp_begin dotnet

STYLE_LABEL="style (dotnet format)"
TESTS_LABEL="tests (dotnet test)"

# _dotnet_is_always_all <path> — a file whose change can alter the result of
# any check regardless of which project it lives in: a solution, an
# MSBuild-wide props/targets file, central package versions, the pinned SDK,
# or the NuGet configuration. A plain `case` (never a for-loop over a glob
# list): a list built from these globs would be pathname-expanded against
# the real .sln file every project has, silently losing the pattern.
_dotnet_is_always_all() {
  case "$1" in
    *.sln|*Directory.Build.props|*Directory.Build.targets| \
    *Directory.Packages.props|global.json|*nuget.config|*NuGet.Config)
      return 0 ;;
  esac
  return 1
}

# _dotnet_always_all_changed — exit 0 when a changed path (deleted ones
# included) is one of the always-ALL files above.
_dotnet_always_all_changed() {
  local f
  jp_scoped || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _dotnet_is_always_all "$f" && return 0
  done < <(jp_changed)
  return 1
}

DOTNET_WHERE="not found on PATH"

# A check another profile took over (jp_covered) prints its own skip line and
# is left out of everything below, before any tool is looked for.
style_covered=0
tests_covered=0
if jp_covered style "$STYLE_LABEL"; then style_covered=1; fi
if jp_covered tests "$TESTS_LABEL"; then tests_covered=1; fi

if ! jp_have dotnet; then
  if [ "${JIG_VERIFY_EXPLAIN:-}" = 1 ]; then
    [ "$style_covered" = 1 ] || jp_plan "$STYLE_LABEL" skip "$DOTNET_WHERE"
    [ "$tests_covered" = 1 ] || jp_plan "$TESTS_LABEL" skip "$DOTNET_WHERE"
    exit 0
  fi
  [ "$style_covered" = 1 ] || jp_skip "$STYLE_LABEL" "$DOTNET_WHERE"
  [ "$tests_covered" = 1 ] || jp_skip "$TESTS_LABEL" "$DOTNET_WHERE"
  jp_end
fi

if [ "${JIG_VERIFY_EXPLAIN:-}" != 1 ] && { [ "$style_covered" = 0 ] || [ "$tests_covered" = 0 ]; }; then
  v=$(jp_version dotnet --version)
fi

# --- style: dotnet format --------------------------------------------------------------------

if [ "${JIG_VERIFY_EXPLAIN:-}" != 1 ]; then

if [ "$style_covered" = 1 ]; then
  :
elif jp_scoped && ! _dotnet_always_all_changed; then
  files=$(jp_changed cs fs vb)
  if [ -z "$files" ]; then
    jp_skip "$STYLE_LABEL" "scope: no changed .cs/.fs/.vb files"
  else
    n=$(printf '%s\n' "$files" | grep -c .)
    # One argument per line, so a path with a space stays one path.
    IFS='
'
    set -f
    # shellcheck disable=SC2086
    set -- $files
    set +f
    IFS=$' \t\n'
    if jp_check_cmd style "$STYLE_LABEL" narrowed dotnet -- "$@"; then
      jp_run "$STYLE_LABEL" "$v, scope: $n files" "${JP_CMD[@]}"
    fi
  fi
elif jp_scoped; then
  jp_full_left_to_ci "$STYLE_LABEL" "sln/build config changed" \
    || if jp_check_cmd style "$STYLE_LABEL" full dotnet; then
      jp_run "$STYLE_LABEL" "$v, scope: sln/build config changed, whole project" "${JP_CMD[@]}"
    fi
elif jp_check_cmd style "$STYLE_LABEL" full dotnet; then
  jp_run "$STYLE_LABEL" "$v" "${JP_CMD[@]}"
fi
fi

# --- tests: dotnet test ------------------------------------------------------------------

# Every *.csproj/*.fsproj in the project, computed once (a scoped run only):
# each ancestor lookup below would otherwise re-walk the whole file list.
DOTNET_PROJECT_FILES=""
if jp_scoped; then
  while IFS= read -r pf; do
    case "$pf" in
      *.csproj|*.fsproj)
        DOTNET_PROJECT_FILES="$DOTNET_PROJECT_FILES
$pf"
        ;;
    esac
  done < <(jp_files)
fi

# _dotnet_project_at <dir> — the project file directly inside <dir>, or
# nothing. Not inlined into a `$( )`: bash 3.2 misparses a `case` there.
_dotnet_project_at() {
  local dir="$1" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$(dirname "$p")" = "$dir" ] && { printf '%s\n' "$p"; return 0; }
  done <<EOF
$DOTNET_PROJECT_FILES
EOF
  return 1
}

# _dotnet_nearest_project <path> — the project file of the nearest ancestor
# directory that has one, walking up from <path>'s own directory to the
# repository root. Nothing when no ancestor has a project file at all.
_dotnet_nearest_project() {
  local f="$1" dir hit
  dir=$(dirname "$f")
  while :; do
    if hit=$(_dotnet_project_at "$dir"); then
      printf '%s\n' "$hit"
      return 0
    fi
    [ "$dir" = "." ] && return 1
    dir=$(dirname "$dir")
  done
}

# _dotnet_is_test_project <project-file> — the project references a test
# SDK: Microsoft.NET.Test.Sdk, or a PackageReference for xunit, NUnit or
# MSTest (any of their common package names: xunit.core, NUnit3TestAdapter,
# MSTest.TestFramework, MSTest.TestAdapter, ...).
_dotnet_is_test_project() {
  local proj="$1"
  [ -f "$proj" ] || return 1
  grep -q 'Microsoft.NET.Test.Sdk' "$proj" && return 0
  grep -Eqi '<PackageReference[[:space:]]+Include="(xunit|nunit|mstest)' "$proj" && return 0
  return 1
}

# _dotnet_builtin <path> — the test project a changed path needs: that
# project's file when the nearest ancestor project references a test SDK;
# ALL for a project-wide file, a path with no ancestor project, or an
# ancestor project that is not itself a test project (D4: "any other
# change" runs the full suite, it is never widened to a sibling test
# project).
_dotnet_builtin() {
  local f="$1" proj
  if jp_is_doc "$f"; then return 0; fi
  if _dotnet_is_always_all "$f"; then
    printf 'ALL\n'
    return 0
  fi
  if proj=$(_dotnet_nearest_project "$f") && _dotnet_is_test_project "$proj"; then
    printf '%s\n' "$proj"
  else
    printf 'ALL\n'
  fi
  return 0
}

# _dotnet_test <note> [<project>...] — `dotnet test`, once with no argument
# for a full run, once per project when narrowed: `dotnet test` accepts at
# most one project or solution, so several selected test projects are run
# one invocation each rather than passed on a single command line. Each
# invocation is its own `narrowed` command line, with that one project as the
# selection. A table that cannot build the command line has printed the
# check's fail line (jp_check_cmd), so no verdict follows it.
_dotnet_test() {
  local note="$1" proj failed=0
  shift
  if [ $# -eq 0 ]; then
    jp_check_cmd tests "$TESTS_LABEL" full dotnet || return 0
    if jp_exec "${JP_CMD[@]}"; then jp_pass "$TESTS_LABEL" "$note"; else jp_fail "$TESTS_LABEL" "$note"; fi
    return 0
  fi
  for proj in "$@"; do
    jp_check_cmd tests "$TESTS_LABEL" narrowed dotnet -- "$proj" || return 0
    jp_exec "${JP_CMD[@]}" || failed=1
  done
  if [ "$failed" = 0 ]; then jp_pass "$TESTS_LABEL" "$note"; else jp_fail "$TESTS_LABEL" "$note"; fi
  return 0
}

if [ "${JIG_VERIFY_EXPLAIN:-}" = 1 ]; then
  if [ "$style_covered" = 1 ]; then
    :
  elif jp_scoped && _dotnet_always_all_changed; then
    if jp_check_cmd style "$STYLE_LABEL" full dotnet; then
      jp_plan_full "$STYLE_LABEL" "solution or build configuration changed"
    fi
  elif jp_scoped; then
    files=$(jp_changed cs fs vb)
    if [ -z "$files" ]; then
      jp_plan "$STYLE_LABEL" skip "no changed .cs/.fs/.vb files"
    elif jp_check_cmd style "$STYLE_LABEL" narrowed dotnet -- "$files"; then
      jp_plan "$STYLE_LABEL" filtered "changed files: $(printf '%s\n' "$files" | paste -sd, -)"
    fi
  elif jp_check_cmd style "$STYLE_LABEL" full dotnet; then
    jp_plan "$STYLE_LABEL" full "full scope"
  fi
  jp_select _dotnet_builtin
  filters=$JP_SELECTION
  if [ -n "$filters" ] && [ "$filters" != ALL ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ ! -e "$f" ]; then filters=ALL; break; fi
    done <<EOF
$filters
EOF
  fi
  if [ "$tests_covered" = 1 ]; then
    :
  elif jp_scoped && [ -z "$filters" ]; then
    jp_plan_select "$TESTS_LABEL" "$filters" "test projects"
  elif jp_scoped && [ "$filters" != ALL ]; then
    # `dotnet test` runs once per project; one project stands for the check.
    if jp_check_cmd tests "$TESTS_LABEL" narrowed dotnet -- "$filters"; then
      jp_plan_select "$TESTS_LABEL" "$filters" "test projects"
    fi
  elif jp_check_cmd tests "$TESTS_LABEL" full dotnet; then
    jp_plan_select "$TESTS_LABEL" "$filters" "test projects"
  fi
  exit 0
fi

if [ "$tests_covered" = 1 ]; then
  :
elif ! jp_scoped; then
  _dotnet_test "$v"
else
  jp_select _dotnet_builtin
  filters=$JP_SELECTION
  if [ -z "$filters" ]; then
    jp_skip "$TESTS_LABEL" "scope: no changed file maps to a test project"
  elif [ "$filters" = ALL ]; then
    jp_full_left_to_ci "$TESTS_LABEL" "not narrowable" \
      || _dotnet_test "$v, scope: not narrowable, ran full set"
  else
    IFS='
'
    set -f
    # shellcheck disable=SC2086
    set -- $filters
    set +f
    IFS=$' \t\n'
    if missing=$(jp_first_missing "$@"); then
      jp_full_left_to_ci "$TESTS_LABEL" "filter '$missing' selects no tests" \
        || _dotnet_test "$v, scope: filter '$missing' selects no tests, ran full set"
    else
      _dotnet_test "$v, scope: $# test projects$JP_SELECTION_NOTE" "$@"
    fi
  fi
fi

jp_end
