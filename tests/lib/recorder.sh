#!/usr/bin/env bash
# tests/lib/recorder.sh — the stack recorder (task stack-recorder, format 2).
#
# Test tooling only: it never ships to a project. `JIG_RECORD=<dir> tests/run.sh`
# exports JIG_RECORDER=<this file>, and the dispatcher (scripts/jig) hands every
# outermost call to
#
#   recorder.sh record <jig-path> <args...>
#
# which runs the real jig under JIG_RECORDING=<file>::<test>::<NNNN> (so nested
# calls are not recorded) and keeps, under
#   $JIG_RECORD_DIR/calls/<file>/<test>/<NNNN>/
# the raw call (argv, cwd, env, stdin, stdout, stderr, exit, file trees before
# and after, git state, changes) and the normalised views under norm/. File
# contents live as blobs in $JIG_RECORD_DIR/store.git.
#
#   recorder.sh normalise <call-dir> [<file>]
#
# prints a file (or stdin) the way norm/ views were made, with that call's
# substitution table and SHA map, so that another implementation's output can be
# compared with a recording.
#
# A call whose working directory is not inside the test's directory or one beside
# it ($JIG_TEST_TMP.*) is not recorded: its trees would say nothing about it.
#
# Variables (set by tests/run.sh for each test):
#   JIG_RECORD_DIR       the record directory (absolute)
#   JIG_RECORD_TEST      <file>::<test>
#   JIG_RECORD_BASE_ENV  NUL-separated NAME=VALUE snapshot of the runner's environment
#   JIG_RECORD_ROOT      the checkout under test (the <ROOT> placeholder)
#
# The recorder must never change the outcome of the call it records: when a
# step of recording fails, jig still runs and its output and exit code come back
# as they would have, and `recorder_error=<what>` goes into meta.
#
# Notes for readers: paths of the trees may not contain the bytes \001 and \002
# (they stand for separators and newlines while a list is being sorted); the
# tools used are those of the runner's own PATH, because a test's PATH holds
# stubs (a `git` that logs) that recording must not call.
# shellcheck disable=SC2016 # awk programs run through $C (env LC_ALL=C), which hides awk from shellcheck
set -eu
set -o pipefail

NL=$'\n'
TAB=$'\t'
C="env LC_ALL=C"

# --- small helpers ------------------------------------------------------------

# A step run by _rec_sub is a subshell: its REC_ERRORS dies with it, so the step
# name is also appended to $REC_DIR/.errors, which _rec_post folds in.
_rec_err() {
  REC_ERRORS="${REC_ERRORS:+$REC_ERRORS,}$1"
  if [ -n "${REC_DIR:-}" ] && [ -d "$REC_DIR" ]; then
    printf '%s\n' "$1" >> "$REC_DIR/.errors" 2>/dev/null || :
  fi
}

# _rec_now_valid — JIG_NOW is set and is seconds since the epoch, as the
# dispatcher accepts it (common.sh, jig_now_valid). Anything else is the
# dispatcher's to refuse; the recorder only must not trip over it first.
_rec_now_valid() {
  case "${JIG_NOW:-}" in
    '' | *[!0-9]* | ???????????????*) return 1 ;;
  esac
}

# _rec_sub <step> <function> [args...] — one recording step in a subshell of its
# own, so that no shell error in it (a failed expansion is fatal and no `||`
# catches it) can skip the call; the recorder's own git reads never take the
# location the call was given (GIT_DIR and the rest name the call's repository,
# the dispatcher clears them only after this hook), and a failed step is noted.
_rec_sub() {
  local step="$1"
  shift
  (
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_INDEX_FILE GIT_NAMESPACE \
      GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM
    "$@"
  ) || _rec_err "$step"
}

# NUL-terminated records <-> newline-terminated lines (a newline inside a record
# becomes \002), so that awk and sort can handle names with any byte but NUL.
_enc() { $C tr '\n\000' '\002\n'; }
_dec() { $C tr '\n\002' '\000\n'; }

# _has_nul <file> — whether the file holds a NUL byte.
_has_nul() {
  $C tr -d '\000' < "$1" > "$REC_SCR/nul.probe" || return 1
  if cmp -s "$REC_SCR/nul.probe" "$1"; then
    return 1
  fi
  return 0
}

# _blob_id <file> — the id git would give the file's bytes (nothing written).
_blob_id() {
  git hash-object --no-filters -- "$1"
}

# --- normalisation ------------------------------------------------------------

