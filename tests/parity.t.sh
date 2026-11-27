# Tests for the parity check (tests/lib/parity.sh, task parity-check).
#
# Each test records a tiny scenario of its own through `recorder.sh record` (what the
# hook in scripts/jig does) in a world of its own, "$JIG_TEST_TMP.w/t": not the test's
# directory, so that the world can be removed after recording, as tests/run.sh removes
# the directory of a recorded test, and be rebuilt by the check on the same paths.
# Record mode is simulated by exporting what tests/run.sh exports for a test; the record
# directory lies beside the test's directory (".rec"). The recorded JIG_HOME is this
# suite's own release copy, which lives while the test runs: the check uses it as it is.
# shellcheck shell=bash
# shellcheck disable=SC2016 # single-quoted fixture scripts keep their $ literal
# shellcheck disable=SC2030,SC2031 # a scenario changes JIG_HOME in a subshell on purpose

# _pt_begin — the record directory, the world's path, and what the tool is called with.
_pt_begin() {
  PT_NAME="${FUNCNAME[1]}"
  PT_REC="$JIG_TEST_TMP.rec"
  PT_W="$JIG_TEST_TMP.w/t"
  PT_BIN="$JIG_TEST_TMP.outbin"
  PT_ROOT="$JIG_HOME"
  PT_TOOL="$JIG_HOME/tests/lib/parity.sh"
  PT_RECORDER="$JIG_HOME/tests/lib/recorder.sh"
  PT_KEY="parityfix/$PT_NAME"
  PT_TAB=$'\t'
  mkdir -p "$PT_REC" "$PT_BIN" "$PT_W"
  printf 'jig-recording 2\n' > "$PT_REC/FORMAT"
  printf 'PATH=%s\000HOME=/nonexistent-runner-home\000' "$PATH" > "$JIG_TEST_TMP.outenv"
}

# _pt_fake <name> — a script of the test's own, body on stdin; executable, because the
# check execs it as the port. Prints its path.
_pt_fake() {
  local f="$PT_BIN/$1"
  { printf '#!/bin/sh\n'; cat; } > "$f"
  chmod +x "$f"
  printf '%s\n' "$f"
}

# _pt_record <program> [args...] — one recorded call in the world, stdin as the caller
# gives it, stdout and stderr to files of their own (to one file when PT_MERGED is set;
# to PT_OUT_TO and PT_ERR_TO, files of the world, when those are set),
# on a pinned clock unless PT_REAL_CLOCK is set. Its exit code is the call's own: not
# the test's business.
_pt_record() {
  local out="$JIG_TEST_TMP.outo" err="$JIG_TEST_TMP.oute" benv="$JIG_TEST_TMP.outenv"
  (
    export JIG_TEST_TMP="$PT_W"
    export JIG_RECORD_DIR="$PT_REC" JIG_RECORD_BASE_ENV="$benv"
    export JIG_RECORD_ROOT="$PT_ROOT" JIG_RECORD_TEST="parityfix::$PT_NAME"
    if [ -n "${PT_REAL_CLOCK:-}" ]; then
      unset JIG_NOW
    else
      export JIG_NOW=1700000000
    fi
    unset JIG_RECORDING JIG_RECORDER
    cd "$PT_W" || exit 1
    if [ -n "${PT_OUT_TO:-}" ] && [ -n "${PT_MERGED:-}" ]; then
      bash "$PT_RECORDER" record "$@" > "$PT_OUT_TO" 2>&1
    elif [ -n "${PT_OUT_TO:-}" ]; then
      bash "$PT_RECORDER" record "$@" > "$PT_OUT_TO" 2> "${PT_ERR_TO:-$err}"
    elif [ -n "${PT_MERGED:-}" ]; then
      bash "$PT_RECORDER" record "$@" > "$out" 2>&1
    else
      bash "$PT_RECORDER" record "$@" > "$out" 2> "$err"
    fi
  ) || true
}

# _pt_meta <seq> <key> — a field of the recorded call's meta.
_pt_meta() { sed -n "s/^$2=//p" "$PT_REC/calls/parityfix/$PT_NAME/$1/meta"; }

