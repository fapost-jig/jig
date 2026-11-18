# Tests for `.github/scripts/ci-nightly-tested.sh` (task ci-tests-run-once).
# shellcheck shell=bash
#
# No network: `gh` is a stub on PATH. A call that asks for `event=schedule`
# is answered from $PWD/nightly.txt (`<id> <head sha> <url>`, what the script's
# --jq filter prints), any other call from $PWD/runs.txt (`<id> <event>
# <status> <conclusion> <url>`, newest first); a missing file makes the call
# fail. Every call is logged to $PWD/gh.log. Fixture histories live under the
# test's tmp dir; the script runs there with HEAD at the tip of main. Helpers
# are prefixed nt_.

# nt_history <dir> — main with two commits: `old` (the tree a nightly run
# tested) and HEAD. Tag `same` is a commit with HEAD's own tree on another
# parent, `other` has a different tree.
nt_history() {
  mkdir -p "$1"
  (
    cd "$1" || exit 1
    fixture_repo
    printf 'one\n' > one.txt
    git add one.txt
    git commit -q -m one
    git tag other
    printf 'two\n' > two.txt
    git add two.txt
    git commit -q -m two
    git tag head
    git checkout -q -b twin other
    printf 'two\n' > two.txt
    git add two.txt
    git commit -q -m "the same tree, another way"
    git tag same
    git checkout -q main
  )
}

nt_sha() {
  git -C "$1" rev-parse "$2"
}

# nt_runs <line>... — the runs of ci on main, newest first.
nt_runs() {
  printf '%s\n' "$@" > "$PWD/runs.txt"
}

# nt_nightly <line> — the newest successful nightly run.
nt_nightly() {
  printf '%s\n' "$1" > "$PWD/nightly.txt"
}

nt_gh() {
  mkdir -p "$PWD/stub-bin"
  cat > "$PWD/stub-bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$PWD/gh.log"
case "\$*" in
  *event=schedule*)
    [ -f "$PWD/nightly.txt" ] || exit 1
    cat "$PWD/nightly.txt"
    ;;
  *)
    [ -f "$PWD/runs.txt" ] || exit 1
    cat "$PWD/runs.txt"
    ;;
esac
STUB
  chmod +x "$PWD/stub-bin/gh"
}

nt_check() {
  local stub="$PWD/stub-bin"
  (cd "$1" && PATH="$stub:$PATH" GITHUB_REPOSITORY=example/jig \
    "$JIG_HOME/.github/scripts/ci-nightly-tested.sh")
}

nt_url() { printf 'https://github.com/example/jig/actions/runs/%s' "$1"; }

# --- tested ------------------------------------------------------------------

# Main is green and the last nightly run tested the very tree: the commit is
# another one, the tree is the same (a revert, a squash).
test_ci_nightly_tested_same_tree_and_green_main_is_tested() {
  local repo="$PWD/repo"
  nt_history "$repo"
  nt_gh
  nt_runs "30 push completed success $(nt_url 30)" "20 schedule completed success $(nt_url 20)"
  nt_nightly "20 $(nt_sha "$repo" same) $(nt_url 20)"

  run nt_check "$repo"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "tested ($(nt_url 20) tested tree"
  assert_contains "$OUT" "$(nt_url 30)"
  assert_file_contains "$PWD/gh.log" "repos/example/jig/actions/workflows/ci.yml/runs"
  assert_file_contains "$PWD/gh.log" "branch=main"
  assert_file_contains "$PWD/gh.log" "event=schedule"
  assert_file_contains "$PWD/gh.log" "status=success"
}

# A cancelled run, a manual dispatch and one still running say nothing about
# whether main is green: the newest finished run of main's own is the one.
test_ci_nightly_tested_looks_past_runs_that_say_nothing() {
  local repo="$PWD/repo"
  nt_history "$repo"
  nt_gh
  nt_runs "34 push in_progress none $(nt_url 34)" "33 push completed cancelled $(nt_url 33)" \
    "32 workflow_dispatch completed failure $(nt_url 32)" "31 push completed success $(nt_url 31)"
  nt_nightly "20 $(nt_sha "$repo" head) $(nt_url 20)"

  run nt_check "$repo"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "tested ("
  assert_contains "$OUT" "$(nt_url 31)"
}

# --- test everything ---------------------------------------------------------

