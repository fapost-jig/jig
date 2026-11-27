# Tests for .github/workflows/ci.yml itself — specifically, the division of the
# suite into shares on every platform, which is the one thing about the file
# that no CI run can check. A workflow whose shares do not cover the suite runs
# exactly what it was told to and reports green on the part it ran.
#
# That is the empty selection domains/verify/RULES.md refuses ("a narrowing
# that selects nothing is not a pass"), one level above a profile: not a filter
# matching no test, but a share of the suite nobody was asked to run at all.
#
# The shares used to be written into the matrices here, and the tests below
# held each platform's entries to 1/n .. n/n. Their number now follows the work
# the run selected (adr-20261110-a-pull-request-runs-the-tests-its-change-reaches):
# the `scope` job computes both matrices with .github/scripts/ci-matrix.sh,
# whose tests hold every platform to 1/n .. n/n with one n
# (tests/ci-matrix.t.sh). What is left to guard here is that the jobs take
# those matrices and nothing else, and hand each share to the runner as it
# was planned.
# shellcheck shell=bash

# cw_file — this repository's workflow, the subject of every test below.
cw_file() { printf '%s\n' "$JIG_HOME/.github/workflows/ci.yml"; }

# cw_job_block <job> — the lines of one job, from its `  <job>:` line to the
# line before the next job.
cw_job_block() {
  awk -v job="  $1:" '
    $0 == job { f = 1; print; next }
    f && /^  [A-Za-z0-9_-]+:[ ]*$/ { exit }
    f { print }
  ' "$(cw_file)"
}

# cw_has <block> <line> — whether <block> holds <line> exactly, leading
# spaces aside.
cw_has() {
  printf '%s\n' "$1" | sed 's/^ *//' | grep -qxF "$2"
}

# The scope job plans the shares with ci-matrix.sh and publishes both
# matrices and the plan every share reads.
test_ci_workflow_scope_plans_the_shares() {
  local block
  block=$(cw_job_block scope)
  # shellcheck disable=SC2016 # workflow expressions, matched literally
  cw_has "$block" 'matrix_unix: ${{ steps.plan.outputs.matrix_unix }}' ||
    fail "scope must publish matrix_unix from its plan step"
  # shellcheck disable=SC2016
  cw_has "$block" 'matrix_windows: ${{ steps.plan.outputs.matrix_windows }}' ||
    fail "scope must publish matrix_windows from its plan step"
  # shellcheck disable=SC2016 # a workflow line, matched literally
  assert_contains "$block" '.github/scripts/ci-matrix.sh "$SUITE"' \
    "the plan step must ask ci-matrix.sh for the shares"
  assert_contains "$block" 'name: plan' "scope must upload the plan artifact"
}

# Each test job's matrix is scope's answer, with no key of its own beside it:
# a base key would make GitHub merge entries and run one share per platform.
test_ci_workflow_test_jobs_take_their_matrix_from_scope() {
  local block
  block=$(cw_job_block test)
  # shellcheck disable=SC2016
  cw_has "$block" 'matrix: ${{ fromJSON(needs.scope.outputs.matrix_unix) }}' ||
    fail "the test job's matrix must be scope's matrix_unix, whole"
  block=$(cw_job_block test-windows)
  # shellcheck disable=SC2016
  cw_has "$block" 'matrix: ${{ fromJSON(needs.scope.outputs.matrix_windows) }}' ||
    fail "the test-windows job's matrix must be scope's matrix_windows, whole"
}

# The share reaches the runner as scope named it, through the one script
# that reads the plan, and nothing else decides it.
test_ci_workflow_test_jobs_pass_their_share_and_plan_to_the_runner() {
  local job block
  for job in test test-windows; do
    block=$(cw_job_block "$job")
    # shellcheck disable=SC2016
    cw_has "$block" 'JIG_TEST_SHARD: ${{ matrix.shard }}' ||
      fail "$job must run its own share: JIG_TEST_SHARD: \${{ matrix.shard }}"
    assert_eq 1 "$(printf '%s\n' "$block" | grep -c 'JIG_TEST_SHARD:')" \
      "$job must set JIG_TEST_SHARD once, from the matrix"
    cw_has "$block" 'run: .github/scripts/ci-run-tests.sh' ||
      fail "$job must run the suite through .github/scripts/ci-run-tests.sh"
    assert_contains "$block" 'uses: actions/download-artifact@v8' \
      "$job must download the plan before it runs"
    # shellcheck disable=SC2016 # a workflow expression, matched literally
    assert_contains "$block" 'path: ${{ runner.temp }}/report/report.tsv' \
      "$job must keep its report: the nightly reports are the next plan's durations"
  done
}