# _pt_world_gone — what tests/run.sh does after a recorded test.
_pt_world_gone() { rm -rf "$JIG_TEST_TMP.w"; }

# _pt_check [args...] — the tool; its output and exit code are in OUT and RC.
_pt_check() {
  run bash "$PT_TOOL" check --recordings "$PT_REC" "$@"
}

# _pt_list <lines...> — a list of intended differences of the test's own, one line per
# argument; prints its path.
_pt_list() {
  local f="$JIG_TEST_TMP.outlist" l
  : > "$f"
  for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
  printf '%s\n' "$f"
}

test_every_kind_of_call_is_equal_on_the_program_that_made_it() {
  local multi
  _pt_begin
  multi=$(_pt_fake multi <<'EOF'
case "$1" in
  (write)
    printf 'out %s\n' "$*"
    printf 'err line\n' >&2
    printf 'made\n' > made.txt
    mkdir -p sub
    printf 'x\n' > sub/inner.txt
    exit 3
    ;;
  (read)
    cat > got.txt
    printf 'read %s\n' "$(cat got.txt)"
    ;;
  (mixed)
    printf '1\n'
    printf '2\n' >&2
    printf '3\n'
    ;;
esac
EOF
)
  printf 'seed\n' > "$PT_W/seed.txt"
  printf 'some input\n' > "$JIG_TEST_TMP.outin"
  _pt_record "$multi" write "a b" < /dev/null
  _pt_record "$multi" read < "$JIG_TEST_TMP.outin"
  PT_MERGED=1 _pt_record "$multi" mixed < /dev/null
  assert_eq 3 "$(_pt_meta 0001 exit)" "the first call fails on purpose"
  assert_eq separate "$(_pt_meta 0001 streams)"
  assert_eq data "$(_pt_meta 0002 stdin)"
  assert_eq merged "$(_pt_meta 0003 streams)"
  _pt_world_gone
  _pt_check --port "$multi" --name multi
  assert_eq 0 "$RC" "a program against its own recording: $OUT"
  assert_contains "$OUT" "ok       $PT_KEY/0001"
  assert_contains "$OUT" "ok       $PT_KEY/0002"
  assert_contains "$OUT" "ok       $PT_KEY/0003"
  assert_contains "$OUT" "parity: 3 calls selected: 3 equal, 0 intended, 0 differ, 0 skipped, 0 errors; 0 stale entries"
  assert_no_file "$JIG_TEST_TMP.w" "the world is removed, and the parent the check had to make with it"
}

test_a_commit_made_by_the_call_replays_equal() {
  local commit cnt
  _pt_begin
  cnt="$PT_BIN/counter"
  printf '0\n' > "$cnt"
  # the commit's time moves with every run, so its real id differs on the replay
  commit=$(_pt_fake commit <<EOF
set -e
n=\$(cat "$cnt")
printf '%s\n' \$((n + 1)) > "$cnt"
GIT_AUTHOR_DATE="\$((1600000000 + n)) +0000"
GIT_COMMITTER_DATE=\$GIT_AUTHOR_DATE
export GIT_AUTHOR_DATE GIT_COMMITTER_DATE
cd repo
printf 'a\n' > a.txt
git add a.txt
git commit -q -m one
printf 'head %s\n' "\$(git rev-parse HEAD)"
EOF
)
  git init -q "$PT_W/repo"
  git -C "$PT_W/repo" symbolic-ref HEAD refs/heads/main
  git -C "$PT_W/repo" config user.name tester
  git -C "$PT_W/repo" config user.email tester@example.invalid
  _pt_record "$commit" < /dev/null
  assert_contains "$(cat "$PT_REC/calls/parityfix/$PT_NAME/0001/norm/stdout")" "head <sha:1>"
  _pt_world_gone
  _pt_check --port "$commit" --name p
  assert_eq 0 "$RC" "the same commit by the same program, on a clock that moved: $OUT"
  assert_contains "$OUT" "ok       $PT_KEY/0001"
  assert_eq 2 "$(cat "$cnt")" "the program ran once more, for the replay"
}

