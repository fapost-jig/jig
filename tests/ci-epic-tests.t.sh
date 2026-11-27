# shellcheck shell=bash
# Tests for `.github/scripts/ci-epic-tests.sh`: which tests a run on an epic branch runs by default
# instead of the whole bash suite.

cet_run() {
  run "$JIG_HOME/.github/scripts/ci-epic-tests.sh" "$@"
}

test_ci_epic_tests_the_migration_epic_runs_its_own_suites() {
  cet_run epic/stack-migration
  assert_eq 0 "$RC"
  assert_contains "$OUT" "tests next-ts:: next-go:: parity:: parity-ports:: recorder::"
  assert_contains "$OUT" "dispatcher::test_version_prints_semver"
}

test_ci_epic_tests_every_filter_names_a_test_file_that_exists() {
  local f file
  cet_run epic/stack-migration
  for f in ${OUT#tests }; do
    file=${f%%::*}
    assert_file "$JIG_HOME/tests/$file.t.sh"
    case "$f" in
      *::) ;;
      *) grep -q "^${f#*::}()" "$JIG_HOME/tests/$file.t.sh" || fail "$f names no test" ;;
    esac
  done
}

test_ci_epic_tests_main_and_other_branches_run_the_whole_scope() {
  local b
  for b in main epic/x epic/stack-migration-2 epic/stack-migration/sub task/windows-phase1-run ""; do
    cet_run "$b"
    assert_eq 0 "$RC"
    assert_contains "$OUT" "whole ("
  done
}

test_ci_epic_tests_usage() {
  cet_run
  assert_eq 2 "$RC"
  cet_run a b
  assert_eq 2 "$RC"
}
