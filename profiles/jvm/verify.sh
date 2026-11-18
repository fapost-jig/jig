#!/usr/bin/env bash
# Verification for the jvm profile. Called by `jig verify` from the
# repository root. Exit 0 = pass, 1 = fail, 2 = skip (no check could run).
# Prints one line per check: "jvm: <check>: pass|fail|skip (<note>)".
#
# One role, `tests` (`checks:` in profile.yaml), run by whichever build
# systems the project has; the tool is in the label: `tests (gradle check)`,
# `tests (mvn test)`. Every command line comes from the profile's check table
# through jp_check_cmd (schemas/profile.md, Check table); what the table leaves
# to this script is the tool chosen at run time -- the wrapper, and the words
# `check` (Gradle) and `test` (Maven) that name the tool's own task.
#
# Two build systems, each optional and independent (adr-20260918-profiles-narrow-per-check-with-project-tools): Gradle, when
# a Gradle build file sits at the repository root -- the project's own
# `./gradlew` first, `gradle` from PATH otherwise; `check`. Maven,
# when a root `pom.xml` exists -- `./mvnw` first, `mvn` from PATH otherwise;
# `test`. A project that has both runs both; a project that has
# neither (the profile activated without either manifest) skips both,
# naming what it looked for. `gradlew`/`mvnw` are run through `sh`, never
# through their own executable bit: a checkout that lost +x (common coming
# from Windows) must not turn into "command not found".
#
# Narrowing (ADR-0041, adr-20260918-profiles-narrow-per-check-with-project-tools), per check: a changed file maps to the
# nearest ancestor directory *below the repository root* that holds a
# build.gradle(.kts) (Gradle) or a pom.xml (Maven) -- a root-level build
# file is deliberately not a candidate here, it is one of the "always ALL"
# triggers below instead. Gradle turns that directory into the task
# `:<dir, / replaced by :>:check`; Maven turns it into `-pl <dir> -am
# test`. A path with no such ancestor (outside every subproject) runs the
# full set, with a reason. A root build/settings file, `gradle/**`,
# `gradlew*` or `gradle.properties` sends Gradle's check to its full set; a
# root `pom.xml`, `.mvn/**` or `mvnw*` sends Maven's. A project map's
# filters, like the built-in ones, are subproject or module *paths*: a
# project map cannot know Gradle's task syntax, and a path is what
# `schemas/verify-map.md` documents for this profile.
set -eu
set -o pipefail

# shellcheck source=../../scripts/lib/profile.sh
. "$(dirname "$0")/../../scripts/lib/profile.sh"

jp_begin jvm

HAS_GRADLE=0
if [ -f build.gradle ] || [ -f build.gradle.kts ] \
   || [ -f settings.gradle ] || [ -f settings.gradle.kts ]; then
  HAS_GRADLE=1
fi
HAS_MAVEN=0
[ -f pom.xml ] && HAS_MAVEN=1

# The label of each build system's check: the role, the tool in parentheses.
GRADLE_LABEL="tests (gradle check)"
MVN_LABEL="tests (mvn test)"

# The one role covers both build systems: when another profile took `tests`
# over (jp_covered), the label of each build system the project has prints its
# own skip line and is left out of everything below, before any tool is looked
# for. A project with neither asks with both labels, the two lines it prints
# uncovered.
gradle_covered=0
mvn_covered=0
if [ "$HAS_GRADLE" = 1 ] || [ "$HAS_MAVEN" = 0 ]; then
  if jp_covered tests "$GRADLE_LABEL"; then gradle_covered=1; fi
fi
if [ "$HAS_MAVEN" = 1 ] || [ "$HAS_GRADLE" = 0 ]; then
  if jp_covered tests "$MVN_LABEL"; then mvn_covered=1; fi
fi

if [ "$HAS_GRADLE" = 0 ] && [ "$HAS_MAVEN" = 0 ]; then
  if [ "${JIG_VERIFY_EXPLAIN:-}" = 1 ]; then
    [ "$gradle_covered" = 1 ] || jp_plan "$GRADLE_LABEL" skip "no root Gradle build"
    [ "$mvn_covered" = 1 ] || jp_plan "$MVN_LABEL" skip "no root pom.xml"
    exit 0
  fi
  [ "$gradle_covered" = 1 ] || jp_skip "$GRADLE_LABEL" "no build.gradle(.kts) or settings.gradle(.kts) at the repository root"
  [ "$mvn_covered" = 1 ] || jp_skip "$MVN_LABEL" "no pom.xml at the repository root"
  jp_end
