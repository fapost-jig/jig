#!/usr/bin/env bash
# Verification for the swift profile. Called by `jig verify` from the
# repository root. Exit 0 = pass, 1 = fail, 2 = skip (no check could run).
# Prints one line per check: "swift: <check>: pass|fail|skip (<note>)", the
# check being its role and tool: `build (swift build)`, `tests (swift test)`
# (`checks:` in profile.yaml). Each command line comes from the profile's check
# table through jp_check_cmd (schemas/profile.md, Check table).
#
# Tools come from PATH only (adr-20260918-profiles-narrow-per-check-with-project-tools D2): swift build and swift test are
# both subcommands of the one `swift` binary, so there is no project
# environment to look in. Missing on a machine without an installed
# toolchain (e.g. Windows) is a skip, not a failure (D7).
#
# Narrowing (ADR-0041, adr-20260918-profiles-narrow-per-check-with-project-tools; D4 swift row): swift is never narrowed —
# `swift test --filter` selects by test name, not by changed file, so there
# is no reliable file-to-test mapping for either check. A scoped run still
# runs build and test in full and says `scope: not narrowable, ran full
# set`, with one exception: when every changed path is documentation
# (*.md, docs/**) or the project's map marks it `-` (D5: swift declares no
# filters, only `-` and `ALL`), nothing in the change can affect a build or
# a test, and both checks are skipped instead of run. A map decision other
# than `-` still forces the full run, whatever its own text says — this
# profile has no filter to honour it with.
set -eu
set -o pipefail

# shellcheck source=../../scripts/lib/profile.sh
. "$(dirname "$0")/../../scripts/lib/profile.sh"

jp_begin swift

# _swift_builtin <path> — ALL for anything but documentation; nothing for a
# path that cannot affect a build or a test.
_swift_builtin() {
  case "$1" in
    *.md | docs/*) return 0 ;;
    *) printf 'ALL\n' ;;
  esac
  return 0
}

build_label="build (swift build)"
tests_label="tests (swift test)"

# A check another profile took over (jp_covered) prints its own skip line and
# is left out of everything below, before any tool is looked for.
build_covered=0
tests_covered=0
if jp_covered build "$build_label"; then build_covered=1; fi
if jp_covered tests "$tests_label"; then tests_covered=1; fi

if [ "${JIG_VERIFY_EXPLAIN:-}" = 1 ]; then
  if ! jp_have swift; then
    [ "$build_covered" = 1 ] || jp_plan "$build_label" skip "swift not found on PATH"
    [ "$tests_covered" = 1 ] || jp_plan "$tests_label" skip "swift not found on PATH"
  else
    selection=$(jp_decide _swift_builtin)
    if jp_scoped && [ -z "$selection" ]; then
      [ "$build_covered" = 1 ] || jp_plan "$build_label" skip "only documentation changed"
      [ "$tests_covered" = 1 ] || jp_plan "$tests_label" skip "only documentation changed"
    else
      if [ "$build_covered" = 1 ]; then :
      elif jp_ci_runs_full || jp_check_cmd build "$build_label" full swift; then
        jp_plan_full "$build_label" "swift checks cannot narrow by file"
      fi
      if [ "$tests_covered" = 1 ]; then :
      elif jp_ci_runs_full || jp_check_cmd tests "$tests_label" full swift; then
        jp_plan_full "$tests_label" "swift checks cannot narrow by file"
      fi
    fi
  fi
  exit 0
fi

if ! jp_have swift; then
  [ "$build_covered" = 1 ] || jp_skip "$build_label" "swift not found on PATH"
  [ "$tests_covered" = 1 ] || jp_skip "$tests_label" "swift not found on PATH"
  jp_end
fi

v=""
if [ "$build_covered" = 0 ] || [ "$tests_covered" = 0 ]; then
  v=$(jp_version swift --version)
fi

SWIFT_NOTE=""
SWIFT_SKIP=0
SWIFT_SKIP_REASON=""
if jp_scoped; then
  sel=$(jp_decide _swift_builtin)
  if [ -z "$sel" ]; then
    SWIFT_SKIP=1
    SWIFT_SKIP_REASON="scope: only documentation changed"
  else
    # Any non-empty decision forces the full run, `ALL` or otherwise: this
    # profile declares no filters (D5), so a map token this profile does
    # not recognise still means "something may be affected", not "nothing
    # is".
    SWIFT_NOTE=", scope: not narrowable, ran full set"
  fi
fi

if [ "$SWIFT_SKIP" = 1 ]; then
  [ "$build_covered" = 1 ] || jp_skip "$build_label" "$SWIFT_SKIP_REASON"
  [ "$tests_covered" = 1 ] || jp_skip "$tests_label" "$SWIFT_SKIP_REASON"
else
  if [ "$build_covered" = 1 ]; then :
  else
    jp_full_left_to_ci "$build_label" "not narrowable" \
      || if jp_check_cmd build "$build_label" full swift; then
        jp_run "$build_label" "$v$SWIFT_NOTE" "${JP_CMD[@]}"
      fi
  fi
  if [ "$tests_covered" = 1 ]; then :
  else
    jp_full_left_to_ci "$tests_label" "not narrowable" \
      || if jp_check_cmd tests "$tests_label" full swift; then
        jp_run "$tests_label" "$v$SWIFT_NOTE" "${JP_CMD[@]}"
      fi
  fi
fi

jp_end
