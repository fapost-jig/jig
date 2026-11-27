# Shared by the tests that run the TypeScript port (tests/next-ts.t.sh, tests/parity-context-ts.t.sh):
# the checkout's Node, the lock on next/ts and the install of its locked dependencies. Sourced by a
# test file, never run.
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
  _nts_lock_try "$1" && return 0
  fail "next/ts is in use by another run (pid ${_NTS_LOCK_HOLDER:-unknown}, lock $1/.check.lock); wait for it, or remove the lock if that run is gone"
}

# _nts_lock_try <dir> — _nts_lock_take without failing: exit 0 with the lock claimed, or 1 with
# _NTS_LOCK_HOLDER naming the live holder. Called as a plain command, never in a subshell: the pid
# it writes must be this test's own shell.
_nts_lock_try() {
  local lock="$1/.check.lock" pid holder
  # The pid of this test's own subshell: `$$` is the runner's shell, which outlives the test, and
  # bash 3.2 has no BASHPID. A simple command's child is forked by this shell itself, so its PPID is
  # this shell; inside `$(...)` it would be the substitution's subshell, gone at once.
  sh -c 'echo $PPID' > "$JIG_TEST_TMP/lock.pid" || fail "cannot tell this test's pid"
  read -r pid < "$JIG_TEST_TMP/lock.pid" || fail "cannot tell this test's pid"
  _NTS_LOCK_PID="$pid"
  _NTS_LOCK_HOLDER=""
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
  _NTS_LOCK_HOLDER=$holder
  return 1
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

# _nts_deps <dir> — make sure <dir>/node_modules holds the locked dependencies, for a test that only
# reads them (it runs the port from the checkout's sources). When they are current nothing is taken.
# Otherwise the lock is claimed to install them; a live holder is waited for, once a second, for up
# to 600 s, because the holder is another test of the same run installing or checking the very same
# tree, and failing at once would make two tests of one run on a fresh machine fail each other. The
# wait is bounded, so it cannot hang a run.
_nts_deps() {
  local dir="$1" waited=0
  while :; do
    if [ -f "$dir/node_modules/.package-lock.json" ] \
       && [ ! "$dir/package-lock.json" -nt "$dir/node_modules/.package-lock.json" ]; then
      return 0
    fi
    if _nts_lock_try "$dir"; then
      break
    fi
    [ "$waited" -lt 600 ] || fail "next/ts stayed locked for 600 s ($dir/.check.lock); its dependencies were not installed"
    sleep 1
    waited=$((waited + 1))
  done
  if ! _nts_install "$dir"; then
    _nts_lock_release "$dir"
    fail "npm ci failed in $dir"
  fi
  _nts_lock_release "$dir"
}