test_a_wrong_port_differs_in_every_view_it_changes() {
  local good bad rpt
  _pt_begin
  good=$(_pt_fake good <<'EOF'
printf 'hello\n'
printf 'data\n' > out.txt
EOF
)
  bad=$(_pt_fake bad <<'EOF'
printf 'HELLO\n'
printf 'other\n' > out.txt
exit 4
EOF
)
  _pt_record "$good" < /dev/null
  _pt_world_gone
  rpt="$JIG_TEST_TMP.outrpt"
  _pt_check --port "$bad" --name bad --report "$rpt"
  assert_eq 1 "$RC" "$OUT"
  assert_contains "$OUT" "DIFF     $PT_KEY/0001  (exit, stdout, files/_T_/out.txt)"
  assert_contains "$OUT" "1 calls selected: 0 equal, 0 intended, 1 differ, 0 skipped, 0 errors; 0 stale entries"
  assert_file "$rpt/$PT_KEY/0001/stdout.diff"
  assert_file_contains "$rpt/$PT_KEY/0001/stdout.diff" "^-hello"
  assert_file_contains "$rpt/$PT_KEY/0001/stdout.diff" "^+HELLO"
  assert_file "$rpt/$PT_KEY/0001/files%2F_T_%2Fout.txt.diff"
  assert_file "$rpt/$PT_KEY/0001/exit.diff"
  assert_dir "$rpt/$PT_KEY/0001/replay/norm"
  assert_no_file "$rpt/$PT_KEY/0001/changes.diff" "both made the same file: the change list is the same"
}

# The report goes into a directory of its own: one that already holds anything
# (here a call directory of an earlier report) is refused and left as it was.
test_a_report_directory_that_is_not_empty_is_refused_and_kept() {
  local good rpt
  _pt_begin
  good=$(_pt_fake good <<'EOF'
printf 'hello\n'
EOF
)
  _pt_record "$good" < /dev/null
  _pt_world_gone
  rpt="$JIG_TEST_TMP.outrpt"
  mkdir -p "$rpt/$PT_KEY/0001"
  printf 'keep\n' > "$rpt/$PT_KEY/0001/mine.txt"
  _pt_check --port "$good" --name good --report "$rpt"
  assert_eq 2 "$RC" "$OUT"
  assert_contains "$OUT" "the report directory is not empty"
  assert_eq keep "$(cat "$rpt/$PT_KEY/0001/mine.txt")" "nothing of the earlier report is removed"
  # an empty one is taken
  rm -rf "$rpt"
  mkdir "$rpt"
  _pt_check --port "$good" --name good --report "$rpt"
  assert_eq 0 "$RC" "$OUT"
}

test_an_intended_entry_covers_a_difference_and_its_lines_pattern_must_fit() {
  local good bad list
  _pt_begin
  good=$(_pt_fake good <<'EOF'
printf 'hello\n'
printf 'data\n' > out.txt
EOF
)
  bad=$(_pt_fake bad <<'EOF'
printf 'HELLO\n'
printf 'data\n' > out.txt
EOF
)
  _pt_record "$good" < /dev/null
  _pt_world_gone
  list=$(_pt_list "# a comment" "" \
    "bad${PT_TAB}parityfix/*/*${PT_TAB}stdout${PT_TAB}^(hello|HELLO)\$${PT_TAB}the port shouts")
  _pt_check --port "$bad" --name bad --intended "$list"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "intended $PT_KEY/0001  (stdout: line 3 — the port shouts)"
  assert_contains "$OUT" "0 equal, 1 intended, 0 differ"
  # another port's entry does not cover it
  _pt_check --port "$bad" --name other --intended "$list"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "DIFF     $PT_KEY/0001  (stdout)"
  assert_not_contains "$OUT" "stale    " "an entry of another port is not checked, so it is not stale"
  # a lines pattern that fits only some of the changed lines covers nothing
  list=$(_pt_list "bad${PT_TAB}parityfix/*/*${PT_TAB}stdout${PT_TAB}^hello\$${PT_TAB}only the old line")
  _pt_check --port "$bad" --name bad --intended "$list"
  assert_eq 1 "$RC" "$OUT"
  assert_contains "$OUT" "DIFF     $PT_KEY/0001  (stdout)"
  assert_contains "$OUT" "stale    $list:1  (matched 1 calls, covered no difference)"
  # `-` is any lines, `*` any view
  list=$(_pt_list "*${PT_TAB}*/*/*${PT_TAB}*${PT_TAB}-${PT_TAB}everything is intended")
  _pt_check --port "$bad" --name bad --intended "$list"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "intended $PT_KEY/0001  (stdout: line 1 — everything is intended)"
}