# A hand-written denominator next to the share would be a second copy of the
# count that can disagree with the matrix.
test_ci_workflow_writes_no_share_count_by_hand() {
  local literal
  literal=$(grep -n 'matrix\.shard *}}/' "$(cw_file)" || true)
  assert_eq "" "$literal" "the share is <i>/<n> as scope wrote it; nothing appends a denominator"
}

# The suite a run tested is in each test job's name: ci-reuse.sh reads it to
# tell a run of the whole suite from a run of part of it.
test_ci_workflow_test_job_names_carry_the_suite() {
  # shellcheck disable=SC2016
  cw_has "$(cw_job_block test)" 'name: ${{ matrix.os }} ${{ matrix.shard }} (${{ needs.scope.outputs.suite }})' ||
    fail "the test job's name must end in (\${{ needs.scope.outputs.suite }})"
  # shellcheck disable=SC2016
  cw_has "$(cw_job_block test-windows)" 'name: windows-latest (Git Bash) ${{ matrix.shard }} (${{ needs.scope.outputs.suite }})' ||
    fail "the test-windows job's name must end in (\${{ needs.scope.outputs.suite }})"
}

# Only a run whose proof is the whole suite releases: scope's `whole`, which
# is true for a run of the whole suite, a reuse of a pull request's run of it
# and a narrow run on top of one. Not `suite`: a narrow run may test only the
# difference and still be whole.
test_ci_workflow_release_needs_the_whole_suite() {
  local block
  block=$(cw_job_block release)
  # shellcheck disable=SC2016
  assert_contains "$block" "needs.scope.outputs.whole == 'true'" \
    "release must tag only after a run whose proof is the whole suite"
  assert_not_contains "$block" "outputs.suite" \
    "release must read scope's whole, not its suite"
  # shellcheck disable=SC2016
  assert_contains "$(cw_job_block scope)" 'whole: ${{ steps.scope.outputs.whole }}' \
    "scope must publish whole"
}

# A pull request's run records the merge it tested, for the push that merges
# it (ci-reuse.sh reads the file back from the `plan` artifact).
test_ci_workflow_scope_records_the_tree_a_pull_request_tested() {
  local block
  block=$(cw_job_block scope)
  assert_contains "$block" "git rev-parse --verify --quiet 'HEAD^2'" "scope must read the head parent"
  assert_contains "$block" "git rev-parse --verify --quiet 'HEAD^{tree}'" "scope must read the tested tree"
  # shellcheck disable=SC2016
  assert_contains "$block" "'base=%s\\nhead=%s\\ntree=%s\\n' \"\$pr_base\" \"\$pr_head\" \"\$pr_tree\" > \"\$plan/tested\"" \
    "scope must write base, head and tree to the tested file of the plan"
  # Only a pull request writes it, and only when both parents resolved.
  printf '%s\n' "$block" | awk '
    /if \[ "\$EVENT" = pull_request \]; then/ { inpr = 1 }
    inpr && /plan\/tested/ { found = 1 }
    END { exit !found }
  ' || fail "the tested file must be written inside the pull_request branch"
  # shellcheck disable=SC2016
  assert_contains "$block" 'if [ -n "$pr_base" ] && [ -n "$pr_head" ] && [ -n "$pr_tree" ]; then' \
    "the tested file needs both parents and the tree"
}

# On `narrow <commit>` scope measures from that commit; what the outputs are
# is decided by .github/scripts/ci-outputs.sh (tests/ci-outputs.t.sh holds the
# rules), and written once, after the decisions, from its answer.
test_ci_workflow_scope_handles_a_narrow_answer() {
  local block
  block=$(cw_job_block scope)
  assert_contains "$block" 'narrow*)' "scope must handle the narrow answer of ci-reuse.sh"
  # shellcheck disable=SC2016
  assert_contains "$block" '.github/scripts/ci-scope.sh "$nbase"' "scope must measure a narrow push from its commit"
  # shellcheck disable=SC2016
  assert_contains "$block" '.github/scripts/ci-outputs.sh "$line" "$reuse" "$nline"' \
    "scope must decide its outputs in ci-outputs.sh"
  # shellcheck disable=SC2016
  assert_contains "$block" '>> "$GITHUB_OUTPUT"' "scope writes its outputs"
  # No output of the decision is written by the workflow itself.
  assert_not_contains "$block" 'echo "suite=' "the suite is ci-outputs.sh's to decide"
  assert_not_contains "$block" 'echo "whole=' "whole is ci-outputs.sh's to decide"
  # shellcheck disable=SC2016
  [ "$(printf '%s\n' "$block" | grep -c 'ci-outputs.sh "\$line"')" -eq 1 ] || fail "ci-outputs.sh must be asked once"
  # The outputs are written after the narrow measurement, and the shares are
  # planned from the final suite (step order: scope, then plan).
  printf '%s\n' "$block" | awk '
    /nbase=/ { n = NR }
    /ci-outputs.sh "\$line"/ { w = NR }
    END { exit !(n && w && n < w) }
  ' || fail "outputs must be decided after the narrow measurement"
}

