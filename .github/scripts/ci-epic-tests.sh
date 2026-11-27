#!/usr/bin/env bash
# ci-epic-tests.sh — which tests a run on an epic branch runs by default, instead of the whole bash
# suite. Run by the `scope` job of .github/workflows/ci.yml, for a push to a branch and for a manual
# dispatch whose `tests` input is empty.
#
# Usage: ci-epic-tests.sh <branch>
#
# Prints one line, `tests <filter>...` or `whole (...)`:
#
#   - tests: <branch> is exactly a name in EPIC_TESTS. The stack-migration epic changes no bash
#     (.ai/specs/stack-migration/spec.md): its CI runs the new stack's tests and the parity check of
#     the ported commands, which records only those commands' bash tests. The filters are
#     tests/run.sh's (`<file>::` or `<file>::<test>`);
#   - whole: every other branch, main included, runs what its scope decides.
#
# The whole bash suite still runs on main, and once before the epic lands there.
set -eu
set -o pipefail

# One line per epic: the branch, a tab, its filters. Remove the line when the epic reaches main.
EPIC_TESTS='epic/stack-migration	next-ts:: next-go:: parity:: parity-ports:: recorder:: dispatcher::test_version_prints_semver dispatcher::test_version_rejects_an_unknown_option'

main() {
  local branch="${1:-}" name filters
  if [ $# -ne 1 ]; then
    printf 'ci-epic-tests: usage: ci-epic-tests.sh <branch>\n' >&2
    exit 2
  fi
  while IFS=$'\t' read -r name filters; do
    if [ -n "$branch" ] && [ "$name" = "$branch" ]; then
      printf 'tests %s\n' "$filters"
      return 0
    fi
  done <<EOT
$EPIC_TESTS
EOT
  printf 'whole (%s runs what its scope decides)\n' "${branch:--}"
}

main "$@"
