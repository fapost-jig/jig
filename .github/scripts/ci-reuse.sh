#!/usr/bin/env bash
# ci-reuse.sh — decide whether a push to main may skip the suite because a
# pull request's run already tested the very tree main now has
# (adr-20261027-main-is-not-retested-when-a-pull-request-tested-its-tree).
# Run by the `scope` job of .github/workflows/ci.yml, in the root of a full
# checkout of the pushed commit, on a push to main whose scope is full.
#
# Why: a release cost four runs of the whole suite — the task's pull request,
# its merge into main, the release pull request, its merge — and two of them
# tested a tree that had just been tested.
#
# Prints one line:
#
#   - reuse (<run url> ...): a successful run of `ci` on a pull request tested
#     this tree, the whole suite on every platform. The suite is skipped and
#     the run goes on to `release`;
#   - test (<why>): anything else. The suite runs as it always did.
#
# The pull request is the one GitHub records as having made HEAD: into main,
# with HEAD as its merge commit, so a direct push never reuses. Its runs are
# found by its head commit P: a run does not say which pull request it ran
# for once that pull request merged (`pull_requests` is empty then). So a run
# of the same commit P for a second, open pull request into another branch —
# an epic — would count too, though it tested a merge onto that branch. That
# needs one branch proposed into main and into an epic at the same commit;
# the ADR names it as residual risk.
#
# What a pull request's run tested is GitHub's merge of its head P into the
# tip of main at the time, B: `refs/pull/N/merge`. That ref is gone once the
# pull request merges, and the run's own `head_sha` is P, not the merge. So
# the tree is reached by an argument instead: main only moves forward (the
# branch rule refuses a non-fast-forward push), and the run came before this
# push, so B is <before> or an ancestor of it. When <before> is an ancestor
# of P, so is B, GitHub's merge of the two is P's own tree, and when that tree
# is HEAD's, the run tested what main now holds. A pull request that was not
# up to date with main when it merged fails the ancestry test, and main tests
# everything — which is exactly the case where main's tree is new.
#
# The run counts only when it was full: `knowledge` skipped (the scope was
# full), every test share ran the same kind of suite — its name ends in
# CR_ALL_SUFFIX for the whole suite or in CR_SELECTED_SUFFIX for the tests the
# change reaches (adr-20261110-a-pull-request-runs-the-tests-its-change-reaches),
# never a mix, and a share of neither kind does not count —, no other job
# skipped but those in CR_PR_SKIPS, which never run on a pull request into
# main, and at least one Linux or macOS share and at least one Windows Git Bash
# share passed —
# a pull request that skipped Windows covers Linux and macOS only, and main
# releases for Windows too. The name prefix below is the second copy of the
# `test-windows` job's name; tests/ci-workflow.t.sh holds the two together,
# and a rename that slipped past it would only make main test everything.
#
# What the push needs decides which kind of run counts. A push whose scope is
# the whole suite (`all`, the default) reuses only a run of the whole suite. A
# push whose scope is `selected` reuses either: a run of the whole suite
# covers any selection, and a run of selected tests covers it when the `plan`
# artifact of that run (its `filters` file, one tests/run.sh filter per line)
# holds every filter of the push, <filters-file>. The push's own selection is
# measured from the last green run on main, not from <before>, so it can be
# wider than the pull request's: a missing filter, a missing or unreadable
# artifact (kept seven days) and an empty filter list all mean the run does
# not count. Such a push does not release and does not close `red-main`;
# both ask the scope for `all` themselves.
#
# Unmeasurable is never a reason to skip: a missing <before>, a commit that
# cannot be read, a GitHub API that does not answer — each prints `test`.
#
# Environment: GITHUB_REPOSITORY (owner/name; set by Actions) and GH_TOKEN for
# `gh`.
#
# Usage: .github/scripts/ci-reuse.sh <before> [<suite> <filters-file>]
#   <before>        github.event.before: the tip of main before this push.
#   <suite>         `all` (default) or `selected`: the scope of this push.
#   <filters-file>  with `selected`: the filters of this push, one per line
#                   (what ci-scope.sh writes to CI_SCOPE_FILTERS).
set -eu
set -o pipefail

