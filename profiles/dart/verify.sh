#!/usr/bin/env bash
# Verification for the dart profile. Called by `jig verify` from the
# repository root. Exit 0 = pass, 1 = fail, 2 = skip (no check could run).
# Prints one line per check: "dart: <check>: pass|fail|skip (<note>)", the check
# being its role and tool: `static (dart analyze)` or `static (flutter
# analyze)`, `style (dart format)`, `tests (dart test)` or `tests (flutter
# test)` (`checks:` in profile.yaml). Each command line comes from the
# profile's check table through jp_check_cmd (schemas/profile.md, Check table);
# the runner, chosen on the fly, is the default the table leaves to this
# script. Every fallback to the full set is a `full` command line.
#
# The stack toolchain comes from PATH (adr-20260918-profiles-narrow-per-check-with-project-tools, D2): `flutter` for a
# Flutter project (pubspec.yaml declares `sdk: flutter` under a
# dependency), `dart` otherwise. `dart format` is always the `dart` binary,
# even in a Flutter project, because `flutter format` does not exist as a
# subcommand; a project with only `flutter` on PATH (no plain `dart`) skips
# the format check.
#
# Narrowing (ADR-0041, adr-20260918-profiles-narrow-per-check-with-project-tools), per check: analyze and format take the
# changed .dart files as arguments; test runs the test files the changed
# paths map to — a changed *_test.dart itself, or test/a/b_test.dart for a
# changed lib/a/b.dart — and everything when a path maps to nothing or a
# project-wide file changed.
#
# `flutter test`/`dart test` runs Dart, and web/ is Flutter's own front end
# for the web build target — its HTML, CSS and JS entry point, read by
# neither a widget nor a unit test. A changed pubspec.yaml already sends the
# test check to the full set: it declares the asset bundle a golden test can
# read, so an asset under it is left to that existing rule rather than
# narrowed away (ADR-0013).
set -eu
set -o pipefail

# shellcheck source=../../scripts/lib/profile.sh
. "$(dirname "$0")/../../scripts/lib/profile.sh"

jp_begin dart

# Files whose change can alter the result of any check.
DART_ALL_GLOBS="pubspec.yaml pubspec.lock analysis_options.yaml"

# Flutter's own front end for the web build target. Neither `flutter test`
# nor `dart test` bundles or serves it, so changing one cannot change what a
# test observes; it holds only the HTML/CSS/JS entry point (index.html,
# manifest.json, icons), never a .dart source.
DART_FRONTEND_GLOBS="web/*"

# _dart_is_flutter — whether pubspec.yaml declares a dependency on the
# Flutter SDK, the one signal that decides which binary runs the checks.
_dart_is_flutter() {
  [ -f pubspec.yaml ] || return 1
  grep -qE 'sdk:[[:space:]]*flutter' pubspec.yaml
}

DART_RUNNER=dart
if _dart_is_flutter; then
  DART_RUNNER=flutter
fi

# The checks' labels: role and tool.
STATIC_LABEL="static ($DART_RUNNER analyze)"
STYLE_LABEL="style (dart format)"
TESTS_LABEL="tests ($DART_RUNNER test)"

