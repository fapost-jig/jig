# Tests for the stack recorder (tests/lib/recorder.sh) and the hook in scripts/jig
# that hands the outermost call of a test to it (task stack-recorder).
#
# Most tests record a small script of their own through `recorder.sh record`,
# which is what the hook does: the script says exactly what the call did, so the
# record can be compared with it field by field. Record mode is simulated by
# exporting what tests/run.sh exports for a test: JIG_RECORD_DIR, JIG_RECORD_TEST,
# JIG_RECORD_BASE_ENV and JIG_RECORD_ROOT; the record directory lies beside the
# test's directory (".rec"), never inside it.
# shellcheck shell=bash
# shellcheck disable=SC2016 # single-quoted fixture scripts keep their $ literal
# shellcheck disable=SC2030,SC2031 # a scenario changes JIG_TEST_TMP and JIG_NOW in a subshell on purpose
# shellcheck disable=SC2094 # the call reads the log it appends to: that is what the test checks

# _rec_begin — what run.sh gives a test in record mode, built by hand under this
# test's name. The base environment holds GH_TOKEN, so a token equal to it is the
# runner's and any other is the test's.
_rec_begin() {
  REC="$JIG_TEST_TMP.rec"
  REC_BIN="$JIG_HOME/tests/lib/recorder.sh"
  REC_NAME="${FUNCNAME[1]}"
  mkdir -p "$REC" "$JIG_TEST_TMP.outbin"
  printf 'jig-recording 2\n' > "$REC/FORMAT"
  printf 'PATH=%s\000HOME=/nonexistent-runner-home\000GH_TOKEN=runner-secret\000' "$PATH" \
    > "$JIG_TEST_TMP.outenv"
  export GH_TOKEN=runner-secret
  export JIG_RECORD_DIR="$REC" JIG_RECORD_BASE_ENV="$JIG_TEST_TMP.outenv"
  export JIG_RECORD_ROOT="$JIG_HOME" JIG_RECORD_TEST="recorder::$REC_NAME"
  unset JIG_RECORDING JIG_RECORDER
}

# _rec_fake <name> — a script of the test's own to record, body on stdin.
_rec_fake() {
  local f="$JIG_TEST_TMP.outbin/$1"
  { printf '#!/bin/sh\n'; cat; } > "$f"
  printf '%s\n' "$f"
}

# _rec_call <program> [args...] — what the hook does: record this call.
_rec_call() { bash "$REC_BIN" record "$@"; }

# _rec_d <seq> — the directory of that call of this test.
_rec_d() { printf '%s/calls/recorder/%s/%s\n' "$REC" "$REC_NAME" "$1"; }

# _rec_meta <call-dir> <key>
_rec_meta() { sed -n "s/^$2=//p" "$1/meta"; }

# _rec_list <file> — a NUL-terminated list, one record per line.
_rec_list() { tr '\000' '\n' < "$1"; }

