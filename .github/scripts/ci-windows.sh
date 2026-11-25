#!/usr/bin/env bash
# ci-windows.sh — whether the Windows test shards run
# (the 2026-11-25 amendments of
# adr-20260924-windows-runs-on-a-pull-request-that-touches-platform-behaviour
# and adr-20261110-a-pull-request-runs-the-tests-its-change-reaches). Run by
# the `scope` job of .github/workflows/ci.yml.
#
# Usage: ci-windows.sh <event> [<branch>]
#   <event>   github.event_name
#   <branch>  github.ref_name (only a push's branch matters)
#
# Prints one line, `windows (...)` or `skip (...)`, and why:
#
#   - skip: a pull request, and a push to `epic/**` (an epic reaches main
#     through a pull request). Ten Windows shares held a pull request for
#     ~45 minutes (#647), and main repeats the whole suite after the merge;
#   - windows: everything else — main's push, the nightly run and a manual
#     dispatch run every platform, and `release` tags only on a whole main
#     run. A break only Windows shows is a red main, not a red pull request.
#
# `smoke-windows` is not decided here: it runs on every full scope.
set -eu

main() {
  local event="${1:-}" branch="${2:-}"
  [ $# -ge 1 ] && [ $# -le 2 ] || { printf 'ci-windows: usage: ci-windows.sh <event> [<branch>]\n' >&2; exit 2; }
  case "$event:$branch" in
    pull_request:* | push:epic/*)
      printf 'skip (%s leaves Windows to main, nightly and manual runs)\n' "$event"
      ;;
    *) printf 'windows (%s runs every platform)\n' "$event" ;;
  esac
}

main "$@"