# A push is measured from the base .github/scripts/ci-green-base.sh names, read
# from the unfiltered list of runs. The `status=success` list lagged behind a
# run that had just ended (run 44170402355), so the inline question is gone.
test_ci_workflow_scope_measures_a_push_with_ci_green_base() {
  local block
  block=$(cw_job_block scope)
  printf '%s\n' "$block" | grep -qF '.github/scripts/ci-green-base.sh' ||
    fail "the scope job must take a push's base from .github/scripts/ci-green-base.sh"
  # shellcheck disable=SC2016 # shell variables in a workflow, matched literally
  if printf '%s\n' "$block" | grep -qF -- '-f branch="$BRANCH" -f status=success'; then
    fail "the scope job must not ask for a branch's last successful run by status=success: that list lags behind a run that just ended"
  fi
}

# A pull request's run checks out the pull request merged into its base as the
# base is now. Measured from the event's base.sha — where the branch started —
# every commit that landed on the base since counts as the pull request's own:
# #394, two spec files, ran the full suite because main had changed
# scripts/lib/config.sh meanwhile. Both scope scripts take the merge commit's
# first parent instead, and nothing in the scope job reads base.sha.
test_ci_workflow_scope_measures_a_pull_request_from_its_merge_parent() {
  local block
  block=$(cw_job_block scope)
  printf '%s\n' "$block" | grep -qF "git rev-parse --verify --quiet 'HEAD^1'" ||
    fail "the scope job must take a pull request's base as the merge commit's first parent (HEAD^1)"
  # shellcheck disable=SC2016 # shell variables in a workflow, matched literally
  printf '%s\n' "$block" | grep -qF '.github/scripts/ci-scope.sh "$pr_base"' ||
    fail "the scope job must pass the merge parent to ci-scope.sh"
  if printf '%s\n' "$block" | grep -qF 'pull_request.base.sha'; then
    fail "the scope job must not read github.event.pull_request.base.sha: it is where the branch started, not what it merges into"
  fi
}

# An epic branch's first push has no successful run to measure from, and an
# empty base ran the whole suite on every platform for a branch that differed
# from main by spec files alone (nineteen jobs held the organisation's whole
# concurrent-job limit and the other runs queued behind them). ci-push-base.sh picks the base (its
# tests, tests/ci-push-base.t.sh, run it on real histories); what is left to
# guard here is that the scope job asks it and acts on each of its answers.
test_ci_workflow_push_scope_follows_ci_push_base() {
  local block
  block=$(cw_job_block scope)
  # shellcheck disable=SC2016 # shell variables in a workflow, matched literally
  printf '%s\n' "$block" | grep -qF '.github/scripts/ci-push-base.sh "$BRANCH" "$green"' ||
    fail "a push must ask ci-push-base.sh for its base"
  # shellcheck disable=SC2016
  printf '%s\n' "$block" | grep -qF '.github/scripts/ci-scope.sh "$push_base"' ||
    fail "a push must measure its scope from push_base"
  printf '%s\n' "$block" | grep -qF 'line="light (epic holds nothing beyond its base' ||
    fail "an epic holding nothing beyond its base must be light"
  if printf '%s\n' "$block" | grep -qF 'origin/main'; then
    fail "the base is ci-push-base.sh's to compute, not the workflow's"
  fi
}