test_a_simple_call_keeps_every_field() {
  local fake d rc=0 expected
  _rec_begin
  fake=$(_rec_fake simple <<'EOF'
printf 'to stdout\n'
printf 'to stderr\n' >&2
printf 'made\n' > made.txt
exit 3
EOF
)
  # stdin as record mode gives it (tests/run.sh: exec </dev/null), not the
  # runner's own, which under `jig verify` is a pipe
  _rec_call "$fake" "a b" $'c\nd' < /dev/null > "$JIG_TEST_TMP.outo" 2> "$JIG_TEST_TMP.oute" || rc=$?
  assert_eq 3 "$rc" "the recorder returns jig's exit code"
  assert_eq "to stdout" "$(cat "$JIG_TEST_TMP.outo")" "stdout reaches the caller"
  assert_eq "to stderr" "$(cat "$JIG_TEST_TMP.oute")" "stderr reaches the caller"
  d=$(_rec_d 0001)
  assert_dir "$d"
  assert_eq 2 "$(sed -n 's/^format=//p' "$d/meta")" "format"
  assert_eq "recorder::$REC_NAME" "$(_rec_meta "$d" test)"
  assert_eq 0001 "$(_rec_meta "$d" seq)"
  assert_eq 3 "$(_rec_meta "$d" exit)"
  assert_eq separate "$(_rec_meta "$d" streams)"
  assert_eq none "$(_rec_meta "$d" stdin)"
  assert_eq real "$(_rec_meta "$d" clock)"
  assert_eq no "$(_rec_meta "$d" concurrent)"
  assert_eq "<T>.outbin/simple" "$(_rec_meta "$d" entry)"
  assert_eq "" "$(_rec_meta "$d" recorder_error)"
  # argv: raw, an argument with a space and one with a newline.
  printf '%s\000%s\000' "a b" $'c\nd' > "$JIG_TEST_TMP.outx"
  cmp -s "$JIG_TEST_TMP.outx" "$d/argv" || fail "argv differs from what was passed"
  printf '%s\000' "$PWD" > "$JIG_TEST_TMP.outx"
  cmp -s "$JIG_TEST_TMP.outx" "$d/cwd" || fail "cwd differs"
  cmp -s "$JIG_TEST_TMP.outo" "$d/stdout" || fail "recorded stdout differs"
  cmp -s "$JIG_TEST_TMP.oute" "$d/stderr" || fail "recorded stderr differs"
  assert_no_file "$d/stdin"
  # the call's one change, raw and normalised, and the file it made
  expected=$(printf 'A\t<T>/made.txt')
  assert_eq "$expected" "$(_rec_list "$d/changes")"
  assert_eq "$(printf 'A\t<T>/made.txt')" "$(cat "$d/norm/changes")"
  assert_eq "made" "$(cat "$d/norm/files/_T_/made.txt")"
  assert_eq "to stderr" "$(cat "$d/norm/stderr")"
  # no scratch left behind, and no call still marked active
  assert_no_file "$d/.tmp"
  assert_no_file "$REC/calls/recorder/$REC_NAME/.active"
}

test_a_blob_comes_back_from_the_store_byte_for_byte() {
  local fake d id
  _rec_begin
  fake=$(_rec_fake blob <<'EOF'
printf 'one\ntwo\0three\n\n' > data.bin
chmod +x data.bin
printf 'plain\n' > "name with
newline.txt"
ln -s data.bin link
mkdir sub
EOF
)
  _rec_call "$fake" > /dev/null
  d=$(_rec_d 0001)
  id=$(_rec_list "$d/tree.after" | grep -F "<T>/data.bin" | cut -f 3)
  case "$id" in ????????????????????????????????????????) ;; *) fail "no blob id for data.bin: [$id]" ;; esac
  git --git-dir="$REC/store.git" cat-file blob "$id" > "$JIG_TEST_TMP.outx"
  cmp -s "$JIG_TEST_TMP.outx" "$JIG_TEST_TMP/data.bin" || fail "blob differs from the file"
  assert_contains "$(_rec_list "$d/tree.after")" "$(printf 'f\t755\t%s\t%s' "$id" "<T>/data.bin")"
  assert_contains "$(_rec_list "$d/tree.after")" "$(printf 'l\t-\tdata.bin\t%s' "<T>/link")"
  assert_contains "$(_rec_list "$d/tree.after")" "$(printf 'd\t-\t-\t%s' "<T>/sub")"
  # a name with a newline in it is stored and listed too
  id=$(git --git-dir="$REC/store.git" hash-object --no-filters "$JIG_TEST_TMP/name with
newline.txt")
  assert_contains "$(tr '\000' '|' < "$d/tree.after")" "f"$'\t'"644"$'\t'"$id"$'\t'"<T>/name with"$'\n'"newline.txt|"
  # the file has a NUL: its normalised view is `binary <id>`
  id=$(git hash-object --no-filters "$JIG_TEST_TMP/data.bin")
  assert_eq "binary $id" "$(cat "$d/norm/files/_T_/data.bin")"
}

test_merged_streams_keep_the_order_the_caller_saw() {
  local fake d
  _rec_begin
  fake=$(_rec_fake merged <<'EOF'
printf '1\n'
printf '2\n' >&2
printf '3\n'
EOF
)
  _rec_call "$fake" > "$JIG_TEST_TMP.outo" 2>&1
  assert_eq "$(printf '1\n2\n3')" "$(cat "$JIG_TEST_TMP.outo")" "the caller sees the interleaving it would have"
  d=$(_rec_d 0001)
  assert_eq merged "$(_rec_meta "$d" streams)"
  cmp -s "$JIG_TEST_TMP.outo" "$d/stdout" || fail "merged capture differs from the caller's file"
  assert_no_file "$d/stderr"
  assert_no_file "$d/norm/stderr"
}