# _nf_filter <call-dir> <persist 0|1> <esc 0|1> <sha 0|1> <nonl 0|1> — the
# normaliser, stdin to stdout. Literal substitutions come from <call-dir>/subst,
# SHAs are numbered against <call-dir>/shas (new ones are appended to it
# when <persist> is 1), <esc> escapes backslash and \002 (newline) first, and
# <nonl> says the input has no final newline, which the output then lacks too.
_nf_filter() {
  NF_SUBST="$1/subst" NF_SHAS="$1/shas" NF_PERSIST="$2" NF_ESC="$3" NF_SHA="$4" NF_NONL="$5" \
    $C awk '
    function repl(s, from, to,   out, i, lf) {
      lf = length(from)
      if (lf == 0) return s
      out = ""
      while ((i = index(s, from)) > 0) {
        out = out substr(s, 1, i - 1) to
        s = substr(s, i + lf)
      }
      return out s
    }
    function esc(s,   out, i, n, c) {
      out = ""
      n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\") out = out "\\\\"
        else if (c == "\002") out = out "\\n"
        else out = out c
      }
      return out
    }
    function mapsha(tok,   tl, i) {
      tl = length(tok)
      if (tl < 7 || tl > 40 || tok !~ /^[0-9a-f]+$/) return tok
      if (tl == 40) {
        if (!(tok in seen)) {
          maxn++
          seen[tok] = maxn
          nks++
          ks[nks] = tok
          if (shaout != "") printf "%d\t%s\n", maxn, tok >> shaout
        }
        return "<sha:" seen[tok] ">"
      }
      for (i = 1; i <= nks; i++)
        if (substr(ks[i], 1, tl) == tok) return "<sha:" seen[ks[i]] ">"
      return tok
    }
    # A whole number a little above the pinned clock is a count that started
    # from it (the clone revision seeds itself with JIG_NOW and adds one per
    # write): <NOW+k>, so two recordings on different clocks read the same.
    function nowtext(s,   out, rest, v) {
      out = ""
      rest = s
      while (match(rest, /[0-9]+/)) {
        v = substr(rest, RSTART, RLENGTH)
        if (length(v) == length(nowv) && v + 0 > nowv + 0 && v + 0 <= nowv + 1000) v = "<NOW+" (v - nowv) ">"
        out = out substr(rest, 1, RSTART - 1) v
        rest = substr(rest, RSTART + RLENGTH)
      }
      return out rest
    }
    function shatext(s,   out, rest) {
      out = ""
      rest = s
      while (match(rest, /[A-Za-z0-9_]+/)) {
        out = out substr(rest, 1, RSTART - 1) mapsha(substr(rest, RSTART, RLENGTH))
        rest = substr(rest, RSTART + RLENGTH)
      }
      return out rest
    }
    BEGIN {
      sf = ENVIRON["NF_SUBST"]
      while ((getline row < sf) > 0) {
        t = index(row, "\t")
        if (t < 2) continue
        nsub++
        ph[nsub] = substr(row, 1, t - 1)
        orig[nsub] = substr(row, t + 1)
        if (ph[nsub] == "<NOW>") nowv = orig[nsub]
      }
      close(sf)
      hf = ENVIRON["NF_SHAS"]
      while ((getline row < hf) > 0) {
        t = index(row, "\t")
        if (t < 2) continue
        num = substr(row, 1, t - 1) + 0
        s = substr(row, t + 1)
        if (!(s in seen)) { seen[s] = num; nks++; ks[nks] = s }
        if (num > maxn) maxn = num
      }
      close(hf)
      shaout = (ENVIRON["NF_PERSIST"] == "1") ? hf : ""
      esc_on = (ENVIRON["NF_ESC"] == "1")
      sha_on = (ENVIRON["NF_SHA"] == "1")
      nonl = (ENVIRON["NF_NONL"] == "1")
    }
    {
      line = $0
      if (esc_on) line = esc(line)
      if (sha_on && line ~ /[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]/) line = shatext(line)
      for (i = 1; i <= nsub; i++) line = repl(line, orig[i], ph[i])
      if (nowv != "" && line ~ /[0-9]/) line = nowtext(line)
      if (have) print prev
      prev = line
      have = 1
    }
    END {
      if (have) {
        if (nonl) printf "%s", prev
        else print prev
      }
      if (shaout != "") close(shaout)
    }'
}

# _nf_nonl <file> — 1 when the file is not empty and does not end in a newline.
_nf_nonl() {
  local last
  if [ ! -s "$1" ]; then
    printf '0\n'
    return 0
  fi
  last=$(tail -c 1 "$1" | od -An -tx1)
  case "$last" in
    *0a*) printf '0\n' ;;
    *) printf '1\n' ;;
  esac
}

# _nf_text <call-dir> <file> <persist> — a file as its norm/ view: its text
# normalised, or `binary <blob id>` when it holds a NUL.
_nf_text() {
  local dir="$1" file="$2" persist="$3" nonl
  if _has_nul "$file"; then
    printf 'binary %s\n' "$(_blob_id "$file")"
    return 0
  fi
  nonl=$(_nf_nonl "$file")
  _nf_filter "$dir" "$persist" 0 1 "$nonl" < "$file"
}

