# Tests for `.github/scripts/ci-reuse.sh` (task reuse-green-tree-on-main).
# shellcheck shell=bash
#
# No network: `gh` is a stub on PATH. It answers the pull request that made a
# commit from $PWD/pulls.txt (the head commits the script's filter would
# keep), the pull-request runs from $PWD/runs.txt and a run's jobs from
# $PWD/jobs-<id>.txt, a run's `plan` artifact download from $PWD/plan-<id>/
# (copied into the -D directory), fails a call whose file is missing, and logs
# every call to $PWD/gh.log. Every test builds
# a fixture history under its own tmp dir — main, a pull request's branch and
# its merge — and runs the script there with HEAD at the merge (cr_check),
# the way the `scope` job does on a push to main. Helpers are prefixed cr_.

# --- fixture builders --------------------------------------------------------

# cr_commit <dir> <file> <content> <message> — write and commit one file.
cr_commit() {
  (
    cd "$1" || exit 1
    printf '%s\n' "$3" > "$2"
    git add "$2"
    git commit -q -m "$4"
  )
}

# cr_history <dir> <up-to-date> — main with one commit, a branch `pr` with a
# change, and HEAD on main at the merge of `pr`. When <up-to-date> is `yes`,
# `pr` contains main's tip (the branch merged main back in); with `no`, the
# branch never did, but made main's change itself, so the merge has the
# branch's own tree while main's tip is not in its history — the case only
# the ancestry test can tell. Prints nothing; read the commits with cr_sha.
cr_history() {
  local dir="$1"
  mkdir -p "$dir"
  (
    cd "$dir" || exit 1
    fixture_repo
    git checkout -q -b pr
    printf 'feature\n' > feature.txt
    git add feature.txt
    git commit -q -m feature
    git checkout -q main
    printf 'other\n' > other.txt
    git add other.txt
    git commit -q -m "other change on main"
    git tag before
    git checkout -q pr
    if [ "$2" = yes ]; then
      git merge -q --no-edit main
    else
      printf 'other\n' > other.txt
      git add other.txt
      git commit -q -m "the same change, made on the branch"
    fi
    git checkout -q main
    git merge -q --no-ff --no-edit pr
  )
}

# cr_sha <dir> <rev> — the commit <rev> names in <dir>.
cr_sha() {
  git -C "$1" rev-parse "$2"
}

# cr_pulls <sha>... — the head commits of the pull requests into main merged
# as HEAD (what the script's --jq filter keeps).
cr_pulls() {
  printf '%s\n' "$@" > "$PWD/pulls.txt"
}

# cr_runs <line>... — the successful pull-request runs GitHub lists, newest
# first, each `<id> <head_sha> <url>`.
cr_runs() {
  printf '%s\n' "$@" > "$PWD/runs.txt"
}

# cr_jobs <id> <conclusion name>... — the jobs of run <id>.
cr_jobs() {
  local id="$1"
  shift
  printf '%s\n' "$@" > "$PWD/jobs-$id.txt"
}

# cr_full_jobs <id> — the jobs of a full pull-request run, Windows included,
# as the jobs API listed them for run 40490575838 (#323) under this ci.yml:
# every share by name, and the main-only jobs skipped.
cr_full_jobs() {
  cr_jobs "$1" "success changelog" "success scope" "success windows-latest smoke (install.ps1)" \
    "success ubuntu-latest 1/2 (all)" "success ubuntu-latest 2/2 (all)" \
    "success macos-latest 1/3 (all)" "success macos-latest 2/3 (all)" "success macos-latest 3/3 (all)" \
    "success windows-latest (Git Bash) 1/10 (all)" "success windows-latest (Git Bash) 2/10 (all)" \
    "success windows-latest (Git Bash) 3/10 (all)" "success windows-latest (Git Bash) 4/10 (all)" \
    "success windows-latest (Git Bash) 5/10 (all)" "success windows-latest (Git Bash) 6/10 (all)" \
    "success windows-latest (Git Bash) 7/10 (all)" "success windows-latest (Git Bash) 8/10 (all)" \
    "success windows-latest (Git Bash) 9/10 (all)" "success windows-latest (Git Bash) 10/10 (all)" \
    "skipped knowledge" "skipped epic-pr" "success ci-ok" "skipped release" "skipped red-main"
}

# cr_gh — install the stub `gh`.
cr_gh() {
  mkdir -p "$PWD/stub-bin"
  cat > "$PWD/stub-bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$PWD/gh.log"
case "\$*" in
  "run download "*)
    id="\$3"
    dir=""
    while [ \$# -gt 0 ]; do
      [ "\$1" != -D ] || dir="\$2"
      shift
    done
    [ -d "$PWD/plan-\$id" ] && [ -n "\$dir" ] || exit 1
    cp "$PWD/plan-\$id/"* "\$dir/"
    ;;
  "issue list "*)
    [ ! -f "$PWD/issue-fails" ] || exit 1
    [ ! -f "$PWD/issue.txt" ] || cat "$PWD/issue.txt"
    ;;
  */pulls*)
    [ -f "$PWD/pulls.txt" ] || exit 1
    cat "$PWD/pulls.txt"
    ;;
  */jobs*)
    id="\$*"
    id=\${id#*actions/runs/}
    id=\${id%%/jobs*}
    [ -f "$PWD/jobs-\$id.txt" ] || exit 1
    cat "$PWD/jobs-\$id.txt"
    ;;
  *)
    [ -f "$PWD/runs.txt" ] || exit 1
    cat "$PWD/runs.txt"
    ;;
