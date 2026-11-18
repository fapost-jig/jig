# Tests for `.github/scripts/ci-green-base.sh` (task ci-scope-misses-a-just-finished-run).
# shellcheck shell=bash
#
# No network: `gh` is a stub on PATH. Its Nth call answers with the contents of
# $PWD/runs-N.txt when that file exists, else with $PWD/runs.txt, and fails
# when neither does; every call is logged to $PWD/gh.log. A listing line is
# what the script's --jq filter prints: `<id> <head sha> <status> <conclusion>`.
# Every test builds a fixture history under its own tmp dir and runs the script
# there with HEAD at the tip of main, the way the `scope` job does on a push,
# with CI_GREEN_BASE_WAIT=0 so that waiting costs nothing. Helpers are
# prefixed cg_.

# --- fixture builders --------------------------------------------------------

# cg_commit <dir> <file> <content> <message> — write and commit one file.
cg_commit() {
  (
    cd "$1" || exit 1
    mkdir -p "$(dirname "$2")"
    printf '%s\n' "$3" > "$2"
    git add "$2"
    git commit -q -m "$4"
  )
}

# cg_sha <dir> <rev> — the commit <rev> names in <dir>.
cg_sha() {
  git -C "$1" rev-parse "$2"
}

# cg_runs <n|-> <line>... — the listing GitHub answers on the <n>th ask, or on
# every ask without a file of its own when <n> is `-`.
cg_runs() {
  local n="$1" file
  shift
  if [ "$n" = - ]; then file="$PWD/runs.txt"; else file="$PWD/runs-$n.txt"; fi
  printf '%s\n' "$@" > "$file"
}

# cg_gh — install the stub `gh`.
cg_gh() {
  mkdir -p "$PWD/stub-bin"
  cat > "$PWD/stub-bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$PWD/gh.log"
n=0
[ -f "$PWD/gh.count" ] && n=\$(cat "$PWD/gh.count")
n=\$((n + 1))
printf '%s\n' "\$n" > "$PWD/gh.count"
if [ -f "$PWD/runs-\$n.txt" ]; then
  cat "$PWD/runs-\$n.txt"
elif [ -f "$PWD/runs.txt" ]; then
  cat "$PWD/runs.txt"
else
  exit 1
fi
STUB
  chmod +x "$PWD/stub-bin/gh"
}

# cg_check <dir> [VAR=value...] — run the script under test in <dir> for the
# branch main, with the stub on PATH.
cg_check() {
  local dir="$1" stub="$PWD/stub-bin"
  shift
  (cd "$dir" && env PATH="$stub:$PATH" GITHUB_REPOSITORY=example/jig \
    CI_GREEN_BASE_WAIT=0 "$@" "$JIG_HOME/.github/scripts/ci-green-base.sh" main 2>"$PWD/../cg-stderr.txt")
}

# cg_asks — how many times the stub was asked.
cg_asks() {
  if [ -f "$PWD/gh.log" ]; then wc -l < "$PWD/gh.log" | tr -d ' '; else echo 0; fi
}

# --- the incident --------------------------------------------------------------

# Run 44170371907 was a release; run 44170402355, one line of documentation,
# asked for the last green run two seconds after the release ended and was
# not told about it. The first ask shows the release in progress, the second
# shows it done: the base is the release, and the scope is light.
test_ci_green_base_waits_for_a_run_that_just_finished() {
  local repo="$PWD/repo" old bump head
  mkdir -p "$repo"
  (cd "$repo" && fixture_repo)
  cg_commit "$repo" scripts/lib/version.sh 'JIG_VERSION="1.0.0"' "old"
  old=$(cg_sha "$repo" HEAD)
  cg_commit "$repo" scripts/lib/version.sh 'JIG_VERSION="1.1.0"' "release 1.1.0"
  bump=$(cg_sha "$repo" HEAD)
  cg_commit "$repo" README.md "one roadmap line" "docs only"
  head=$(cg_sha "$repo" HEAD)
  cg_gh
  cg_runs 1 "30 $bump in_progress none" "20 $old completed success"
  cg_runs 2 "30 $bump completed success" "20 $old completed success"

  run cg_check "$repo" GITHUB_RUN_ID=40
  assert_eq 0 "$RC" "$OUT"
  assert_eq "$bump" "$OUT"
  assert_eq 2 "$(cg_asks)"
  assert_file_contains "$PWD/cg-stderr.txt" "waiting for run 30 ($bump): in_progress/none"

  # What the base decides: from the release the change is documentation only;
  # from the run before it, the diff holds the version change.
  run bash -c "cd '$repo' && '$JIG_HOME/.github/scripts/ci-scope.sh' '$bump'"
  assert_eq 0 "$RC" "$OUT"
  case "$OUT" in light*) ;; *) fail "measured from the release the scope must be light: $OUT" ;; esac
  run bash -c "cd '$repo' && '$JIG_HOME/.github/scripts/ci-scope.sh' '$old'"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "JIG_VERSION"
  [ "$head" != "$bump" ] || fail "the fixture needs a commit after the release"
}