cmd_normalise() {
  local dir file="" scr input
  [ $# -ge 1 ] && [ $# -le 2 ] || { printf 'usage: recorder.sh normalise <call-dir> [<file>]\n' >&2; exit 2; }
  dir="$1"
  [ $# -lt 2 ] || file="$2"
  [ -d "$dir" ] || { printf 'recorder.sh normalise: not a call directory: %s\n' "$dir" >&2; exit 2; }
  scr=$(mktemp -d "${TMPDIR:-/tmp}/jig-normalise.XXXXXX") || exit 1
  REC_SCR="$scr"
  trap 'rm -rf "$scr"' EXIT
  if [ -n "$file" ]; then
    input="$file"
  else
    input="$scr/stdin"
    cat > "$input"
  fi
  _nf_text "$dir" "$input" 0
}

# --- recording ------------------------------------------------------------------

# _rec_fd_file_v <fd> <var> — <var> <- the path of the regular file this
# shell's <fd> writes to, or fail: /proc/<pid>/fd on Linux and Git Bash, lsof
# elsewhere (macOS). It runs in this shell, never in $(...), where descriptor 1
# would be the substitution's pipe; the helpers it starts look at this shell's
# descriptors by its pid. A name that is not the very file the descriptor holds
# (renamed, deleted, an escaped name) is not used: on Linux the path and the
# descriptor are compared with -ef; on macOS `-ef /dev/fd/<n>` does not see the
# file behind the descriptor, so the inode lsof reports is compared with the
# path's own.
_rec_fd_file_v() {
  local fd="$1" p="" ino="" got
  if [ -L "/proc/$$/fd/$fd" ]; then
    p=$(readlink "/proc/$$/fd/$fd" 2>/dev/null) || return 1
    [ -n "$p" ] && [ -f "$p" ] && [ "$p" -ef "/proc/$$/fd/$fd" ] || return 1
  elif command -v lsof >/dev/null 2>&1; then
    got=$(lsof -a -p "$$" -d "$fd" -Fin 2>/dev/null) || return 1
    p=$(printf '%s\n' "$got" | sed -n 's/^n//p')
    ino=$(printf '%s\n' "$got" | sed -n 's/^i//p')
    [ -n "$p" ] && [ -n "$ino" ] && [ -f "$p" ] || return 1
    got=$(ls -di "$p" 2>/dev/null) || return 1
    got=${got#"${got%%[! ]*}"}
    [ "${got%% *}" = "$ino" ] || return 1
  else
    return 1
  fi
  printf -v "$2" '%s' "$p"
}

# _rec_size <file> — its size in bytes.
_rec_size() {
  local n
  n=$(wc -c < "$1") || return 1
  printf '%s\n' "$((n + 0))"
}

# _rec_plain <args...> — run the real jig as if nothing recorded it, and end.
_rec_plain() {
  if [ -n "${REC_CALL_PATH+x}" ]; then
    PATH="$REC_CALL_PATH"
    export PATH
  fi
  JIG_RECORDING="${JIG_RECORDING:-unrecorded}"
  export JIG_RECORDING
  exec "$BASH" "$REC_JIG" "$@"
}

# _rec_load_base — the runner's environment as variables _rb_<name>, and
# REC_BASE_PATH.
_rec_load_base() {
  local rec name
  [ -f "$JIG_RECORD_BASE_ENV" ] || return 1
  while IFS= read -r -d '' rec; do
    name=${rec%%=*}
    case "$name" in
      '' | [0-9]* | *[!A-Za-z0-9_]*) continue ;;
    esac
    printf -v "_rb_$name" '%s' "${rec#*=}"
  done < "$JIG_RECORD_BASE_ENV"
  REC_BASE_PATH=${_rb_PATH:-}
}

# _rec_cwd_in_test — whether the call runs inside the test's own world, the
# directory or one beside it: a call made anywhere else (the fixture cache a
# first test builds when tests run one at a time, a scratch directory in /tmp)
# has file trees that say nothing about it, and is not recorded.
_rec_cwd_in_test() {
  local t
  for t in "$JIG_TEST_TMP" "$(_rec_logical "$JIG_TEST_TMP")" "$(_rec_phys "$JIG_TEST_TMP")"; do
    [ -n "$t" ] || continue
    case "$PWD" in
      "$t" | "$t"/* | "$t".*) return 0 ;;
    esac
  done
  return 1
}

# _rec_setup — everything that has to hold before a call can be recorded: the
# variables, the call's directory and its number. Fails with nothing recorded.
_rec_setup() {
  local n
  case "${JIG_RECORD_DIR:-}" in /?*) ;; *) return 1 ;; esac
  case "${JIG_RECORD_TEST:-}" in ?*::?*) ;; *) return 1 ;; esac
  [ -n "${JIG_TEST_TMP:-}" ] || return 1
  [ -n "${JIG_RECORD_BASE_ENV:-}" ] || return 1
  _rec_cwd_in_test || return 1
  REC_FILE=${JIG_RECORD_TEST%%::*}
  REC_TEST=${JIG_RECORD_TEST#*::}
  case "$REC_FILE$REC_TEST" in */* | *"$NL"*) return 1 ;; esac
  _rec_load_base || return 1
  if [ -n "$REC_BASE_PATH" ]; then
    PATH="$REC_BASE_PATH"
    export PATH
  fi
  REC_TDIR="$JIG_RECORD_DIR/calls/$REC_FILE/$REC_TEST"
  mkdir -p "$REC_TDIR" || return 1
  [ -w "$REC_TDIR" ] || return 1
  n=1
  while :; do
    printf -v REC_SEQ '%04d' "$n"
    if mkdir "$REC_TDIR/$REC_SEQ" 2>/dev/null; then
      break
    fi
    n=$((n + 1))
    [ "$n" -le 9999 ] || return 1
  done
  REC_DIR="$REC_TDIR/$REC_SEQ"
  REC_SCR="$REC_DIR/.tmp"
  mkdir "$REC_SCR" || return 1
  REC_STORE="$JIG_RECORD_DIR/store.git"
  return 0
}

# _rec_active_others — 1 when a call other than this one is marked active.
_rec_active_others() {
  local m
  for m in "$REC_TDIR/.active/"*; do
    [ -e "$m" ] || continue
    [ "${m##*/}" != "$REC_SEQ" ] || continue
    return 0
  done
  return 1
}

# _rec_later_started — whether a call numbered after this one exists: it began
# while this one was still running.
_rec_later_started() {
  local m
  for m in "$REC_TDIR/"[0-9][0-9][0-9][0-9]; do
    [ -d "$m" ] || continue
    if [ "$((10#${m##*/}))" -gt "$((10#$REC_SEQ))" ]; then
      return 0
    fi
  done
  return 1
}

_rec_store_init() {
  if [ -f "$REC_STORE/HEAD" ]; then
    return 0
  fi
  git init --bare -q "$REC_STORE" 2>/dev/null || [ -f "$REC_STORE/HEAD" ]
}

# _rec_env — $REC_DIR/env: what differs from the runner's environment, plus
# PATH, LANG, LC_*, TZ and JIG_NOW always; never the recorder's own variables.
_rec_env() {
  local out="$REC_DIR/env" name value ref
  : > "$out"
  while IFS= read -r name; do
    case "$name" in
      JIG_RECORD | JIG_RECORD_* | JIG_RECORDER | JIG_RECORDING | _ | SHLVL | PWD | OLDPWD) continue ;;
    esac
    if [ "$name" = PATH ]; then
      value=$REC_CALL_PATH
    else
      value=${!name}
    fi
    case "$name" in
      PATH | LANG | LC_* | TZ | JIG_NOW) ;;
      *)
        ref="_rb_$name"
        if [ -n "${!ref+x}" ] && [ "${!ref}" = "$value" ]; then
          continue
        fi
        ;;
    esac
    printf '%s=%s\000' "$name" "$value" >> "$out"
  done < <(compgen -e | $C sort)
}

