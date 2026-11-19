# Tests for `.github/scripts/ci-outputs.sh` (task ci-tests-run-once).
# shellcheck shell=bash
#
# The outputs of the `scope` job, decided from the answers of ci-scope.sh and
# ci-reuse.sh.
#
# A table test: every combination of the scope line, the reuse line and the
# narrow scope line the workflow can hand over, with the four outputs each one
# must give. Helpers are prefixed co_ (ci-outputs).

CO_URL="https://github.com/example/jig/actions/runs/7"
CO_KNOWLEDGE="knowledge::test_real_repository_knowledge_passes_with_no_failures"

# co_expect <scope> <reuse> <narrow> <full> <suite> <whole> <reuse-out> [<filters>]
# — run the script and compare the outputs, line for line.
co_expect() {
  local want
  want="full=$4
suite=$5
whole=$6
reuse=$7"
  [ -z "${8:-}" ] || want="$want
filters=$8"
  run "$JIG_HOME/.github/scripts/ci-outputs.sh" "$1" "$2" "$3"
  assert_eq 0 "$RC" "$OUT"
  assert_eq "$want" "$OUT" "for scope '$1', reuse '$2', narrow '$3'"
}

# The paths of base 503c034, unchanged: no reuse was asked, or it said test.
test_ci_outputs_a_light_run_tests_nothing() {
  co_expect "light (docs only)" "test (push to main is always tested)" "" false none false false
}

test_ci_outputs_a_selected_run_runs_the_selection() {
  co_expect "selected (1 test)" "test (no green run of the pull request has tree T)" "" true selected false false
}

test_ci_outputs_a_full_run_runs_the_whole_suite() {
  co_expect "full (JIG_VERSION changed)" "test (no pull request into main was merged as X)" "" true all true false
}

test_ci_outputs_a_reuse_failure_tests_everything() {
  co_expect "full (push)" "test (ci-reuse.sh failed; testing everything)" "" true all true false
  co_expect "selected (1 test)" "test (ci-reuse.sh failed; testing everything)" "" true selected false false
}

# Exact reuse: a whole-suite run of the pull request proves the whole suite,
# a run of selected tests does not.
test_ci_outputs_exact_reuse_of_a_whole_suite_run_for_an_all_push() {
  co_expect "full (JIG_VERSION changed)" "reuse ($CO_URL tested tree T on every platform; suite: all)" "" \
    true all true true
}

test_ci_outputs_exact_reuse_of_a_whole_suite_run_for_a_selected_push() {
  co_expect "selected (1 test)" "reuse ($CO_URL tested tree T on every platform; suite: all)" "" \
    true selected true true
}

test_ci_outputs_exact_reuse_of_a_selected_run_for_a_selected_push_is_not_whole() {
  co_expect "selected (1 test)" "reuse ($CO_URL tested tree T on every platform; suite: selected)" "" \
    true selected false true
}

# A reuse line without the marker proves nothing about the whole suite.
test_ci_outputs_a_reuse_line_without_a_marker_is_not_whole() {
  co_expect "selected (1 test)" "reuse ($CO_URL tested tree T)" "" true selected false true
}

# An all push reused from a run that is not marked whole is still not whole:
# the reuse marker decides, not the push's own suite.
test_ci_outputs_a_full_push_reusing_a_run_not_marked_whole_is_not_whole() {
  co_expect "full (x)" "reuse ($CO_URL tested tree T on every platform; suite: selected)" "" true all false true
  co_expect "full (x)" "reuse ($CO_URL tested tree T)" "" true all false true
}

# A light scope is never reused, whatever the line says.
test_ci_outputs_a_light_run_is_never_reused() {
  co_expect "light (docs only)" "reuse ($CO_URL tested tree T on every platform; suite: all)" "" false none false false
}

# Narrow: the whole suite passed on the tree the difference starts from.
test_ci_outputs_a_narrow_light_difference_still_runs_the_knowledge_check() {
  co_expect "full (push)" "narrow abc123 ($CO_URL tested tree T in full; main has moved since)" "light (docs only)" \
    true selected true false "$CO_KNOWLEDGE"
  co_expect "selected (1 test)" "narrow abc123 ($CO_URL tested tree T in full; main has moved since)" "light (docs only)" \
    true selected true false "$CO_KNOWLEDGE"
}

test_ci_outputs_a_narrow_selected_difference_runs_the_selection() {
  co_expect "full (push)" "narrow abc123 (x)" "selected (2 tests)" true selected true false
}

test_ci_outputs_a_narrow_full_difference_runs_the_whole_suite() {
  co_expect "full (push)" "narrow abc123 (x)" "full (common.sh changed)" true all true false
  co_expect "selected (1 test)" "narrow abc123 (x)" "full (common.sh changed)" true all true false
}

test_ci_outputs_a_narrow_without_a_measurement_runs_the_whole_suite() {
  co_expect "full (push)" "narrow abc123 (x)" "" true all true false
}

test_ci_outputs_wrong_arguments_are_refused() {
  run "$JIG_HOME/.github/scripts/ci-outputs.sh" "light (x)"
  assert_eq 2 "$RC" "$OUT"
}

# The knowledge check as a one-filter selection is something ci-matrix.sh
# plans shares for: one test, one share a platform.
test_ci_outputs_the_knowledge_filter_alone_makes_a_matrix() {
  printf '%s\n' "$CO_KNOWLEDGE" > filters
  mkdir -p durations
  run bash -c 'cd "$1" && .github/scripts/ci-matrix.sh selected "$2" "$3"' _ "$JIG_HOME" "$PWD/filters" "$PWD/durations"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" 'matrix_unix={"include":[{"os":"ubuntu-latest","shard":"1/1"},{"os":"macos-latest","shard":"1/1"}]}'
  assert_contains "$OUT" 'matrix_windows={"shard":["1/1"]}'
}

# The knowledge test the script names is the one ci-scope.sh adds to every
# selection: two copies of the name, held together here.
test_ci_outputs_the_knowledge_filter_matches_ci_scope() {
  grep -qxF "CI_KNOWLEDGE_TEST=\"$CO_KNOWLEDGE\"" "$JIG_HOME/.github/scripts/ci-scope.sh" \
    || fail "ci-scope.sh names another knowledge test"
  grep -qxF "CO_KNOWLEDGE_TEST=\"$CO_KNOWLEDGE\"" "$JIG_HOME/.github/scripts/ci-outputs.sh" \
    || fail "ci-outputs.sh names another knowledge test"
}
