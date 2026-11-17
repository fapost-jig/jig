# Tests for scripts/lib/profiles.sh (domains/verify).
# shellcheck shell=bash
# Every profiles_harness call below intentionally passes a single-quoted
# script containing $VAR references meant to expand inside the harness's
# inner `bash -c`, not at this call site (same pattern as fm_harness in
# frontmatter.t.sh).
# shellcheck disable=SC2016

# profiles_harness <script> — run <script> with profiles.sh (and its
# dependencies common.sh/config.sh) sourced. JIG_LIB points at the real
# framework checkout ($JIG_HOME); JIG_PROJECT is the current directory
# (a fixture repository set up by the caller).
profiles_harness() {
  run bash -c '
    JIG_LIB="$JIG_HOME/scripts/lib"
    JIG_PROJECT="$(pwd)"
    export JIG_LIB JIG_PROJECT
    . "$JIG_LIB/common.sh"
    . "$JIG_LIB/config.sh"
    . "$JIG_LIB/profiles.sh"
  '"$1"
}

# --- profile_get ---------------------------------------------------------------

test_profile_get_reads_scalar() {
  fixture_repo
  mkdir -p fx
  cat > fx/profile.yaml <<'EOF'
name: fixture
description: A test fixture profile.
detect: always
EOF
  profiles_harness 'profile_get "$PWD/fx" name'
  assert_eq 0 "$RC"
  assert_eq "fixture" "$OUT"

  profiles_harness 'profile_get "$PWD/fx" description'
  assert_eq "A test fixture profile." "$OUT"
}

test_profile_get_missing_key_prints_nothing() {
  fixture_repo
  mkdir -p fx
  printf 'name: fixture\n' > fx/profile.yaml
  profiles_harness 'profile_get "$PWD/fx" requires'
  assert_eq 0 "$RC"
  assert_eq "" "$OUT"
}

test_profile_get_missing_file_prints_nothing() {
  fixture_repo
  profiles_harness 'profile_get "$PWD/does-not-exist" name'
  assert_eq 0 "$RC"
  assert_eq "" "$OUT"
}

test_profile_get_on_real_generic_profile() {
  fixture_repo
  profiles_harness 'profile_get "$JIG_HOME/profiles/generic" detect'
  assert_eq "always" "$OUT"
}

# profile_get was `sed | sed | head` and _profiles_list_lines a `sed`, a `tr`
# and two more `sed`: a process per key of every profile `init` looks at. Read
# with builtins they answer the same for every shape a profile.yaml line takes.
test_profile_get_answers_what_the_sed_it_replaced_answered() {
  fixture_repo
  mkdir -p fx
  {
    printf 'name: fixture   # a comment\n'
    printf 'spaced:    two words   \n'
    printf 'hash: a#b\n'
    printf 'empty:\n'
    printf 'twice: first\n'
    printf 'twice: second\n'
    printf 'crlf: value\r\n'
    printf 'detect: [composer.json, "src/**/*.php"]\n'
    printf ' indented: no\n'
    printf 'last: no newline'
  } > fx/profile.yaml
  profiles_harness '
    was() {
      sed -n "s/^${1}:[[:space:]]*//p" "$PWD/fx/profile.yaml" | sed "s/[[:space:]]*#.*//; s/[[:space:]]*\$//" | head -n 1
    }
    for key in name spaced hash empty twice crlf detect indented last absent; do
      now=$(profile_get "$PWD/fx" "$key")
      [ "$(was "$key")" = "$now" ] || printf "%s: was <%s> now <%s>\n" "$key" "$(was "$key")" "$now"
      printf "%s=<%s> " "$key" "$now"
    done
    profile_get_v v "$PWD/fx" name && printf "v=<%s> " "$v"
    profile_get_v v "$PWD/none" name || printf "none=<%s>" "$v"
  '
  assert_eq 0 "$RC"
  assert_eq 'name=<fixture> spaced=<two words> hash=<a> empty=<> twice=<first> crlf=<value> detect=<[composer.json, "src/**/*.php"]> indented=<> last=<no newline> absent=<> v=<fixture> none=<>' "$OUT"
}