# _rec_phys <path> — the physical form of an existing directory, else nothing.
_rec_phys() {
  if [ -d "$1" ]; then
    (cd "$1" 2>/dev/null && pwd -P) || true
  fi
}

# _rec_logical <path> — an existing directory as `cd` names it: `//` folded.
_rec_logical() {
  if [ -d "$1" ]; then
    (cd "$1" 2>/dev/null && pwd) || true
  fi
}

# _rec_phys_list <colon list> — the same list with every directory physical.
_rec_phys_list() {
  local IFS=: comp out="" one
  for comp in $1; do
    one=""
    if [ -n "$comp" ]; then one=$(_rec_phys "$comp"); fi
    [ -n "$one" ] || one=$comp
    out="${out:+$out:}$one"
  done
  printf '%s' "$out"
}

# _rec_subst_add <placeholder> <original> — one row of the substitution table,
# unless that original has one already.
_rec_subst_add() {
  [ -n "$2" ] || return 0
  case "$SUBST_SEEN" in *"$NL$2$NL"*) return 0 ;; esac
  SUBST_SEEN="$SUBST_SEEN$2$NL"
  SUBST_N=$((SUBST_N + 1))
  printf '%s\t%s\t%s\t%s\n' "${#2}" "$SUBST_N" "$1" "$2" >> "$SUBST_LIST"
}