test_an_exit_difference_is_matched_as_one_line() {
  local good bad list
  _pt_begin
  good=$(_pt_fake good <<'EOF'
printf 'same\n'
exit 1
EOF
)
  bad=$(_pt_fake bad <<'EOF'
printf 'same\n'
exit 2
EOF
)
  _pt_record "$good" < /dev/null
  _pt_world_gone
  list=$(_pt_list "bad${PT_TAB}*/*/*${PT_TAB}exit${PT_TAB}^1 -> 3\$${PT_TAB}not this one")
  _pt_check --port "$bad" --name bad --intended "$list"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "DIFF     $PT_KEY/0001  (exit)"
  list=$(_pt_list "bad${PT_TAB}*/*/*${PT_TAB}exit${PT_TAB}^1 -> 2\$${PT_TAB}usage errors are 2 now")
  _pt_check --port "$bad" --name bad --intended "$list"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "intended $PT_KEY/0001  (exit: line 1 — usage errors are 2 now)"
}

test_a_stale_entry_fails_the_run_and_an_entry_without_a_reason_is_a_usage_error() {
  local good list
  _pt_begin
  good=$(_pt_fake good <<'EOF'
printf 'hello\n'
EOF
)
  _pt_record "$good" < /dev/null
  _pt_world_gone
  # it fits the call and covers nothing: stale; one that fits no call is only unchecked
  list=$(_pt_list \
    "# comment" \
    "p${PT_TAB}parityfix/*/*${PT_TAB}stdout${PT_TAB}-${PT_TAB}it once did" \
    "p${PT_TAB}nothing/*/*${PT_TAB}stdout${PT_TAB}-${PT_TAB}another suite's")
  _pt_check --port "$good" --name p --intended "$list"
  assert_eq 1 "$RC" "$OUT"
  assert_contains "$OUT" "ok       $PT_KEY/0001"
  assert_contains "$OUT" "stale    $list:2  (matched 1 calls, covered no difference)"
  assert_not_contains "$OUT" "$list:3"
  assert_contains "$OUT" "1 equal, 0 intended, 0 differ, 0 skipped, 0 errors; 1 stale entries"
  # no reason
  list=$(_pt_list "p${PT_TAB}parityfix/*/*${PT_TAB}stdout${PT_TAB}-${PT_TAB}")
  _pt_check --port "$good" --name p --intended "$list"
  assert_eq 2 "$RC"
  assert_contains "$OUT" "$list:1: the reason is required"
  assert_not_contains "$OUT" "parity: " "nothing was replayed"
  # the wrong number of fields
  list=$(_pt_list "# ok" "p${PT_TAB}parityfix/*/*${PT_TAB}stdout${PT_TAB}-")
  _pt_check --port "$good" --name p --intended "$list"
  assert_eq 2 "$RC"
  assert_contains "$OUT" "$list:2: 5 TAB-separated fields are required"
  # a lines field that is not an ERE
  list=$(_pt_list "p${PT_TAB}parityfix/*/*${PT_TAB}stdout${PT_TAB}(${PT_TAB}broken")
  _pt_check --port "$good" --name p --intended "$list"
  assert_eq 2 "$RC"
  assert_contains "$OUT" "$list:1: the lines field is not an extended regular expression"
}

