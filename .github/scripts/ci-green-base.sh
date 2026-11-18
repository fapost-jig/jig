#!/usr/bin/env bash
# ci-green-base.sh — name the commit a push to a branch is measured from: the
# newest successful run of `ci` whose head is in the pushed history.
# Run by the `scope` job of .github/workflows/ci.yml, in the root of a full
# checkout of the pushed commit, on a push; its answer is what ci-scope.sh
# takes as the base commit.
#
# Why: runs on main are serialized, so when a run's scope job starts, the run
# before it has just finished — and the list of runs filtered to
# `status=success` may not show it yet. Run 44170371907 (a release, a change
# of JIG_VERSION) finished at 20:33:21; run 44170402355 (one roadmap line)
# started its scope job at 20:33:23, the filtered list still ended at the
# release before, the base fell back one run too far, the diff held the
# JIG_VERSION change, and the whole suite ran on every platform for a line of
# documentation.
#
# So the list is read unfiltered, where a run whose status has not caught up
# is still visible, and the base is chosen from it:
#
#   - ignored: this run (GITHUB_RUN_ID) and any run with a greater or equal
#     id, which is queued behind it; a run whose head is not in the local
#     history or not an ancestor of HEAD;
#   - the base is the newest run that completed as a success, newest judged by
#     the commit graph, not by the order of the list: a success replaces the
#     best so far when the best is an ancestor of it;
#   - a run could still improve the base when its head is an ancestor of HEAD
#     but not HEAD itself, not an ancestor of the best so far, and it has not
#     completed or has no conclusion yet. While one exists, the script waits
#     CI_GREEN_BASE_WAIT seconds (default 5) and asks again, up to
#     CI_GREEN_BASE_TRIES asks in all (default 6).
#
# When the asks run out, the best proven success is the answer: an older base
# measures more changes and so runs more tests, the safe direction. A run that
# did not succeed is never a base. Nothing proven, a failing `gh` or no
# GITHUB_REPOSITORY prints nothing, and ci-scope.sh then runs everything.
#
# Prints one sha, or nothing. What it chose and whether it waited goes to
# stderr. Exits 0 on every ordinary outcome, 2 on a usage error.
#
# Environment: GITHUB_REPOSITORY (owner/name; set by Actions), GITHUB_RUN_ID
# (set by Actions), GH_TOKEN for `gh`, CI_GREEN_BASE_WAIT and
# CI_GREEN_BASE_TRIES.
#
# Usage: .github/scripts/ci-green-base.sh <branch>
set -eu
set -o pipefail

# _cg_counts <id> <sha> — whether a run is one the base may come from: not
# this run or one queued behind it, and a head in the history of HEAD.
_cg_counts() {
  [ -n "${2:-}" ] || return 1
  if [ -n "${GITHUB_RUN_ID:-}" ]; then
    case "$1" in
      *[!0-9]*) return 1 ;;
    esac
    [ "$1" -lt "$GITHUB_RUN_ID" ] || return 1
  fi
  git cat-file -e "$2^{commit}" 2>/dev/null || return 1
  git merge-base --is-ancestor "$2" HEAD 2>/dev/null
}

# _cg_eval <listing> — read the unfiltered list of runs. Sets CG_BEST to the
# newest proven success and CG_WAITING to a description of a run that could
# still improve it, empty when there is none.
_cg_eval() {
  local listing="$1" id sha status conclusion
  CG_BEST=""
  CG_WAITING=""
  # The best is found over the whole list first: the order of the list says
  # nothing about the graph.
  while read -r id sha status conclusion; do
    _cg_counts "$id" "$sha" || continue
    [ "$status" = completed ] && [ "$conclusion" = success ] || continue
    if [ -z "$CG_BEST" ] || git merge-base --is-ancestor "$CG_BEST" "$sha" 2>/dev/null; then
      CG_BEST="$sha"
    fi
  done <<EOF
$listing
EOF
  while read -r id sha status conclusion; do
    _cg_counts "$id" "$sha" || continue
    [ "$sha" != "$CG_HEAD" ] || continue
    if [ -n "$CG_BEST" ] && git merge-base --is-ancestor "$sha" "$CG_BEST" 2>/dev/null; then
      continue
    fi
    if [ "$status" != completed ] || [ "$conclusion" = none ]; then
      CG_WAITING="run $id ($sha): $status/$conclusion"
      return 0
    fi
  done <<EOF
$listing
EOF
}

main() {
  local branch="${1:-}" slug listing tries wait n=0
  if [ $# -ne 1 ] || [ -z "$branch" ]; then
    printf 'usage: ci-green-base.sh <branch>\n' >&2
    exit 2
  fi

  slug="${GITHUB_REPOSITORY:-}"
  if [ -z "$slug" ]; then
    echo "ci-green-base: GITHUB_REPOSITORY is not set; cannot ask GitHub" >&2
    exit 0
  fi
  CG_HEAD=$(git rev-parse HEAD 2>/dev/null) || {
    echo "ci-green-base: cannot read HEAD" >&2
    exit 0
  }
  tries="${CI_GREEN_BASE_TRIES:-6}"
  wait="${CI_GREEN_BASE_WAIT:-5}"
  case "$tries" in '' | *[!0-9]*) tries=6 ;; esac
  [ "$tries" -ge 1 ] || tries=1
  case "$wait" in '' | *[!0-9]*) wait=5 ;; esac

  CG_BEST=""
  while [ "$n" -lt "$tries" ]; do
    n=$((n + 1))
    listing=$(gh api -X GET "repos/$slug/actions/workflows/ci.yml/runs" \
      -f branch="$branch" -f per_page=100 \
      --jq '.workflow_runs[] | "\(.id) \(.head_sha) \(.status) \(.conclusion // "none")"' \
      2>/dev/null) || {
      echo "ci-green-base: cannot read the runs of ci on $branch" >&2
      [ -z "$CG_BEST" ] || printf '%s\n' "$CG_BEST"
      exit 0
    }
    _cg_eval "$listing"
    [ -n "$CG_WAITING" ] || break
    if [ "$n" -lt "$tries" ]; then
      echo "ci-green-base: waiting for $CG_WAITING (ask $n of $tries)" >&2
      sleep "$wait"
    else
      echo "ci-green-base: still waiting for $CG_WAITING after $n asks; using the proven success" >&2
    fi
  done

  if [ -n "$CG_BEST" ]; then
    echo "ci-green-base: base on $branch is $CG_BEST" >&2
    printf '%s\n' "$CG_BEST"
  else
    echo "ci-green-base: no successful run of ci in the history of HEAD on $branch" >&2
  fi
}

main "$@"