# _rec_subst — $REC_DIR/subst: placeholder, TAB, original; longest original
# first, each path in its logical and physical form, then the call's clock.
_rec_subst() {
  local p ph orig now utc today
  SUBST_LIST="$REC_SCR/subst.list"
  SUBST_SEEN="$NL"
  SUBST_N=0
  : > "$SUBST_LIST"
  for p in "JIG_HOME:${JIG_HOME:-}" "ROOT:${JIG_RECORD_ROOT:-}" "T:${JIG_TEST_TMP:-}" "CACHE:${JIG_TEST_CACHE:-}"; do
    ph="<${p%%:*}>"
    orig=${p#*:}
    [ -n "$orig" ] || continue
    _rec_subst_add "$ph" "$orig"
    _rec_subst_add "$ph" "$(_rec_logical "$orig")"
    _rec_subst_add "$ph" "$(_rec_phys "$orig")"
  done
  # The run host tests/run.sh derives from a hash of the test's directory.
  _rec_subst_add '<RUN_HOST>' "${JIG_VERIFY_RUN_HOST:-}"
  if [ -n "${REC_BASE_PATH:-}" ]; then
    _rec_subst_add '<PATH>' "$REC_BASE_PATH"
    _rec_subst_add '<PATH>' "$(_rec_phys_list "$REC_BASE_PATH")"
  fi
  if _rec_now_valid; then
    now=$((10#$JIG_NOW))
    utc=$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || utc=""
    today=$(date -r "$now" +%Y-%m-%d 2>/dev/null || date -d "@$now" +%Y-%m-%d 2>/dev/null) || today=""
    _rec_subst_add '<NOW_UTC>' "$utc"
    _rec_subst_add '<TODAY>' "$today"
    _rec_subst_add '<NOW>' "$JIG_NOW"
  fi
  $C sort -t "$TAB" -k1,1nr -k2,2n "$SUBST_LIST" | cut -f 3- > "$REC_DIR/subst"
}

# --- file trees -----------------------------------------------------------------

# _rec_roots — REC_ROOTS: the test's directory and the ones beside it, minus the
# $JIG_TEST_TMP.out* capture files of this very call and the record directory
# itself. A file inside the trees that a stream is redirected to is part of them.
_rec_roots() {
  local r
  REC_ROOTS=()
  REC_PRUNE=0
  [ -n "${JIG_TEST_TMP:-}" ] || return 0
  if [ -e "$JIG_TEST_TMP" ] || [ -L "$JIG_TEST_TMP" ]; then
    REC_ROOTS[0]=$JIG_TEST_TMP
  fi
  for r in "$JIG_TEST_TMP".*; do
    [ -e "$r" ] || [ -L "$r" ] || continue
    case "$r" in "$JIG_TEST_TMP".out*) continue ;; esac
    case "$r" in "$JIG_RECORD_DIR" | "$JIG_RECORD_DIR"/*) continue ;; esac
    REC_ROOTS[${#REC_ROOTS[@]}]=$r
  done
  for r in ${REC_ROOTS[@]+"${REC_ROOTS[@]}"}; do
    case "$JIG_RECORD_DIR" in "$r"/*) REC_PRUNE=1 ;; esac
  done
}

# _rec_hash_files <list-file> <ids-file> — one blob id per line of the list, `-`
# for a file that could not be stored.
_rec_hash_files() {
  local p id base="${JIG_TEST_TMP%/*}"
  # Paths go through stdin relative to the parent of $JIG_TEST_TMP (every root
  # starts with $JIG_TEST_TMP): an absolute path on stdin is a drive path on
  # Windows. Paths with a newline never reach this list (see _rec_snapshot).
  while IFS= read -r p; do
    printf '%s\n' "${p#"$base"/}"
  done < "$1" > "$1.rel"
  if (cd "$base" && git --git-dir="$REC_STORE" hash-object -w --no-filters --stdin-paths) < "$1.rel" > "$2" 2>/dev/null; then
    rm -f "$1.rel"
    return 0
  fi
  rm -f "$1.rel"
  : > "$2"
  while IFS= read -r p; do
    id=$(git --git-dir="$REC_STORE" hash-object -w --no-filters -- "$p" 2>/dev/null) || id="-"
    printf '%s\n' "$id" >> "$2"
  done < "$1"
}

# _rec_snapshot <before|after> — tree.<name> and gits.<name> in the call's
# directory. Records are NUL-terminated `type TAB mode TAB ref TAB path`, sorted
# by path, a path starting with <T> in place of $JIG_TEST_TMP (so a tree can be
# put back under another root); gits.<name> holds `g TAB <git dir>` and
# `w TAB <work tree>` with the real paths, for this recorder's own use.
_rec_snapshot() {
  local name="$1" tree="$REC_DIR/tree.$1" gits="$REC_DIR/gits.$1"
  local list="$REC_SCR/list.$1" raw="$REC_SCR/raw.$1" plain="$REC_SCR/plain.$1" ids="$REC_SCR/ids.$1"
  local p rp mode tgt id base
  : > "$tree"
  : > "$gits"
  _rec_roots
  [ "${#REC_ROOTS[@]}" -gt 0 ] || return 0
  if [ "$REC_PRUNE" -eq 1 ]; then
    { find "${REC_ROOTS[@]}" -path "$JIG_RECORD_DIR" -prune -o -print0 2>/dev/null || true; }
  else
    { find "${REC_ROOTS[@]}" -print0 2>/dev/null || true; }
  fi | _enc | $C sort | _dec > "$list"
  : > "$plain"
  {
    while IFS= read -r -d '' p; do
      case "$p" in
        "$JIG_TEST_TMP"*) rp="<T>${p#"$JIG_TEST_TMP"}" ;;
        *) rp=$p ;;
      esac
      if [ -L "$p" ]; then
        tgt=$(readlink "$p") || tgt="-"
        printf 'l\t-\t%s\t%s\000' "$tgt" "$rp"
      elif [ -d "$p" ]; then
        printf 'd\t-\t-\t%s\000' "$rp"
        base=${p##*/}
        if [ -f "$p/HEAD" ]; then
          if [ "$base" = .git ] || { [ -d "$p/objects" ] && [ -d "$p/refs" ]; }; then
            printf 'g\t%s\000' "$p" >&5
          fi
          if [ "$base" = .git ]; then
            printf 'w\t%s\000' "${p%/.git}" >&5
          fi
        fi
      elif [ -f "$p" ]; then
        if [ -x "$p" ]; then mode=755; else mode=644; fi
        case "$p" in
          *"$NL"*)
            id=$(git --git-dir="$REC_STORE" hash-object -w --no-filters -- "$p" 2>/dev/null) || id="-"
            printf 'f\t%s\t%s\t%s\000' "$mode" "$id" "$rp"
            ;;
          *)
            printf 'f\t%s\t@\t%s\000' "$mode" "$rp"
            printf '%s\n' "$p" >> "$plain"
            ;;
        esac
        # A work tree whose .git is a file (a linked worktree).
        if [ "${p##*/}" = .git ]; then
          printf 'w\t%s\000' "${p%/.git}" >&5
        fi
      elif [ -e "$p" ]; then
        printf 'o\t-\t-\t%s\000' "$rp"
      fi
    done < "$list"
  } 5> "$gits" > "$raw"
  _rec_hash_files "$plain" "$ids"
  _enc < "$raw" | IDS="$ids" $C awk '
    BEGIN { idf = ENVIRON["IDS"] }
    {
      if (match($0, /^f\t[0-9]+\t@\t/)) {
        if ((getline id < idf) <= 0) id = "-"
        $0 = substr($0, 1, RLENGTH - 2) id "\t" substr($0, RLENGTH + 1)
      }
      print
    }' | _dec > "$tree"
}

# _rec_rel <path> — the path with <T> in place of the test's directory.
_rec_rel() {
  case "$1" in
    "$JIG_TEST_TMP"*) printf '<T>%s\n' "${1#"$JIG_TEST_TMP"}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# --- git state ------------------------------------------------------------------

# _rec_gitstate <name> — git.<name>: the meaning of the git directories and work
# trees found in the tree, in byte order of path.
_rec_gitstate() {
  local name="$1" out="$REC_DIR/git.$1" kind p ref
  {
    while IFS="$TAB" read -r -d '' kind p; do
      case "$kind" in
        g)
          printf '[gitdir %s]\n' "$(_rec_rel "$p")"
          if ref=$(git --git-dir="$p" symbolic-ref -q HEAD 2>/dev/null); then
            printf 'HEAD ref: %s\n' "$ref"
          elif ref=$(git --git-dir="$p" rev-parse -q --verify HEAD 2>/dev/null); then
            printf 'HEAD %s\n' "$ref"
          else
            printf 'HEAD unborn\n'
          fi
          git --git-dir="$p" for-each-ref --format='ref %(objectname) %(refname)' 2>/dev/null || printf 'refs: error\n'
          git config --file "$p/config" --list 2>/dev/null | sed 's/^/config /' || printf 'config: error\n'
          ;;
        w)
          printf '[worktree %s]\n' "$(_rec_rel "$p")"
          if ref=$(git --no-optional-locks -C "$p" symbolic-ref -q --short HEAD 2>/dev/null); then
            printf 'branch %s\n' "$ref"
          else
            printf 'branch (detached)\n'
          fi
          if ref=$(git --no-optional-locks -C "$p" status --porcelain=v1 -z --untracked-files=all 2>/dev/null | $C tr '\000' '\n'); then
            if [ -n "$ref" ]; then
              printf '%s\n' "$ref" | sed 's/^/status /'
            fi
          else
            printf 'status: error\n'
          fi
          ;;
      esac
    done < <(_enc < "$REC_DIR/gits.$name" | $C sort -u | _dec)
  } > "$out"
}

