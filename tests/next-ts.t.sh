# Tests for the TypeScript skeleton: next/ts and its launcher scripts/jig-next-ts
# (spec stack-migration, Phase 1; nothing in bash calls it).
#
# The skeleton has its own checks, written in TypeScript and run by Node: type check, unit and
# integration tests, the schema drift check, the bundle, the dependency rules. This file is how
# they run under `tests/run.sh` and so under `jig verify`: one test installs the locked
# dependencies when they are missing or stale and runs `npm run check`; one holds the launcher to
# `jig --version`. The map (.ai/verify/shell.map) sends changes of next/ts/** and
# scripts/jig-next-ts* here.
#
# Node 22.18 or later is part of what this branch needs. A machine without it fails these tests
# with the reason; it does not skip them, because a skip would read as a pass for the TypeScript half.
# shellcheck shell=bash

# _nts_root — the checkout under test. The runner tests a release copy of the framework (JIG_HOME),
# which has no node_modules; the dependencies are installed once, in the checkout itself, and
# survive the run.
_nts_root() {
  printf '%s\n' "${ROOT:-$JIG_HOME}"
}

# _nts_need_node — fail, saying why, unless Node 22.18 or later and npm are on PATH.
_nts_need_node() {
  local v major minor rest
  command -v node >/dev/null 2>&1 \
    || fail "node was not found: the TypeScript skeleton needs Node 22.18 or later (https://nodejs.org)"
  command -v npm >/dev/null 2>&1 \
    || fail "npm was not found: it comes with Node 22.18 or later (https://nodejs.org)"
  v=$(node -p 'process.versions.node') || fail "node does not run"
  major=${v%%.*}
  rest=${v#*.}
  minor=${rest%%.*}
  if [ "$major" -lt 22 ] || { [ "$major" -eq 22 ] && [ "$minor" -lt 18 ]; }; then
    fail "Node $v is too old: the TypeScript skeleton needs Node 22.18 or later"
  fi
}

# _nts_install <dir> — `npm ci` of the locked dependencies, unless node_modules is there and not older
# than the lockfile. Without scripts: no package of the skeleton may run code when it is installed.
# Only the test that runs `npm run check` calls it, so the install never races a reader of node_modules
# inside one run; two runs in one checkout at once are what `jig verify` already refuses.
_nts_install() {
  local dir="$1" log="$JIG_TEST_TMP/npm-ci.log"
  if [ -f "$dir/node_modules/.package-lock.json" ] \
     && [ ! "$dir/package-lock.json" -nt "$dir/node_modules/.package-lock.json" ]; then
    return 0
  fi
  if ! (cd "$dir" && npm ci --ignore-scripts --no-audit --no-fund) > "$log" 2>&1; then
    tail -n 30 "$log"
    fail "npm ci failed in $dir"
  fi
}

test_next_ts_checks_pass() {
  local dir log="$JIG_TEST_TMP/npm-check.log"
  _nts_need_node
  dir="$(_nts_root)/next/ts"
  assert_dir "$dir" "the skeleton is missing"
  assert_file "$dir/package-lock.json" "the lockfile is missing"
  _nts_install "$dir"
  # typecheck, schema drift, unit and integration tests, bundle, dependency rules.
  if ! (cd "$dir" && npm run check) > "$log" 2>&1; then
    tail -n 80 "$log"
    fail "npm run check failed in next/ts"
  fi
  assert_file_contains "$log" "check-deps: ok"
  assert_file "$dir/dist/jig.mjs" "the bundle was not built"
}

test_next_ts_launcher_prints_what_jig_version_prints() {
  local root expected got
  _nts_need_node
  root="$(_nts_root)"
  assert_file "$root/scripts/jig-next-ts"
  assert_file "$root/scripts/jig-next-ts.cmd"
  expected=$(bash "$root/scripts/jig" --version) || fail "scripts/jig --version failed"
  got=$(node "$root/scripts/jig-next-ts" --version) || fail "scripts/jig-next-ts --version failed"
  assert_eq "$expected" "$got" "the launcher's version differs from bash's"
}

test_next_ts_launcher_refuses_a_bad_jig_now_as_bash_does() {
  local root
  _nts_need_node
  root="$(_nts_root)"
  run env JIG_NOW=soon bash "$root/scripts/jig" --version
  local expected_rc="$RC" expected_out="$OUT"
  run env JIG_NOW=soon node "$root/scripts/jig-next-ts" --version
  assert_eq "$expected_rc" "$RC"
  assert_eq "$expected_out" "$OUT"
  assert_contains "$OUT" "JIG_NOW must be seconds since the epoch, got 'soon'"
}