fi

# --- module/subproject resolution, shared shape for both build systems -----

# _jvm_nearest_module <marker> <path> — the nearest ancestor directory of
# <path>, strictly below the repository root, that directly contains a file
# matching <marker> (a case pattern: "build.gradle|build.gradle.kts" or
# "pom.xml"). Nothing when no such ancestor exists (the path is outside
# every subproject, or there is only the root project). Not inlined into a
# `$( )`: bash 3.2 misparses a `case` there.
_jvm_nearest_module() {
  local marker="$1" f="$2" dir
  dir=$(dirname "$f")
  while [ "$dir" != "." ]; do
    if _jvm_dir_has "$marker" "$dir"; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

# _jvm_dir_has <marker> <dir> — <dir> directly contains a file matching
# <marker>. A filesystem check, not a scan of tracked files: build.gradle(.kts)
# and pom.xml are fixed, conventional names, so there is nothing to search
# for beyond the path itself.
_jvm_dir_has() {
  case "$1" in
    'build.gradle|build.gradle.kts')
      [ -f "$2/build.gradle" ] || [ -f "$2/build.gradle.kts" ] ;;
    pom.xml)
      [ -f "$2/pom.xml" ] ;;
    *)
      return 1 ;;
  esac
}

# _jvm_join <sep> <arg>... — <arg>s joined by <sep>, e.g. for Maven's
# comma-separated `-pl`.
_jvm_join() {
  local sep="$1" out="" a
  shift
  for a in "$@"; do
    if [ -z "$out" ]; then out="$a"; else out="$out$sep$a"; fi
  done
  printf '%s\n' "$out"
}

