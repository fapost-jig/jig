# Tests for `.github/scripts/ci-push-base.sh`. shellcheck shell=bash
#
# Every test builds a real history under its own tmp dir (fixture_repo, one
# commit on main) and gives it an `origin/main` the way a full checkout has
# one, then runs the script there the way the `scope` job does on a push.
# Helpers are prefixed pb_.

# pb_repo <dir> — a repository with main's commit, and origin/main at it.
pb_repo() {
  mkdir -p "$1"
  (cd "$1" && fixture_repo && git update-ref refs/remotes/origin/main HEAD)
}

# pb_commit <dir> <file> — one commit adding <file>.
pb_commit() {
  (cd "$1" && printf '%s\n' "$2" > "$2" && git add -A && git commit -q -m "$2")
}

# pb_run <dir> <branch> <green> — the script, in <dir>.
pb_run() {
  local dir="$1"
  shift
  (cd "$dir" && "$JIG_HOME/.github/scripts/ci-push-base.sh" "$@")
}

test_ci_push_base_epic_without_a_green_run_starts_where_it_left_main() {
  local repo="$PWD/repo" fork
  pb_repo "$repo"
  fork=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" switch -q -c epic/x
  pb_commit "$repo" spec.md

  run pb_run "$repo" epic/x ""
  assert_eq 0 "$RC"
  assert_eq "base $fork (merge-base with main)" "$OUT"
}

test_ci_push_base_epic_synced_with_main_is_measured_from_main_tip() {
  local repo="$PWD/repo" tip
  pb_repo "$repo"
  git -C "$repo" switch -q -c epic/x
  pb_commit "$repo" spec.md
  # main moves on; the epic merges it, and origin/main is the new tip.
  git -C "$repo" switch -q main
  pb_commit "$repo" other.txt
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  tip=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" switch -q epic/x
  git -C "$repo" merge -q --no-ff -m sync main
  pb_commit "$repo" more.md

  run pb_run "$repo" epic/x ""
  assert_eq "base $tip (merge-base with main)" "$OUT"
}

test_ci_push_base_epic_holding_nothing_beyond_main_is_empty() {
  local repo="$PWD/repo" head
  pb_repo "$repo"
  git -C "$repo" switch -q -c epic/x
  head=$(git -C "$repo" rev-parse HEAD)

  run pb_run "$repo" epic/x ""
  assert_eq 0 "$RC"
  assert_contains "$OUT" "empty $head (merge-base with main is HEAD"
}

test_ci_push_base_epic_with_a_green_run_is_measured_from_it() {
  local repo="$PWD/repo" green
  pb_repo "$repo"
  git -C "$repo" switch -q -c epic/x
  pb_commit "$repo" a.md
  green=$(git -C "$repo" rev-parse HEAD)
  pb_commit "$repo" b.md

  run pb_run "$repo" epic/x "$green"
  assert_eq "base $green (last successful run)" "$OUT"
}

# The same tree already passed: nothing to test again, decided on purpose.
test_ci_push_base_rerun_of_a_green_epic_commit_is_empty() {
  local repo="$PWD/repo" head
  pb_repo "$repo"
  git -C "$repo" switch -q -c epic/x
  pb_commit "$repo" a.md
  head=$(git -C "$repo" rev-parse HEAD)

  run pb_run "$repo" epic/x "$head"
  assert_contains "$OUT" "empty $head (last successful run is HEAD"
}

test_ci_push_base_epic_without_origin_main_has_no_base() {
  local repo="$PWD/repo"
  pb_repo "$repo"
  git -C "$repo" update-ref -d refs/remotes/origin/main
  git -C "$repo" switch -q -c epic/x
  pb_commit "$repo" a.md

  run pb_run "$repo" epic/x ""
  assert_eq 0 "$RC"
  assert_contains "$OUT" "none ("
}

test_ci_push_base_other_branches_take_the_green_run_or_nothing() {
  local repo="$PWD/repo" head
  pb_repo "$repo"
  head=$(git -C "$repo" rev-parse HEAD)

  run pb_run "$repo" main ""
  assert_contains "$OUT" "none (no successful run on main)"
  # Not an epic: HEAD == base is not 'empty' here, scope's own rules apply.
  run pb_run "$repo" main "$head"
  assert_eq "base $head (last successful run)" "$OUT"
  run pb_run "$repo" feature/y ""
  assert_contains "$OUT" "none ("
}

test_ci_push_base_takes_exactly_two_arguments() {
  run pb_run "$PWD" epic/x
  assert_eq 2 "$RC"
}