test_stdin_is_kept_and_given_to_the_command() {
  local fake d
  _rec_begin
  fake=$(_rec_fake reads <<'EOF'
cat > got.txt
EOF
)
  _rec_call "$fake" <<'EOF' > /dev/null
line one
line two
EOF
  d=$(_rec_d 0001)
  assert_eq data "$(_rec_meta "$d" stdin)"
  assert_eq "$(printf 'line one\nline two')" "$(cat "$d/stdin")"
  assert_eq "$(printf 'line one\nline two')" "$(cat got.txt)" "the command got what the caller sent"
  printf 'from a pipe\n' | _rec_call "$fake" > /dev/null
  d=$(_rec_d 0002)
  assert_eq data "$(_rec_meta "$d" stdin)"
  assert_eq "from a pipe" "$(cat got.txt)"
  _rec_call "$fake" < /dev/null > /dev/null
  d=$(_rec_d 0003)
  assert_eq none "$(_rec_meta "$d" stdin)"
  assert_no_file "$d/stdin"
}

test_changes_and_git_state_leave_git_internals_out() {
  local fake d changes
  _rec_begin
  mkdir repo
  git init -q repo
  git -C repo symbolic-ref HEAD refs/heads/main
  printf 'b\n' > repo/b.txt
  printf 'c\n' > repo/c.txt
  printf 'd\n' > repo/d
  fake=$(_rec_fake gitwork <<'EOF'
set -e
cd repo
echo a > a.txt
git add a.txt
git commit -q -m one
echo changed > b.txt
rm c.txt
rm d
ln -s a.txt d
echo hook > .git/hooks/post-x
EOF
)
  _rec_call "$fake" > /dev/null
  d=$(_rec_d 0001)
  changes=$(_rec_list "$d/changes")
  assert_eq "$(printf 'A\t<T>/repo/.git/hooks/post-x\nA\t<T>/repo/a.txt\nM\t<T>/repo/b.txt\nD\t<T>/repo/c.txt\nT\t<T>/repo/d')" "$changes" \
    "objects, index, HEAD, refs, logs and COMMIT_EDITMSG are not changes; hooks are"
  # the raw tree still has the git files, byte for byte
  assert_contains "$(_rec_list "$d/tree.after")" "<T>/repo/.git/COMMIT_EDITMSG"
  assert_contains "$(_rec_list "$d/tree.after")" "<T>/repo/.git/index"
  # git by meaning, before and after
  assert_contains "$(cat "$d/git.before")" "[gitdir <T>/repo/.git]"
  assert_contains "$(cat "$d/git.before")" "HEAD ref: refs/heads/main"
  assert_eq 0 "$(grep -c '^ref ' "$d/git.before" || true)" "no ref before the commit"
  assert_contains "$(cat "$d/git.after")" "[worktree <T>/repo]"
  assert_contains "$(cat "$d/git.after")" "branch main"
  assert_contains "$(cat "$d/git.after")" "status ?? b.txt"
  assert_contains "$(cat "$d/git.after")" " refs/heads/main"
  assert_contains "$(cat "$d/norm/git.after")" "[gitdir <T>/repo/.git]"
  assert_contains "$(cat "$d/norm/git.after")" "ref <sha:1> refs/heads/main"
  assert_eq "changed" "$(cat "$d/norm/files/_T_/repo/b.txt")"
  assert_eq "hook" "$(cat "$d/norm/files/_T_/repo/.git/hooks/post-x")"
  assert_no_file "$d/norm/files/_T_/repo/c.txt"
}

