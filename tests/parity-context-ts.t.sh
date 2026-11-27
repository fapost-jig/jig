# Tests that the TypeScript port of `jig context` (next/ts, task pilot-context-ts) gives the same
# answer as the bash jig for every recorded `jig context` call, by the parity check
# (tests/lib/parity.sh, conventions/parity.md). The port's own in-process tests are next/ts/test/,
# run by tests/next-ts.t.sh (`npm run check`).
#
# Every test records for itself, because tests run in parallel subshells: it runs one share of the
# bash tests that call `jig context` under `JIG_RECORD` (a nested tests/run.sh of this release copy,
# one job), then replays the recorded `context` calls on the port. The bash tests are split into
# shares so the jobs of a run carry them side by side: a replay costs a few seconds per call, and
# one test holding all of them would take a quarter of an hour on its own. A share is every fifth
# test of tests/context.t.sh, by its place in the file, so a test added there lands in a share
# without this file changing; the tests of other files that call `jig context` are a share of their
# own, listed below. The same shares as tests/parity-context-go.t.sh, so the two ports are judged
# alike.
#
# The port runs from the checkout's sources (`$ROOT/scripts/jig-next-ts`), not from the world's
# release copy: the copy is built from the files git lists, which leave out next/ts/node_modules,
# and the port needs its dependencies. The sources are this working tree's, as the copy's are, and
# nothing `jig context` prints names the framework's directory.
#
# Intended differences are in tests/parity/intended.tsv (port `ts`, or `*` for both ports), each
# with its reason. Node 22.18 or later is needed, as for tests/next-ts.t.sh: without it these fail.
# shellcheck shell=bash

# shellcheck source=lib/next-ts.sh
. "$JIG_HOME/tests/lib/next-ts.sh"

# The tests outside tests/context.t.sh that call `jig context`.
_PCT_OTHERS="checkout::test_checkout_taken_record_is_written_by_a_command_that_works_the_task
knowledge::test_new_adr_proposed_is_listed_checked_and_promoted_to_accepted
knowledge::test_new_feature_proposed_not_resolved_by_context_until_accepted
knowledge::test_rejected_document_does_not_resolve_via_context
knowledge::test_check_fails_when_two_stubs_link_the_same_source
knowledge::test_new_copy_passes_knowledge_check_with_domains
knowledge::test_new_copy_not_resolved_by_context_until_accepted
queue::test_queue_next_sees_a_new_taken_record_as_a_new_revision
spec::test_spec_is_not_knowledge
status::test_status_omits_review_stale_when_the_receipt_is_current
status::test_status_queue_without_a_queue_shows_no_place
task::test_task_pause_if_requested_shows_why_the_cancel_was_refused
task::test_task_actions_of_an_invalid_git_level_agree_with_their_commands
task::test_parked_tasks_start_no_process_per_ready_task"

# The tests whose calls the check cannot replay, so that the bash jig differs from its own recording
# (the self-check, `--port '<JIG_HOME>/scripts/jig'`): they prove nothing about a port either.
#   test_context_resolve_lists_a_linked_specs_documents — the linked repository is beside the test's
#     directory, outside the recorded trees;
#   test_context_resolve_prints_the_context_when_the_pause_is_refused — the test makes runtime/
#     unwritable, and the trees keep no directory modes;
#   task::test_context_starts_no_process_* (not listed above) — the replayed tree.before differs.
_PCT_UNREPLAYABLE="test_context_resolve_lists_a_linked_specs_documents
test_context_resolve_prints_the_context_when_the_pause_is_refused"

# The number of shares tests/context.t.sh is split into.
_PCT_SHARES=5

# _pct_share <k> — the tests of share <k> (0-based) of tests/context.t.sh, one `context::<test>`
# per line: every test whose place in the file, counted from 0, leaves <k> divided by the shares.
_pct_share() {
  _pct_context_tests | awk -v k="$1" -v n="$_PCT_SHARES" '(NR - 1) % n == k { print "context::" $0 }'
}

