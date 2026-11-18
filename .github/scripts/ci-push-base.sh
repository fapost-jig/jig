#!/usr/bin/env bash
# ci-push-base.sh — the commit a push is measured from, and whether it adds
# anything at all (adr-20260924-windows-runs-on-a-pull-request-that-touches-platform-behaviour,
# amendment of 2026-11-17; adr-0040-epic-branches-release-a-feature-once).
# Run by the `scope` job of .github/workflows/ci.yml in the root of a full
# checkout (every branch fetched, so `origin/main` exists), on a push.
#
# Usage: .github/scripts/ci-push-base.sh <branch> <green-sha>
#   <green-sha> is the head of the branch's last successful run, empty when
#   there is none or the API did not answer.
#
# Prints one line, which starts with one of three words:
#
#   - base <sha> (<why>): measure the push from <sha>. It is <green-sha>, and
#     for an epic branch with no such run, where the branch left main
#     (`git merge-base origin/main HEAD`): what main holds was tested on main,
#     on every platform, so only what the epic added needs testing;
#   - empty <sha> (<why>): an epic branch whose base is HEAD itself, so it holds
#     nothing beyond what was already tested — a branch just cut from main, or
#     one synced to main and nothing else (`jig spec ship` pushes such an epic).
#     Without this the empty diff reads as unmeasurable and the whole suite
#     runs on every platform. The workflow answers `light` and `skip`. A rerun
#     of a green commit is the same case: the same tree already passed;
#   - none (<why>): no base. ci-scope.sh then runs everything, as it always
#     did. Every branch other than `epic/**` gets <green-sha> or this.
#
# Exit 0 always: an answer of `none` is the safe one.
set -eu
set -o pipefail

main() {
  local branch="${1:-}" green="${2:-}" base="" why="" head=""
  [ $# -eq 2 ] || { printf 'usage: ci-push-base.sh <branch> <green-sha>\n' >&2; exit 2; }

  case "$branch" in
    epic/*) ;;
    *)
      if [ -n "$green" ]; then
        printf 'base %s (last successful run)\n' "$green"
      else
        printf 'none (no successful run on %s)\n' "$branch"
      fi
      return 0
      ;;
  esac

  if [ -n "$green" ]; then
    base="$green"
    why="last successful run"
  else
    base=$(git merge-base origin/main HEAD 2>/dev/null) || base=""
    why="merge-base with main"
    if [ -z "$base" ]; then
      printf 'none (no successful run on %s and no merge-base with origin/main)\n' "$branch"
      return 0
    fi
  fi

  head=$(git rev-parse HEAD 2>/dev/null) || head=""
  if [ -n "$head" ] && [ "$base" = "$head" ]; then
    printf 'empty %s (%s is HEAD: the branch holds nothing beyond what was tested)\n' "$base" "$why"
  else
    printf 'base %s (%s)\n' "$base" "$why"
  fi
}

main "$@"