CR_WINDOWS_PREFIX="windows-latest (Git Bash) "
# The jobs of ci.yml that a pull request into main always skips: their `if:`
# asks for a push or the nightly run on main, or for an epic's head branch.
# tests/ci-reuse.t.sh holds every job of ci.yml to this list or to the list
# of jobs a full pull-request run runs, so a new job is a decision made here.
CR_PR_SKIPS="release epic-pr red-main"
# The end of a test share's name when it ran the whole suite; the job names
# in ci.yml carry the suite, and tests/ci-workflow.t.sh holds them to it.
CR_ALL_SUFFIX=" (all)"
CR_SELECTED_SUFFIX=" (selected)"
# Test shares, by the start of their names: Linux, macOS and Windows.
CR_TEST_PREFIXES="ubuntu-latest macos-latest"

_cr_line() {
  printf '%s (%s)\n' "$1" "$2"
  exit 0
}

# _cr_have <sha> — make <sha> readable locally, fetching it when the
# checkout does not have it (a squash-merged branch, a deleted one).
_cr_have() {
  git cat-file -e "$1^{commit}" 2>/dev/null && return 0
  git fetch -q --depth=1 origin "$1" 2>/dev/null || return 1
  git cat-file -e "$1^{commit}" 2>/dev/null
}

# _cr_covers <run-id> — whether the `plan` artifact of a run of selected tests
# holds every filter of this push (CR_SUITE_FILTERS). Status 1 when it does
# not or cannot be read; the reason goes to stdout.
_cr_covers() {
  local dir f n=0
  dir=$(mktemp -d 2>/dev/null) || { echo "no scratch directory for its plan"; return 1; }
  if ! gh run download "$1" -R "$CR_SLUG" -n plan -D "$dir" >/dev/null 2>&1 \
    || [ ! -r "$dir/filters" ]; then
    rm -rf "$dir"
    echo "its plan artifact cannot be read"
    return 1
  fi
  if [ ! -r "$CR_SUITE_FILTERS" ]; then
    rm -rf "$dir"
    echo "the filters of this push cannot be read"
    return 1
  fi
  while IFS= read -r f || [ -n "$f" ]; do
    [ -n "$f" ] || continue
    n=$((n + 1))
    if ! grep -qxF -- "$f" "$dir/filters"; then
      rm -rf "$dir"
      echo "it did not run the filter '$f' this push needs"
      return 1
    fi
  done < "$CR_SUITE_FILTERS"
  rm -rf "$dir"
  if [ "$n" -eq 0 ]; then
    echo "this push names no filter to compare"
    return 1
  fi
  return 0
}

# _cr_full <run-id> — whether the run tested what this push needs, Windows
# included, judged from its jobs (and, for selected tests, its plan). Status 1
# when it did not or the jobs cannot be read; the reason goes to stdout.
_cr_full() {
  local jobs line conclusion name knowledge="" windows=0 unix=0 p q nall=0 nsel=0
  jobs=$(gh api -X GET "repos/$CR_SLUG/actions/runs/$1/jobs" -f per_page=100 \
    --jq '.jobs[] | "\(.conclusion) \(.name)"' 2>/dev/null) || {
    echo "its jobs cannot be read"
    return 1
  }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    conclusion=${line%% *}
    name=${line#* }
    if [ "$name" = knowledge ]; then
      knowledge=$conclusion
      continue
    fi
    case " $CR_PR_SKIPS " in *" $name "*) continue ;; esac
    if [ "$conclusion" != success ]; then
      echo "job '$name' ended as '$conclusion'"
      return 1
    fi
    p=""
    case "$name" in
      "$CR_WINDOWS_PREFIX"*) p=windows ;;
      *)
        for q in $CR_TEST_PREFIXES; do
          case "$name" in "$q "*) p=unix ;; esac
        done
        ;;
    esac
    [ -n "$p" ] || continue
    case "$name" in
      *"$CR_ALL_SUFFIX") nall=$((nall + 1)) ;;
      *"$CR_SELECTED_SUFFIX")
        if [ "$CR_SUITE" != selected ]; then
          echo "share '$name' did not run the whole suite"
          return 1
        fi
        nsel=$((nsel + 1))
        ;;
      *) echo "share '$name' did not run the whole suite"; return 1 ;;
    esac
    if [ "$p" = windows ]; then windows=$((windows + 1)); else unix=$((unix + 1)); fi
  done <<EOF