test_only_the_tests_own_environment_is_recorded() {
  local fake d
  _rec_begin
  fake=$(_rec_fake quiet <<'EOF'
:
EOF
)
  _rec_call "$fake" > /dev/null
  d=$(_rec_d 0001)
  assert_not_contains "$(_rec_list "$d/env")" "GH_TOKEN" "the runner's own token is not kept"
  assert_contains "$(_rec_list "$d/env")" "PATH=$PATH"
  assert_contains "$(_rec_list "$d/env")" "HOME=$HOME" "HOME differs from the runner's"
  GH_TOKEN=test-fake-token _rec_call "$fake" > /dev/null
  d=$(_rec_d 0002)
  assert_contains "$(_rec_list "$d/env")" "GH_TOKEN=test-fake-token" "a token the test set is kept"
  assert_contains "$(cat "$d/norm/env")" "GH_TOKEN=test-fake-token"
  assert_contains "$(cat "$d/norm/env")" "PATH=<PATH>"
  assert_not_contains "$(_rec_list "$d/env")" "JIG_RECORD"
  assert_not_contains "$(_rec_list "$d/env")" "JIG_RECORDING"
  if grep -rqF runner-secret "$REC"; then
    fail "the runner's token is somewhere in the record"
  fi
}

test_a_nested_call_is_not_recorded_and_the_next_outer_one_gets_the_next_number() {
  local fake out
  _rec_begin
  export JIG_RECORDER="$REC_BIN"
  jig version > "$JIG_TEST_TMP.outo"
  assert_dir "$(_rec_d 0001)"
  out=$(cat "$JIG_TEST_TMP.outo")
  case "$out" in jig\ [0-9]*) ;; *) fail "jig version through the recorder: [$out]" ;; esac
  assert_eq "$out" "$(cat "$(_rec_d 0001)/stdout")"
  assert_eq entry "$(printf 'entry')"
  assert_eq "<JIG_HOME>/scripts/jig" "$(_rec_meta "$(_rec_d 0001)" entry)"
  # called while a recording is on: not recorded
  JIG_RECORDING=outer jig version > /dev/null
  assert_no_file "$(_rec_d 0002)"
  # a recorded script that calls jig itself: the inner calls are details
  fake=$(_rec_fake caller <<'EOF'
"$JIG_BIN" version > /dev/null
"$JIG_BIN" version > /dev/null
EOF
)
  _rec_call "$fake"
  assert_dir "$(_rec_d 0002)"
  assert_no_file "$(_rec_d 0003)"
  jig version > /dev/null
  assert_dir "$(_rec_d 0003)"
  assert_no_file "$(_rec_d 0004)"
}

test_without_a_recorder_the_dispatcher_does_what_it_did() {
  local plain recorded
  _rec_begin
  plain=$(jig version)
  case "$plain" in jig\ [0-9]*) ;; *) fail "jig version: [$plain]" ;; esac
  assert_no_file "$REC/calls" "no record without JIG_RECORDER"
  # an empty JIG_RECORDER is no recorder
  recorded=$(JIG_RECORDER='' jig version)
  assert_eq "$plain" "$recorded"
  assert_no_file "$REC/calls"
  # and with one, the output is the same
  recorded=$(JIG_RECORDER="$REC_BIN" jig version)
  assert_eq "$plain" "$recorded"
  assert_dir "$(_rec_d 0001)"
}

test_a_call_inside_another_recorded_call_is_marked_concurrent() {
  local outer inner d
  _rec_begin
  inner=$(_rec_fake inner <<'EOF'
:
EOF
)
  outer=$(_rec_fake outer <<EOF
bash "$REC_BIN" record "$inner"
EOF
)
  _rec_call "$outer"
  assert_eq yes "$(_rec_meta "$(_rec_d 0001)" concurrent)" "the call that was running when another began"
  assert_eq yes "$(_rec_meta "$(_rec_d 0002)" concurrent)" "the call that began inside another"
  _rec_call "$inner"
  assert_eq no "$(_rec_meta "$(_rec_d 0003)" concurrent)" "a call alone"
}

