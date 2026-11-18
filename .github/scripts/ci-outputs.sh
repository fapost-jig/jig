#!/usr/bin/env bash
# ci-outputs.sh — the outputs of the `scope` job of .github/workflows/ci.yml,
# decided from the answers of the scripts that measured the run
# (adr-20261110-a-pull-request-runs-the-tests-its-change-reaches,
# adr-20261027-main-is-not-retested-when-a-pull-request-tested-its-tree,
# adr-20261118-main-tests-what-changed-since-a-full-pull-request-run).
#
# The decision lives here and not in the workflow because it decides whether a
# release is tagged, and a rule in workflow shell can be tested only by
# reading its text (0034-releases-are-tagged-by-ci).
#
# Usage: .github/scripts/ci-outputs.sh <scope-line> <reuse-line> [<narrow-scope-line>]
#   <scope-line>   what ci-scope.sh said about this run: `light ...`,
#                  `selected ...` or `full ...` (anything else counts as full).
#   <reuse-line>   what ci-reuse.sh said, or `test (...)` when it was not
#                  asked or failed: `reuse (...; suite: <all|selected>)`,
#                  `narrow <commit> (...)` or `test (...)`.
#   <narrow-scope-line>
#                  with `narrow`: what ci-scope.sh said about the push measured
#                  from the narrow commit. Missing or unreadable counts as full.
#
# Prints `key=value` lines, which the step appends to $GITHUB_OUTPUT:
#
#   full    `false` only for a light run; the knowledge job runs then, and
#           the test shares do not;
#   suite   `none`, `selected` or `all`: what the test shares run, and the
#           word in their names that ci-reuse.sh reads;
#   whole   `true` when the proof behind the run is the whole suite: it ran
#           the whole suite, it reused a pull request's run of the whole
#           suite, or it narrowed from such a run and tests what differs from
#           it. `release` tags only then; `red-main` still reads `suite`;
#   reuse   `true` when the suite's jobs skip because a pull request's run
#           already tested this tree;
#
# and, when the shares must run a selection the caller has to write for the
# matrix, `filters=<tests/run.sh filter>` (the caller keeps it out of
# $GITHUB_OUTPUT and into its filters file).
#
# The rules, in order:
#
#   1. The scope line gives the suite: light is `none`, selected is
#      `selected`, anything else `all`. A light run is never reused.
#   2. `reuse (...)` is reuse=true. Its marker `suite: all` makes it whole;
#      `suite: selected` (a pull request's run of selected tests, covering this
#      push's selection) does not, and neither does a line without a marker.
#   3. `narrow ...` is whole, whatever the difference since the tree that
#      run tested in full is, and the suite follows that difference:
#        - light: the suite is `selected` with the knowledge test as its one
#          filter, and reuse is false. The whole suite passed on the tree the
#          difference starts from, but a knowledge document of the difference
#          can break against it (a link to a file the pull request removed),
#          and a light push checks exactly that, so the merged tree gets that
#          check on every share;
#        - selected: the suite is `selected`, the shares run the selection the
#          caller measured, reuse is false;
#        - anything else: the whole suite runs, reuse is false.
#   4. The suite `all` is whole.
set -eu

CO_KNOWLEDGE_TEST="knowledge::test_real_repository_knowledge_passes_with_no_failures"

main() {
  local scope="${1:-}" reuse="${2:-}" nscope="${3:-}"
  local suite=all whole=false reu=false filters=""
  [ $# -ge 2 ] && [ $# -le 3 ] || { printf 'usage: ci-outputs.sh <scope-line> <reuse-line> [<narrow-scope-line>]\n' >&2; exit 2; }

  case "$scope" in
    light*) suite=none ;;
    selected*) suite=selected ;;
  esac

  if [ "$suite" != none ]; then
    case "$reuse" in
      reuse*)
        reu=true
        case "$reuse" in *"suite: all"*) whole=true ;; esac
        ;;
      narrow*)
        whole=true
        case "$nscope" in
          light*) suite=selected; filters=$CO_KNOWLEDGE_TEST ;;
          selected*) suite=selected ;;
          *) suite=all ;;
        esac
        ;;
    esac
  fi
  [ "$suite" != all ] || whole=true

  if [ "$suite" = none ]; then echo "full=false"; else echo "full=true"; fi
  echo "suite=$suite"
  echo "whole=$whole"
  echo "reuse=$reu"
  [ -z "$filters" ] || echo "filters=$filters"
}

main "$@"