test_a_record_directory_of_another_format_is_a_usage_error() {
  local good
  _pt_begin
  good=$(_pt_fake good <<'EOF'
printf 'hello\n'
EOF
)
  printf 'jig-recording 1\n' > "$PT_REC/FORMAT"
  _pt_check --port "$good"
  assert_eq 2 "$RC"
  assert_contains "$OUT" "is not a jig-recording 2 directory"
  _pt_check
  assert_eq 2 "$RC"
  assert_contains "$OUT" "--port is required"
}

test_a_call_on_the_real_clock_is_skipped_and_cannot_make_a_green_run() {
  local good
  _pt_begin
  good=$(_pt_fake good <<'EOF'
printf 'hello\n'
EOF
)
  PT_REAL_CLOCK=1 _pt_record "$good" < /dev/null
  assert_eq real "$(_pt_meta 0001 clock)"
  _pt_world_gone
  _pt_check --port "$good" --name p
  assert_eq 1 "$RC" "nothing was compared: $OUT"
  assert_contains "$OUT" "skip     $PT_KEY/0001  (clock was not pinned)"
  assert_contains "$OUT" "1 calls selected: 0 equal, 0 intended, 0 differ, 1 skipped, 0 errors; 0 stale entries"
  assert_contains "$OUT" "no call was compared"
  # a compared call beside the skipped one makes the run green
  mkdir -p "$PT_W"
  _pt_record "$good" < /dev/null
  _pt_world_gone
  _pt_check --port "$good" --name p
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "2 calls selected: 1 equal, 0 intended, 0 differ, 1 skipped, 0 errors; 0 stale entries"
}

test_commands_and_filters_select_calls() {
  local prog
  _pt_begin
  prog=$(_pt_fake prog <<'EOF'
printf 'did %s\n' "$1"
EOF
)
  _pt_record "$prog" alpha < /dev/null
  _pt_record "$prog" beta < /dev/null
  _pt_record "$prog" alpha < /dev/null
  _pt_world_gone
  _pt_check --port "$prog" --name p --command alpha
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "2 calls selected: 2 equal"
  assert_not_contains "$OUT" "$PT_KEY/0002"
  # commands are or-ed; a filter and a command are and-ed; <file>:: is the whole file
  _pt_check --port "$prog" --name p --command alpha --command beta "other::" "parityfix::"
  assert_contains "$OUT" "3 calls selected: 3 equal"
  _pt_check --port "$prog" --name p "parityfix::$PT_NAME" --command beta
  assert_contains "$OUT" "1 calls selected: 1 equal"
  assert_contains "$OUT" "$PT_KEY/0002"
}

test_nothing_selected_is_not_a_green_run() {
  local prog
  _pt_begin
  prog=$(_pt_fake prog <<'EOF'
printf 'x\n'
EOF
)
  _pt_record "$prog" x < /dev/null
  _pt_world_gone
  _pt_check --port "$prog" --name p "parityfix::no_such_test"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "parity: no calls selected"
  _pt_check --port "$prog" --name p "nofile::"
  assert_eq 1 "$RC"
  assert_contains "$OUT" "parity: no calls selected"
  _pt_check --port "$prog" --name p --command nosuchword
  assert_eq 1 "$RC"
  assert_contains "$OUT" "parity: no calls selected"
}