test_normalise_replaces_paths_the_clock_and_shas() {
  local fake d utc sha1 sha2 out
  _rec_begin
  export JIG_NOW=1700000000
  sha1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  sha2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  fake=$(_rec_fake shaout <<EOF
printf 'first $sha1\n'
EOF
)
  _rec_call "$fake" > /dev/null
  d=$(_rec_d 0001)
  assert_eq pinned "$(_rec_meta "$d" clock)"
  assert_eq "first <sha:1>" "$(cat "$d/norm/stdout")"
  assert_eq "$(printf '1\t%s' "$sha1")" "$(cat "$d/shas")"
  utc=$(date -u -r 1700000000 +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d @1700000000 +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\n' \
    "repo at $JIG_TEST_TMP/repo and $JIG_TEST_TMP.tmpdir/x" \
    "stamp $utc epoch 1700000000" \
    "commit $sha1 short ${sha1%?????????????????????????????????} then $sha2 short ${sha2%?????????????????????????????????} unknown ccccccc" \
    "word ${sha1}x and path/${sha2}" \
    "revision 1700000003 not 1700001001 nor 17000000030" \
    "host $JIG_VERIFY_RUN_HOST" > "$JIG_TEST_TMP.outx"
  out=$(bash "$REC_BIN" normalise "$d" "$JIG_TEST_TMP.outx")
  assert_eq "$(printf '%s\n' \
    'repo at <T>/repo and <T>.tmpdir/x' \
    'stamp <NOW_UTC> epoch <NOW>' \
    'commit <sha:1> short <sha:1> then <sha:2> short <sha:2> unknown ccccccc' \
    'word '"$sha1"'x and path/<sha:2>' \
    'revision <NOW+3> not 1700001001 nor 17000000030' \
    'host <RUN_HOST>')" "$out"
  # a foreign output does not add to the call's own map
  assert_eq "$(printf '1\t%s' "$sha1")" "$(cat "$d/shas")"
  # from stdin; no final newline stays none
  out=$(printf '%s' "$JIG_TEST_TMP/a" | bash "$REC_BIN" normalise "$d" | od -An -c | tr -d ' ')
  assert_eq '<T>/a' "$(printf '%s' "$out" | sed 's/\\n$//')"
  assert_eq 5 "$(printf '%s' "$JIG_TEST_TMP/a" | bash "$REC_BIN" normalise "$d" | wc -c | tr -d ' ')" "no newline added"
  # a file with a NUL becomes binary <blob id>
  printf 'a\000b %s\n' "$JIG_TEST_TMP" > "$JIG_TEST_TMP.outx"
  assert_eq "binary $(git hash-object --no-filters "$JIG_TEST_TMP.outx")" "$(bash "$REC_BIN" normalise "$d" "$JIG_TEST_TMP.outx")"
}

# _rec_det_run <name> <now> <git date> — the same scenario, in a directory of its
# own and on its own clock. The date git stamps commits with is read from a file
# beside the test directory (not from the environment, which is recorded).
_rec_det_run() {
  local name="$1" fake
  (
    W="$JIG_TEST_TMP.outdet"
    mkdir -p "$W/$name" "$W/rec-$name"
    export JIG_TEST_TMP="$W/$name"
    export JIG_RECORD_DIR="$W/rec-$name"
    export JIG_NOW="$2"
    cd "$JIG_TEST_TMP" || exit 1
    printf '%s\n' "$3" > "$JIG_TEST_TMP.outdate"
    fake="$W/scenario"
    cat > "$fake" <<'EOF'
#!/bin/sh
set -e
GIT_AUTHOR_DATE=$(cat "$JIG_TEST_TMP.outdate")
GIT_COMMITTER_DATE=$GIT_AUTHOR_DATE
export GIT_AUTHOR_DATE GIT_COMMITTER_DATE
printf 'now %s\n' "$JIG_NOW"
printf 'at %s\n' "$JIG_TEST_TMP"
mkdir repo
cd repo
git init -q .
git symbolic-ref HEAD refs/heads/main
printf 'hello\n' > f.txt
git add f.txt
git commit -q -m first
printf 'full %s\n' "$(git rev-parse HEAD)"
printf 'short %s\n' "$(git rev-parse --short=9 HEAD)"
printf 'again\n' >> f.txt
git commit -q -a -m second
printf 'second %s\n' "$(git rev-parse HEAD)"
printf '\000\001binary\n' > blob.bin
printf 'dirty\n' > untracked.txt
EOF
    _rec_call "$fake" > /dev/null
  )
}

test_two_recordings_of_the_same_scenario_normalise_to_the_same_bytes() {
  local a b
  _rec_begin
  _rec_det_run a 1700000000 "2020-01-01T00:00:00Z"
  _rec_det_run b 1800000123 "2021-02-03T04:05:06Z"
  a="$JIG_TEST_TMP.outdet/rec-a/calls/recorder/$REC_NAME/0001"
  b="$JIG_TEST_TMP.outdet/rec-b/calls/recorder/$REC_NAME/0001"
  assert_dir "$a/norm"
  assert_dir "$b/norm"
  # the raw records do differ: that is what the normaliser is for
  if cmp -s "$a/stdout" "$b/stdout"; then
    fail "the two scenarios should differ in time, path and commit ids"
  fi
  assert_eq "" "$(_rec_meta "$a" recorder_error)"
  assert_eq "" "$(_rec_meta "$b" recorder_error)"
  # norm/ is byte for byte the same; the real ids behind the numbers live
  # beside it, in shas, and are what differs
  diff -r "$a/norm" "$b/norm" || fail "the normalised views differ"
  assert_eq "$(cut -f 1 "$a/shas")" "$(cut -f 1 "$b/shas")" "the same numbers"
  if cmp -s "$a/shas" "$b/shas"; then fail "the commit ids should differ"; fi
  assert_contains "$(cat "$a/norm/stdout")" "now <NOW>"
  assert_contains "$(cat "$a/norm/stdout")" "at <T>"
  # numbered by first appearance: git.after (the branch tip) comes before stdout
  assert_contains "$(cat "$a/norm/stdout")" "full <sha:2>"
  assert_contains "$(cat "$a/norm/stdout")" "short <sha:2>"
  assert_contains "$(cat "$a/norm/stdout")" "second <sha:1>"
  assert_contains "$(cat "$a/norm/git.after")" "ref <sha:1> refs/heads/main"
  assert_contains "$(cat "$a/norm/git.after")" "status ?? untracked.txt"
  assert_contains "$(cat "$a/norm/changes")" "A"$'\t'"<T>/repo/blob.bin"
  case "$(cat "$a/norm/files/_T_/repo/blob.bin")" in binary\ ?*) ;; *) fail "blob.bin is not binary in norm/" ;; esac
}

