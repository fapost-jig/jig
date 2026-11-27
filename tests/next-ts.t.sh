# Tests for the TypeScript skeleton: next/ts and its launcher scripts/jig-next-ts
# (spec stack-migration, Phase 1; nothing in bash calls it).
#
# The skeleton has its own checks, written in TypeScript and run by Node: type check, unit and
# integration tests, the schema drift check, the bundle, the dependency rules. This file is how
# they run under `tests/run.sh` and so under `jig verify`: one test installs the locked
# dependencies when they are missing or stale and runs `npm run check`, under a lock of its own
# (next/ts/.check.lock) because both change next/ts in place; one holds the launcher to
# `jig --version`. The map (.ai/verify/shell.map) sends changes of next/ts/** and
# scripts/jig-next-ts* here.
#
# Node 22.18 or later is part of what this branch needs. A machine without it fails these tests
# with the reason; it does not skip them, because a skip would read as a pass for the TypeScript half.
# shellcheck shell=bash

# The helpers (_nts_root, _nts_need_node, the lock, the install) are in tests/lib/next-ts.sh.
# shellcheck source=lib/next-ts.sh
. "$JIG_HOME/tests/lib/next-ts.sh"

test_next_ts_checks_pass() {
  local dir log="$JIG_TEST_TMP/npm-check.log"
  _nts_need_node
  dir="$(_nts_root)/next/ts"
  assert_dir "$dir" "the skeleton is missing"
  assert_file "$dir/package-lock.json" "the lockfile is missing"
  # The install waits for a parity test of the same run that is installing them (_nts_deps); the
  # check itself then takes the lock and fails at once on a live holder, as before.
  _nts_deps "$dir"
  _nts_lock_take "$dir"
  if ! _nts_install "$dir"; then
    _nts_lock_release "$dir"
    fail "npm ci failed in $dir"
  fi
  # typecheck, schema drift, unit and integration tests, bundle, dependency rules.
  if ! (cd "$dir" && npm run check) > "$log" 2>&1; then
    # Every failed test by name first: the tail alone shows only the last of them.
    grep '^not ok ' "$log" || true
    tail -n 80 "$log"
    _nts_lock_release "$dir"
    fail "npm run check failed in next/ts"
  fi
  if [ ! -f "$dir/dist/jig.mjs" ]; then
    _nts_lock_release "$dir"
    fail "the bundle was not built"
  fi
  _nts_lock_release "$dir"
  assert_file_contains "$log" "check-deps: ok"
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