# The Windows decision is ci-windows.sh's (tests/ci-windows.t.sh holds the
# rules): the scope job asks it with the event and the branch, and does not
# decide by event or by diff in the workflow.
test_ci_workflow_windows_is_decided_by_ci_windows_sh_from_the_event() {
  local block
  block=$(cw_job_block scope)
  # shellcheck disable=SC2016
  printf '%s\n' "$block" | grep -qF '.github/scripts/ci-windows.sh "$EVENT" "$BRANCH"' ||
    fail "the scope job must ask ci-windows.sh with the event and the branch"
  if printf '%s\n' "$block" | grep -qF 'ci-windows-scope'; then
    fail "ci-windows-scope.sh is gone: no pull request asks for Windows by its diff"
  fi
  if printf '%s\n' "$block" | grep -qF 'win="skip'; then
    fail "the skip decision lives in ci-windows.sh, not in the workflow"
  fi
}

# The plan step gives ci-matrix.sh the event: a pull request's whole suite is
# Linux only, and that rule is the script's.
test_ci_workflow_plan_passes_the_event_to_ci_matrix() {
  local block
  block=$(cw_job_block scope)
  # shellcheck disable=SC2016
  printf '%s\n' "$block" | grep -qF '.github/scripts/ci-matrix.sh "$SUITE" "$plan/filters" "$plan/durations" "$EVENT"' ||
    fail "the plan step must pass the event to ci-matrix.sh"
  # shellcheck disable=SC2016
  printf '%s\n' "$block" | grep -qF 'EVENT: ${{ github.event_name }}' ||
    fail "the plan step must read github.event_name"
}

# ci-ok needs the branch to hold Windows to every run but a pull request and an
# epic push (the only ones ci-windows.sh skips).
test_ci_workflow_ci_ok_is_told_the_ref() {
  # shellcheck disable=SC2016
  cw_has "$(cw_job_block ci-ok)" 'REF_NAME: ${{ github.ref_name }}' ||
    fail "ci-ok must pass github.ref_name to ci-ok.sh"
}