test_ci_green_base_asks_the_unfiltered_list() {
  local repo="$PWD/repo" old
  mkdir -p "$repo"
  (cd "$repo" && fixture_repo)
  cg_commit "$repo" a.txt a "a"
  old=$(cg_sha "$repo" HEAD~1)
  cg_commit "$repo" b.txt b "b"
  cg_gh
  cg_runs - "20 $old completed success"

  run cg_check "$repo"
  assert_eq 0 "$RC" "$OUT"
  assert_eq "$old" "$OUT"
  assert_file_contains "$PWD/gh.log" "actions/workflows/ci.yml/runs"
  assert_file_contains "$PWD/gh.log" "branch=main"
  assert_file_contains "$PWD/gh.log" "per_page=100"
  if grep -qF 'status=success' "$PWD/gh.log"; then
    fail "the list must not be filtered to successes: $(cat "$PWD/gh.log")"
  fi
}

# --- runs that do not count --------------------------------------------------------

# This run's own record, and a run queued behind it, are not waited for: the
# first is this very job, the second tests a commit that is not behind us.
test_ci_green_base_ignores_its_own_run_and_later_ones() {
  local repo="$PWD/repo" old head
  mkdir -p "$repo"
  (cd "$repo" && fixture_repo)
  old=$(cg_sha "$repo" HEAD)
  cg_commit "$repo" a.txt a "a"
  head=$(cg_sha "$repo" HEAD)
  cg_gh
  cg_runs - "50 $head queued none" "40 $head in_progress none" "20 $old completed success"

  run cg_check "$repo" GITHUB_RUN_ID=40
  assert_eq 0 "$RC" "$OUT"
  assert_eq "$old" "$OUT"
  assert_eq 1 "$(cg_asks)"
}

test_ci_green_base_a_later_run_of_an_earlier_commit_is_not_waited_for() {
  local repo="$PWD/repo" old mid
  mkdir -p "$repo"
  (cd "$repo" && fixture_repo)
  old=$(cg_sha "$repo" HEAD)
  cg_commit "$repo" a.txt a "a"
  mid=$(cg_sha "$repo" HEAD)
  cg_commit "$repo" b.txt b "b"
  cg_gh
  # A run queued behind this one (a greater id) for an ancestor of HEAD.
  cg_runs - "50 $mid in_progress none" "20 $old completed success"

  run cg_check "$repo" GITHUB_RUN_ID=40
  assert_eq 0 "$RC" "$OUT"
  assert_eq "$old" "$OUT"
  assert_eq 1 "$(cg_asks)"
}

test_ci_green_base_ignores_a_success_outside_the_history() {
  local repo="$PWD/repo" base side
  mkdir -p "$repo"
  (cd "$repo" && fixture_repo)
  base=$(cg_sha "$repo" HEAD)
  (cd "$repo" && git checkout -q -b side)
  cg_commit "$repo" side.txt side "side"
  side=$(cg_sha "$repo" HEAD)
  (cd "$repo" && git checkout -q main)
  cg_commit "$repo" a.txt a "a"
  cg_gh
  cg_runs - "30 $side completed success" "20 $base completed success"

  run cg_check "$repo"
  assert_eq 0 "$RC" "$OUT"
  assert_eq "$base" "$OUT"
}

# --- waiting -------------------------------------------------------------------------

