# Tests for the Go skeleton of the next Jig implementation: the module next/go and
# its launcher scripts/jig-next-go (spec stack-migration, task go-skeleton).
#
# The Go code carries its own tests (`go test ./...` in next/go); this file runs
# them with the rest of the suite, adds what only a shell sees (the cross builds,
# the launcher) and checks the module the way a release would.
#
# Every test skips when `go` is not on PATH. Go's caches are the person's own,
# not the test's HOME (_ng_go), so a warm cache is used and nothing is downloaded
# that the machine does not already have.
#
# test_govulncheck is opt-in: it needs the network and the vulnerability database,
# so it runs only with JIG_NEXT_GO_VULNCHECK=1. Wiring it into CI belongs to the
# task that turns Go on in CI.
# shellcheck shell=bash

# _ng_go — skip without go, and give Go the caches and configuration of the real
# home directory: the test's HOME is empty, and a cold cache means the network.
_ng_go() {
  local real
  command -v go >/dev/null 2>&1 || skip "go is not on PATH"
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
  export GOFLAGS=-mod=readonly
  export GOWORK=off
  NG_MODULE="$JIG_HOME/next/go"
  [ -f "$NG_MODULE/go.mod" ] || fail "no module at $NG_MODULE"
}

# _ng_ok <description> — fail with the output of the last `run` unless it passed.
_ng_ok() {
  [ "$RC" -eq 0 ] || fail "$1 failed ($RC): $OUT"
}

test_next_go_is_formatted() {
  _ng_go
  command -v gofmt >/dev/null 2>&1 || skip "gofmt is not on PATH"
  run gofmt -l "$NG_MODULE"
  _ng_ok "gofmt"
  assert_eq "" "$OUT" "files that gofmt would change"
}

test_next_go_vet() {
  _ng_go
  cd "$NG_MODULE" || fail "cannot enter $NG_MODULE"
  run env CGO_ENABLED=0 go vet ./...
  _ng_ok "go vet"
}

test_next_go_unit_tests() {
  _ng_go
  cd "$NG_MODULE" || fail "cannot enter $NG_MODULE"
  run env CGO_ENABLED=0 go test -count=1 ./...
  _ng_ok "go test"
}

test_next_go_mod_verify() {
  _ng_go
  cd "$NG_MODULE" || fail "cannot enter $NG_MODULE"
  run go mod verify
  _ng_ok "go mod verify"
}

# The binary of every platform Jig would ship builds without cgo. The sizes are
# printed, for the comparison of the two skeletons in Phase 2: no threshold here.
test_next_go_cross_builds() {
  _ng_go
  local os arch ext out size
  out="$JIG_TEST_TMP/cross"
  mkdir -p "$out"
  cd "$NG_MODULE" || fail "cannot enter $NG_MODULE"
  for os in linux darwin windows; do
    for arch in amd64 arm64; do
      ext=""
      [ "$os" != windows ] || ext=".exe"
      run env CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" go build -o "$out/jig-next-$os-$arch$ext" ./cmd/jig-next
      _ng_ok "go build $os/$arch"
      size=$(wc -c < "$out/jig-next-$os-$arch$ext" | tr -d ' ')
      printf 'size: %s/%s %s bytes\n' "$os" "$arch" "$size"
    done
  done
}

test_next_go_launcher_prints_the_version_jig_prints() {
  _ng_go
  local want
  want=$("$JIG_BIN" --version)
  run env JIG_NEXT_BUILD_DIR="$JIG_TEST_TMP/build" "$JIG_HOME/scripts/jig-next-go" --version
  _ng_ok "jig-next-go --version"
  assert_eq "$want" "$OUT"
}

# The launcher builds only when it must: a second run leaves the binary as it is, and a newer
# Go source makes it build again.
_ng_mtime() {
  # Decided by the value, as jig_file_mtime does: GNU `stat -f` prints a file system block and
  # fails, so an `||` fallback would answer with that block and the time together.
  local out
  out=$(stat -f %m "$1" 2>/dev/null) || out=""
  case "$out" in
    '' | *[!0-9]*) out=$(stat -c %Y "$1") ;;
  esac
  printf '%s\n' "$out"
}