# Off main the matrices are held to a few shares at a time, so one run cannot
# take the organisation's whole concurrent-job limit; main (push and nightly) is not
# held back (adr-20261016-the-suite-runs-in-shares-on-every-platform).
test_ci_workflow_matrices_are_limited_off_main_and_free_on_main() {
  # shellcheck disable=SC2016
  cw_has "$(cw_job_block test)" "max-parallel: \${{ github.ref == 'refs/heads/main' && 20 || 6 }}" ||
    fail "test must run at most 6 shares at a time off main, and at least all of them on main"
  # shellcheck disable=SC2016
  cw_has "$(cw_job_block test-windows)" "max-parallel: \${{ github.ref == 'refs/heads/main' && 20 || 5 }}" ||
    fail "test-windows must run at most 5 shares at a time off main, and at least all of them on main"
  # The main limit must stay above every ceiling ci-matrix.sh has (4 and 10).
  # shellcheck disable=SC2016
  [ "$(grep -c "max-parallel: \${{ github.ref == 'refs/heads/main' && 20 ||" "$(cw_file)")" -eq 2 ] ||
    fail "both matrix jobs must carry the limit"
}

# A pull request into an untested base is light (ci-untested-base.sh): the
# base reaches the script through env, never interpolated into the script.
test_ci_workflow_scope_asks_ci_untested_base_with_the_base_ref_from_env() {
  local block run_part
  block=$(cw_job_block scope)
  # shellcheck disable=SC2016
  cw_has "$block" 'BASE_REF: ${{ github.base_ref }}' || fail "scope must pass github.base_ref through env"
  # shellcheck disable=SC2016
  assert_contains "$block" '.github/scripts/ci-untested-base.sh "$EVENT" "$BASE_REF"' \
    "scope must ask ci-untested-base.sh about the event and base"
  [ "$(printf '%s\n' "$block" | grep -c 'github\.base_ref')" -eq 1 ] ||
    fail "github.base_ref must appear once, in env, and not in the run script"
  # A skip answer is light and never reaches ci-scope.sh.
  # shellcheck disable=SC2016 # a workflow line, matched literally
  assert_contains "$block" 'skip*) line="light ${untested#skip }" ;;' "a skip answer must be a light scope"
  # shellcheck disable=SC2016 # an awk program, not a shell expansion
  run_part=$(printf '%s\n' "$block" | awk '/untested=\$\(/ { f = 1 } f && /ci-scope.sh/ { print NR ": " $0; exit }')
  # shellcheck disable=SC2016 # a workflow line, matched literally
  assert_contains "$run_part" 'ci-scope.sh "$pr_base"' "ci-scope.sh stays the answer for any other base"
}

# A manual dispatch has a concurrency group of its own, so a push to the same
# branch cannot cancel it; every other event keeps ci-<ref>.
test_ci_workflow_a_dispatch_run_has_its_own_concurrency_group() {
  local group
  group=$(awk '/^concurrency:/ { f = 1; next } f && /^  group:/ { print; exit }' "$(cw_file)")
  assert_contains "$group" "github.event_name == 'workflow_dispatch'" "the group must tell a dispatch apart"
  assert_contains "$group" "format('ci-dispatch-{0}', github.run_id)" "a dispatch must be grouped by its run"
  assert_contains "$group" "format('ci-{0}', github.ref)" "every other event must keep ci-<ref>"
}

# The jobs that run the next/ts and next/go tests pin Node and Go, so a red
# run means code and not the runner image: next-ts fails without Node at its
# engines floor and next-go skips without go. The Node pin is read from
# next/ts/package.json, so it cannot drift from the floor engines promises.
test_ci_workflow_test_jobs_pin_node_and_go_for_the_next_stacks() {
  local floor job block
  floor=$(sed -n 's/.*"node"[[:space:]]*:[[:space:]]*">=\([0-9][0-9.]*\)".*/\1/p' "$JIG_HOME/next/ts/package.json" | head -n 1)
  [ -n "$floor" ] || fail "next/ts/package.json must declare engines.node as \">=X.Y\""
  for job in test test-windows; do
    block=$(cw_job_block "$job")
    assert_contains "$block" 'uses: actions/setup-node@v7' "$job must set up Node"
    assert_contains "$block" 'uses: actions/setup-go@v7' "$job must set up Go"
    cw_has "$block" "node-version: '$floor'" ||
      fail "$job must pin Node to the engines floor of next/ts ($floor)"
    cw_has "$block" 'go-version-file: next/go/go.mod' ||
      fail "$job must read the Go version from next/go/go.mod"
  done
}

# A manual dispatch's `tests` input: empty by default (the branch's default: an epic's own suites,
# else everything), `all` the whole suite, anything else the filters. It reaches the scope script
# through env, never interpolated into it, and the filters go to the plan.
test_ci_workflow_a_dispatch_input_selects_tests() {
  local block
  awk '/^  workflow_dispatch:/ { f = 1; next } f && /^  [a-z_]+:/ { exit } f { print }' "$(cw_file)" \
    > "$JIG_TEST_TMP/dispatch"
  cw_has "$(cat "$JIG_TEST_TMP/dispatch")" "default: ''" || fail "the tests input must default to empty"
  block=$(cw_job_block scope)
  # shellcheck disable=SC2016 # workflow lines, matched literally
  cw_has "$block" 'DISPATCH_TESTS: ${{ inputs.tests }}' || fail "scope must read the input through env"
  [ "$(printf '%s\n' "$block" | grep -c 'inputs\.tests')" -eq 1 ] ||
    fail "inputs.tests must appear once, in env, and not in the run script"
  # shellcheck disable=SC2016
  assert_contains "$block" 'all) line="full ($EVENT runs everything)" ;;' "all must stay the whole suite"
  # shellcheck disable=SC2016
  assert_contains "$block" 'for f in $tests; do printf' "the tests' words must become the filters"
}

# A push to an epic, and a dispatch on one with an empty input, ask ci-epic-tests.sh for the epic's
# own suites; main is never asked (its scope is ci-scope.sh's and ci-reuse.sh's, unchanged).
test_ci_workflow_an_epic_runs_its_own_suites() {
  local block
  block=$(cw_job_block scope)
  # shellcheck disable=SC2016
  assert_contains "$block" '.github/scripts/ci-epic-tests.sh "$BRANCH"' "scope must ask ci-epic-tests.sh"
  # shellcheck disable=SC2016
  assert_contains "$block" 'push:*:full* | push:*:selected* | workflow_dispatch::*)' \
    "only a tested push and a dispatch without tests ask for the epic's suites"
}

# Both test jobs warm the Go module cache before the tests: next-go and parity-ports expect the
# warm cache of a developer's machine, and a cold one prints `go: downloading` into their answers.
test_ci_workflow_test_jobs_download_the_go_modules() {
  local job block
  for job in test test-windows; do
    block=$(cw_job_block "$job")
    cw_has "$block" 'run: go mod download' || fail "$job must download the Go modules"
    cw_has "$block" 'working-directory: next/go' || fail "$job must download them in next/go"
  done
}
