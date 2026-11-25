# shellcheck shell=bash
# Tests for `.github/scripts/ci-windows.sh` (the 2026-11-25 amendment of
# adr-20260924-windows-runs-on-a-pull-request-that-touches-platform-behaviour):
# which events run the Windows shards.

cwn_run() {
  run "$JIG_HOME/.github/scripts/ci-windows.sh" "$@"
}

test_ci_windows_a_pull_request_never_runs_the_shards() {
  cwn_run pull_request
  assert_eq 0 "$RC"
  assert_contains "$OUT" "skip (pull_request leaves Windows to main, nightly and manual runs)"
}

test_ci_windows_a_push_to_an_epic_branch_skips_them() {
  cwn_run push epic/profile-layers
  assert_eq 0 "$RC"
  assert_contains "$OUT" "skip (push leaves Windows to main, nightly and manual runs)"
}

test_ci_windows_main_the_nightly_run_and_a_dispatch_run_every_platform() {
  cwn_run push main
  assert_eq 0 "$RC"
  assert_contains "$OUT" "windows (push runs every platform)"
  cwn_run schedule main
  assert_contains "$OUT" "windows (schedule runs every platform)"
  cwn_run workflow_dispatch epic/x
  assert_contains "$OUT" "windows (workflow_dispatch runs every platform)"
  # Only a pull request or a push to an epic is skipped: any other branch's
  # push is tested everywhere.
  cwn_run push task/x
  assert_contains "$OUT" "windows (push runs every platform)"
}

test_ci_windows_refuses_a_call_without_an_event() {
  cwn_run
  assert_eq 2 "$RC"
  assert_contains "$OUT" "usage"
}