test_next_go_launcher_builds_only_when_a_source_is_newer() {
  _ng_go
  # A copy of the framework's launcher and module of its own: dating a source ahead in the release
  # copy would make every other test's launcher rebuild.
  local fw="$JIG_TEST_TMP/fw" bin first second third src
  mkdir -p "$fw/scripts" "$fw/next"
  cp "$JIG_HOME/scripts/jig-next-go" "$fw/scripts/"
  cp -R "$JIG_HOME/next/go" "$fw/next/"
  rm -rf "$fw/next/go/.build"
  bin="$JIG_TEST_TMP/build/jig-next"
  src="$fw/next/go/cmd/jig-next/main.go"
  run env JIG_NEXT_BUILD_DIR="$JIG_TEST_TMP/build" "$fw/scripts/jig-next-go" --help
  _ng_ok "first run"
  # Dated ahead of every source, so that nothing is newer than it and a rebuild shows in the time.
  touch -t 203001010000 "$bin"
  first=$(_ng_mtime "$bin")
  run env JIG_NEXT_BUILD_DIR="$JIG_TEST_TMP/build" "$fw/scripts/jig-next-go" --help
  _ng_ok "second run"
  second=$(_ng_mtime "$bin")
  assert_eq "$first" "$second"
  touch -t 203101010000 "$src"
  run env JIG_NEXT_BUILD_DIR="$JIG_TEST_TMP/build" "$fw/scripts/jig-next-go" --help
  _ng_ok "run after a source changed"
  third=$(_ng_mtime "$bin")
  [ "$third" != "$first" ] || fail "a newer Go source did not rebuild the binary"
  # A file go:embed takes in is the binary's too, and so is a source deleted: its directory's time
  # moves.
  touch -t 203001010000 "$bin"
  first=$(_ng_mtime "$bin")
  touch -t 203101010000 "$fw/next/go/schemas/frontmatter.schema.json"
  run env JIG_NEXT_BUILD_DIR="$JIG_TEST_TMP/build" "$fw/scripts/jig-next-go" --help
  _ng_ok "run after an embedded file changed"
  [ "$(_ng_mtime "$bin")" != "$first" ] || fail "a newer embedded file did not rebuild the binary"
  # Everything dated in the past, the binary after it, then a source deleted now.
  printf 'package main\n' > "$fw/next/go/cmd/jig-next/extra.go"
  find "$fw/next/go" -exec touch -t 201901010000 {} +
  touch -t 202001010000 "$bin"
  first=$(_ng_mtime "$bin")
  rm "$fw/next/go/cmd/jig-next/extra.go"
  run env JIG_NEXT_BUILD_DIR="$JIG_TEST_TMP/build" "$fw/scripts/jig-next-go" --help
  _ng_ok "run after a source was deleted"
  [ "$(_ng_mtime "$bin")" != "$first" ] || fail "deleting a Go source did not rebuild the binary"
}

test_next_go_launcher_prints_help() {
  _ng_go
  run env JIG_NEXT_BUILD_DIR="$JIG_TEST_TMP/build" "$JIG_HOME/scripts/jig-next-go" --help
  _ng_ok "jig-next-go --help"
  assert_contains "$OUT" "Usage: jig-next"
}

test_next_go_launcher_refuses_an_unknown_command() {
  _ng_go
  local out="$JIG_TEST_TMP/out" err="$JIG_TEST_TMP/err" rc=0
  env JIG_NEXT_BUILD_DIR="$JIG_TEST_TMP/build" "$JIG_HOME/scripts/jig-next-go" task list >"$out" 2>"$err" || rc=$?
  assert_eq 1 "$rc"
  assert_eq "" "$(cat "$out")" "stdout"
  assert_eq "jig: error: unknown command: task" "$(cat "$err")"
}

test_next_go_launcher_refuses_a_bad_jig_now() {
  _ng_go
  run env JIG_NOW=soon JIG_NEXT_BUILD_DIR="$JIG_TEST_TMP/build" "$JIG_HOME/scripts/jig-next-go" --version
  assert_eq 1 "$RC"
  assert_eq "jig: error: JIG_NOW must be seconds since the epoch, got 'soon'" "$OUT"
}

test_next_go_launcher_says_when_go_is_missing() {
  local bin
  bin="$JIG_TEST_TMP/bin-without-go"
  mkdir -p "$bin"
  ln -s "$(command -v dirname)" "$bin/dirname"
  run env PATH="$bin" "$(command -v bash)" "$JIG_HOME/scripts/jig-next-go" --version
  assert_eq 1 "$RC"
  assert_eq "jig-next-go: error: go is not installed" "$OUT"
}

# The Windows launcher hands its arguments to scripts/jig-next-go through Git
# Bash, as scripts/jig.cmd does for scripts/jig; it is LF-only like jig.cmd.
test_next_go_windows_launcher_runs_jig_next_go_through_git_bash() {
  local cmd="$JIG_HOME/scripts/jig-next-go.cmd"
  assert_file "$cmd"
  assert_file_contains "$cmd" 'git --exec-path'
  assert_file_contains "$cmd" '%~dp0jig-next-go"'
  if LC_ALL=C grep -q "$(printf '\r')" "$cmd"; then
    fail "scripts/jig-next-go.cmd has CRLF line endings"
  fi
}

# Opt-in: asks the vulnerability database over the network. govulncheck is a `tool`
# of next/go/go.mod, so its version is the one go.sum pins and nothing is installed.
test_govulncheck() {
  [ "${JIG_NEXT_GO_VULNCHECK:-}" = 1 ] || skip "set JIG_NEXT_GO_VULNCHECK=1 to ask the vulnerability database"
  _ng_go
  cd "$NG_MODULE" || fail "cannot enter $NG_MODULE"
  run go tool govulncheck ./...
  _ng_ok "govulncheck"
}