test_a_recording_that_cannot_be_made_does_not_change_the_call() {
  local fake out rc d
  _rec_begin
  fake=$(_rec_fake plain <<'EOF'
printf 'out\n'
printf 'err\n' >&2
exit 4
EOF
)
  # the record directory cannot be made
  printf 'x' > "$JIG_TEST_TMP.outfile"
  rc=0
  JIG_RECORD_DIR="$JIG_TEST_TMP.outfile/rec" _rec_call "$fake" > "$JIG_TEST_TMP.outo" 2> "$JIG_TEST_TMP.oute" || rc=$?
  assert_eq 4 "$rc"
  assert_eq out "$(cat "$JIG_TEST_TMP.outo")"
  assert_eq err "$(cat "$JIG_TEST_TMP.oute")"
  # the variables are missing altogether
  rc=0
  env -u JIG_RECORD_DIR -u JIG_RECORD_TEST bash "$REC_BIN" record "$fake" > "$JIG_TEST_TMP.outo" 2> "$JIG_TEST_TMP.oute" || rc=$?
  assert_eq 4 "$rc"
  assert_eq out "$(cat "$JIG_TEST_TMP.outo")"
  # the blob store is unusable: the call is still made and the failure is named
  mkdir -p "$REC.broken"
  printf 'jig-recording 2\n' > "$REC.broken/FORMAT"
  printf 'not a repository\n' > "$REC.broken/store.git"
  rc=0
  JIG_RECORD_DIR="$REC.broken" _rec_call "$fake" > "$JIG_TEST_TMP.outo" 2> "$JIG_TEST_TMP.oute" || rc=$?
  assert_eq 4 "$rc"
  assert_eq out "$(cat "$JIG_TEST_TMP.outo")"
  assert_eq err "$(cat "$JIG_TEST_TMP.oute")"
  d="$REC.broken/calls/recorder/$REC_NAME/0001"
  assert_dir "$d"
  assert_eq 4 "$(_rec_meta "$d" exit)"
  assert_contains "$(_rec_meta "$d" recorder_error)" "store"
  out=$(cat "$d/stdout")
  assert_eq out "$out"
}

