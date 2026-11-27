# Tests that the next implementations of Jig (the TypeScript and the Go skeletons) give the same
# answer as the bash jig for `jig version`, by the parity check (tests/lib/parity.sh, ADR
# adr-20261127-ports-are-checked-by-replaying-recordings-in-place) — the smallest command, and the
# first whose port is proved by a bash recording instead of by a hand-written assertion.
#
# Every test records for itself, because tests run in parallel subshells: it runs the dispatcher's
# two `jig version` tests under `JIG_RECORD` (a nested tests/run.sh of this release copy), then
# replays the recorded calls on its port. The recorded world is a release copy of the framework on
# a path of its own, so the ports are taken in that copy: `<JIG_HOME>/scripts/jig-next-ts`, and the
# Go binary with `JIG_NEXT_ROOT=<JIG_HOME>`, which keeps the version it prints the recorded one.
#
# The TypeScript test needs Node 22.18 or later and skips without it; the Go test skips without
# `go`. The bash test is the self-check of the harness: the bash jig must equal its own recording.
# shellcheck shell=bash

# _pp_summary — what a clean check of the two recorded calls prints last.
_pp_summary() {
  printf 'parity: 2 calls selected: 2 equal, 0 intended, 0 differ, 0 skipped, 0 errors; 0 stale entries'
}

# _pp_record — record the two `jig version` tests of the dispatcher into $JIG_TEST_TMP/rec, in a
# run of their own; PP_REC is its directory.
_pp_record() {
  PP_REC="$JIG_TEST_TMP/rec"
  mkdir -p "$PP_REC"
  (
    unset JIG_RECORD JIG_RECORD_DIR JIG_RECORD_TEST JIG_RECORD_ROOT JIG_RECORD_BASE_ENV \
      JIG_RECORDING JIG_RECORDER
    cd "$JIG_HOME" || exit 1
    JIG_TEST_JOBS=1 JIG_RECORD="$PP_REC" "$JIG_HOME/tests/run.sh" \
      dispatcher::test_version_prints_semver \
      dispatcher::test_version_rejects_an_unknown_option
  ) > "$JIG_TEST_TMP/record.log" 2>&1 \
    || fail "recording the dispatcher's version tests failed: $(tail -20 "$JIG_TEST_TMP/record.log")"
  assert_file "$PP_REC/FORMAT"
}

# _pp_check <check args...> — replay the recorded `jig version` calls; the check's output
# and exit status are in OUT and RC.
_pp_check() {
  run bash "$JIG_HOME/tests/lib/parity.sh" check --recordings "$PP_REC" --command version "$@"
}

# _pp_equal — the last check found both calls equal.
_pp_equal() {
  assert_eq 0 "$RC" "the check failed: $OUT"
  assert_contains "$OUT" "$(_pp_summary)"
}

test_jig_version_of_bash_matches_its_own_recordings() {
  _pp_record
  _pp_check --port '<JIG_HOME>/scripts/jig' --name bash
  _pp_equal
}

test_jig_version_of_the_ts_port_matches_the_bash_recordings() {
  local v major minor rest
  command -v node >/dev/null 2>&1 || skip "node is not on PATH"
  v=$(node -p 'process.versions.node') || skip "node does not run"
  major=${v%%.*}
  rest=${v#*.}
  minor=${rest%%.*}
  if [ "$major" -lt 22 ] || { [ "$major" -eq 22 ] && [ "$minor" -lt 18 ]; }; then
    skip "Node $v is older than 22.18"
  fi
  _pp_record
  _pp_check --port '<JIG_HOME>/scripts/jig-next-ts' --name ts
  _pp_equal
}

test_jig_version_of_the_go_port_matches_the_bash_recordings() {
  local real
  command -v go >/dev/null 2>&1 || skip "go is not on PATH"
  # Go's caches are the person's own, as in tests/next-go.t.sh (_ng_go): the test's HOME is empty
  # and a cold cache means the network.
  real=$(eval "printf '%s' ~$(id -un)" 2>/dev/null) || real=""
  if [ -z "$real" ] || [ ! -d "$real" ]; then
    real=$HOME
  fi
  if [ "$real" != "$HOME" ]; then
    GOENV=$(HOME=$real go env GOENV) && export GOENV
    GOCACHE=$(HOME=$real go env GOCACHE) && export GOCACHE
    GOMODCACHE=$(HOME=$real go env GOMODCACHE) && export GOMODCACHE
    GOPATH=$(HOME=$real go env GOPATH) && export GOPATH
  fi
  export GOFLAGS=-mod=readonly GOWORK=off
  # Built before the check, never inside a replay (conventions/parity.md).
  mkdir -p "$JIG_TEST_TMP/gobin"
  (cd "$JIG_HOME/next/go" && CGO_ENABLED=0 go build -o "$JIG_TEST_TMP/gobin/jig-next" ./cmd/jig-next) \
    || fail "go build failed"
  _pp_record
  _pp_check --port "$JIG_TEST_TMP/gobin/jig-next" --name go --port-env 'JIG_NEXT_ROOT=<JIG_HOME>'
  _pp_equal
}