$jobs
EOF
  if [ "$knowledge" != skipped ]; then
    echo "its scope was light"
    return 1
  fi
  if [ "$unix" -eq 0 ]; then
    echo "it ran no Linux or macOS share of the suite"
    return 1
  fi
  if [ "$windows" -eq 0 ]; then
    echo "it skipped the Windows Git Bash shares"
    return 1
  fi
  if [ "$nall" -gt 0 ] && [ "$nsel" -gt 0 ]; then
    echo "its shares mix the whole suite and selected tests"
    return 1
  fi
  if [ "$nsel" -gt 0 ]; then
    _cr_covers "$1" || return 1
  fi
  return 0
}

main() {
  local before="${1:-}" head tree heads runs id sha url why seen=0
  CR_SUITE="${2:-all}"
  CR_SUITE_FILTERS="${3:-}"
  case "$#:$CR_SUITE" in
    1:all | 2:all | 3:all | 3:selected) ;;
    *) printf 'usage: ci-reuse.sh <before> [<suite> <filters-file>]\n' >&2; exit 2 ;;
  esac

  case "$before" in
    '') _cr_line test "no commit before the push" ;;
    *[!0]*) ;;
    *) _cr_line test "new branch, nothing before the push" ;;
  esac
  git cat-file -e "$before^{commit}" 2>/dev/null || _cr_line test "$before is not in the history"
  head=$(git rev-parse HEAD 2>/dev/null) || _cr_line test "cannot read HEAD"
  tree=$(git rev-parse 'HEAD^{tree}' 2>/dev/null) || _cr_line test "cannot read the tree of HEAD"

  CR_SLUG="${GITHUB_REPOSITORY:-}"
  [ -n "$CR_SLUG" ] || _cr_line test "GITHUB_REPOSITORY is not set; cannot ask GitHub"

  # The pull request into main whose merge is HEAD; a direct push has none.
  heads=$(gh api "repos/$CR_SLUG/commits/$head/pulls" \
    --jq ".[] | select(.base.ref == \"main\" and .merge_commit_sha == \"$head\") | .head.sha" \
    2>/dev/null) || _cr_line test "cannot read the pull request that made $head"
  [ -n "$heads" ] || _cr_line test "no pull request into main was merged as $head"

  runs=""
  for sha in $heads; do
    runs="$runs$(gh api -X GET "repos/$CR_SLUG/actions/workflows/ci.yml/runs" \
      -f event=pull_request -f status=success -f head_sha="$sha" \
      --jq '.workflow_runs[] | "\(.id) \(.head_sha) \(.html_url)"' 2>/dev/null)
" || _cr_line test "cannot read the pull-request runs of ci"
  done

  while read -r id sha url; do
    [ -n "${url:-}" ] || continue
    _cr_have "$sha" || continue
    [ "$(git rev-parse "$sha^{tree}" 2>/dev/null)" = "$tree" ] || continue
    seen=1
    if ! git merge-base --is-ancestor "$before" "$sha" 2>/dev/null; then
      echo "skipping $url: its branch did not contain main's tip $before" >&2
      continue
    fi
    if why=$(_cr_full "$id"); then
      _cr_line reuse "$url tested tree $tree on every platform"
    fi
    echo "skipping $url: $why" >&2
  done <<EOF
$runs
EOF

  if [ "$seen" -eq 1 ]; then
    _cr_line test "no green pull-request run tested what this push needs of tree $tree on top of $before"
  fi
  _cr_line test "no green run of the pull request has tree $tree"
}

main "$@"
