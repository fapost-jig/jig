# shellcheck shell=bash
# Tests for `.github/scripts/ci-untested-base.sh`: which pull requests run no
# test suite because their base branch is tested another way.

cub_run() {
  run "$JIG_HOME/.github/scripts/ci-untested-base.sh" "$@"
}

test_ci_untested_base_a_pull_request_into_the_migration_epic_skips() {
  cub_run pull_request epic/stack-migration
  assert_eq 0 "$RC"
  assert_contains "$OUT" "skip (pull requests into epic/stack-migration run no tests"
}

test_ci_untested_base_a_pull_request_into_main_is_tested() {
  cub_run pull_request main
  assert_eq 0 "$RC"
  assert_contains "$OUT" "test (pull_request into main runs what its scope needs)"
}

test_ci_untested_base_another_epic_is_tested() {
  cub_run pull_request epic/x
  assert_contains "$OUT" "test (pull_request into epic/x"
}

test_ci_untested_base_names_are_compared_whole() {
  cub_run pull_request epic/stack-migration-2
  assert_contains "$OUT" "test (pull_request into epic/stack-migration-2"
  cub_run pull_request epic/stack
  assert_contains "$OUT" "test (pull_request into epic/stack "
  cub_run pull_request epic/stack-migration/sub
  assert_contains "$OUT" "test (pull_request into epic/stack-migration/sub"
}

test_ci_untested_base_other_events_are_tested_whatever_the_base() {
  local event
  for event in push workflow_dispatch schedule; do
    cub_run "$event" epic/stack-migration
    assert_eq 0 "$RC"
    assert_contains "$OUT" "test ($event into epic/stack-migration runs what its scope needs)"
  done
  cub_run workflow_dispatch
  assert_contains "$OUT" "test (workflow_dispatch into - runs"
}

test_ci_untested_base_refuses_a_call_without_an_event() {
  cub_run
  assert_eq 2 "$RC"
  assert_contains "$OUT" "usage"
}