# --- changes --------------------------------------------------------------------

# _rec_changes — `changes` (A/M/D/T and a path, NUL-terminated records) and the
# working file changes.x (path \001 letter \001 type \001 blob), without the
# files git keeps for itself.
_rec_changes() {
  local gd="$REC_SCR/gitdirs"
  cat "$REC_DIR/gits.before" "$REC_DIR/gits.after" | _enc | $C sort -u \
    | TT="$JIG_TEST_TMP" $C awk -F '\t' '
        $1 == "g" {
          g = substr($0, 3)
          if (index(g, ENVIRON["TT"]) == 1) g = "<T>" substr(g, length(ENVIRON["TT"]) + 1)
          print g
        }' > "$gd"
  _enc < "$REC_DIR/tree.before" > "$REC_SCR/tree.before.enc"
  _enc < "$REC_DIR/tree.after" | _rec_changes_awk "$gd" "$REC_SCR/tree.before.enc" > "$REC_SCR/changes.unsorted"
  $C sort "$REC_SCR/changes.unsorted" > "$REC_DIR/changes.x"
  $C awk '{ i = index($0, "\001"); j = index(substr($0, i + 1), "\001"); print substr($0, i + 1, j - 1) "\t" substr($0, 1, i - 1) }' \
    "$REC_DIR/changes.x" | _dec > "$REC_DIR/changes"
}

_rec_changes_awk() {
  REC_GD="$1" REC_BEFORE="$2" $C awk '
    function isint(c) {
      return (c == "objects" || c == "logs" || c == "refs" || c == "packed-refs" || c == "index" \
        || c == "HEAD" || c == "ORIG_HEAD" || c == "FETCH_HEAD" || c ~ /^MERGE_/ || c == "AUTO_MERGE" \
        || c ~ /^REBASE_/ || c ~ /^rebase-/ || c == "sequencer" || c == "COMMIT_EDITMSG" \
        || c == "config" || c == "description" || c ~ /\.lock$/ || c == "rr-cache" \
        || c == "worktrees" || c == "gc.log" || c == "shallow")
    }
    function internal(p,   pos, k, q, rel, c, j, hit) {
      pos = 0
      hit = ""
      while ((k = index(substr(p, pos + 1), "/")) > 0) {
        pos += k
        q = substr(p, 1, pos - 1)
        if (q != "" && (q in gd)) hit = q
      }
      if (hit == "") return 0
      rel = substr(p, length(hit) + 2)
      c = rel
      j = index(c, "/")
      if (j > 0) c = substr(c, 1, j - 1)
      return isint(c)
    }
    function parse(row,   a, b, c) {
      a = index(row, "\t")
      b = index(substr(row, a + 1), "\t")
      c = index(substr(row, a + b + 1), "\t")
      psig = substr(row, 1, a + b + c - 1)
      ptyp = substr(row, 1, 1)
      pref = substr(row, a + b + 1, c - 1)
      ppath = substr(row, a + b + c + 1)
    }
    BEGIN {
      f = ENVIRON["REC_GD"]
      while ((getline g < f) > 0) gd[g] = 1
      close(f)
      f = ENVIRON["REC_BEFORE"]
      while ((getline row < f) > 0) {
        parse(row)
        bsig[ppath] = psig
        btyp[ppath] = ptyp
      }
      close(f)
    }
    {
      parse($0)
      seen[ppath] = 1
      if (internal(ppath)) next
      if (!(ppath in bsig)) {
        printf "%s\001A\001%s\001%s\n", ppath, ptyp, (ptyp == "f" ? pref : "")
      } else if (bsig[ppath] != psig) {
        printf "%s\001%s\001%s\001%s\n", ppath, (btyp[ppath] != ptyp ? "T" : "M"), ptyp, (ptyp == "f" ? pref : "")
      }
    }
    END {
      for (p in bsig) {
        if ((p in seen) || internal(p)) continue
        printf "%s\001D\001%s\001\n", p, btyp[p]
      }
    }'
}

# --- norm/ ----------------------------------------------------------------------