_jvm_gradle_always_all() {
  case "$1" in
    build.gradle|build.gradle.kts|settings.gradle|settings.gradle.kts| \
    gradle.properties|gradlew*|gradle/*) return 0 ;;
  esac
  return 1
}

_jvm_gradle_builtin() {
  local f="$1" dir
  if jp_is_doc "$f"; then return 0; fi
  if _jvm_gradle_always_all "$f"; then printf 'ALL\n'; return 0; fi
  if dir=$(_jvm_nearest_module 'build.gradle|build.gradle.kts' "$f"); then
    printf '%s\n' "$dir"
  else
    printf 'ALL\n'
  fi
  return 0
}

_jvm_maven_always_all() {
  case "$1" in
    pom.xml|mvnw*|.mvn/*) return 0 ;;
  esac
  return 1
}

_jvm_maven_builtin() {
  local f="$1" dir
  if jp_is_doc "$f"; then return 0; fi
  if _jvm_maven_always_all "$f"; then printf 'ALL\n'; return 0; fi
  if dir=$(_jvm_nearest_module pom.xml "$f"); then
    printf '%s\n' "$dir"
  else
    printf 'ALL\n'
  fi
  return 0
}

# _jvm_explain_cmd <label> <filters> <default-cmd>... -- under `--explain`,
# exit 0 when the check table can build the command line the planned run
# would use: `narrowed` for a selection of subprojects or modules, `full`
# otherwise (everything, or a fallback to the full set). When it cannot,
# jp_check_cmd has printed the check's PLAN line.
_jvm_explain_cmd() {
  local label="$1" filters="$2"
  shift 2
  if jp_scoped && [ "$filters" != ALL ]; then
    jp_check_cmd tests "$label" narrowed "$@" -- "$filters"
  else
    jp_check_cmd tests "$label" full "$@"
  fi
}

if [ "${JIG_VERIFY_EXPLAIN:-}" = 1 ]; then
  if [ "$gradle_covered" = 1 ]; then
    :
  elif [ "$HAS_GRADLE" = 0 ]; then
    jp_plan "$GRADLE_LABEL" skip "no root Gradle build"
  elif [ ! -f ./gradlew ] && ! jp_have gradle; then
    jp_plan "$GRADLE_LABEL" skip "gradlew not found and gradle not found on PATH"
  else
    jp_select _jvm_gradle_builtin
    filters=$JP_SELECTION
    if [ -n "$filters" ] && [ "$filters" != ALL ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ ! -e "$f" ]; then filters=ALL; break; fi
      done <<EOF
$filters
EOF
    fi
    if jp_scoped && [ -z "$filters" ]; then
      jp_plan_select "$GRADLE_LABEL" "$filters" "Gradle subprojects"
    elif _jvm_explain_cmd "$GRADLE_LABEL" "$filters" gradle check; then
      jp_plan_select "$GRADLE_LABEL" "$filters" "Gradle subprojects"
    fi
  fi
  if [ "$mvn_covered" = 1 ]; then
    :
  elif [ "$HAS_MAVEN" = 0 ]; then
    jp_plan "$MVN_LABEL" skip "no root pom.xml"
  elif [ ! -f ./mvnw ] && ! jp_have mvn; then
    jp_plan "$MVN_LABEL" skip "mvnw not found and mvn not found on PATH"
  else
    jp_select _jvm_maven_builtin
    filters=$JP_SELECTION
    if [ -n "$filters" ] && [ "$filters" != ALL ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ ! -e "$f" ]; then filters=ALL; break; fi
      done <<EOF
$filters
EOF
    fi
    if jp_scoped && [ -z "$filters" ]; then
      jp_plan_select "$MVN_LABEL" "$filters" "Maven modules"
    elif _jvm_explain_cmd "$MVN_LABEL" "$filters" mvn test; then
      jp_plan_select "$MVN_LABEL" "$filters" "Maven modules"
    fi
  fi
  exit 0
fi

# --- Gradle ------------------------------------------------------------------

if [ "$gradle_covered" = 0 ] && [ "$HAS_GRADLE" = 1 ]; then
  # The command as words, run through jp_run/jp_exec so it reaches the
  # project's environment: the wrapper via sh (+x-independent), or gradle
  # from the PATH of wherever the project runs.
  GRADLE_CMD=()
  if [ -f ./gradlew ]; then
    GRADLE_CMD=(sh ./gradlew)
  elif jp_have gradle; then
    GRADLE_CMD=(gradle)
  fi

  if [ "${#GRADLE_CMD[@]}" -eq 0 ]; then
    jp_skip "$GRADLE_LABEL" "gradlew not found and gradle not found on PATH"
  else
    # Not jp_version: the real Gradle CLI's `--version` banner starts with
    # a blank line, so jp_version's plain first-line capture always reports
    # "unknown" for it -- a gap in the shared library, worth a version this
    # profile can actually name (RULES.md: the verdict names the tool's
    # version so "green here, red there" has a visible cause). Same
    # guarantee as jp_version: guarded, so a tool that cannot answer this
    # way never fails the check it only annotates.
    gv=$(jp_exec "${GRADLE_CMD[@]}" --version 2>/dev/null | sed -n 's/^Gradle //p' | sed -n '1p') || gv=""
    [ -n "$gv" ] || gv="unknown"

    # _jvm_gradle_always_all <path> — a root build/settings file, the
    # wrapper's own files, or gradle.properties: none of these belong to one
    # subproject.
    # _jvm_gradle_builtin <path> — the subproject directory a changed path
    # belongs to (D4), or ALL for an always-ALL file or a path outside every
    # subproject.
    # _jvm_gradle_run <note> [<task>...] — `check`, or the given tasks. The
    # table holds no tool words for Gradle (the wrapper is chosen above), so
    # the full run's default is `<gradle> check` and the narrowed run's is
    # `<gradle>` alone, followed by the tasks the table's `{selection}` places.
    _jvm_gradle_run() {
      local note="$1"
      shift
      if [ $# -eq 0 ]; then
        if jp_check_cmd tests "$GRADLE_LABEL" full "${GRADLE_CMD[@]}" check; then
          jp_run "$GRADLE_LABEL" "$note" "${JP_CMD[@]}"
        fi
      else
        if jp_check_cmd tests "$GRADLE_LABEL" narrowed "${GRADLE_CMD[@]}" -- "$@"; then
          jp_run "$GRADLE_LABEL" "$note" "${JP_CMD[@]}"
        fi
      fi
    }

    if ! jp_scoped; then
      _jvm_gradle_run "$gv"
    else
      jp_select _jvm_gradle_builtin
      filters=$JP_SELECTION
      if [ -z "$filters" ]; then
        jp_skip "$GRADLE_LABEL" "scope: no changed file maps to a subproject"
      elif [ "$filters" = ALL ]; then
        jp_full_left_to_ci "$GRADLE_LABEL" "not narrowable" \
          || _jvm_gradle_run "$gv, scope: not narrowable, ran full set"
      else
        IFS='
'
        set -f
        # shellcheck disable=SC2086
        set -- $filters
        set +f
        IFS=$' \t\n'
        if missing=$(jp_first_missing "$@"); then
          jp_full_left_to_ci "$GRADLE_LABEL" "filter '$missing' selects no tests" \
            || _jvm_gradle_run "$gv, scope: filter '$missing' selects no tests, ran full set"
        else
          n=$#
          # One subproject directory per line -> one Gradle task per line,
          # `:` for `/`, ":check" appended; a second IFS-newline `set --`
          # turns them into _jvm_gradle_run's argument list.
          tasks=$(for d in "$@"; do
            printf ':%s:check\n' "$(printf '%s' "$d" | tr '/' ':')"
          done)
          IFS='
'
          set -f
          # shellcheck disable=SC2086
          set -- $tasks
          set +f
          IFS=$' \t\n'
          _jvm_gradle_run "$gv, scope: $n subprojects$JP_SELECTION_NOTE" "$@"
        fi
      fi
    fi
  fi
fi

# --- Maven -------------------------------------------------------------------

if [ "$mvn_covered" = 0 ] && [ "$HAS_MAVEN" = 1 ]; then
  MVN_CMD=()
  if [ -f ./mvnw ]; then
    MVN_CMD=(sh ./mvnw)
  elif jp_have mvn; then
    MVN_CMD=(mvn)
  fi

  if [ "${#MVN_CMD[@]}" -eq 0 ]; then
    jp_skip "$MVN_LABEL" "mvnw not found and mvn not found on PATH"
  else
    mv_=$(jp_version "${MVN_CMD[@]}" --version)

    # _jvm_maven_always_all <path> — the root pom.xml, `.mvn/**` or the
    # wrapper's own files: none of these belong to one module.
    # _jvm_maven_builtin <path> — the module directory a changed path
    # belongs to (D4), or ALL for an always-ALL file or a path outside every
    # module.
    # _jvm_maven_run <note> [-pl <modules> -am] — `test`, narrowed or not.
    # As for Gradle, the table holds no tool words: the full run's default is
    # `<mvn> test`; the narrowed run's is `<mvn>` followed by the selection,
    # and `test` goes after the selection here, because Maven reads its goal
    # last and the table's `{selection}` is the options before it.
    _jvm_maven_run() {
      local note="$1"
      shift
      if [ $# -eq 0 ]; then
        if jp_check_cmd tests "$MVN_LABEL" full "${MVN_CMD[@]}" test; then
          jp_run "$MVN_LABEL" "$note" "${JP_CMD[@]}"
        fi
      else
        if jp_check_cmd tests "$MVN_LABEL" narrowed "${MVN_CMD[@]}" -- "$@"; then
          jp_run "$MVN_LABEL" "$note" "${JP_CMD[@]}" test
        fi
      fi
    }

    if ! jp_scoped; then
      _jvm_maven_run "$mv_"
    else
      jp_select _jvm_maven_builtin
      filters=$JP_SELECTION
      if [ -z "$filters" ]; then
        jp_skip "$MVN_LABEL" "scope: no changed file maps to a module"
      elif [ "$filters" = ALL ]; then
        jp_full_left_to_ci "$MVN_LABEL" "not narrowable" \
          || _jvm_maven_run "$mv_, scope: not narrowable, ran full set"
      else
        IFS='
'
        set -f
        # shellcheck disable=SC2086
        set -- $filters
        set +f
        IFS=$' \t\n'
        if missing=$(jp_first_missing "$@"); then
          jp_full_left_to_ci "$MVN_LABEL" "filter '$missing' selects no tests" \
            || _jvm_maven_run "$mv_, scope: filter '$missing' selects no tests, ran full set"
        else
          n=$#
          joined=$(_jvm_join , "$@")
          _jvm_maven_run "$mv_, scope: $n modules$JP_SELECTION_NOTE" -pl "$joined" -am
        fi
      fi
    fi
  fi
fi

jp_end