# The newer run never reports: after the asks run out the proven success is
# the answer, and a success is never replaced by a run that did not finish.
test_ci_green_base_gives_the_proven_success_when_the_asks_run_out() {
  local repo="$PWD/repo" old bump
  mkdir -p "$repo"
  (cd "$repo" && fixture_repo)
  old=$(cg_sha "$repo" HEAD)
  cg_commit "$repo" a.txt a "a"
  bump=$(cg_sha "$repo" HEAD)
  cg_commit "$repo" b.txt b "b"
  cg_gh
  cg_runs - "30 $bump in_progress none" "20 $old completed success"

  run cg_check "$repo" CI_GREEN_BASE_TRIES=3
  assert_eq 0 "$RC" "$OUT"
  assert_eq "$old" "$OUT"
  assert_eq 3 "$(cg_asks)"
}

test_ci_green_base_a_failure_after_the_last_success_is_not_waited_for() {
  local repo="$PWD/repo" old bad
  mkdir -p "$repo"
  (cd "$repo" && fixture_repo)
  old=$(cg_sha "$repo" HEAD)
  cg_commit "$repo" a.txt a "a"
  bad=$(cg_sha "$repo" HEAD)
  cg_commit "$repo" b.txt b "b"
  cg_gh
  cg_runs - "30 $bad completed failure" "20 $old completed success"

  run cg_check "$repo"
  assert_eq 0 "$RC" "$OUT"
  assert_eq "$old" "$OUT"
  assert_eq 1 "$(cg_asks)"
}

# --- choosing --------------------------------------------------------------------------

# The newest is judged by the graph, not by where the list puts it.
test_ci_green_base_the_newest_success_by_the_graph_wins() {
  local repo="$PWD/repo" old new
  mkdir -p "$repo"
  (cd "$repo" && fixture_repo)
  old=$(cg_sha "$repo" HEAD)
  cg_commit "$repo" a.txt a "a"
  new=$(cg_sha "$repo" HEAD)
  cg_commit "$repo" b.txt b "b"
  cg_gh
  cg_runs - "20 $old completed success" "30 $new completed success"

  run cg_check "$repo"
  assert_eq 0 "$RC" "$OUT"
  assert_eq "$new" "$OUT"
  assert_eq 1 "$(cg_asks)"

  # And the other way round.
  cg_runs - "30 $new completed success" "20 $old completed success"
  run cg_check "$repo"
  assert_eq "$new" "$OUT"
}

test_ci_green_base_no_success_prints_nothing() {
  local repo="$PWD/repo" old
  mkdir -p "$repo"
  (cd "$repo" && fixture_repo)
  old=$(cg_sha "$repo" HEAD)
  cg_commit "$repo" a.txt a "a"
  cg_gh
  cg_runs - "20 $old completed failure"

  run cg_check "$repo"
  assert_eq 0 "$RC" "$OUT"
  assert_eq "" "$OUT"
}

# --- unmeasurable ----------------------------------------------------------------------

test_ci_green_base_a_failing_gh_prints_nothing() {
  local repo="$PWD/repo"
  mkdir -p "$repo"
  (cd "$repo" && fixture_repo)
  cg_gh

  run cg_check "$repo"
  assert_eq 0 "$RC" "$OUT"
  assert_eq "" "$OUT"
}

test_ci_green_base_without_a_repository_prints_nothing() {
  local repo="$PWD/repo" old
  mkdir -p "$repo"
  (cd "$repo" && fixture_repo)
  old=$(cg_sha "$repo" HEAD)
  cg_commit "$repo" a.txt a "a"
  cg_gh
  cg_runs - "20 $old completed success"

  run cg_check "$repo" GITHUB_REPOSITORY=
  assert_eq 0 "$RC" "$OUT"
  assert_eq "" "$OUT"
  assert_eq 0 "$(cg_asks)"
}

test_ci_green_base_without_a_branch_is_a_usage_error() {
  local repo="$PWD/repo"
  mkdir -p "$repo"
  (cd "$repo" && fixture_repo)
  run bash -c "cd '$repo' && '$JIG_HOME/.github/scripts/ci-green-base.sh'"
  assert_eq 2 "$RC" "$OUT"
  assert_contains "$OUT" "usage: ci-green-base.sh <branch>"
}