_rec_norm() {
  local nd="$REC_DIR/norm" view x t r np dest
  mkdir -p "$nd/files" || return 1
  : > "$REC_DIR/shas"
  for view in git.before git.after stdout stderr; do
    [ -f "$REC_DIR/$view" ] || continue
    _nf_text "$REC_DIR" "$REC_DIR/$view" 1 > "$nd/$view"
  done
  # The paths of the changes, normalised in one pass (no SHA numbers in a path).
  $C awk '{ i = index($0, "\001"); j = index(substr($0, i + 1), "\001"); print substr($0, 1, i - 1) }' "$REC_DIR/changes.x" > "$REC_SCR/cpaths"
  _nf_filter "$REC_DIR" 0 1 0 0 < "$REC_SCR/cpaths" > "$REC_SCR/cpaths.norm"
  # The letter, type and blob of each change, TAB-separated: bash 3.2 does not
  # split a read on \001 (it is its own quoting byte), so the path is left out
  # here and read from cpaths.norm, line for line.
  $C awk '{ n = split($0, f, "\001"); print f[2] "\t" f[3] "\t" f[4] }' "$REC_DIR/changes.x" > "$REC_SCR/changes.t"
  # norm/changes: letter, TAB, normalised path.
  {
    exec 6< "$REC_SCR/cpaths.norm"
    while IFS="$TAB" read -r x t r; do
      IFS= read -r -u 6 np || np=""
      printf '%s\t%s\n' "$x" "$np"
    done < "$REC_SCR/changes.t"
    exec 6<&-
  } > "$nd/changes"
  # norm/files/<name>: every added or changed regular file, under its path with
  # each of < > : " \ | ? * made _, since NTFS forbids them in a name (two
  # paths may then share a name; a known limit). One tr for all the paths.
  $C tr '<>:"\\|?*' '_________' < "$REC_SCR/cpaths.norm" > "$REC_SCR/cpaths.files"
  exec 6< "$REC_SCR/cpaths.files"
  while IFS="$TAB" read -r x t r; do
    IFS= read -r -u 6 np || np=""
    case "$x$t" in
      Af | Mf | Tf) ;;
      *) continue ;;
    esac
    [ "$r" != "-" ] && [ -n "$r" ] || continue
    dest="$nd/files/$np"
    mkdir -p "$(dirname "$dest")" || { _rec_err "norm-file"; continue; }
    if git --git-dir="$REC_STORE" cat-file blob "$r" > "$REC_SCR/blob" 2>/dev/null; then
      _nf_text "$REC_DIR" "$REC_SCR/blob" 1 > "$dest" || _rec_err "norm-file"
    else
      _rec_err "blob-missing"
    fi
  done < "$REC_SCR/changes.t"
  exec 6<&-
  # argv, cwd and env last: they may hold SHAs, and numbering follows the views above.
  for view in argv cwd env; do
    _enc < "$REC_DIR/$view" > "$REC_SCR/view.enc"
    _nf_filter "$REC_DIR" 1 1 1 0 < "$REC_SCR/view.enc" > "$nd/$view"
  done
}

# --- the call -------------------------------------------------------------------

# _rec_pre — everything recorded before jig runs. Its own diagnostics go to
# recorder.log in the call's directory: nothing of the recorder reaches the
# caller's stderr.
_rec_pre() {
  _rec_store_init || _rec_err "store"
  mkdir -p "$REC_TDIR/.active" || _rec_err "active"
  REC_CONCURRENT=no
  if _rec_active_others; then REC_CONCURRENT=yes; fi
  mkdir "$REC_TDIR/.active/$REC_SEQ" || _rec_err "active"
  : > "$REC_DIR/argv"
  if [ "$#" -gt 0 ]; then
    printf '%s\000' "$@" > "$REC_DIR/argv" || _rec_err "argv"
  fi
  printf '%s\000' "$PWD" > "$REC_DIR/cwd" || _rec_err "cwd"
  # The call's environment as it is, GIT_DIR and the rest included.
  ( _rec_env ) || _rec_err env
  _rec_sub subst _rec_subst
  REC_CLOCK=real
  if _rec_now_valid; then REC_CLOCK=pinned; fi
  REC_STDIN=none
  if [ -t 0 ]; then
    REC_STDIN="tty"
  elif [ -p /dev/stdin ] || [ -f /dev/stdin ]; then
    REC_STDIN=data
    if cat > "$REC_DIR/stdin"; then
      exec 0< "$REC_DIR/stdin"
    else
      _rec_err "stdin"
    fi
  fi
  _rec_sub tree.before _rec_snapshot before
  _rec_sub git.before _rec_gitstate before
}

# _rec_post <exit code> — everything recorded after jig ran. None of it can
# change the result, which is already known.
_rec_post() {
  local rc="$1" entry step
  _rec_sub tree.after _rec_snapshot after
  _rec_sub git.after _rec_gitstate after
  _rec_sub changes _rec_changes
  _rec_sub norm _rec_norm
  if _rec_active_others || _rec_later_started; then REC_CONCURRENT=yes; fi
  entry=$(printf '%s\n' "$REC_JIG" | _nf_filter "$REC_DIR" 0 0 0 0) || entry="$REC_JIG"
  if [ -s "$REC_DIR/recorder.log" ]; then
    _rec_err "log"
  else
    rm -f "$REC_DIR/recorder.log"
  fi
  # Last: every _rec_err above has written its step here as well.
  if [ -s "$REC_DIR/.errors" ]; then
    while IFS= read -r step; do
      case ",$REC_ERRORS," in
        *",$step,"*) ;;
        *) REC_ERRORS="${REC_ERRORS:+$REC_ERRORS,}$step" ;;
      esac
    done < "$REC_DIR/.errors"
  fi
  rm -f "$REC_DIR/.errors"
  {
    printf 'format=2\n'
    printf 'test=%s::%s\n' "$REC_FILE" "$REC_TEST"
    printf 'seq=%s\n' "$REC_SEQ"
    printf 'exit=%s\n' "$rc"
    printf 'streams=%s\n' "$REC_STREAMS"
    printf 'stdin=%s\n' "$REC_STDIN"
    printf 'clock=%s\n' "$REC_CLOCK"
    printf 'concurrent=%s\n' "$REC_CONCURRENT"
    printf 'entry=%s\n' "$entry"
    if [ -n "$REC_ERRORS" ]; then
      printf 'recorder_error=%s\n' "$REC_ERRORS"
    fi
  } > "$REC_DIR/meta"
  rmdir "$REC_TDIR/.active/$REC_SEQ" 2>/dev/null || true
  rmdir "$REC_TDIR/.active" 2>/dev/null || true
  rm -f "$REC_DIR/gits.before" "$REC_DIR/gits.after" "$REC_DIR/changes.x"
  rm -rf "$REC_SCR"
}