esac
STUB
  chmod +x "$PWD/stub-bin/gh"
}

# cr_check <dir> <before> [<suite> <filters-file>] — run the script under test
# in <dir>.
cr_check() {
  local stub="$PWD/stub-bin" dir="$1"
  shift
  (cd "$dir" && PATH="$stub:$PATH" GITHUB_REPOSITORY=example/jig \
    "$JIG_HOME/.github/scripts/ci-reuse.sh" "$@")
}

# cr_filters <file> <filter>... — the filters of the push, one per line.
cr_filters() {
  local file="$1"
  shift
  printf '%s\n' "$@" > "$file"
}

# cr_plan <id> <filter>... — the `plan` artifact of run <id>, with its filters.
cr_plan() {
  local id="$1"
  shift
  mkdir -p "$PWD/plan-$id"
  printf '%s\n' "$@" > "$PWD/plan-$id/filters"
}

# cr_selected_jobs <id> — the jobs of a pull-request run of selected tests.
cr_selected_jobs() {
  cr_jobs "$1" "success scope" "skipped knowledge" "success ubuntu-latest 1/1 (selected)" \
    "success macos-latest 1/1 (selected)" "success windows-latest (Git Bash) 1/2 (selected)" \
    "success windows-latest (Git Bash) 2/2 (selected)" \
    "success windows-latest smoke (install.ps1)" \
    "success changelog" "skipped epic-pr" "skipped release" "success ci-ok"
}

# cr_selected_setup <dir> — a history, a stub and a selected run 7 of it;
# sets CR_PR and CR_BEFORE.
cr_selected_setup() {
  cr_history "$1" yes
  CR_PR=$(cr_sha "$1" pr)
  CR_BEFORE=$(cr_sha "$1" before)
  cr_gh
  cr_pulls "$CR_PR"
  cr_runs "7 $CR_PR https://github.com/example/jig/actions/runs/7"
}

# --- reuse -------------------------------------------------------------------

test_ci_reuse_full_run_of_an_up_to_date_branch_is_reused() {
  local repo="$PWD/repo" pr before
  cr_history "$repo" yes
  pr=$(cr_sha "$repo" pr)
  before=$(cr_sha "$repo" before)
  cr_gh
  cr_pulls "$pr"
  cr_runs "7 $pr https://github.com/example/jig/actions/runs/7"
  cr_full_jobs 7

  run cr_check "$repo" "$before"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "reuse (https://github.com/example/jig/actions/runs/7 tested tree"
  assert_contains "$OUT" "; suite: all)"
  # The question asked is the successful pull-request runs of ci.
  # The pull request is the one into main merged as HEAD, and its runs are
  # asked for by its head commit.
  assert_file_contains "$PWD/gh.log" "repos/example/jig/commits/$(cr_sha "$repo" HEAD)/pulls"
  assert_file_contains "$PWD/gh.log" 'select(.base.ref == "main" and .merge_commit_sha =='
  assert_file_contains "$PWD/gh.log" "repos/example/jig/actions/workflows/ci.yml/runs"
  assert_file_contains "$PWD/gh.log" "event=pull_request"
  assert_file_contains "$PWD/gh.log" "status=success"
  assert_file_contains "$PWD/gh.log" "head_sha=$pr"
  assert_file_contains "$PWD/gh.log" "repos/example/jig/actions/runs/7/jobs"
}

# A run that does not qualify is passed over for an older one that does: a
# re-run of the same head, say, after the first attempt skipped Windows.
test_ci_reuse_looks_past_a_run_that_was_not_full() {
  local repo="$PWD/repo" pr before
  cr_history "$repo" yes
  pr=$(cr_sha "$repo" pr)
  before=$(cr_sha "$repo" before)
  cr_gh
  cr_pulls "$pr"
  cr_runs "9 $pr https://github.com/example/jig/actions/runs/9" \
    "8 $pr https://github.com/example/jig/actions/runs/8"
  cr_jobs 9 "success scope" "skipped knowledge" "success ubuntu-latest 1/2 (all)" \
    "skipped windows-latest (Git Bash) \${{ matrix.shard }}/\${{ strategy.job-total }}" \
    "success ci-ok"
  cr_full_jobs 8

  run cr_check "$repo" "$before"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "reuse (https://github.com/example/jig/actions/runs/8 tested"
}

# --- test everything ------------------------------------------------------------

# The merge has the branch's tree, but main's tip is not in the branch: the
# pull request's run may have tested a merge onto an older main, so nothing
# says this tree was tested.
test_ci_reuse_branch_behind_main_tests_everything() {
  local repo="$PWD/repo" pr before
  cr_history "$repo" no
  pr=$(cr_sha "$repo" pr)
  before=$(cr_sha "$repo" before)
  cr_gh
  cr_pulls "$pr"
  cr_runs "7 $pr https://github.com/example/jig/actions/runs/7"
  cr_full_jobs 7

  [ "$(cr_sha "$repo" 'pr^{tree}')" = "$(cr_sha "$repo" 'HEAD^{tree}')" ] \
    || fail "the fixture must give the merge the branch's own tree"

  run cr_check "$repo" "$before"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "did not contain main's tip $before"
  assert_contains "$OUT" "test (no green pull-request run tested what this push needs of tree"
}