test_profiles_list_lines_answers_what_the_pipeline_it_replaced_answered() {
  fixture_repo
  mkdir -p fx
  {
    printf 'plain: [a, b, c]\n'
    printf 'tight: [a,b]\n'
    printf 'quoted: ["src/**/*.php", "a b" , c]   # globs\n'
    printf 'holes: [a,, b, ]\n'
    printf 'none: []\n'
    printf 'scalar: always\n'
    printf 'half: "a, b"\n'
    printf 'lone: ["]\n'
  } > fx/profile.yaml
  profiles_harness '
    was() {
      raw=$(profile_get "$PWD/fx" "$1")
      case "$raw" in
        \[*\])
          raw=$(printf "%s" "$raw" | sed "s/^\[//; s/\]\$//")
          printf "%s\n" "$raw" | tr "," "\n" \
            | sed "s/^[[:space:]]*//; s/[[:space:]]*\$//; s/^\"\(.*\)\"\$/\1/" \
            | sed "/^\$/d"
          ;;
      esac
    }
    for key in plain tight quoted holes none scalar half lone absent; do
      now=$(_profiles_list_lines "$PWD/fx" "$key" | tr "\n" "|")
      [ "$(was "$key" | tr "\n" "|")" = "$now" ] || printf "%s: was <%s> now <%s>\n" "$key" "$(was "$key" | tr "\n" "|")" "$now"
      printf "%s=<%s> " "$key" "$now"
    done
    _profiles_list_lines "$PWD/none" plain; printf "rc=%s" "$?"
  '
  assert_eq 0 "$RC"
  assert_eq 'plain=<a|b|c|> tight=<a|b|> quoted=<src/**/*.php|a b|c|> holes=<a|b|> none=<> scalar=<> half=<> lone=<"|> absent=<> rc=0' "$OUT"
}

test_profiles_glob_to_findpath_collapses_double_stars() {
  fixture_repo
  profiles_harness '
    for glob in "src/**/*.php" "**/*.sh" "a/**" "plain.json" "a/***/b" "****"; do
      was=$(printf "%s" "$glob" | sed "s#[*][*]/#*#g; s#[*][*]#*#g")
      _profiles_glob_to_findpath_v now "$glob"
      [ "$was" = "$now" ] || printf "%s: was <%s> now <%s>\n" "$glob" "$was" "$now"
      printf "<%s> " "$now"
    done
  '
  assert_eq 0 "$RC"
  assert_eq "<src/*.php> <*.sh> <a/*> <plain.json> <a/*b> <**> " "$OUT"
}

# --- profiles_active -------------------------------------------------------

test_profiles_active_defaults_to_generic() {
  fixture_repo
  mkdir -p .ai
  printf 'profiles: []\n' > .ai/config.yaml
  profiles_harness 'profiles_active'
  assert_eq 0 "$RC"
  assert_eq "generic" "$OUT"
}

test_profiles_active_dedups_and_puts_generic_first() {
  fixture_repo
  mkdir -p .ai
  printf 'profiles: [php, generic, php, laravel]\n' > .ai/config.yaml
  profiles_harness 'profiles_active'
  assert_eq 0 "$RC"
  assert_eq "generic php laravel" "$OUT"
}

# --- profiles_reached / profiles_unreached ---------------------------------

test_profiles_reached_equals_active_today() {
  fixture_repo
  mkdir -p .ai
  printf 'profiles: [php, generic, laravel]\n' > .ai/config.yaml
  profiles_harness 'profiles_reached'
  assert_eq 0 "$RC"
  assert_eq "generic php laravel" "$OUT"
}

test_profiles_unreached_prints_the_unlisted_directory() {
  fixture_repo
  mkdir -p .ai/profiles/generic .ai/profiles/php .ai/profiles/warehouse
  printf 'profiles: [php]\n' > .ai/config.yaml
  profiles_harness 'profiles_unreached'
  assert_eq 0 "$RC"
  assert_eq "warehouse" "$OUT"
}

test_profiles_unreached_prints_nothing_when_all_are_listed() {
  fixture_repo
  mkdir -p .ai/profiles/generic .ai/profiles/php
  printf 'profiles: [php]\n' > .ai/config.yaml
  profiles_harness 'profiles_unreached'
  assert_eq 0 "$RC"
  assert_eq "" "$OUT"
}

test_profiles_unreached_prints_nothing_without_a_profiles_dir() {
  fixture_repo
  mkdir -p .ai
  printf 'profiles: [php]\n' > .ai/config.yaml
  profiles_harness 'profiles_unreached'
  assert_eq 0 "$RC"
  assert_eq "" "$OUT"
}

# --- profiles_detect -------------------------------------------------------

test_profiles_detect_empty_repo_is_generic_only() {
  fixture_repo
  profiles_harness 'profiles_detect "$JIG_HOME/profiles"'
  assert_eq 0 "$RC"
  assert_eq "generic" "$OUT"
}

