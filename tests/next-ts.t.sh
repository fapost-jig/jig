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

# _nts_lock_take <dir> — claim <dir>/.check.lock for this test: a file made by exclusive create
# (`set -C`, the claim of jig_claim_file in scripts/lib/common.sh) that holds the holder's pid.
# The lock stands for everything that changes next/ts in place: the install replaces node_modules
# and `npm run check` builds dist/. `jig verify` has its own lock, which a direct
# `tests/run.sh next-ts::` in the same checkout does not take; this one is taken by both.
# A lock whose pid is gone is stale: it is removed and claimed once more. A live holder fails the
# test at once, naming its pid: no waiting, so no loop to hang. The window between a claim and the
# pid reaching the file is read as a live holder, never as a stale lock.
_nts_lock_take() {
  local lock="$1/.check.lock" pid holder
  # The pid of this test's own subshell: `$$` is the runner's shell, which outlives the test, and
  # bash 3.2 has no BASHPID. A simple command's child is forked by this shell itself, so its PPID is
  # this shell; inside `$(...)` it would be the substitution's subshell, gone at once.
  sh -c 'echo $PPID' > "$JIG_TEST_TMP/lock.pid" || fail "cannot tell this test's pid"
  read -r pid < "$JIG_TEST_TMP/lock.pid" || fail "cannot tell this test's pid"
  _NTS_LOCK_PID="$pid"
  if ( set -C; printf '%s\n' "$pid" > "$lock" ) 2>/dev/null; then
    return 0
  fi
  holder=$(cat "$lock" 2>/dev/null) || holder=""
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
    rm -f "$lock"
    if ( set -C; printf '%s\n' "$pid" > "$lock" ) 2>/dev/null; then
      return 0
    fi
    holder=$(cat "$lock" 2>/dev/null) || holder=""
  fi
  fail "next/ts is in use by another run (pid ${holder:-unknown}, lock $lock); wait for it, or remove the lock if that run is gone"
}

# _nts_lock_release <dir> — give the lock back, if it is still this test's own.
# The test library has no cleanup hook, so every path out of a locked section calls this first.
_nts_lock_release() {
  local lock="$1/.check.lock" holder
  holder=$(cat "$lock" 2>/dev/null) || return 0
  [ "$holder" != "${_NTS_LOCK_PID:-}" ] || rm -f "$lock"
}

# _nts_install <dir> — `npm ci` of the locked dependencies, unless node_modules is there and not older
# than the lockfile. Without scripts: no package of the skeleton may run code when it is installed.
# Called with the lock held. The install goes to a staging directory beside node_modules, which
# `npm ci` would otherwise delete first and rebuild in place while a reader (a launcher test, a
# bundle) looks at it; the finished tree is then swapped in by rename, so a reader sees the old
# tree, or the new one, and no half of either (apart from the instant between the two renames).
# Returns non-zero, with the log's tail printed, when the install fails.
_nts_install() {
  local dir="$1" log="$JIG_TEST_TMP/npm-ci.log" stage="$1/.deps.stage" old="$1/.deps.old" f
  if [ -f "$dir/node_modules/.package-lock.json" ] \
     && [ ! "$dir/package-lock.json" -nt "$dir/node_modules/.package-lock.json" ]; then
    return 0
  fi
  # Leftovers of a run that was killed: the lock is ours, so nobody is using them.
  rm -rf "$stage" "$old"
  mkdir "$stage" || return 1
  for f in package.json package-lock.json .npmrc; do
    if [ -f "$dir/$f" ]; then cp "$dir/$f" "$stage/$f" || return 1; fi
  done
  if ! (cd "$stage" && npm ci --ignore-scripts --no-audit --no-fund) > "$log" 2>&1; then
    tail -n 30 "$log"
    rm -rf "$stage"
    return 1
  fi
  if [ -e "$dir/node_modules" ]; then mv "$dir/node_modules" "$old" || { rm -rf "$stage"; return 1; }; fi
  if ! mv "$stage/node_modules" "$dir/node_modules"; then
    [ ! -e "$old" ] || mv "$old" "$dir/node_modules"
    rm -rf "$stage"
    return 1
  fi
  rm -rf "$old" "$stage"
}

test_next_ts_checks_pass() {
  local dir log="$JIG_TEST_TMP/npm-check.log"
  _nts_need_node
  dir="$(_nts_root)/next/ts"
  assert_dir "$dir" "the skeleton is missing"
  assert_file "$dir/package-lock.json" "the lockfile is missing"
  _nts_lock_take "$dir"
  if ! _nts_install "$dir"; then
    _nts_lock_release "$dir"
    fail "npm ci failed in $dir"
  fi
  # typecheck, schema drift, unit and integration tests, bundle, dependency rules.
  if ! (cd "$dir" && npm run check) > "$log" 2>&1; then
    # The whole log is too long to print: the failing subtests (node's TAP `not ok` blocks) go
    # first, then the tail, so a failure far up the log is still read (a CI run shows no file).
    awk '/^ *not ok /{n=30} n>0{print; n--}' "$log" | head -n 300
    tail -n 40 "$log"
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
