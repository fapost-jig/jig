#!/usr/bin/env bash
# ci-untested-base.sh — whether a pull request's base branch is one whose pull
# requests run no test suite. Run by the `scope` job of .github/workflows/ci.yml.
#
# Usage: ci-untested-base.sh <event> [<base_ref>]
#   <event>     github.event_name
#   <base_ref>  github.base_ref (only a pull request has one)
#
# Prints one line, `skip (...)` or `test (...)`, and why:
#
#   - skip: a pull request whose base is exactly a name in UNTESTED_BASES. The
#     stack-migration spec tests those changes locally and by a manual
#     dispatch, so CI runs the knowledge check only (the scope is `light`);
#   - test: everything else — other bases, and every event but a pull request.
#     A pull request from the epic into main has base `main` and stays full.
#
# The names are compared whole: `epic/stack-migration-2` is not
# `epic/stack-migration`. Nothing is read from a pull request's own content.
set -eu
set -o pipefail

# Branches whose pull requests run no tests, one per line. Remove the line
# when the migration's epic reaches main.
UNTESTED_BASES='epic/stack-migration'

main() {
  local event="${1:-}" base="${2:-}" name
  if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    printf 'ci-untested-base: usage: ci-untested-base.sh <event> [<base_ref>]\n' >&2
    exit 2
  fi
  if [ "$event" = pull_request ] && [ -n "$base" ]; then
    while IFS= read -r name; do
      if [ "$name" = "$base" ]; then
        printf 'skip (pull requests into %s run no tests: the stack-migration spec tests them locally and by a manual dispatch)\n' "$base"
        return 0
      fi
    done <<EOT
$UNTESTED_BASES
EOT
  fi
  printf 'test (%s into %s runs what its scope needs)\n' "$event" "${base:--}"
}

main "$@"