# The same mapping is used by the run and by the preliminary plan.
_dart_builtin_test() {
  local f="$1" rest
  if jp_path_matches "$f" "$DART_ALL_GLOBS"; then
    printf 'ALL\n'
    return 0
  fi
  case "$f" in
    *.md|*.rst|docs/*|.ai/*) return 0 ;;
  esac
  if jp_path_matches "$f" "$DART_FRONTEND_GLOBS"; then
    return 0
  fi
  case "$f" in
    *.dart) ;;
    *) printf 'ALL\n'; return 0 ;;
  esac
  case "$f" in
    *_test.dart) printf '%s\n' "$f"; return 0 ;;
  esac
  case "$f" in
    lib/*)
      rest=${f#lib/}
      rest=${rest%.dart}
      printf 'test/%s_test.dart\n' "$rest"
      ;;
    *) printf 'ALL\n' ;;
  esac
  return 0
}

# _dart_all_reason <path> — why the full set runs, for the path
# jp_decide_cause named. "not narrowable" was one shrug for three different
# situations, and the person reading it could not tell their pubspec.yaml
# from a class no test is named after. An empty <path> means the project's
# own map asked for the full set; that line's author knows why, so the old
# wording stands rather than a guess at their reason.
_dart_all_reason() {
  local f="$1"
  if [ -z "$f" ]; then
    printf 'not narrowable\n'
  elif jp_path_matches "$f" "$DART_ALL_GLOBS"; then
    printf '%s can affect any test\n' "$f"
  else
    case "$f" in
      *.dart) printf 'no test is named after %s\n' "$f" ;;
      *) printf 'the profile cannot map %s to tests\n' "$f" ;;
    esac
  fi
  return 0
}

if [ "${JIG_VERIFY_EXPLAIN:-}" = 1 ]; then
  for role in static style; do
    tool="$DART_RUNNER"
    label=$STATIC_LABEL
    if [ "$role" = style ]; then tool=dart; label=$STYLE_LABEL; fi
    if jp_covered "$role" "$label"; then
      :
    elif ! jp_have "$tool"; then
      jp_plan "$label" skip "$tool not found on PATH"
    elif jp_scoped && jp_changed_any pubspec.yaml pubspec.lock analysis_options.yaml; then
      if jp_ci_runs_full || jp_check_cmd "$role" "$label" full "$tool"; then
        jp_plan_full "$label" "pubspec or analysis options changed"
      fi
    elif jp_scoped; then
      files=$(jp_changed dart)
      if [ -z "$files" ]; then
        jp_plan "$label" skip "no changed .dart files"
      elif jp_check_cmd "$role" "$label" narrowed "$tool"; then
        jp_plan "$label" filtered "changed .dart files: $(printf '%s\n' "$files" | paste -sd, -)"
      fi
    elif jp_check_cmd "$role" "$label" full "$tool"; then
      jp_plan "$label" full "full scope"
    fi
  done
  if jp_covered tests "$TESTS_LABEL"; then
    :
  elif ! jp_have "$DART_RUNNER"; then
    jp_plan "$TESTS_LABEL" skip "$DART_RUNNER not found on PATH"
  else
    jp_select _dart_builtin_test
    filters=$JP_SELECTION
    if [ -n "$filters" ] && [ "$filters" != ALL ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ ! -e "$f" ]; then filters=ALL; break; fi
      done <<EOF
$filters
EOF
    fi
    if [ "$filters" = ALL ]; then
      why=$(_dart_all_reason "$(jp_decide_cause _dart_builtin_test)")
    else
      why=
    fi
    # A narrowed run with nothing to run needs no command; any other asks the
    # check table, `narrowed` for a selection of test files, `full` otherwise.
    explain_mode=full
    if jp_scoped && [ -n "$filters" ] && [ "$filters" != ALL ]; then
      explain_mode=narrowed
    fi
    if jp_scoped && [ -z "$filters" ]; then
      jp_plan_select "$TESTS_LABEL" "$filters" "test files" "$why"
    elif jp_check_cmd tests "$TESTS_LABEL" "$explain_mode" "$DART_RUNNER"; then
      jp_plan_select "$TESTS_LABEL" "$filters" "test files" "$why"
    fi
  fi
  exit 0
fi

# --- static: analyze -------------------------------------------------------

if jp_covered static "$STATIC_LABEL"; then
  :
elif ! jp_have "$DART_RUNNER"; then
  jp_skip "$STATIC_LABEL" "$DART_RUNNER not found on PATH"
else
  v=$(jp_version "$DART_RUNNER" --version)
  if jp_scoped && ! jp_changed_any pubspec.yaml pubspec.lock analysis_options.yaml; then
    files=$(jp_changed dart)
    if [ -z "$files" ]; then
      jp_skip "$STATIC_LABEL" "scope: no changed .dart files"
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
      if jp_check_cmd static "$STATIC_LABEL" narrowed "$DART_RUNNER" -- "$@"; then
        jp_run "$STATIC_LABEL" "$v, scope: $n files" "${JP_CMD[@]}"
      fi
    fi
  elif jp_scoped; then
    jp_full_left_to_ci "$STATIC_LABEL" "pubspec or analysis options changed" \
      || if jp_check_cmd static "$STATIC_LABEL" full "$DART_RUNNER"; then
        jp_run "$STATIC_LABEL" "$v, scope: pubspec or analysis options changed, whole project" "${JP_CMD[@]}"
      fi
  elif jp_check_cmd static "$STATIC_LABEL" full "$DART_RUNNER"; then
    jp_run "$STATIC_LABEL" "$v" "${JP_CMD[@]}"
  fi
fi

# --- style: format -----------------------------------------------------------

# `dart format` is bundled with the Dart SDK, and the Flutter SDK bundles
# its own copy of `dart` too, so a project with either toolchain installed
# ordinarily has it; a project with only a bare `flutter` shim on PATH does
# not, and the check skips rather than guessing at `flutter format`.
if jp_covered style "$STYLE_LABEL"; then
  :
elif ! jp_have dart; then
  jp_skip "$STYLE_LABEL" "dart not found on PATH"
else
  v=$(jp_version dart --version)
  if jp_scoped && ! jp_changed_any pubspec.yaml pubspec.lock analysis_options.yaml; then
    files=$(jp_changed dart)
    if [ -z "$files" ]; then
      jp_skip "$STYLE_LABEL" "scope: no changed .dart files"
    else
      n=$(printf '%s\n' "$files" | grep -c .)
      IFS='
'
      set -f
      # shellcheck disable=SC2086
      set -- $files
      set +f
      IFS=$' \t\n'
      if jp_check_cmd style "$STYLE_LABEL" narrowed dart -- "$@"; then
        jp_run "$STYLE_LABEL" "$v, scope: $n files" "${JP_CMD[@]}"
      fi
    fi
  elif jp_scoped; then
    jp_full_left_to_ci "$STYLE_LABEL" "pubspec or analysis options changed" \
      || if jp_check_cmd style "$STYLE_LABEL" full dart; then
        jp_run "$STYLE_LABEL" "$v, scope: pubspec or analysis options changed, whole project" "${JP_CMD[@]}"
      fi
  elif jp_check_cmd style "$STYLE_LABEL" full dart; then
    jp_run "$STYLE_LABEL" "$v" "${JP_CMD[@]}"
  fi
fi

# --- tests: test -------------------------------------------------------------

if jp_covered tests "$TESTS_LABEL"; then
  :
elif ! jp_have "$DART_RUNNER"; then
  jp_skip "$TESTS_LABEL" "$DART_RUNNER not found on PATH"
else
  v=$(jp_version "$DART_RUNNER" --version)
  if ! jp_scoped; then
    if jp_check_cmd tests "$TESTS_LABEL" full "$DART_RUNNER"; then
      jp_run "$TESTS_LABEL" "$v" "${JP_CMD[@]}"
    fi
  else
    jp_select _dart_builtin_test
    filters=$JP_SELECTION
    if [ -z "$filters" ]; then
      jp_skip "$TESTS_LABEL" "scope: no changed file maps to a test"
    elif [ "$filters" = ALL ]; then
      why=$(_dart_all_reason "$(jp_decide_cause _dart_builtin_test)")
      jp_full_left_to_ci "$TESTS_LABEL" "$why" \
        || if jp_check_cmd tests "$TESTS_LABEL" full "$DART_RUNNER"; then
          jp_run "$TESTS_LABEL" "$v, scope: $why, ran full set" "${JP_CMD[@]}"
        fi
    else
      IFS='
'
      set -f
      # shellcheck disable=SC2086
      if missing=$(jp_first_missing $filters); then
        set +f
        IFS=$' \t\n'
        jp_full_left_to_ci "$TESTS_LABEL" "filter '$missing' selects no tests" \
          || if jp_check_cmd tests "$TESTS_LABEL" full "$DART_RUNNER"; then
            jp_run "$TESTS_LABEL" "$v, scope: filter '$missing' selects no tests, ran full set" "${JP_CMD[@]}"
          fi
      else
        n=$(printf '%s\n' "$filters" | grep -c .)
        # shellcheck disable=SC2086
        set -- $filters
        set +f
        IFS=$' \t\n'
        if jp_check_cmd tests "$TESTS_LABEL" narrowed "$DART_RUNNER" -- "$@"; then
          jp_run "$TESTS_LABEL" "$v, scope: $n test files$JP_SELECTION_NOTE" "${JP_CMD[@]}"
        fi
      fi
    fi
  fi
fi

jp_end
