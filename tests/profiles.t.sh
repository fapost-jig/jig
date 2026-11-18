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

test_profiles_reached_is_the_list_when_nothing_extends() {
  fixture_repo
  mkdir -p .ai
  printf 'profiles: [php, generic, laravel]\n' > .ai/config.yaml
  profiles_harness 'profiles_reached'
  assert_eq 0 "$RC"
  assert_eq "generic php laravel" "$OUT"
}

# A base reached only through `extends` is reached: it runs, so it is never
# named unreached.
test_profiles_reached_includes_a_base_reached_through_extends() {
  fixture_repo
  mkdir -p .ai/profiles/generic .ai/profiles/base .ai/profiles/warehouse
  printf 'name: base\n' > .ai/profiles/base/profile.yaml
  printf 'name: warehouse\nextends: base\n' > .ai/profiles/warehouse/profile.yaml
  printf 'profiles: [warehouse]\n' > .ai/config.yaml
  profiles_harness 'profiles_reached'
  assert_eq 0 "$RC"
  assert_eq "generic warehouse base" "$OUT"
  profiles_harness 'profiles_unreached'
  assert_eq 0 "$RC"
  assert_eq "" "$OUT"
}

# A stack that does not resolve reaches nothing knowable: nothing is named.
test_profiles_unreached_names_nothing_when_the_stack_does_not_resolve() {
  fixture_repo
  mkdir -p .ai/profiles/generic .ai/profiles/warehouse .ai/profiles/stray
  printf 'name: warehouse\nextends: missing\n' > .ai/profiles/warehouse/profile.yaml
  printf 'profiles: [warehouse]\n' > .ai/config.yaml
  profiles_harness 'profiles_reached'
  assert_eq 1 "$RC"
  assert_eq "" "$OUT"
  profiles_harness 'profiles_unreached'
  assert_eq 1 "$RC"
  assert_eq "" "$OUT"
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

test_profiles_detect_artisan_with_composer_json_is_laravel_and_php() {
  fixture_repo
  printf '{}\n' > composer.json
  : > artisan
  profiles_harness 'profiles_detect "$JIG_HOME/profiles"'
  assert_eq 0 "$RC"
  assert_contains "$OUT" "generic"
  assert_contains "$OUT" "laravel"
  assert_contains "$OUT" "php"
}

# laravel is a layer over php, and detection names only what matched: php comes
# in when the stack is resolved (profiles_stack_v), not here.
test_profiles_detect_artisan_alone_is_laravel_and_php_comes_by_extends() {
  fixture_repo
  : > artisan
  profiles_harness 'profiles_detect "$JIG_HOME/profiles"'
  assert_eq 0 "$RC"
  assert_contains "$OUT" "laravel"
  assert_not_contains "$OUT" "php"
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

test_profiles_check_table_rejects_an_unknown_field_and_a_drop_with_no_base() {
  fixture_repo
  _table_rejects "unknown field 'ful'" 'checks: [tests]' 'checks.tests.ful: x'
  _table_rejects "field 'drop' removes the check of a base; role 'tests' is not one of a base's" \
    'checks: [tests]' 'checks.tests.drop: true'
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

# _table_layer_lint <base-roles> <note> <profile.yaml line>... — lint a fixture
# layer's profile.yaml the way `jig verify` does: the roles of its bases handed in.
_table_layer_lint() {
  local roles="$1" note="$2" l
  shift 2
  mkdir -p fx
  : > fx/profile.yaml
  for l in "$@"; do printf '%s\n' "$l" >> fx/profile.yaml; done
  profiles_harness 'profiles_check_table "$PWD/fx" "'"$roles"'" "'"$note"'"'
}

test_profiles_check_table_a_layer_writes_the_roles_of_its_bases_and_drops_them() {
  fixture_repo
  _table_layer_lint "tests manifest" "top's chain (php)" \
    'extends: php' 'checks.tests.full: --fast' 'checks.manifest.drop: true  # not here'
  assert_eq 0 "$RC" "$OUT"
  assert_eq "" "$OUT"
}

test_profiles_check_table_a_role_in_no_chain_names_the_chain() {
  fixture_repo
  _table_layer_lint "tests" "top's chain (php)" 'extends: php' 'checks.nope.full: x'
  assert_eq 1 "$RC"
  assert_eq "2: role 'nope' is in no checks: of top's chain (php)" "$OUT"
}

test_profiles_check_table_drop_is_exactly_true_and_alone_in_its_role() {
  fixture_repo
  _table_layer_lint "tests" "n" 'checks.tests.drop: false'
  assert_eq "1: drop must be exactly true" "$OUT"
  _table_layer_lint "tests" "n" 'checks.tests.drop:'
  assert_eq "1: drop must be exactly true" "$OUT"
  _table_layer_lint "tests" "n" 'checks.tests.drop: true' 'checks.tests.full: --x'
  assert_eq "2: checks.tests.drop cannot be combined with another field of tests" "$OUT"
  _table_layer_lint "tests" "n" 'checks.tests.full: --x' 'checks.tests.drop: true'
  assert_eq "2: checks.tests.drop cannot be combined with another field of tests" "$OUT"
  _table_layer_lint "tests" "n" 'checks.tests.drop: true' 'checks.tests.drop: true'
  assert_eq "2: checks.tests.drop is set twice" "$OUT"
}

test_profiles_check_table_a_layer_still_cannot_drop_its_own_role() {
  fixture_repo
  _table_layer_lint "manifest" "n" 'checks: [tests]' 'checks.tests.drop: true'
  assert_eq "2: field 'drop' removes the check of a base; role 'tests' is not one of a base's" "$OUT"
}

test_profiles_check_rows_with_lines_leads_each_row_with_its_line_number() {
  fixture_repo
  _table_lint 'checks: [tests, lint]' 'name: x' 'checks.tests.full: a' '' 'checks.lint.drop: true'
  profiles_harness 'profiles_check_rows "$PWD/fx" --lines'
  assert_eq "3	tests	full	a
5	lint	drop	true" "$OUT"
}

# --- layer overrides: profiles_check_layers, profiles_check_overrides_v, profiles_check_merged ----

# _lp <name> <verify|pure> <profile.yaml line>... — a profile under ./root;
# `verify` gives it a verify.sh, `pure` none.
_lp() {
  local name="$1" kind="$2" l
  shift 2
  mkdir -p "root/$name"
  { printf 'name: %s\n' "$name"; for l in "$@"; do printf '%s\n' "$l"; done; } > "root/$name/profile.yaml"
  [ "$kind" != verify ] || printf '#!/usr/bin/env bash\nexit 0\n' > "root/$name/verify.sh"
}

# _layers_fixture — php (tests, manifest; tests narrows), laravel over php with
# its own tests (command), and warehouse, a pure layer, over laravel.
_layers_fixture() {
  fixture_repo
  _lp php verify 'checks: [tests, manifest]' 'checks.tests.command: phpunit' \
    'checks.tests.narrowed: {selection}' 'checks.manifest.command: composer' 'checks.manifest.full: validate'
  _lp laravel verify 'extends: php' 'checks: [lint]' 'checks.lint.command: pint' 'checks.lint.full: --test'
  _lp warehouse pure 'extends: laravel'
}

# _layers <names>... — profiles_check_layers over the fixture with the edges of
# warehouse > laravel > php.
_layers() {
  profiles_harness 'e=$(printf "warehouse\tlaravel\nlaravel\tphp\n"); profiles_check_layers "$PWD/root" "$e" '"$*"
}

test_profiles_check_layers_passes_a_layer_with_rows_for_its_chain() {
  _layers_fixture
  printf 'checks.lint.full: --dirty\nchecks.tests.full: --x\nchecks.tests.narrowed: --y {selection}\nchecks.manifest.drop: true\n' \
    >> root/warehouse/profile.yaml
  _layers warehouse laravel php
  assert_eq 0 "$RC" "$OUT"
  assert_eq "" "$OUT"
}

test_profiles_check_layers_names_the_first_problem_of_each_layer_with_its_line() {
  _layers_fixture
  printf 'checks.nope.full: x\n' >> root/warehouse/profile.yaml
  _layers warehouse laravel php
  assert_eq 1 "$RC"
  assert_eq "warehouse	3	role 'nope' is in no checks: of warehouse's chain (laravel, php)" "$OUT"
}

test_profiles_check_layers_refuses_a_checks_list_on_a_pure_layer() {
  _layers_fixture
  printf 'checks: [tests]\n' >> root/warehouse/profile.yaml
  _layers warehouse laravel php
  assert_eq 1 "$RC"
  assert_contains "$OUT" "warehouse	3	a layer with no verify.sh runs no check of its own, so checks: must be empty"
  # an empty list is nothing
  printf 'name: warehouse\nextends: laravel\nchecks: []\n' > root/warehouse/profile.yaml
  _layers warehouse laravel php
  assert_eq 0 "$RC" "$OUT"
}

test_profiles_check_layers_refuses_a_base_that_reads_no_table() {
  _layers_fixture
  _lp bare verify 'checks: [tests]'
  _lp over pure 'extends: bare' 'checks.tests.full: --x'
  profiles_harness 'e=$(printf "over\tbare\n"); profiles_check_layers "$PWD/root" "$e" over bare'
  assert_eq 1 "$RC"
  assert_eq "over	3	bare declares no check table; an override of bare:tests would not be read" "$OUT"
}

test_profiles_check_layers_refuses_narrowed_for_a_check_the_base_never_narrows() {
  _layers_fixture
  printf 'checks.manifest.narrowed: {selection}\n' >> root/warehouse/profile.yaml
  _layers warehouse laravel php
  assert_eq 1 "$RC"
  assert_eq "warehouse	3	php:manifest does not narrow; a narrowed override would never be read" "$OUT"
}

test_profiles_check_layers_refuses_two_branches_changing_one_role() {
  _layers_fixture
  _lp shop pure 'extends: laravel' 'checks.lint.full: --a'
  _lp depot pure 'extends: laravel' 'checks.lint.full: --b'
  profiles_harness 'e=$(printf "shop\tlaravel\ndepot\tlaravel\nlaravel\tphp\n"); profiles_check_layers "$PWD/root" "$e" shop depot laravel php'
  assert_eq 1 "$RC"
  assert_eq "depot	3	shop and depot both override laravel:lint; laravel runs once, so one of them would be ignored" "$OUT"
}

test_profiles_check_layers_lets_a_layer_and_the_one_over_it_change_one_role() {
  _layers_fixture
  printf 'checks.lint.full: --a\n' >> root/laravel/profile.yaml
  _lp mid pure 'extends: php' 'checks.tests.full: --a'
  _lp top pure 'extends: mid' 'checks.tests.full: --b'
  profiles_harness 'e=$(printf "top\tmid\nmid\tphp\n"); profiles_check_layers "$PWD/root" "$e" top mid php'
  assert_eq 0 "$RC" "$OUT"
}

test_profiles_check_overrides_v_the_top_layer_wins_field_by_field() {
  _layers_fixture
  _lp mid pure 'extends: php' 'checks.tests.full: --mid' 'checks.tests.narrowed: --mid {selection}'
  _lp top pure 'extends: mid' 'checks.tests.full: --top' 'checks.manifest.drop: true'
  profiles_harness 'e=$(printf "top\tmid\nmid\tphp\n"); profiles_check_overrides_v o "$PWD/root/php" "$e"; printf "%s\n" "$o"'
  assert_eq 0 "$RC" "$OUT"
  assert_eq "tests	narrowed	--mid {selection}	mid
tests	full	--top	top
manifest	drop	true	top" "$OUT"
}

test_profiles_check_overrides_v_a_layer_outside_the_edges_changes_nothing() {
  _layers_fixture
  _lp top pure 'extends: php' 'checks.tests.full: --top'
  profiles_harness 'profiles_check_overrides_v o "$PWD/root/php" ""; printf "[%s]\n" "$o"'
  assert_eq "[]" "$OUT"
  profiles_harness 'e=$(printf "other\tphp\n"); profiles_check_overrides_v o "$PWD/root/php" "$e"; printf "[%s]\n" "$o"'
  assert_eq "[]" "$OUT"
}

test_profiles_check_overrides_v_a_drop_outlasts_a_field_of_the_layer_above() {
  _layers_fixture
  _lp mid pure 'extends: php' 'checks.tests.drop: true'
  _lp top pure 'extends: mid' 'checks.tests.full: --top'
  profiles_harness 'e=$(printf "top\tmid\nmid\tphp\n"); profiles_check_overrides_v o "$PWD/root/php" "$e"; printf "%s\n" "$o"'
  assert_eq "tests	drop	true	mid" "$OUT"
}

test_profiles_check_merged_without_layers_is_the_table_as_written() {
  _layers_fixture
  profiles_harness 'profiles_check_merged "$PWD/root/php" ""'
  assert_eq 0 "$RC" "$OUT"
  assert_eq "tests	listed	
manifest	listed	
tests	command	phpunit
tests	narrowed	{selection}
manifest	command	composer
manifest	full	validate" "$OUT"
  profiles_harness 'profiles_check_handdown "$PWD/root/php"'
  assert_contains "$OUT" "manifest	full	validate"
}

test_profiles_check_merged_lays_the_fields_of_the_layers_over_the_bases_own() {
  _layers_fixture
  _lp top pure 'extends: php' 'checks.tests.full: --fast' 'checks.tests.command: pest' 'checks.manifest.full: []'
  profiles_harness 'e=$(printf "top\tphp\n"); profiles_check_merged "$PWD/root/php" "$e"'
  assert_eq 0 "$RC" "$OUT"
  assert_eq "tests	listed	
manifest	listed	
tests	command	pest
tests	narrowed	{selection}
manifest	command	composer
manifest	full	[]
tests	full	--fast" "$OUT"
}

test_profiles_check_merged_a_dropped_role_has_one_drop_row_and_no_fields() {
  _layers_fixture
  _lp top pure 'extends: php' 'checks.manifest.drop: true'
  profiles_harness 'e=$(printf "top\tphp\n"); profiles_check_merged "$PWD/root/php" "$e"'
  assert_eq "tests	listed	
manifest	listed	
tests	command	phpunit
tests	narrowed	{selection}
manifest	drop	top" "$OUT"
}

test_profiles_check_merged_reaches_a_base_through_a_layer_with_its_own_table() {
  _layers_fixture
  # warehouse over laravel over php: `tests` is php's, `lint` laravel's.
  printf 'checks.tests.full: --wh\nchecks.lint.full: --wh-lint\n' >> root/warehouse/profile.yaml
  profiles_harness 'e=$(printf "warehouse\tlaravel\nlaravel\tphp\n"); profiles_check_merged "$PWD/root/php" "$e"'
  assert_contains "$OUT" "tests	full	--wh"
  assert_not_contains "$OUT" "wh-lint"
  profiles_harness 'e=$(printf "warehouse\tlaravel\nlaravel\tphp\n"); profiles_check_merged "$PWD/root/laravel" "$e"'
  assert_contains "$OUT" "lint	full	--wh-lint"
  assert_not_contains "$OUT" "--wh$"
  # laravel's own table holds its own role only: php's rows are not its to read
  assert_not_contains "$OUT" "phpunit"
}

test_profiles_check_merged_prints_nothing_for_a_profile_without_rows() {
  _layers_fixture
  _lp bare verify 'checks: [tests]'
  profiles_harness 'profiles_check_merged "$PWD/root/bare" ""'
  assert_eq "" "$OUT"
}

# profiles_layer_maps_v: the pure layers whose tests run in a profile, topmost
# first. A layer with a verify.sh of its own reads its own map and is not one.
test_profiles_layer_maps_names_the_pure_layers_whose_tests_run_in_a_profile() {
  _layers_fixture
  _lp shop pure 'extends: warehouse'
  profiles_harness 'e=$(printf "shop\twarehouse\nwarehouse\tlaravel\nlaravel\tphp\n"); profiles_layer_maps_v v "$PWD/root" php "$e"; printf "[%s]" "$v"'
  assert_eq "[shop warehouse]" "$OUT"
  profiles_harness 'e=$(printf "shop\twarehouse\nwarehouse\tlaravel\nlaravel\tphp\n"); profiles_layer_maps_v v "$PWD/root" laravel "$e"; printf "[%s]" "$v"'
  assert_eq "[]" "$OUT"
  profiles_harness 'profiles_layer_maps_v v "$PWD/root" php ""; printf "[%s]" "$v"'
  assert_eq "[]" "$OUT"
}

# --- stacks: profiles_stack_v --------------------------------------------------

# _stack_profile <root> <name> [<extends-line>] — a profile directory under <root>.
_stack_profile() {
  mkdir -p "$1/$2"
  printf 'name: %s\n%s\n' "$2" "${3:-}" > "$1/$2/profile.yaml"
}

# stack_of <names...> — the stack of those names, read from the fixture's own
# installed profiles and a fixture source, in run order.
stack_of() {
  profiles_harness 'profiles_stack_v out --stock-root "$PWD/src/profiles" '"$*"' || { printf "ERR %s\n" "$PROFILES_STACK_ERROR"; exit 1; }; printf "%s\n" "$out"'
}

test_stack_layer_before_its_base_in_listed_order() {
  fixture_repo
  _stack_profile src/profiles generic
  _stack_profile src/profiles php
  _stack_profile src/profiles laravel 'extends: php'
  stack_of generic laravel php
  assert_eq 0 "$RC"
  assert_eq "generic laravel php" "$OUT"
}

test_stack_layer_listed_after_its_base_still_runs_first() {
  fixture_repo
  _stack_profile src/profiles generic
  _stack_profile src/profiles php
  _stack_profile src/profiles laravel 'extends: php'
  stack_of generic php laravel
  assert_eq "generic laravel php" "$OUT"
}

test_stack_layer_alone_brings_its_base() {
  fixture_repo
  _stack_profile src/profiles generic
  _stack_profile src/profiles php
  _stack_profile src/profiles laravel 'extends: php'
  stack_of generic laravel
  assert_eq "generic laravel php" "$OUT"
}

test_stack_shared_base_waits_for_every_layer_over_it() {
  fixture_repo
  _stack_profile src/profiles generic
  _stack_profile src/profiles php
  _stack_profile src/profiles laravel 'extends: php'
  _stack_profile src/profiles a 'extends: laravel'
  _stack_profile src/profiles b 'extends: laravel'
  stack_of generic a b
  assert_eq "generic a b laravel php" "$OUT"
}

test_stack_without_extends_keeps_the_list() {
  fixture_repo
  _stack_profile src/profiles generic
  _stack_profile src/profiles php
  _stack_profile src/profiles node
  stack_of generic node php node
  assert_eq "generic node php" "$OUT"
}

test_stack_default_names_are_generic_and_the_config_list() {
  fixture_repo
  mkdir -p .ai
  printf 'profiles: [top]\n' > .ai/config.yaml
  _stack_profile .ai/profiles top 'extends: base'
  _stack_profile .ai/profiles base
  profiles_harness 'profiles_stack_v out --stock-root "$PWD/src/profiles"; printf "%s\n" "$out"'
  assert_eq 0 "$RC"
  assert_eq "generic top base" "$OUT"
}

test_stack_edges_name_each_layer_and_its_base() {
  fixture_repo
  _stack_profile src/profiles generic
  _stack_profile src/profiles php
  _stack_profile src/profiles laravel 'extends: php'
  _stack_profile src/profiles a 'extends: laravel'
  profiles_harness 'profiles_stack_v out --edges --stock-root "$PWD/src/profiles" generic a; printf "%s\n" "$out"'
  assert_eq 0 "$RC"
  assert_eq "a	laravel
laravel	php" "$OUT"
}

test_stack_reads_a_stock_extends_from_the_stock_root_not_the_installed_copy() {
  fixture_repo
  _stack_profile src/profiles generic
  _stack_profile src/profiles php
  _stack_profile src/profiles laravel 'extends: php'
  # The installed copy is from before the release that added extends.
  _stack_profile .ai/profiles laravel
  cp -R src/profiles/php .ai/profiles/php
  printf 'jig.version: 0\n---\nabc .ai/profiles/laravel/profile.yaml\nabc .ai/profiles/php/profile.yaml\n' > .ai/manifest
  stack_of generic laravel
  assert_eq "generic laravel php" "$OUT"
}

test_stack_missing_base_names_layer_and_base() {
  fixture_repo
  _stack_profile .ai/profiles generic
  _stack_profile .ai/profiles top 'extends: ghost'
  profiles_harness 'profiles_stack_v out top; rc=$?; printf "%s|%s|%s\n" "$rc" "$PROFILES_STACK_LAYER" "$PROFILES_STACK_ERROR"'
  assert_contains "$OUT" "1|top|top: extends 'ghost', which is not installed (run jig upgrade)"
}

test_stack_missing_base_against_a_source_says_so() {
  fixture_repo
  _stack_profile .ai/profiles top 'extends: ghost'
  stack_of top
  assert_eq 1 "$RC"
  assert_contains "$OUT" "top: extends 'ghost', which is neither shipped with jig nor in .ai/profiles"
}

test_stack_cycle_is_named() {
  fixture_repo
  _stack_profile .ai/profiles a 'extends: b'
  _stack_profile .ai/profiles b 'extends: a'
  profiles_harness 'profiles_stack_v out a; printf "%s\n" "$PROFILES_STACK_ERROR"'
  assert_contains "$OUT" "a: extends cycle: a -> b -> a"
}

test_stack_extends_itself_is_a_cycle() {
  fixture_repo
  _stack_profile .ai/profiles a 'extends: a'
  profiles_harness 'profiles_stack_v out a; printf "%s\n" "$PROFILES_STACK_ERROR"'
  assert_contains "$OUT" "a: extends cycle: a -> a"
}

test_stack_extends_a_list_is_refused() {
  fixture_repo
  _stack_profile .ai/profiles a 'extends: [b, c]'
  profiles_harness 'profiles_stack_v out a; rc=$?; printf "%s|%s\n" "$rc" "$PROFILES_STACK_ERROR"'
  assert_contains "$OUT" "1|a: extends names one profile, not a list"
}

test_stack_extends_generic_is_refused() {
  fixture_repo
  _stack_profile .ai/profiles a 'extends: generic'
  profiles_harness 'profiles_stack_v out a; printf "%s\n" "$PROFILES_STACK_ERROR"'
  assert_contains "$OUT" "a: extends 'generic', which is always first and is no base"
}

test_stack_extends_an_invalid_name_is_refused() {
  fixture_repo
  _stack_profile .ai/profiles a 'extends: ../x'
  profiles_harness 'profiles_stack_v out a; printf "%s\n" "$PROFILES_STACK_ERROR"'
  assert_contains "$OUT" "a: extends '../x' is not a profile name"
}

test_stack_an_invalid_listed_name_is_an_error_not_a_death() {
  fixture_repo
  mkdir -p .ai
  printf 'profiles: [..]\n' > .ai/config.yaml
  profiles_harness 'profiles_stack_v out; rc=$?; printf "%s|%s\n" "$rc" "$PROFILES_STACK_ERROR"'
  assert_eq 0 "$RC"
  assert_contains "$OUT" "1|..: invalid profile name"
}

# --- stacks: stock and project profiles ------------------------------------------

test_stack_clash_project_profile_under_a_stock_name_copy_mode() {
  fixture_repo
  _stack_profile src/profiles generic
  _stack_profile src/profiles php
  _stack_profile src/profiles generic
  # The project wrote its own `php`; the manifest does not track it.
  _stack_profile .ai/profiles php 'detect: [mine.txt]'
  printf 'jig.version: 0\n---\n' > .ai/manifest
  stack_of generic php
  assert_eq 1 "$RC"
  assert_contains "$OUT" "php: profile '.ai/profiles/php' is the project's own, but 'php' is a stock profile; rename the project's (and its extends: lines)"
}

test_stack_clash_names_the_clashing_base_of_a_layer() {
  fixture_repo
  _stack_profile src/profiles generic
  _stack_profile src/profiles php
  _stack_profile .ai/profiles php 'detect: [mine.txt]'
  _stack_profile .ai/profiles mine 'extends: php'
  mkdir -p .ai
  printf 'jig.version: 0\n---\n' > .ai/manifest
  stack_of generic mine
  assert_eq 1 "$RC"
  assert_contains "$OUT" "'.ai/profiles/php' is the project's own"
}

test_stack_clash_is_not_raised_in_link_mode() {
  fixture_repo
  skip_unless_symlinks
  _stack_profile src/profiles generic
  _stack_profile src/profiles php
  mkdir -p .ai/profiles
  ln -s "$PWD/src/profiles/php" .ai/profiles/php
  stack_of generic php
  assert_eq 0 "$RC"
  assert_eq "generic php" "$OUT"
}

test_stack_project_profile_under_a_stock_name_clashes_in_link_mode_too() {
  fixture_repo
  skip_unless_symlinks
  _stack_profile src/profiles generic
  _stack_profile src/profiles php
  # Link mode: the manifest body is empty, the stock ones are symlinks.
  _stack_profile .ai/profiles php 'detect: [mine.txt]'
  mkdir -p .ai
  printf 'jig.version: 0\njig.mode: link\n---\n' > .ai/manifest
  stack_of generic php
  assert_eq 1 "$RC"
  assert_contains "$OUT" "is the project's own, but 'php' is a stock profile"
}

test_stack_a_modified_stock_profile_is_not_a_clash() {
  fixture_repo
  _stack_profile src/profiles generic
  _stack_profile src/profiles php
  cp -R src/profiles/php .ai/profiles/php
  printf 'detect: [edited.txt]\n' >> .ai/profiles/php/profile.yaml
  mkdir -p .ai
  printf 'jig.version: 0\n---\nabc .ai/profiles/php/profile.yaml\n' > .ai/manifest
  stack_of generic php
  assert_eq 0 "$RC"
  assert_eq "generic php" "$OUT"
}

test_stack_a_byte_identical_untracked_directory_is_an_interrupted_install_not_a_clash() {
  fixture_repo
  _stack_profile src/profiles generic
  _stack_profile src/profiles php
  cp -R src/profiles/php .ai/profiles/php
  mkdir -p .ai
  printf 'jig.version: 0\n---\n' > .ai/manifest
  stack_of generic php
  assert_eq 0 "$RC"
  assert_eq "generic php" "$OUT"
}

test_stack_only_the_stack_is_checked_for_clashes() {
  fixture_repo
  _stack_profile src/profiles generic
  _stack_profile src/profiles php
  _stack_profile .ai/profiles php 'detect: [mine.txt]'
  mkdir -p .ai
  printf 'jig.version: 0\n---\n' > .ai/manifest
  stack_of generic
  assert_eq 0 "$RC"
  assert_eq "generic" "$OUT"
}

test_profiles_is_stock_by_source_manifest_or_symlink() {
  fixture_repo
  skip_unless_symlinks
  _stack_profile src/profiles in-source
  _stack_profile .ai/profiles tracked
  _stack_profile .ai/profiles mine
  mkdir -p .ai
  ln -s "$PWD/src/profiles/in-source" .ai/profiles/linked
  printf 'jig.version: 0\n---\nabc .ai/profiles/tracked/profile.yaml\n' > .ai/manifest
  profiles_harness 'for n in in-source tracked linked mine; do profiles_is_stock "$n" "$PWD/src/profiles" && echo "$n stock" || echo "$n own"; done'
  assert_contains "$OUT" "in-source stock"
  assert_contains "$OUT" "tracked stock"
  assert_contains "$OUT" "linked stock"
  assert_contains "$OUT" "mine own"
}

test_declared_carry_reads_the_stack() {
  fixture_repo
  mkdir -p .ai
  printf 'profiles: [top]\n' > .ai/config.yaml
  _stack_profile .ai/profiles generic
  _stack_profile .ai/profiles top 'extends: base'
  _stack_profile .ai/profiles base 'carry: [vendor]'
  profiles_harness 'profiles_carry'
  assert_eq 0 "$RC"
  assert_eq "base	vendor" "$OUT"
}

test_declared_carry_falls_back_to_the_list_when_the_stack_does_not_resolve() {
  fixture_repo
  mkdir -p .ai
  printf 'profiles: [top]\n' > .ai/config.yaml
  _stack_profile .ai/profiles generic
  _stack_profile .ai/profiles top "carry: [node_modules]
extends: ghost"
  profiles_harness 'profiles_carry'
  assert_eq 0 "$RC"
  assert_eq "top	node_modules" "$OUT"
}