test_a_world_path_that_is_taken_is_an_error_and_is_left_alone() {
  local prog
  _pt_begin
  prog=$(_pt_fake prog <<'EOF'
printf 'x\n' > made.txt
EOF
)
  _pt_record "$prog" < /dev/null
  _pt_world_gone
  # the world's own path
  mkdir -p "$JIG_TEST_TMP.w/t"
  printf 'precious\n' > "$JIG_TEST_TMP.w/t/keep.txt"
  _pt_check --port "$prog" --name p
  assert_eq 1 "$RC"
  assert_contains "$OUT" "ERROR    $PT_KEY/0001  (replay: path taken: $PT_W)"
  assert_contains "$OUT" "0 equal, 0 intended, 0 differ, 0 skipped, 1 errors"
  assert_eq "precious" "$(cat "$JIG_TEST_TMP.w/t/keep.txt")"
  assert_no_file "$JIG_TEST_TMP.w/t/made.txt"
  # a neighbour of the form <T>.*
  rm -rf "$JIG_TEST_TMP.w"
  mkdir -p "$JIG_TEST_TMP.w/t.other"
  _pt_check --port "$prog" --name p
  assert_eq 1 "$RC"
  assert_contains "$OUT" "replay: path taken: $PT_W.other"
  assert_dir "$JIG_TEST_TMP.w/t.other"
  assert_no_file "$JIG_TEST_TMP.w/t"
}

test_a_missing_jig_home_is_built_for_the_run_and_removed_after() {
  local prog hm
  _pt_begin
  hm="$JIG_TEST_TMP.hm/home"
  prog=$(_pt_fake prog <<'EOF'
if [ -f "$JIG_HOME/scripts/jig" ]; then printf 'framework at %s\n' "$JIG_HOME"; else printf 'none\n'; fi
EOF
)
  # the recording's JIG_HOME is a path that held a framework copy while the call ran
  mkdir -p "$hm/scripts"
  : > "$hm/scripts/jig"
  (
    export JIG_HOME="$hm"
    _pt_record "$prog" < /dev/null
  )
  assert_contains "$(cat "$PT_REC/calls/parityfix/$PT_NAME/0001/norm/stdout")" "framework at <JIG_HOME>"
  _pt_world_gone
  rm -rf "$JIG_TEST_TMP.hm"
  _pt_check --port "$prog" --name p --home "$PT_ROOT"
  assert_eq 0 "$RC" "$OUT"
  assert_contains "$OUT" "ok       $PT_KEY/0001"
  assert_no_file "$JIG_TEST_TMP.hm" "the release copy and the directories made for it are removed"
}

test_port_env_reaches_the_port_and_only_the_port() {
  local rec port
  _pt_begin
  rec=$(_pt_fake rec <<'EOF2'
printf 'v=bar\n'
EOF2
)
  port=$(_pt_fake port <<'EOF2'
printf 'v=%s\n' "${PT_X:-unset}"
EOF2
)
  _pt_record "$rec" < /dev/null
  _pt_world_gone
  _pt_check --port "$port" --name p
  assert_eq 1 "$RC" "without the variable the port prints something else: $OUT"
  assert_contains "$OUT" "DIFF     $PT_KEY/0001  (stdout)"
  _pt_check --port "$port" --name p --port-env PT_X=bar
  assert_eq 0 "$RC" "$OUT"
  _pt_check --port "$port" --name p --port-env "not a name"
  assert_eq 2 "$RC"
  assert_contains "$OUT" "--port-env wants NAME=VALUE"
}

test_a_stream_that_went_to_a_file_of_the_world_is_replayed_into_it() {
  local prog
  _pt_begin
  prog=$(_pt_fake prog <<'EOF2'
printf 'to out\n'
printf 'to err\n' >&2
printf 'made\n' > made.txt
EOF2
)
  # a shell `>` made the files before the call; q.out already holds a line
  printf 'older\n' > "$PT_W/q.out"
  : > "$PT_W/r.err"
  : > "$PT_W/m.out"
  PT_OUT_TO="$PT_W/q.out" PT_ERR_TO="$PT_W/r.err" _pt_record "$prog" < /dev/null
  PT_OUT_TO="$PT_W/m.out" PT_MERGED=1 _pt_record "$prog" < /dev/null
  assert_contains "$(cat "$PT_REC/calls/parityfix/$PT_NAME/0001/changes" | tr '\000' '|')" "M"$'\t'"<T>/q.out"
  _pt_world_gone
  _pt_check --port "$prog" --name p
  assert_eq 0 "$RC" "the streams are appended to the same files in the restored world: $OUT"
  assert_contains "$OUT" "2 calls selected: 2 equal, 0 intended, 0 differ"
}