test_profiles_detect_no_root_defaults_to_source_root() {
  fixture_repo
  profiles_harness 'profiles_detect'
  assert_eq 0 "$RC"
  assert_eq "generic" "$OUT"
}

test_profiles_detect_composer_json_is_php() {
  fixture_repo
  printf '{}\n' > composer.json
  profiles_harness 'profiles_detect "$JIG_HOME/profiles"'
  assert_eq 0 "$RC"
  assert_contains "$OUT" "generic"
  assert_contains "$OUT" "php"
  assert_not_contains "$OUT" "laravel"
  assert_not_contains "$OUT" "go"
  assert_not_contains "$OUT" "node"
}

test_profiles_detect_artisan_pulls_in_php_via_requires() {
  fixture_repo
  printf '{}\n' > composer.json
  : > artisan
  profiles_harness 'profiles_detect "$JIG_HOME/profiles"'
  assert_eq 0 "$RC"
  assert_contains "$OUT" "generic"
  assert_contains "$OUT" "laravel"
  assert_contains "$OUT" "php"
}

test_profiles_detect_artisan_alone_pulls_in_php_by_closure() {
  fixture_repo
  : > artisan
  profiles_harness 'profiles_detect "$JIG_HOME/profiles"'
  assert_eq 0 "$RC"
  assert_contains "$OUT" "laravel"
  assert_contains "$OUT" "php"
}

test_profiles_detect_go_mod_is_go() {
  fixture_repo
  printf 'module example.com/x\n' > go.mod
  profiles_harness 'profiles_detect "$JIG_HOME/profiles"'
  assert_eq 0 "$RC"
  assert_contains "$OUT" "go"
  assert_not_contains "$OUT" "node"
  assert_not_contains "$OUT" "php"
}

test_profiles_detect_package_json_is_node() {
  fixture_repo
  printf '{}\n' > package.json
  profiles_harness 'profiles_detect "$JIG_HOME/profiles"'
  assert_eq 0 "$RC"
  assert_contains "$OUT" "node"
  assert_not_contains "$OUT" "go"
}

test_profiles_detect_shell_script_is_shell() {
  fixture_repo
  mkdir -p scripts
  printf '#!/usr/bin/env bash\necho hi\n' > scripts/x.sh
  profiles_harness 'profiles_detect "$JIG_HOME/profiles"'
  assert_eq 0 "$RC"
  assert_contains "$OUT" "shell"
}

test_profiles_detect_result_is_one_per_line() {
  fixture_repo
  printf '{}\n' > composer.json
  : > artisan
  profiles_harness 'profiles_detect "$JIG_HOME/profiles" | wc -l | tr -d "[:space:]"'
  assert_eq 0 "$RC"
  assert_eq "3" "$OUT"
}

# --- profiles_check_requires -----------------------------------------------

test_check_requires_warns_when_dependency_not_active() {
  fixture_repo
  mkdir -p .ai/profiles/laravel
  cat > .ai/profiles/laravel/profile.yaml <<'EOF'
name: laravel
description: fixture
detect: [artisan]
requires: [php]
EOF
  mkdir -p .ai
  printf 'profiles: [laravel]\n' > .ai/config.yaml

  profiles_harness 'profiles_check_requires'
  assert_eq 0 "$RC"
  assert_contains "$OUT" "profile 'laravel' requires 'php', which is not active"
}

test_check_requires_silent_when_dependency_active() {
  fixture_repo
  mkdir -p .ai/profiles/laravel .ai/profiles/php
  cat > .ai/profiles/laravel/profile.yaml <<'EOF'
name: laravel
description: fixture
detect: [artisan]
requires: [php]
EOF
  cat > .ai/profiles/php/profile.yaml <<'EOF'
name: php
description: fixture
detect: [composer.json]
EOF
  mkdir -p .ai
  printf 'profiles: [laravel, php]\n' > .ai/config.yaml

  profiles_harness 'profiles_check_requires'
  assert_eq 0 "$RC"
  assert_eq "" "$OUT"
}

# --- _profiles_valid_name / profiles_dir -----------------------------------

test_profiles_valid_name_accepts_well_shaped_names() {
  fixture_repo
  local name
  for name in generic php go-lang node_modules a X9; do
    profiles_harness "_profiles_valid_name '$name'"
    assert_eq 0 "$RC" "rejected well-shaped name [$name]"
  done
}