# _rec_git_wrapper <body> — a `git` first on the runner's PATH as the recorder sees
# it (the base environment), outside the trees. $REAL is the real git and $LOG the
# wrapper's log file; the body runs before git does.
_rec_git_wrapper() {
  local real
  real=$(env -i PATH="$PATH" /bin/sh -c 'command -v git')
  case "$real" in /*) ;; *) fail "no absolute git on PATH: $real" ;; esac
  {
    printf "#!/bin/sh\nREAL='%s'\nLOG='%s'\n" "$real" "$JIG_TEST_TMP.outgit.log"
    printf '%s\n' "$1"
    printf 'exec "$REAL" "$@"\n'
  } > "$JIG_TEST_TMP.outbin/git"
  chmod +x "$JIG_TEST_TMP.outbin/git"
  printf 'PATH=%s:%s\000HOME=/nonexistent-runner-home\000GH_TOKEN=runner-secret\000' \
    "$JIG_TEST_TMP.outbin" "$PATH" > "$JIG_TEST_TMP.outenv"
}

test_a_placeholder_in_a_norm_files_name_is_path_safe() {
  local fake d name
  _rec_begin
  fake=$(_rec_fake plain <<'EOF'
printf 'two\n' > plain.txt
EOF
)
  _rec_call "$fake"
  d=$(_rec_d 0001)
  assert_eq "" "$(_rec_meta "$d" recorder_error)"
  assert_contains "$(cat "$d/norm/changes")" "A"$'\t'"<T>/plain.txt"
  assert_eq "two" "$(cat "$d/norm/files/_T_/plain.txt")"
  name=$(cd "$d/norm/files" && find . | grep '[<>]' || true)
  assert_eq "" "$name" "no placeholder bracket in a name under norm/files"
}

test_a_name_under_norm_files_holds_no_byte_ntfs_forbids() {
  local fake d name
  skip_unless_ntfs_forbidden_names
  _rec_begin
  fake=$(_rec_fake odd <<'EOF'
mkdir 'we<ir>d'
printf 'one\n' > 'we<ir>d/a:b"c|d?e*f.txt'
EOF
)
  _rec_call "$fake"
  d=$(_rec_d 0001)
  assert_eq "" "$(_rec_meta "$d" recorder_error)"
  assert_contains "$(cat "$d/norm/changes")" "A"$'\t'"<T>/we<ir>d/a:b\"c|d?e*f.txt"
  assert_eq "one" "$(cat "$d/norm/files/_T_/we_ir_d/a_b_c_d_e_f.txt")"
  name=$(cd "$d/norm/files" && find . | grep '[<>:"\\|?*]' || true)
  assert_eq "" "$name" "no name under norm/files holds < > : \" \\ | ? *"
}

test_an_error_noted_in_a_step_subshell_reaches_meta() {
  local fake d out rc=0
  _rec_begin
  _rec_git_wrapper 'case " $* " in *" cat-file blob "*) exit 1 ;; esac'
  fake=$(_rec_fake adds <<'EOF'
printf 'out\n'
printf 'added\n' > added.txt
exit 5
EOF
)
  _rec_call "$fake" > "$JIG_TEST_TMP.outo" 2>&1 || rc=$?
  assert_eq 5 "$rc" "the call's exit is unchanged"
  assert_eq out "$(cat "$JIG_TEST_TMP.outo")" "the call's output is unchanged"
  d=$(_rec_d 0001)
  out=$(_rec_meta "$d" recorder_error)
  assert_contains "$out" "blob-missing"
  assert_not_contains "$out" "blob-missing,blob-missing" "each step is named once"
  assert_eq "<T>.outbin/adds" "$(_rec_meta "$d" entry)" "the folded errors leave entry alone"
  assert_no_file "$d/.errors"
}

test_blobs_are_hashed_from_paths_relative_to_the_trees_parent() {
  local fake d id
  _rec_begin
  _rec_git_wrapper 'case " $* " in *" --stdin-paths "*) cat > "$LOG.in"; cat "$LOG.in" >> "$LOG"; exec "$REAL" "$@" < "$LOG.in" ;; esac'
  fake=$(_rec_fake adds <<'EOF'
printf 'added\n' > added.txt
EOF
)
  _rec_call "$fake"
  d=$(_rec_d 0001)
  assert_eq "" "$(_rec_meta "$d" recorder_error)"
  assert_file "$JIG_TEST_TMP.outgit.log"
  if grep -q '^/' "$JIG_TEST_TMP.outgit.log"; then fail "an absolute path went through stdin"; fi
  assert_contains "$(cat "$JIG_TEST_TMP.outgit.log")" "${JIG_TEST_TMP##*/}/added.txt"
  id=$(_rec_list "$d/tree.after" | grep -F "<T>/added.txt" | cut -f 3)
  assert_eq "added" "$(git --git-dir="$REC/store.git" cat-file blob "$id")"
}