# _pct_context_tests — the tests of tests/context.t.sh in file order, without the unreplayable ones.
_pct_context_tests() {
  U="$_PCT_UNREPLAYABLE" awk '
    BEGIN { n = split(ENVIRON["U"], u, "\n"); for (i = 1; i <= n; i++) skip[u[i]] = 1 }
    /^test_[A-Za-z0-9_]*\(\)/ { name = $1; sub(/\(\).*/, "", name); if (!(name in skip)) print name }
  ' "$JIG_HOME/tests/context.t.sh"
}

# _pct_check <tests, one per line> — record those tests, replay their `jig context` calls on the
# TypeScript port; every compared call must be equal or intended, with at least one compared.
_pct_check() {
  local list="$1" rec="$JIG_TEST_TMP/rec" root t args=()
  [ -n "$list" ] || fail "no test selected"
  while IFS= read -r t; do
    if [ -n "$t" ]; then args+=("$t"); fi
  done <<EOF
$list
EOF
  _nts_need_node
  root=$(_nts_root)
  assert_file "$root/scripts/jig-next-ts"
  # Before any replay (conventions/parity.md): the replay's HOME is the recorded test's directory.
  _nts_deps "$root/next/ts"
  mkdir -p "$rec"
  (
    unset JIG_RECORD JIG_RECORD_DIR JIG_RECORD_TEST JIG_RECORD_ROOT JIG_RECORD_BASE_ENV \
      JIG_RECORDING JIG_RECORDER
    cd "$JIG_HOME" || exit 1
    JIG_TEST_JOBS=1 JIG_RECORD="$rec" "$JIG_HOME/tests/run.sh" "${args[@]}"
  ) > "$JIG_TEST_TMP/record.log" 2>&1 || true
  # A recorded test that fails is the bash suite's own business, not the port's: its calls up to
  # the failure are recorded all the same. A recording that did not happen is a failure.
  assert_file "$rec/FORMAT"
  run bash "$JIG_HOME/tests/lib/parity.sh" check --recordings "$rec" --command context \
    --port "$root/scripts/jig-next-ts" --name ts
  assert_eq 0 "$RC" "the parity check failed: $(printf '%s\n' "$OUT" | grep -v '^ok' | tail -40)"
  assert_contains "$OUT" " 0 differ, "
  assert_contains "$OUT" " 0 errors; 0 stale entries"
}

test_ts_context_matches_the_recordings_of_context_share_1() {
  _pct_check "$(_pct_share 0)"
}

test_ts_context_matches_the_recordings_of_context_share_2() {
  _pct_check "$(_pct_share 1)"
}

test_ts_context_matches_the_recordings_of_context_share_3() {
  _pct_check "$(_pct_share 2)"
}

test_ts_context_matches_the_recordings_of_context_share_4() {
  _pct_check "$(_pct_share 3)"
}

test_ts_context_matches_the_recordings_of_context_share_5() {
  _pct_check "$(_pct_share 4)"
}

test_ts_context_matches_the_recordings_of_other_files_that_call_it() {
  _pct_check "$_PCT_OTHERS"
}

# The shares cover every test of tests/context.t.sh but the unreplayable ones, each exactly once.
test_ts_context_shares_cover_every_context_test_once() {
  local all shares k
  all=$(grep -c '^test_[A-Za-z0-9_]*()' "$JIG_HOME/tests/context.t.sh")
  all=$((all - $(printf '%s\n' "$_PCT_UNREPLAYABLE" | grep -c .)))
  shares=""
  k=0
  while [ "$k" -lt "$_PCT_SHARES" ]; do
    shares="$shares$(_pct_share "$k")
"
    k=$((k + 1))
  done
  assert_eq "$all" "$(printf '%s' "$shares" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
  assert_eq "$all" "$(printf '%s' "$shares" | sed '/^$/d' | wc -l | tr -d ' ')"
}