test_profiles_valid_name_rejects_traversal_and_bad_shapes() {
  fixture_repo
  local name
  for name in .. ../x .hidden . 'a b' ''; do
    profiles_harness "_profiles_valid_name '$name'"
    assert_eq 1 "$RC" "accepted bad name [$name]"
  done
}

test_profiles_dir_prints_path_for_valid_name() {
  fixture_repo
  profiles_harness 'profiles_dir "$JIG_HOME/profiles" generic'
  assert_eq 0 "$RC"
  assert_eq "$JIG_HOME/profiles/generic" "$OUT"
}

test_profiles_dir_dies_on_traversal_name() {
  fixture_repo
  local bad
  for bad in .. '../x' .hidden 'a b' ''; do
    profiles_harness "profiles_dir '$JIG_HOME/profiles' '$bad'"
    assert_eq 1 "$RC" "profiles_dir accepted [$bad]"
    assert_contains "$OUT" "invalid profile name"
  done
}

# --- _adapters_valid_name / adapters_dir ------------------------------------

test_adapters_dir_prints_path_for_valid_name() {
  fixture_repo
  profiles_harness 'adapters_dir "$JIG_HOME/adapters" claude'
  assert_eq 0 "$RC"
  assert_eq "$JIG_HOME/adapters/claude" "$OUT"
}

test_adapters_dir_dies_on_traversal_name() {
  fixture_repo
  local bad
  for bad in .. '../x' .hidden 'a b' ''; do
    profiles_harness "adapters_dir '$JIG_HOME/adapters' '$bad'"
    assert_eq 1 "$RC" "adapters_dir accepted [$bad]"
    assert_contains "$OUT" "invalid adapter name"
  done
}

# --- profiles_active rejects config-driven traversal -----------------------

test_profiles_active_dies_on_invalid_config_name() {
  fixture_repo
  mkdir -p .ai
  printf 'profiles: [.., generic]\n' > .ai/config.yaml
  profiles_harness 'profiles_active'
  assert_eq 1 "$RC"
  assert_contains "$OUT" "invalid profile name"
}

# --- profiles_source_dir / profiles_installed_dir -------------------------

test_profiles_source_dir_points_at_source_profiles() {
  fixture_repo
  profiles_harness 'profiles_source_dir'
  assert_eq 0 "$RC"
  assert_eq "$JIG_HOME/profiles" "$OUT"
}

test_profiles_installed_dir_points_under_dot_ai() {
  fixture_repo
  profiles_harness 'profiles_installed_dir'
  assert_eq 0 "$RC"
  assert_eq "$(pwd)/.ai/profiles" "$OUT"
}

# --- the check table (profiles_check_table, profiles_check_rows) ----------------

# _table_lint <profile.yaml line>... — lint a fixture profile.yaml made of the
# lines, the first `checks: [tests, static]`-style line included by the caller.
_table_lint() {
  local l
  mkdir -p fx
  : > fx/profile.yaml
  for l in "$@"; do printf '%s\n' "$l" >> fx/profile.yaml; done
  profiles_harness 'profiles_check_table "$PWD/fx"'
}

# _table_rejects <expected reason> <profile.yaml line>... — the lint fails and
# names the reason; the line number is asserted by the callers that care.
_table_rejects() {
  local want="$1"
  shift
  _table_lint "$@"
  assert_eq 1 "$RC" "$OUT"
  assert_contains "$OUT" "$want"
}

test_profiles_check_table_accepts_a_good_table() {
  fixture_repo
  _table_lint 'checks: [tests, static, manifest]' \
    'checks.tests.narrowed: {selection}' \
    'checks.static.full: analyse --no-progress   # whole project' \
    'checks.static.narrowed: analyse --no-progress {selection}' \
    'checks.manifest.command: composer' \
    'checks.manifest.full: []'
  assert_eq 0 "$RC" "$OUT"
  assert_eq "" "$OUT"
}

test_profiles_check_table_accepts_checks_list_alone_and_no_file() {
  fixture_repo
  _table_lint 'checks: [tests]'
  assert_eq 0 "$RC" "$OUT"
  rm -rf fx
  mkdir fx
  profiles_harness 'profiles_check_table "$PWD/fx"'
  assert_eq 0 "$RC" "$OUT"
}

test_profiles_check_table_rejects_a_role_that_checks_does_not_list() {
  fixture_repo
  _table_rejects "2: role 'lint' is not listed in checks:" \
    'checks: [tests]' 'checks.lint.full: x'
}

test_profiles_check_table_rejects_a_bad_role() {
  fixture_repo
  _table_rejects "role 'Tests' must be" 'checks: [Tests]' 'checks.Tests.full: x'
  _table_rejects "role '' must be" 'checks: [tests]' 'checks..full: x'
}