test_ci_nightly_tested_red_main_tests_everything() {
  local repo="$PWD/repo"
  nt_history "$repo"
  nt_gh
  nt_runs "30 push completed failure $(nt_url 30)" "20 schedule completed success $(nt_url 20)"
  nt_nightly "20 $(nt_sha "$repo" head) $(nt_url 20)"

  run nt_check "$repo"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (the newest finished run on main ended as 'failure'"
}

test_ci_nightly_tested_a_moved_tree_tests_everything() {
  local repo="$PWD/repo"
  nt_history "$repo"
  nt_gh
  nt_runs "30 push completed success $(nt_url 30)"
  nt_nightly "20 $(nt_sha "$repo" other) $(nt_url 20)"

  run nt_check "$repo"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (the last successful nightly run tested tree"
}

test_ci_nightly_tested_no_nightly_run_tests_everything() {
  local repo="$PWD/repo"
  nt_history "$repo"
  nt_gh
  nt_runs "30 push completed success $(nt_url 30)"
  : > "$PWD/nightly.txt"

  run nt_check "$repo"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (no successful nightly run yet)"
}

test_ci_nightly_tested_no_finished_run_tests_everything() {
  local repo="$PWD/repo"
  nt_history "$repo"
  nt_gh
  nt_runs "30 push in_progress none $(nt_url 30)"
  nt_nightly "20 $(nt_sha "$repo" head) $(nt_url 20)"

  run nt_check "$repo"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (no finished run of ci on main to say it is green)"
}

# --- unmeasurable tests everything -------------------------------------------

test_ci_nightly_tested_runs_unreadable_tests_everything() {
  local repo="$PWD/repo"
  nt_history "$repo"
  nt_gh

  run nt_check "$repo"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (cannot read the runs of ci on main)"
}

test_ci_nightly_tested_nightly_unreadable_tests_everything() {
  local repo="$PWD/repo"
  nt_history "$repo"
  nt_gh
  nt_runs "30 push completed success $(nt_url 30)"

  run nt_check "$repo"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (cannot read the nightly runs of ci)"
}

# A head commit that is neither local nor fetchable cannot vouch for a tree.
test_ci_nightly_tested_unreadable_commit_tests_everything() {
  local repo="$PWD/repo"
  nt_history "$repo"
  nt_gh
  nt_runs "30 push completed success $(nt_url 30)"
  nt_nightly "20 ffffffffffffffffffffffffffffffffffffffff $(nt_url 20)"

  run nt_check "$repo"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (the commit ffffffffffffffffffffffffffffffffffffffff of the last nightly run cannot be read"
}

test_ci_nightly_tested_without_repository_slug_tests_everything() {
  local repo="$PWD/repo" stub="$PWD/stub-bin"
  nt_history "$repo"
  nt_gh

  run env -u GITHUB_REPOSITORY sh -c "cd '$repo' && PATH='$stub:$PATH' '$JIG_HOME/.github/scripts/ci-nightly-tested.sh'"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (GITHUB_REPOSITORY is not set"
  assert_no_file "$PWD/gh.log" "GitHub must not be asked without a repository"
}

# --- the workflow --------------------------------------------------------------

# Only the nightly run on main asks, and a `tested` answer makes it light.
test_ci_nightly_tested_workflow_asks_on_the_nightly_run_only() {
  local file="$JIG_HOME/.github/workflows/ci.yml"
  # shellcheck disable=SC2016 # workflow expressions, matched literally
  {
    grep -qF 'if [ "$EVENT:$BRANCH" = schedule:main ]; then' "$file" || fail "the nightly question is not limited to schedule on main"
    grep -qF '.github/scripts/ci-nightly-tested.sh' "$file" || fail "scope does not run ci-nightly-tested.sh"
    grep -qF 'tested*) line="light (nightly: ${nightly#tested })" ;;' "$file" || fail "a tested tree does not make the nightly light"
  }
}

# The plan takes durations from a nightly run that has reports: a light one is
# green and has none.
test_ci_nightly_tested_plan_looks_past_nightlies_without_reports() {
  local file="$JIG_HOME/.github/workflows/ci.yml"
  grep -qF 'per_page=10' "$file" || fail "the plan step reads one nightly run only"
  grep -qF "gh run download \"\$id\" -R \"\$REPO\" -p 'report-*'" "$file" || fail "the plan step does not try each nightly run for reports"
}