test_output_to_a_file_is_written_as_jig_runs_not_after() {
  local fake d log
  _rec_begin
  log="$JIG_TEST_TMP.outlog"
  printf 'before\n' > "$log"
  # The call reads its own log while it runs: a test polling a background
  # call's log for a line must see it before the call ends.
  fake=$(_rec_fake streams <<'EOF2'
printf 'first\n'
printf 'to stderr\n' >&2
if grep -q '^first$' "$1"; then printf 'streamed\n'; else printf 'held back\n'; fi
EOF2
)
  _rec_call "$fake" "$log" >> "$log" 2>&1
  assert_eq "$(printf 'before\nfirst\nto stderr\nstreamed')" "$(cat "$log")" "the caller's file, written once"
  d=$(_rec_d 0001)
  assert_eq merged "$(_rec_meta "$d" streams)"
  assert_eq "$(printf 'first\nto stderr\nstreamed')" "$(cat "$d/stdout")" "only what the call added"
  # separate files, each written directly
  fake=$(_rec_fake streams2 <<'EOF2'
printf 'out\n'
printf 'err\n' >&2
EOF2
)
  _rec_call "$fake" > "$JIG_TEST_TMP.outo" 2> "$JIG_TEST_TMP.oute"
  d=$(_rec_d 0002)
  assert_eq separate "$(_rec_meta "$d" streams)"
  assert_eq out "$(cat "$JIG_TEST_TMP.outo")"
  assert_eq err "$(cat "$JIG_TEST_TMP.oute")"
  assert_eq out "$(cat "$d/stdout")"
  assert_eq err "$(cat "$d/stderr")"
}

test_a_malformed_jig_now_reaches_the_command_untouched() {
  local fake d rc=0
  _rec_begin
  export JIG_NOW=abc
  fake=$(_rec_fake clock <<'EOF2'
printf 'saw %s\n' "$JIG_NOW"
exit 2
EOF2
)
  run _rec_call "$fake"
  assert_eq 2 "$RC" "the command's own exit code"
  assert_eq "saw abc" "$OUT"
  d=$(_rec_d 0001)
  assert_eq real "$(_rec_meta "$d" clock)"
  assert_eq 2 "$(_rec_meta "$d" exit)"
  assert_eq "" "$(_rec_meta "$d" recorder_error)"
  assert_no_file "$(dirname "$d")/.active" "no call left marked as running"
}

test_git_state_describes_the_work_tree_not_a_git_dir_the_call_was_given() {
  local fake d
  _rec_begin
  git init -q alpha
  git -C alpha symbolic-ref HEAD refs/heads/alpha
  git init -q beta
  git -C beta symbolic-ref HEAD refs/heads/beta
  fake=$(_rec_fake gitdir <<'EOF2'
:
EOF2
)
  (cd alpha && export GIT_DIR="$JIG_TEST_TMP/beta/.git" && _rec_call "$fake")
  d=$(_rec_d 0001)
  assert_contains "$(cat "$d/git.before")" "$(printf '[worktree <T>/alpha]\nbranch alpha')"
  assert_contains "$(cat "$d/norm/env")" "GIT_DIR=<T>/beta/.git" "the call's own environment is still recorded"
}
