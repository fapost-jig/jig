#!/usr/bin/env bash
# ci-nightly-tested.sh — decide whether the nightly run on main may skip the
# suite because the tree main has now was already tested whole by an earlier
# nightly run (adr-20261027-main-is-not-retested-when-a-pull-request-tested-its-tree,
# as amended). Run by the `scope` job of .github/workflows/ci.yml, in the root
# of a full checkout of main, on a `schedule` event.
#
# Why: the nightly run exists to run the whole suite against main whatever the
# tests a pull request chose to run, and to catch a map line that let a change
# skip a test it needed. Run on a tree it already tested, it only repeats
# itself: the same tests, on the same files, on every platform. A suite that
# ran once on a tree does not need to run again on it.
#
# Prints one line:
#
#   - tested (<run url> ...): the nightly run is light. Both hold:
#       (a) the newest completed run of `ci` on main, from a push or the
#           nightly schedule, concluded `success`: main is green now. A run
#           that was cancelled or skipped says nothing about main and is
#           looked past; a manual dispatch is not main's own run;
#       (b) the newest successful `schedule` run of `ci` on main has a head
#           commit whose tree is the tree of HEAD. That run either ran the
#           whole suite or was light for the same reason as this one, so the
#           tree was tested whole at the start of the chain. A tree that
#           moved and came back (a revert) is the same tree and counts;
#   - test (<why>): anything else. The whole suite runs as it always did.
#
# Unmeasurable is never a reason to skip: a GitHub API that does not answer, a
# run whose commit cannot be read, no GITHUB_REPOSITORY — each prints `test`.
# A light nightly is green and has no per-test reports; the plan step of
# ci.yml looks past it for durations.
#
# Environment: GITHUB_REPOSITORY (owner/name; set by Actions) and GH_TOKEN for
# `gh`.
#
# Usage: .github/scripts/ci-nightly-tested.sh
set -eu
set -o pipefail

_nt_line() {
  printf '%s (%s)\n' "$1" "$2"
  exit 0
}

# _nt_have <sha> — make <sha> readable locally, fetching it when the checkout
# does not have it.
_nt_have() {
  git cat-file -e "$1^{commit}" 2>/dev/null && return 0
  git fetch -q --depth=1 origin "$1" 2>/dev/null || return 1
  git cat-file -e "$1^{commit}" 2>/dev/null
}

main() {
  local slug listing sched event status conclusion url sha tree head_tree
  local main_url="" main_conclusion=""
  [ $# -eq 0 ] || { printf 'usage: ci-nightly-tested.sh\n' >&2; exit 2; }

  slug="${GITHUB_REPOSITORY:-}"
  [ -n "$slug" ] || _nt_line test "GITHUB_REPOSITORY is not set; cannot ask GitHub"
  head_tree=$(git rev-parse 'HEAD^{tree}' 2>/dev/null) || _nt_line test "cannot read the tree of HEAD"

  listing=$(gh api -X GET "repos/$slug/actions/workflows/ci.yml/runs" \
    -f branch=main -f per_page=50 \
    --jq '.workflow_runs[] | "\(.id) \(.event) \(.status) \(.conclusion // "none") \(.html_url)"' \
    2>/dev/null) || _nt_line test "cannot read the runs of ci on main"
  while read -r _ event status conclusion url; do
    [ -n "${url:-}" ] || continue
    case "$event" in push | schedule) ;; *) continue ;; esac
    [ "$status" = completed ] || continue
    case "$conclusion" in cancelled | skipped | neutral | none) continue ;; esac
    main_url=$url
    main_conclusion=$conclusion
    break
  done <<EOF
$listing
EOF
  [ -n "$main_url" ] || _nt_line test "no finished run of ci on main to say it is green"
  [ "$main_conclusion" = success ] || _nt_line test "the newest finished run on main ended as '$main_conclusion': $main_url"

  sched=$(gh api -X GET "repos/$slug/actions/workflows/ci.yml/runs" \
    -f branch=main -f event=schedule -f status=success -f per_page=1 \
    --jq '.workflow_runs[0] | select(. != null) | "\(.id) \(.head_sha) \(.html_url)"' \
    2>/dev/null) || _nt_line test "cannot read the nightly runs of ci"
  [ -n "$sched" ] || _nt_line test "no successful nightly run yet"
  read -r _ sha url <<EOF
$sched
EOF
  [ -n "${url:-}" ] || _nt_line test "cannot read the last successful nightly run"
  _nt_have "$sha" || _nt_line test "the commit $sha of the last nightly run cannot be read: $url"
  tree=$(git rev-parse "$sha^{tree}" 2>/dev/null) || _nt_line test "cannot read the tree of $sha"
  if [ "$tree" != "$head_tree" ]; then
    _nt_line test "the last successful nightly run tested tree $tree, main has $head_tree: $url"
  fi
  _nt_line tested "$url tested tree $tree; main is green in $main_url"
}

main "$@"