cmd_record() {
  local rc=0 pid
  [ $# -ge 1 ] || { printf 'usage: recorder.sh record <jig-path> <args...>\n' >&2; exit 2; }
  REC_JIG="$1"
  shift
  REC_CALL_PATH="$PATH"
  REC_ERRORS=""
  if ! _rec_setup 2>/dev/null; then
    _rec_plain "$@"
  fi
  # From here on a failed step is noted in meta and the call is still made.
  REC_STREAMS=separate
  if [ /dev/fd/1 -ef /dev/fd/2 ]; then
    REC_STREAMS=merged
  fi
  # A stream that goes to a regular file jig writes itself, as it would without
  # the recorder: a test that reads the file while jig runs (a background call
  # polled for a line) sees each line as it is written. What the call added is
  # taken from the file afterwards. Any other stream goes to the call's
  # directory and is written back when jig ends.
  REC_OUT_FILE=""
  REC_ERR_FILE=""
  _rec_fd_file_v 1 REC_OUT_FILE || REC_OUT_FILE=""
  if [ "$REC_STREAMS" = separate ]; then
    _rec_fd_file_v 2 REC_ERR_FILE || REC_ERR_FILE=""
  fi
  REC_OUT_AT=0
  REC_ERR_AT=0
  [ -z "$REC_OUT_FILE" ] || REC_OUT_AT=$(_rec_size "$REC_OUT_FILE") || REC_OUT_FILE=""
  [ -z "$REC_ERR_FILE" ] || REC_ERR_AT=$(_rec_size "$REC_ERR_FILE") || REC_ERR_FILE=""
  _rec_pre "$@" 2>> "$REC_DIR/recorder.log" || _rec_err "pre"

  # jig runs in the background so that a signal sent to this process reaches it;
  # its output goes to files (bash 3.2 drops lines written into a pipe).
  PATH="$REC_CALL_PATH"
  export PATH
  JIG_RECORDING="$REC_FILE::$REC_TEST::$REC_SEQ"
  export JIG_RECORDING
  set +e
  if [ "$REC_STREAMS" = merged ]; then
    if [ -n "$REC_OUT_FILE" ]; then
      "$BASH" "$REC_JIG" "$@" <&0 &
    else
      "$BASH" "$REC_JIG" "$@" <&0 > "$REC_DIR/stdout" 2>&1 &
    fi
  elif [ -n "$REC_OUT_FILE" ] && [ -n "$REC_ERR_FILE" ]; then
    "$BASH" "$REC_JIG" "$@" <&0 &
  elif [ -n "$REC_OUT_FILE" ]; then
    "$BASH" "$REC_JIG" "$@" <&0 2> "$REC_DIR/stderr" &
  elif [ -n "$REC_ERR_FILE" ]; then
    "$BASH" "$REC_JIG" "$@" <&0 > "$REC_DIR/stdout" &
  else
    "$BASH" "$REC_JIG" "$@" <&0 > "$REC_DIR/stdout" 2> "$REC_DIR/stderr" &
  fi
  pid=$!
  trap 'kill -TERM "$pid" 2>/dev/null' TERM
  # A background job of a non-interactive shell has SIGINT ignored, so an INT
  # sent to this process reaches jig as a TERM, which its supervisor treats alike.
  trap 'kill -TERM "$pid" 2>/dev/null' INT
  trap 'kill -HUP "$pid" 2>/dev/null' HUP
  wait "$pid"
  rc=$?
  while kill -0 "$pid" 2>/dev/null; do
    wait "$pid"
    rc=$?
  done
  trap - TERM INT HUP
  unset JIG_RECORDING
  PATH="${REC_BASE_PATH:-$REC_CALL_PATH}"
  export PATH

  # What jig added to a file it wrote itself becomes the recorded stream.
  if [ -n "$REC_OUT_FILE" ]; then
    tail -c "+$((REC_OUT_AT + 1))" "$REC_OUT_FILE" > "$REC_DIR/stdout" 2>/dev/null || _rec_err "stdout"
  fi
  if [ -n "$REC_ERR_FILE" ]; then
    tail -c "+$((REC_ERR_AT + 1))" "$REC_ERR_FILE" > "$REC_DIR/stderr" 2>/dev/null || _rec_err "stderr"
  fi

  ( _rec_post "$rc" ) 2>> "$REC_DIR/recorder.log" || :

  # The rest of the output goes back to where jig would have written it.
  [ -n "$REC_OUT_FILE" ] || cat "$REC_DIR/stdout" 2>/dev/null
  if [ "$REC_STREAMS" = separate ] && [ -z "$REC_ERR_FILE" ]; then
    cat "$REC_DIR/stderr" >&2 2>/dev/null
  fi
  exit "$rc"
}

main() {
  local sub="${1:-}"
  [ $# -eq 0 ] || shift
  case "$sub" in
    record) cmd_record "$@" ;;
    normalise) cmd_normalise "$@" ;;
    *)
      printf 'usage: recorder.sh record <jig-path> <args...> | normalise <call-dir> [<file>]\n' >&2
      exit 2
      ;;
  esac
}

main "$@"