# The branch is up to date, but a later commit on main has a tree no pull
# request tested.
test_ci_reuse_a_different_tree_tests_everything() {
  local repo="$PWD/repo" pr before
  cr_history "$repo" yes
  cr_commit "$repo" direct.txt direct "a commit after the merge"
  pr=$(cr_sha "$repo" pr)
  before=$(cr_sha "$repo" before)
  cr_gh
  cr_pulls "$pr"
  cr_runs "7 $pr https://github.com/example/jig/actions/runs/7"
  cr_full_jobs 7

  run cr_check "$repo" "$before"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (no green run of the pull request has tree"
}

test_ci_reuse_a_light_run_tests_everything() {
  local repo="$PWD/repo" pr before
  cr_history "$repo" yes
  pr=$(cr_sha "$repo" pr)
  before=$(cr_sha "$repo" before)
  cr_gh
  cr_pulls "$pr"
  cr_runs "7 $pr https://github.com/example/jig/actions/runs/7"
  cr_jobs 7 "success scope" "success knowledge" "skipped \${{ matrix.os }} \${{ matrix.shard }}" \
    "success changelog" "success ci-ok"

  run cr_check "$repo" "$before"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (no green pull-request run tested what this push needs of tree"
}

# Windows skipped: Linux and macOS ran, the Git Bash shares did not.
test_ci_reuse_a_run_without_windows_tests_everything() {
  local repo="$PWD/repo" pr before
  cr_history "$repo" yes
  pr=$(cr_sha "$repo" pr)
  before=$(cr_sha "$repo" before)
  cr_gh
  cr_pulls "$pr"
  cr_runs "7 $pr https://github.com/example/jig/actions/runs/7"
  cr_jobs 7 "success scope" "skipped knowledge" "success ubuntu-latest 1/2 (all)" \
    "success macos-latest 1/3 (all)" "success windows-latest smoke (install.ps1)" \
    "success changelog" "skipped epic-pr" "skipped release" "success ci-ok"

  run cr_check "$repo" "$before"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test ("
  assert_contains "$OUT" "it skipped the Windows Git Bash shares"
}

# A pull request's run of the whole suite on Linux alone (the 2026-11-25
# amendment of adr-20261110): no macOS and no Windows share, so no run of
# every platform; a macOS share missing from a run that has the others counts
# the same.
test_ci_reuse_a_linux_only_run_tests_everything() {
  local repo="$PWD/repo" pr before
  cr_history "$repo" yes
  pr=$(cr_sha "$repo" pr)
  before=$(cr_sha "$repo" before)
  cr_gh
  cr_pulls "$pr"
  cr_runs "7 $pr https://github.com/example/jig/actions/runs/7"
  cr_jobs 7 "success scope" "skipped knowledge" "success ubuntu-latest 1/4 (all)" \
    "success ubuntu-latest 2/4 (all)" "success windows-latest smoke (install.ps1)" \
    "success changelog" "skipped epic-pr" "skipped release" "success ci-ok"
  run cr_check "$repo" "$before"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test ("
  assert_contains "$OUT" "it ran no macOS share of the suite"

  cr_jobs 7 "success scope" "skipped knowledge" "success ubuntu-latest 1/1 (all)" \
    "success windows-latest (Git Bash) 1/1 (all)" "success windows-latest smoke (install.ps1)" \
    "success changelog" "skipped epic-pr" "skipped release" "success ci-ok"
  run cr_check "$repo" "$before"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "it ran no macOS share of the suite"
}

test_ci_reuse_no_pull_request_runs_tests_everything() {
  local repo="$PWD/repo" pr before
  cr_history "$repo" yes
  pr=$(cr_sha "$repo" pr)
  before=$(cr_sha "$repo" before)
  cr_gh
  cr_pulls "$pr"
  cr_runs ""

  run cr_check "$repo" "$before"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (no green run of the pull request has tree"
}

# --- unmeasurable tests everything ------------------------------------------------

# A push no pull request made — or one GitHub has not linked yet — has no
# run to lean on.
test_ci_reuse_without_a_merged_pull_request_tests_everything() {
  local repo="$PWD/repo" before
  cr_history "$repo" yes
  before=$(cr_sha "$repo" before)
  cr_gh
  cr_pulls ""

  run cr_check "$repo" "$before"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (no pull request into main was merged as $(cr_sha "$repo" HEAD))"
}

test_ci_reuse_pull_request_unreadable_tests_everything() {
  local repo="$PWD/repo" before
  cr_history "$repo" yes
  before=$(cr_sha "$repo" before)
  cr_gh

  run cr_check "$repo" "$before"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (cannot read the pull request that made"
}

test_ci_reuse_runs_unreadable_tests_everything() {
  local repo="$PWD/repo" pr before
  cr_history "$repo" yes
  pr=$(cr_sha "$repo" pr)
  before=$(cr_sha "$repo" before)
  cr_gh
  cr_pulls "$pr"

  run cr_check "$repo" "$before"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (cannot read the pull-request runs of ci)"
}

test_ci_reuse_jobs_unreadable_tests_everything() {
  local repo="$PWD/repo" pr before
  cr_history "$repo" yes
  pr=$(cr_sha "$repo" pr)
  before=$(cr_sha "$repo" before)
  cr_gh
  cr_pulls "$pr"
  cr_runs "7 $pr https://github.com/example/jig/actions/runs/7"

  run cr_check "$repo" "$before"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test ("
  assert_contains "$OUT" "its jobs cannot be read"
}

test_ci_reuse_without_before_tests_everything() {
  local repo="$PWD/repo"
  cr_history "$repo" yes
  cr_gh

  run cr_check "$repo" ""
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (no commit before the push)"
  assert_no_file "$PWD/gh.log" "GitHub must not be asked without a commit to compare"

  run cr_check "$repo" 0000000000000000000000000000000000000000
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (new branch, nothing before the push)"

  run cr_check "$repo" ffffffffffffffffffffffffffffffffffffffff
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (ffffffffffffffffffffffffffffffffffffffff is not in the history)"
}

test_ci_reuse_without_repository_slug_tests_everything() {
  local repo="$PWD/repo" before stub="$PWD/stub-bin"
  cr_history "$repo" yes
  before=$(cr_sha "$repo" before)
  cr_gh

  run env -u GITHUB_REPOSITORY sh -c "cd '$repo' && PATH='$stub:$PATH' '$JIG_HOME/.github/scripts/ci-reuse.sh' '$before'"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test (GITHUB_REPOSITORY is not set"
}

# --- the second copies ---------------------------------------------------------

# ci-reuse.sh recognises the Windows Git Bash shares by the start of their job
# name. A rename in ci.yml alone would only make main test everything, but a
# silent fallback is a speed-up lost without anyone knowing: hold the two
# together here.
test_ci_reuse_windows_prefix_matches_the_workflow() {
  local prefix
  prefix=$(sed -n 's/^CR_WINDOWS_PREFIX="\(.*\)"$/\1/p' "$JIG_HOME/.github/scripts/ci-reuse.sh")
  [ -n "$prefix" ] || fail "no CR_WINDOWS_PREFIX in ci-reuse.sh"
  grep -qF "    name: $prefix\${{ matrix.shard }}" "$JIG_HOME/.github/workflows/ci.yml" \
    || fail "test-windows is no longer named '$prefix…'; update CR_WINDOWS_PREFIX in ci-reuse.sh"
}

# The workflow asks the script on a full push to main only, hands it the
# commit before the push, and publishes its answer as scope's `reuse`.
test_ci_reuse_workflow_asks_on_a_full_push_to_main() {
  local file="$JIG_HOME/.github/workflows/ci.yml"
  # shellcheck disable=SC2016 # workflow expressions, matched literally
  {
    grep -qF 'reuse: ${{ steps.scope.outputs.reuse }}' "$file" || fail "scope does not publish reuse"
    grep -qF 'BEFORE: ${{ github.event.before }}' "$file" || fail "scope does not pass github.event.before"
    grep -qF 'push:main:full* | push:main:selected*)' "$file" || fail "reuse is not limited to a push to main that tests"
    grep -qF '.github/scripts/ci-reuse.sh "$BEFORE"' "$file" || fail "scope does not run ci-reuse.sh"
  }
}

# Every job of ci.yml is either one a full pull-request run into main runs, or
# one such a run always skips (CR_PR_SKIPS in ci-reuse.sh), or `knowledge`,
# whose skip is what says the run was full. A job in neither list would make
# every run look partial and reuse would stop without anyone noticing — which
# is what `red-main` did before it was listed.
test_ci_reuse_every_workflow_job_is_classified() {
  local runs="scope test test-windows smoke-windows changelog ci-ok" skips jobs job
  skips=$(sed -n 's/^CR_PR_SKIPS="\(.*\)"$/\1/p' "$JIG_HOME/.github/scripts/ci-reuse.sh")
  [ -n "$skips" ] || fail "no CR_PR_SKIPS in ci-reuse.sh"
  jobs=$(awk '/^jobs:/{f=1; next} f && /^  [a-z][a-z0-9-]*:$/{sub(/^  /,""); sub(/:$/,""); print}' \
    "$JIG_HOME/.github/workflows/ci.yml")
  [ -n "$jobs" ] || fail "no jobs read from ci.yml"
  for job in $jobs; do
    case " $runs $skips knowledge " in
      *" $job "*) ;;
      *) fail "job '$job' of ci.yml is in neither list: add it to CR_PR_SKIPS in ci-reuse.sh if a pull request into main skips it, or to the runs list here" ;;
    esac
  done
  # And the skip list names only jobs that are there.
  for job in $skips; do
    case " $(printf '%s\n' "$jobs" | tr '\n' ' ')" in
      *" $job "*) ;;
      *) fail "CR_PR_SKIPS names '$job', which ci.yml no longer has" ;;
    esac
  done
}

# A pull request's run of the tests its change reaches tested part of the
# tree: main must not skip the suite on its strength
# (adr-20261110-a-pull-request-runs-the-tests-its-change-reaches).
test_ci_reuse_a_selected_run_tests_everything() {
  local repo="$PWD/repo" pr before
  cr_history "$repo" yes
  pr=$(cr_sha "$repo" pr)
  before=$(cr_sha "$repo" before)
  cr_gh
  cr_pulls "$pr"
  cr_runs "7 $pr https://github.com/example/jig/actions/runs/7"
  cr_jobs 7 "success scope" "skipped knowledge" "success ubuntu-latest 1/1 (selected)" \
    "success macos-latest 1/1 (selected)" "success windows-latest (Git Bash) 1/2 (selected)" \
    "success windows-latest (Git Bash) 2/2 (selected)" \
    "success windows-latest smoke (install.ps1)" \
    "success changelog" "skipped epic-pr" "skipped release" "success ci-ok"

  run cr_check "$repo" "$before"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test ("
  assert_contains "$OUT" "did not run the whole suite"
}

# The suffix ci-reuse.sh reads is the one the workflow writes into the names
# of both test jobs.
test_ci_reuse_all_suffix_matches_the_workflow() {
  local suffix file="$JIG_HOME/.github/workflows/ci.yml"
  suffix=$(sed -n 's/^CR_ALL_SUFFIX="\(.*\)"$/\1/p' "$JIG_HOME/.github/scripts/ci-reuse.sh")
  assert_eq " (all)" "$suffix"
  # shellcheck disable=SC2016 # workflow expressions, matched literally
  grep -qF '${{ matrix.shard }} (${{ needs.scope.outputs.suite }})' "$file" \
    || fail "the test jobs no longer end their names in the suite; update CR_ALL_SUFFIX"
  # The names the suite takes are written by ci-outputs.sh (F5: both suffixes
  # are held to it, since a rename of either would switch reuse off).
  # shellcheck disable=SC2016
  [ "$(sed -n 's/^CR_SELECTED_SUFFIX="\(.*\)"$/\1/p' "$JIG_HOME/.github/scripts/ci-reuse.sh")" = " (selected)" ] \
    || fail "CR_SELECTED_SUFFIX is not ' (selected)'"
  run "$JIG_HOME/.github/scripts/ci-outputs.sh" "full (x)" "test (y)"
  assert_contains "$OUT" "suite=all" "ci-outputs.sh no longer calls the whole suite 'all'; update CR_ALL_SUFFIX"
  run "$JIG_HOME/.github/scripts/ci-outputs.sh" "selected (x)" "test (y)"
  assert_contains "$OUT" "suite=selected" "ci-outputs.sh no longer calls selected tests 'selected'; update CR_SELECTED_SUFFIX"
}

# --- selected tests ----------------------------------------------------------

# A push of selected tests reuses a pull request's run of selected tests when
# that run's plan holds every filter the push needs.
test_ci_reuse_selected_run_with_a_superset_of_filters_is_reused() {
  local repo="$PWD/repo"
  cr_selected_setup "$repo"
  cr_selected_jobs 7
  cr_plan 7 "ci-reuse" "ci-scope" "knowledge"
  cr_filters "$PWD/filters" "ci-scope" "ci-reuse"

  run cr_check "$repo" "$CR_BEFORE" selected "$PWD/filters"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "reuse (https://github.com/example/jig/actions/runs/7 tested tree"
  assert_contains "$OUT" "; suite: selected)"
  assert_file_contains "$PWD/gh.log" "run download 7 -R example/jig -n plan -D"
}

test_ci_reuse_selected_run_missing_a_filter_is_not_reused() {
  local repo="$PWD/repo"
  cr_selected_setup "$repo"
  cr_selected_jobs 7
  cr_plan 7 "ci-reuse"
  cr_filters "$PWD/filters" "ci-reuse" "ci-scope"

  run cr_check "$repo" "$CR_BEFORE" selected "$PWD/filters"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "it did not run the filter 'ci-scope' this push needs"
  assert_contains "$OUT" "test ("
}

# A filter is compared whole: a longer filter does not stand for a shorter one.
test_ci_reuse_selected_filters_are_compared_whole() {
  local repo="$PWD/repo"
  cr_selected_setup "$repo"
  cr_selected_jobs 7
  cr_plan 7 "ci-reuse-extra"
  cr_filters "$PWD/filters" "ci-reuse"

  run cr_check "$repo" "$CR_BEFORE" selected "$PWD/filters"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test ("
}

test_ci_reuse_selected_run_without_a_plan_artifact_is_not_reused() {
  local repo="$PWD/repo"
  cr_selected_setup "$repo"
  cr_selected_jobs 7
  cr_filters "$PWD/filters" "ci-reuse"

  run cr_check "$repo" "$CR_BEFORE" selected "$PWD/filters"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "its plan artifact cannot be read"
  assert_contains "$OUT" "test ("
}

test_ci_reuse_selected_run_without_windows_is_not_reused() {
  local repo="$PWD/repo"
  cr_selected_setup "$repo"
  cr_jobs 7 "success scope" "skipped knowledge" "success ubuntu-latest 1/1 (selected)" \
    "success macos-latest 1/1 (selected)" "success windows-latest smoke (install.ps1)" \
    "success changelog" "skipped epic-pr" "skipped release" "success ci-ok"
  cr_plan 7 "ci-reuse"
  cr_filters "$PWD/filters" "ci-reuse"

  run cr_check "$repo" "$CR_BEFORE" selected "$PWD/filters"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "it skipped the Windows Git Bash shares"
  assert_contains "$OUT" "test ("
}

test_ci_reuse_selected_run_with_mixed_shares_is_not_reused() {
  local repo="$PWD/repo"
  cr_selected_setup "$repo"
  cr_jobs 7 "success scope" "skipped knowledge" "success ubuntu-latest 1/1 (all)" \
    "success macos-latest 1/1 (selected)" "success windows-latest (Git Bash) 1/1 (selected)" \
    "success changelog" "skipped epic-pr" "skipped release" "success ci-ok"
  cr_plan 7 "ci-reuse"
  cr_filters "$PWD/filters" "ci-reuse"

  run cr_check "$repo" "$CR_BEFORE" selected "$PWD/filters"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "its shares mix the whole suite and selected tests"
  assert_contains "$OUT" "test ("
}

# A run of the whole suite covers any selection, with no plan to read.
test_ci_reuse_selected_push_reuses_a_run_of_the_whole_suite() {
  local repo="$PWD/repo"
  cr_selected_setup "$repo"
  cr_full_jobs 7
  cr_filters "$PWD/filters" "ci-reuse"

  run cr_check "$repo" "$CR_BEFORE" selected "$PWD/filters"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "reuse (https://github.com/example/jig/actions/runs/7 tested tree"
  assert_contains "$OUT" "; suite: all)"
}

# The default suite is `all`: a run of selected tests does not count, plan or
# no plan.
test_ci_reuse_suite_all_still_refuses_a_selected_run() {
  local repo="$PWD/repo"
  cr_selected_setup "$repo"
  cr_selected_jobs 7
  cr_plan 7 "ci-reuse"

  run cr_check "$repo" "$CR_BEFORE" all
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "did not run the whole suite"

  run cr_check "$repo" "$CR_BEFORE"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "did not run the whole suite"
  assert_contains "$OUT" "test ("

  cr_filters "$PWD/filters" "ci-reuse"
  run cr_check "$repo" "$CR_BEFORE" all "$PWD/filters"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "did not run the whole suite"
  assert_contains "$OUT" "test ("
}

test_ci_reuse_selected_needs_its_filters_file_and_a_known_suite() {
  local repo="$PWD/repo"
  cr_selected_setup "$repo"

  run cr_check "$repo" "$CR_BEFORE" selected
  assert_eq 2 "$RC" "$OUT"
  assert_contains "$OUT" "usage:"

  run cr_check "$repo" "$CR_BEFORE" everything "$PWD/filters"
  assert_eq 2 "$RC" "$OUT"
  assert_contains "$OUT" "usage:"

  # A filters file that is missing or empty names nothing to compare.
  cr_selected_jobs 7
  cr_plan 7 "ci-reuse"
  run cr_check "$repo" "$CR_BEFORE" selected "$PWD/no-such-file"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test ("
  : > "$PWD/empty"
  run cr_check "$repo" "$CR_BEFORE" selected "$PWD/empty"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "this push names no filter to compare"
}

# The workflow hands scope's suite and the filters it wrote to the script.
test_ci_reuse_workflow_passes_the_suite_and_the_filters() {
  local file="$JIG_HOME/.github/workflows/ci.yml"
  # shellcheck disable=SC2016 # workflow expressions, matched literally
  grep -qF '.github/scripts/ci-reuse.sh "$BEFORE" "$suite" "$plan/filters"' "$file" \
    || fail "scope does not hand the suite and the filters to ci-reuse.sh"
}

# --- narrow ------------------------------------------------------------------

# cr_narrow_history <dir> — main with a commit, a branch `pr` that never
# merged main back, the commit `base` the pull request's run merged onto, a
# further commit on main (`before`, which the run never saw) and HEAD at the
# merge of `pr`. The merge has a tree no run tested, but merging `pr` onto
# `base` gives the tree the run did.
cr_narrow_history() {
  local dir="$1"
  mkdir -p "$dir"
  (
    cd "$dir" || exit 1
    fixture_repo
    git checkout -q -b pr
    printf 'feature\n' > feature.txt
    git add feature.txt
    git commit -q -m feature
    git checkout -q main
    printf 'other\n' > other.txt
    git add other.txt
    git commit -q -m "main moves"
    git tag base
    printf 'later\n' > later.txt
    git add later.txt
    git commit -q -m "main moves again, while the run goes"
    git tag before
    git merge -q --no-ff --no-edit pr
  )
}

# cr_tested <id> <base> <head> <tree> — the `plan` artifact of run <id> with
# its `tested` record.
cr_tested() {
  mkdir -p "$PWD/plan-$1"
  printf 'base=%s\nhead=%s\ntree=%s\n' "$2" "$3" "$4" > "$PWD/plan-$1/tested"
}

# cr_narrow_setup <dir> — a narrow history, a stub, and a whole-suite run 7 of
# the pull request with a true record; sets CR_PR, CR_BEFORE, CR_BASE, CR_TREE.
cr_narrow_setup() {
  cr_narrow_history "$1"
  CR_PR=$(cr_sha "$1" pr)
  CR_BEFORE=$(cr_sha "$1" before)
  CR_BASE=$(cr_sha "$1" base)
  CR_TREE=$(git -C "$1" merge-tree --write-tree "$CR_BASE" "$CR_PR")
  cr_gh
  cr_pulls "$CR_PR"
  cr_runs "7 $CR_PR https://github.com/example/jig/actions/runs/7"
  cr_full_jobs 7
  cr_tested 7 "$CR_BASE" "$CR_PR" "$CR_TREE"
}

# A pull request that was behind main when it merged: its whole-suite run
# tested the tree of the merge onto an older main. The answer names a commit
# with that tree on top of that main, and nothing is pushed or configured.
test_ci_reuse_a_stale_whole_suite_run_narrows() {
  local repo="$PWD/repo" commit
  cr_narrow_setup "$repo"

  run cr_check "$repo" "$CR_BEFORE"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "narrow "
  assert_contains "$OUT" "(https://github.com/example/jig/actions/runs/7 tested tree $CR_TREE in full; main has moved since)"
  commit=${OUT#narrow }
  commit=${commit%% *}
  assert_eq "$CR_TREE" "$(git -C "$repo" rev-parse "$commit^{tree}")" "the commit must hold the tested tree"
  assert_eq "$CR_BASE" "$(git -C "$repo" rev-parse "$commit^")" "the commit must sit on the base the run merged onto"
  assert_file_contains "$PWD/gh.log" "run download 7"
  # Main's own history and configuration are as they were.
  assert_eq "$(cr_sha "$repo" HEAD)" "$(git -C "$repo" rev-parse main)" "HEAD must not move"
  [ -z "$(git -C "$repo" config --local --get user.name || true)" ] || fail "the script must not set a git identity"
}

# The same answer for a push that needs selected tests: a narrow commit is
# measured from the whole suite either way.
test_ci_reuse_a_selected_push_narrows_from_a_whole_suite_run() {
  local repo="$PWD/repo"
  cr_narrow_setup "$repo"
  cr_filters "$PWD/filters" "ci-reuse"

  run cr_check "$repo" "$CR_BEFORE" selected "$PWD/filters"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "narrow "
}

# The commonest behind-main shape: the branch was behind main when its run
# started and nothing landed on main while it went (B is main's tip). The merge
# main made has the tree the run tested, though no commit of the run's has it.
# That is exact reuse of a whole-suite run, not a narrowing from an empty
# difference (which would test the whole suite again).
test_ci_reuse_a_stale_branch_whose_main_did_not_move_is_reused_exactly() {
  local repo="$PWD/repo" pr base tree
  mkdir -p "$repo"
  (
    cd "$repo" || exit 1
    fixture_repo
    git checkout -q -b pr
    printf 'feature\n' > feature.txt
    git add feature.txt
    git commit -q -m feature
    git checkout -q main
    printf 'other\n' > other.txt
    git add other.txt
    git commit -q -m "main moves before the run"
    git tag base
    git merge -q --no-ff --no-edit pr
  )
  pr=$(cr_sha "$repo" pr)
  base=$(cr_sha "$repo" base)
  tree=$(git -C "$repo" merge-tree --write-tree "$base" "$pr")
  assert_eq "$tree" "$(git -C "$repo" rev-parse 'HEAD^{tree}')" "the fixture must make the tested tree HEAD's"
  cr_gh
  cr_pulls "$pr"
  cr_runs "7 $pr https://github.com/example/jig/actions/runs/7"
  cr_full_jobs 7
  cr_tested 7 "$base" "$pr" "$tree"

  run cr_check "$repo" "$base"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "reuse (https://github.com/example/jig/actions/runs/7 tested tree $tree"
  assert_contains "$OUT" "; suite: all"
  assert_not_contains "$OUT" "narrow "

  # A run of selected tests is no whole-suite run: it still does not reuse.
  cr_selected_jobs 7
  cr_plan 7 "ci-reuse"
  cr_filters "$PWD/filters" "ci-reuse"
  run cr_check "$repo" "$base" selected "$PWD/filters"
  assert_eq 0 "$RC" "$OUT"
  assert_not_contains "$OUT" "narrow "
  assert_not_contains "$OUT" "reuse ("
}

# Exact reuse is the stronger claim: a run that tested this very tree wins
# over a run that could narrow.
test_ci_reuse_exact_reuse_wins_over_narrow() {
  local repo="$PWD/repo" pr before
  cr_history "$repo" yes
  pr=$(cr_sha "$repo" pr)
  before=$(cr_sha "$repo" before)
  cr_gh
  cr_pulls "$pr"
  cr_runs "7 $pr https://github.com/example/jig/actions/runs/7"
  cr_full_jobs 7
  cr_tested 7 "$before" "$pr" "$(git -C "$repo" merge-tree --write-tree "$before" "$pr")"

  run cr_check "$repo" "$before"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "reuse (https://github.com/example/jig/actions/runs/7 tested tree"
  assert_not_contains "$OUT" "narrow"
}

# Main is red while an open `red-main` issue exists: no narrowing, the whole
# suite runs; and the same when the question cannot be answered.
test_ci_reuse_a_red_main_does_not_narrow() {
  local repo="$PWD/repo"
  cr_narrow_setup "$repo"
  echo 42 > "$PWD/issue.txt"

  run cr_check "$repo" "$CR_BEFORE"
  assert_eq 0 "$RC" "$OUT"
  assert_eq "test (main is red (#42); a pull request's run cannot narrow it)" "$(printf '%s\n' "$OUT" | tail -n 1)" "the answer must be test"
  assert_file_contains "$PWD/gh.log" "issue list -R example/jig --label red-main --state open"
}

test_ci_reuse_an_unreadable_red_main_state_does_not_narrow() {
  local repo="$PWD/repo"
  cr_narrow_setup "$repo"
  : > "$PWD/issue-fails"

  run cr_check "$repo" "$CR_BEFORE"
  assert_eq 0 "$RC" "$OUT"
  assert_not_contains "$OUT" "narrow "
  assert_contains "$OUT" "test (main's state cannot be read"
}

test_ci_reuse_exact_reuse_works_while_main_is_red() {
  local repo="$PWD/repo" pr before
  cr_history "$repo" yes
  pr=$(cr_sha "$repo" pr)
  before=$(cr_sha "$repo" before)
  cr_gh
  cr_pulls "$pr"
  cr_runs "7 $pr https://github.com/example/jig/actions/runs/7"
  cr_full_jobs 7
  echo 42 > "$PWD/issue.txt"

  run cr_check "$repo" "$before"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "reuse (https://github.com/example/jig/actions/runs/7 tested tree"
}

# A run of selected tests tested part of its tree: nothing narrows from it,
# even with a record and a plan.
test_ci_reuse_a_selected_pull_request_run_does_not_narrow() {
  local repo="$PWD/repo"
  cr_narrow_setup "$repo"
  cr_selected_jobs 7
  cr_plan 7 "ci-reuse"
  cr_filters "$PWD/filters" "ci-reuse"

  run cr_check "$repo" "$CR_BEFORE" selected "$PWD/filters"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "test ("
  assert_not_contains "$OUT" "narrow "
  assert_contains "$OUT" "did not run the whole suite"
}

test_ci_reuse_a_run_without_windows_does_not_narrow() {
  local repo="$PWD/repo"
  cr_narrow_setup "$repo"
  cr_jobs 7 "success scope" "skipped knowledge" "success ubuntu-latest 1/2 (all)" \
    "success macos-latest 1/3 (all)" "success windows-latest smoke (install.ps1)" \
    "success changelog" "skipped epic-pr" "skipped release" "success ci-ok"

  run cr_check "$repo" "$CR_BEFORE"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "it skipped the Windows Git Bash shares"
  assert_contains "$OUT" "test ("
  assert_not_contains "$OUT" "narrow "
}

test_ci_reuse_a_run_without_a_plan_artifact_does_not_narrow() {
  local repo="$PWD/repo"
  cr_narrow_setup "$repo"
  rm -rf "$PWD/plan-7"

  run cr_check "$repo" "$CR_BEFORE"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "no record of the tree it tested"
  assert_contains "$OUT" "test ("
  assert_not_contains "$OUT" "narrow "
}

# A plan artifact from before the record existed holds filters, not `tested`.
test_ci_reuse_a_plan_without_a_tested_record_does_not_narrow() {
  local repo="$PWD/repo"
  cr_narrow_setup "$repo"
  rm -f "$PWD/plan-7/tested"
  cr_plan 7 "ci-reuse"

  run cr_check "$repo" "$CR_BEFORE"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "no record of the tree it tested"
  assert_not_contains "$OUT" "narrow "
}

test_ci_reuse_an_incomplete_record_does_not_narrow() {
  local repo="$PWD/repo"
  cr_narrow_setup "$repo"
  printf 'base=%s\nhead=%s\n' "$CR_BASE" "$CR_PR" > "$PWD/plan-7/tested"

  run cr_check "$repo" "$CR_BEFORE"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "incomplete"
  assert_not_contains "$OUT" "narrow "

  printf 'base=nonsense\nhead=%s\ntree=%s\n' "$CR_PR" "$CR_TREE" > "$PWD/plan-7/tested"
  run cr_check "$repo" "$CR_BEFORE"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "not readable"
  assert_not_contains "$OUT" "narrow "
}

# The record names a head other than the run's own.
test_ci_reuse_a_record_of_another_head_does_not_narrow() {
  local repo="$PWD/repo"
  cr_narrow_setup "$repo"
  cr_tested 7 "$CR_BASE" "$CR_BASE" "$CR_TREE"

  run cr_check "$repo" "$CR_BEFORE"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "names another head than the run"
  assert_not_contains "$OUT" "narrow "
}

# The base the run merged onto is not in main's history before the push: it
# was, say, a commit of a branch main never took.
test_ci_reuse_a_base_that_is_not_an_ancestor_does_not_narrow() {
  local repo="$PWD/repo" stray tree
  cr_narrow_setup "$repo"
  stray=$(cd "$repo" && git checkout -q -b stray base && printf 's\n' > stray.txt \
    && git add stray.txt && git commit -q -m stray && git rev-parse HEAD && git checkout -q main)
  tree=$(git -C "$repo" merge-tree --write-tree "$stray" "$CR_PR")
  cr_tested 7 "$stray" "$CR_PR" "$tree"

  run cr_check "$repo" "$CR_BEFORE"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "is not in main's history up to $CR_BEFORE"
  assert_not_contains "$OUT" "narrow "
}

# The record says a tree the merge does not give.
test_ci_reuse_a_tree_that_does_not_reproduce_does_not_narrow() {
  local repo="$PWD/repo" other
  cr_narrow_setup "$repo"
  other=$(git -C "$repo" rev-parse 'HEAD^{tree}')
  cr_tested 7 "$CR_BASE" "$CR_PR" "$other"

  run cr_check "$repo" "$CR_BEFORE"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "not the $other it recorded"
  assert_not_contains "$OUT" "narrow "
}

# Base and head that conflict: merge-tree cannot reproduce any tree. The base
# is in main's history before the push, so it is the merge that fails.
test_ci_reuse_a_merge_conflict_does_not_narrow() {
  local repo="$PWD/repo" left
  cr_narrow_setup "$repo"
  left=$(cd "$repo" && git checkout -q -b left base && printf 'left\n' > feature.txt \
    && git add feature.txt && git commit -q -m left && git rev-parse HEAD)
  (cd "$repo" && git checkout -q -b w before && git merge -q --no-edit left >/dev/null \
    && git tag -f before >/dev/null && git checkout -q main)
  CR_BEFORE=$(cr_sha "$repo" before)
  cr_tested 7 "$left" "$CR_PR" "$CR_TREE"

  run cr_check "$repo" "$CR_BEFORE"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "does not reproduce its tree"
  assert_not_contains "$OUT" "narrow "
}