test_profiles_check_table_rejects_an_unknown_field_and_reserves_drop() {
  fixture_repo
  _table_rejects "unknown field 'ful'" 'checks: [tests]' 'checks.tests.ful: x'
  _table_rejects "field 'drop' is reserved" 'checks: [tests]' 'checks.tests.drop: true'
  _table_rejects "the key must be checks.<role>.<field>" 'checks: [tests]' 'checks.tests: x'
}

test_profiles_check_table_rejects_a_key_set_twice() {
  fixture_repo
  _table_rejects "3: checks.tests.full is set twice" \
    'checks: [tests]' 'checks.tests.full: a' 'checks.tests.full: b'
}

test_profiles_check_table_rejects_an_indented_key() {
  fixture_repo
  _table_rejects "2: an indented checks.* key is invisible" \
    'checks: [tests]' '  checks.tests.full: a'
}

test_profiles_check_table_rejects_forbidden_characters() {
  fixture_repo
  _table_rejects "cannot contain quotes" 'checks: [tests]' 'checks.tests.full: "a b"'
  _table_rejects "cannot contain quotes" 'checks: [tests]' "checks.tests.full: 'a'"
  _table_rejects "cannot contain quotes" 'checks: [tests]' 'checks.tests.full: $HOME'
  _table_rejects "cannot contain quotes" 'checks: [tests]' 'checks.tests.full: `id`'
  _table_rejects "cannot contain quotes" 'checks: [tests]' 'checks.tests.full: a\b'
}

test_profiles_check_table_a_hash_is_a_comment_not_a_character() {
  fixture_repo
  _table_lint 'checks: [tests]' 'checks.tests.full: a # "quoted" comment'
  assert_eq 0 "$RC" "$OUT"
}

test_profiles_check_table_rejects_selection_misuse() {
  fixture_repo
  _table_rejects "narrowed needs exactly one {selection}, found none" \
    'checks: [tests]' 'checks.tests.narrowed: run'
  _table_rejects "narrowed has more than one {selection}" \
    'checks: [tests]' 'checks.tests.narrowed: {selection} {selection}'
  _table_rejects "{selection} must be a whole word" \
    'checks: [tests]' 'checks.tests.narrowed: --x={selection}'
  _table_rejects "{selection} is only for narrowed, not full" \
    'checks: [tests]' 'checks.tests.full: {selection}'
  _table_rejects "{selection} is only for narrowed, not full" \
    'checks: [tests]' 'checks.tests.full: --x={selection}'
  _table_rejects "{selection} is only for narrowed, not command" \
    'checks: [tests]' 'checks.tests.command: {selection}'
}

test_profiles_check_table_rejects_empty_values() {
  fixture_repo
  _table_rejects "empty value; write [] for no words" 'checks: [tests]' 'checks.tests.full:'
  _table_rejects "empty value; write [] for no words" 'checks: [tests]' 'checks.tests.full:   # nothing'
  _table_rejects "command cannot be []" 'checks: [tests]' 'checks.tests.command: []'
  _table_rejects "narrowed needs exactly one" 'checks: [tests]' 'checks.tests.narrowed: []'
  _table_rejects "inline lists are not supported" 'checks: [tests]' 'checks.tests.full: [a, b]'
}

test_profiles_check_table_reports_the_first_problem_only() {
  fixture_repo
  _table_lint 'checks: [tests]' 'checks.tests.ful: x' 'checks.nope.full: y'
  assert_eq 1 "$RC"
  assert_eq "2: unknown field 'ful' (command, full, narrowed)" "$OUT"
}

test_profiles_check_rows_prints_role_field_value() {
  fixture_repo
  _table_lint 'checks: [tests, lint]' \
    'name: x' \
    'checks.tests.narrowed: {selection}  # tail' \
    'checks.lint.full: []' \
    'checks.lint.command:   clippy  '
  assert_eq 0 "$RC" "$OUT"
  profiles_harness 'profiles_check_rows "$PWD/fx"'
  assert_eq 0 "$RC"
  assert_eq "tests	narrowed	{selection}
lint	full	[]
lint	command	clippy" "$OUT"
}

test_profiles_check_rows_is_empty_without_a_table() {
  fixture_repo
  _table_lint 'checks: [tests]'
  profiles_harness 'profiles_check_rows "$PWD/fx"'
  assert_eq 0 "$RC"
  assert_eq "" "$OUT"
}
