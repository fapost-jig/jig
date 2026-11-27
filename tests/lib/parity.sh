#!/usr/bin/env bash
# tests/lib/parity.sh — the parity check (task parity-check).
#
# Test tooling only: it never ships to a project. It takes the recordings that
# `JIG_RECORD=<dir> tests/run.sh` wrote (format `jig-recording 2`,
# conventions/recordings.md), replays every recorded `jig` call on a port (any
# program: scripts/jig-next-ts, a built Go binary, or scripts/jig for a
# self-check) and compares what it did with the recording, by meaning.
#
#   parity.sh check --recordings <dir> --port <program> [--name <name>]
#                   [--port-env NAME=VALUE]... [--intended <file>] [--report <dir>]
#                   [--home <checkout>] [--command <word>]... [<file>::<test>]...
#
#   --recordings  a record directory (its FORMAT must say `jig-recording 2`)
#   --port        the program run in place of jig, with the recorded arguments. A path
#                 that begins with the literal `<JIG_HOME>/` is taken in the world's
#                 JIG_HOME of each call: `--port '<JIG_HOME>/scripts/jig'` replays
#                 the bash jig the recording was made with (the self-check), where a
#                 path of the working checkout would differ in its build suffix
#   --name        the port's name in the intended list (default: basename of --port)
#   --port-env    a variable the port needs and the recording lacks (JIG_NEXT_ROOT
#                 for the Go binary); repeatable
#   --intended    the list of intended differences (default: tests/parity/intended.tsv
#                 beside this tool): five TAB-separated fields, see that file
#   --report      keep, per call with a difference or an error, <dir>/<file>/<test>/<NNNN>/
#                 with one <view>.diff per differing view and the replay's own call
#                 directory (replay/); without it everything is a scratch directory
#   --home        the checkout a missing JIG_HOME of the world is built from (default:
#                 the checkout this tool lives in)
#   --command     only calls whose first argument is <word>; repeatable (or)
#   <file>::<test>  only that test's calls; <file>:: is a whole file; repeatable (or).
#                 Conditions of one kind are or-ed, of different kinds and-ed.
#
# Exit: 0 every selected call is equal or differs intentionally, nothing failed to
# replay, no list entry is stale, and at least one call was compared; 1 a difference,
# a replay error, a stale entry, or nothing compared; 2 usage (bad arguments, a record
# directory of another format, an entry of the list without a reason).
#
# How a call is replayed (the design is in adr-20261127-ports-are-checked-by-
# replaying-recordings-in-place):
#  * The recorded paths are absolute and point into a directory that tests/run.sh has
#    removed, so the world is rebuilt on those very paths: <T> and every <T>.* of
#    tree.before (directories, files from the blob store with their mode, links).
#    Nothing is rewritten. A path already taken is an error and nothing is touched;
#    what this tool made (down to the topmost directory it had to create) it removes
#    after the call. Calls go one at a time.
#  * JIG_HOME of the recording (a release copy of the framework that is not in the
#    tree) is built once per run on its original path from --home the way tests/run.sh
#    builds it, and removed at the end. A path that already holds a framework copy
#    (scripts/jig) is a live one, e.g. a test run's own: it is used as it is and never
#    removed. Any other existing path is an error for the calls that need it.
#  * The port runs under tests/lib/recorder.sh of this checkout, into a record
#    directory of its own, through a one-line shim (`export` of --port-env, `exec
#    <port> "$@"`): one snapshot of the trees and one normaliser serve both sides.
#    The environment is `env -i` plus the recorded env; the working directory, stdin
#    and the streams are the recorded ones.
#  * Before anything is compared the replay's tree.before and norm/git.before must
#    equal the recorded ones; otherwise it is a replay error, not a verdict.
#  * Compared, byte for byte: exit, norm/stdout, norm/stderr (separate streams),
#    norm/changes, norm/git.after and every file of norm/files in both directions.
#
# Never replayed (reported as `skip` with the reason): concurrent=yes, a
# recorder_error, stdin=tty, clock=real, a fifo or socket in tree.before.
# shellcheck disable=SC2016 # sed and awk programs and messages keep their $ literal
# shellcheck disable=SC2004 # array indices written the same way everywhere
# shellcheck disable=SC2254 # a glob from the intended list is a pattern on purpose
# shellcheck disable=SC2329 # _cleanup is the EXIT trap
set -eu
set -o pipefail

NL=$'\n'
TAB=$'\t'
C="env LC_ALL=C"

# The location of a repository is the caller's to name, not this tool's to inherit.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_INDEX_FILE GIT_NAMESPACE \
  GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM

TOOL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
TOOL_ROOT=$(cd "$TOOL_DIR/../.." && pwd -P)
RECORDER="$TOOL_DIR/recorder.sh"

# Globals the EXIT trap reads.
SCR=""
WORLD_T=""
WORLD_TOPS=""
HOME_TOPS=""
HOMES_OK="$NL"
HOMES_BAD="$NL"

# The run's state.
REC=""
PORT=""
NAME=""
INTENDED=""
REPORT_OPT=""
HOME_SRC=""
REPLAY=""
SHIM=""
RBASE=""
CDIR=""
IN_N=0
IN_PORT=()
IN_CALLS=()
IN_VIEW=()
IN_LINES=()
IN_REASON=()
IN_LINENO=()
IN_MATCHED=()
IN_COVERED=()
DVN=0
DV_VIEW=()
DV_BODY=()
R_STATUS=""
R_DETAIL=""
COV_LINE=""
COV_REASON=""
TAKEN=""
TRACKED_TOP=""

usage() {
  cat <<'EOF'
usage: parity.sh check --recordings <dir> --port <program> [--name <name>]
                       [--port-env NAME=VALUE]... [--intended <file>] [--report <dir>]
                       [--home <checkout>] [--command <word>]... [<file>::<test>]...
EOF
}

_die2() {
  printf 'parity.sh: %s\n' "$*" >&2
  exit 2
}

# --- cleanup --------------------------------------------------------------------

# _rm_checked <path> — rm -rf of a path this tool made: absolute, not the root,
# no `.` or `..` component.
_rm_checked() {
  case "$1" in
    /?*) ;;
    *) return 0 ;;
  esac
  case "$1/" in
    */./* | */../*) return 0 ;;
  esac
  if [ -e "$1" ] || [ -L "$1" ]; then
    rm -rf -- "$1"
  fi
}

# _world_remove — what the call's world made: the topmost directories created,
# and <T> with every <T>.* (none of them existed when the world was begun).
_world_remove() {
  local t x
  if [ -n "$WORLD_TOPS" ]; then
    while IFS= read -r t; do
      if [ -n "$t" ]; then _rm_checked "$t"; fi
    done <<< "$WORLD_TOPS"
  fi
  if [ -n "$WORLD_T" ]; then
    for x in "$WORLD_T" "$WORLD_T".*; do
      if [ -e "$x" ] || [ -L "$x" ]; then _rm_checked "$x"; fi
    done
  fi
  WORLD_T=""
  WORLD_TOPS=""
}

_cleanup() {
  local t
  _world_remove
  if [ -n "$HOME_TOPS" ]; then
    while IFS= read -r t; do
      if [ -n "$t" ]; then _rm_checked "$t"; fi
    done <<< "$HOME_TOPS"
    HOME_TOPS=""
  fi
  case "$SCR" in
    */jig-parity.??*) rm -rf -- "$SCR" ;;
  esac
  SCR=""
}

# --- small helpers --------------------------------------------------------------

# _meta_v <var> <file> <key> — the value of a key=value line, or empty.
_meta_v() {
  local line v=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$3="*)
        v=${line#*=}
        break
        ;;
    esac
  done < "$2"
  printf -v "$1" '%s' "$v"
}

# _subst_first_v <var> <subst file> <placeholder> — the given (first) form of a
# placeholder's original, or empty.
_subst_first_v() {
  local line v=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$3$TAB"*)
        v=${line#*"$TAB"}
        break
        ;;
    esac
  done < "$2"
  printf -v "$1" '%s' "$v"
}

# _phys_dir <path> — the physical form of an existing directory, else nothing.
_phys_dir() {
  if [ -d "$1" ]; then
    (cd "$1" 2> /dev/null && pwd -P) || true
  fi
}

# _logical_dir <path> — an existing directory as `cd` names it (`//` folded).
_logical_dir() {
  if [ -d "$1" ]; then
    (cd "$1" 2> /dev/null && pwd) || true
  fi
}

# _phys_list <colon list> — the same list with every directory physical.
_phys_list() {
  local IFS=: comp out="" one
  for comp in $1; do
    one=""
    if [ -n "$comp" ]; then one=$(_phys_dir "$comp"); fi
    [ -n "$one" ] || one=$comp
    out="${out:+$out:}$one"
  done
  printf '%s' "$out"
}

# _given_v <var> <subst file> <placeholder> <path|list> — the form of a path the
# recorder was given. The table lists it with its `//`-folded and physical forms,
# longest first, so the first row is not necessarily it: it is the row from which the
# recorder derives every row of the placeholder. When no row does (the directory is not
# there any more), the first row.
_given_v() {
  local line rows="" first="" r forms got logical phys ok x
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$3$TAB"*)
        rows="$rows${line#*"$TAB"}$NL"
        if [ -z "$first" ]; then first=${line#*"$TAB"}; fi
        ;;
    esac
  done < "$2"
  got=$first
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if [ "$4" = list ]; then
      forms="$NL$r$NL$(_phys_list "$r")$NL"
    else
      logical=$(_logical_dir "$r")
      phys=$(_phys_dir "$r")
      forms="$NL$r$NL$logical$NL$phys$NL"
    fi
    ok=1
    while IFS= read -r x; do
      [ -n "$x" ] || continue
      case "$forms" in *"$NL$x$NL"*) ;; *) ok=0 ;; esac
    done <<< "$rows"
    if [ "$ok" -eq 1 ]; then
      got=$r
      break
    fi
  done <<< "$rows"
  printf -v "$1" '%s' "$got"
}

# _env_v <var> <name> — the value of a variable of the recorded environment (the
# caller's envarr), or empty.
_env_v() {
  local rec v=""
  for rec in ${envarr[@]+"${envarr[@]}"}; do
    case "$rec" in "$2="*) v=${rec#*=} ;; esac
  done
  printf -v "$1" '%s' "$v"
}

# _enc_name_v <var> <text> — text as a file name: `/` becomes %2F.
_enc_name_v() {
  local s=$2 out=""
  while :; do
    case "$s" in
      */*)
        out="$out${s%%/*}%2F"
        s=${s#*/}
        ;;
      *)
        out="$out$s"
        break
        ;;
    esac
  done
  printf -v "$1" '%s' "$out"
}

# _same <a> <b> — both files hold the same bytes, or neither exists.
_same() {
  if [ -f "$1" ] && [ -f "$2" ]; then
    if cmp -s "$1" "$2"; then return 0; fi
    return 1
  fi
  if [ ! -e "$1" ] && [ ! -e "$2" ]; then return 0; fi
  return 1
}

# _mkdir_top <dir> — mkdir -p, and TRACKED_TOP is the topmost directory that did
# not exist (empty when it did).
_mkdir_top() {
  local d=$1 top=""
  while [ -n "$d" ] && [ ! -e "$d" ] && [ ! -L "$d" ]; do
    top=$d
    d=${d%/*}
  done
  mkdir -p -- "$1" || return 1
  TRACKED_TOP=$top
}

# --- the intended list ----------------------------------------------------------

_bad_list() {
  printf 'parity.sh: %s:%s: %s\n' "$INTENDED" "$1" "$2" >&2
  exit 2
}

_load_intended() {
  local line lineno=0 rest nf f1 f2 f3 f4 f5 rc
  [ -f "$INTENDED" ] || _die2 "the list of intended differences is not a file: $INTENDED"
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    case "$line" in
      '#'*) continue ;;
    esac
    case "$line" in
      *[![:space:]]*) ;;
      *) continue ;;
    esac
    nf=0
    f1="" f2="" f3="" f4="" f5=""
    rest=$line
    while :; do
      nf=$((nf + 1))
      case "$rest" in
        *"$TAB"*)
          case "$nf" in
            1) f1=${rest%%"$TAB"*} ;;
            2) f2=${rest%%"$TAB"*} ;;
            3) f3=${rest%%"$TAB"*} ;;
            4) f4=${rest%%"$TAB"*} ;;
          esac
          rest=${rest#*"$TAB"}
          ;;
        *)
          if [ "$nf" -eq 5 ]; then f5=$rest; fi
          break
          ;;
      esac
    done
    [ "$nf" -eq 5 ] || _bad_list "$lineno" "5 TAB-separated fields are required (port, calls, view, lines, reason), found $nf"
    [ -n "$f1" ] || _bad_list "$lineno" "the port is empty"
    [ -n "$f2" ] || _bad_list "$lineno" "the calls glob is empty"
    case "$f3" in
      exit | stdout | stderr | changes | git.after | files/?* | '*') ;;
      *) _bad_list "$lineno" "the view must be exit, stdout, stderr, changes, git.after, files/<glob> or *: $f3" ;;
    esac
    [ -n "$f4" ] || _bad_list "$lineno" "the lines field is empty (an ERE, or - for any line)"
    case "$f5" in
      *[![:space:]]*) ;;
      *) _bad_list "$lineno" "the reason is required" ;;
    esac
    if [ "$f4" != "-" ]; then
      rc=0
      $C grep -E -e "$f4" /dev/null > /dev/null 2>&1 || rc=$?
      [ "$rc" -le 1 ] || _bad_list "$lineno" "the lines field is not an extended regular expression: $f4"
    fi
    IN_PORT[$IN_N]=$f1
    IN_CALLS[$IN_N]=$f2
    IN_VIEW[$IN_N]=$f3
    IN_LINES[$IN_N]=$f4
    IN_REASON[$IN_N]=$f5
    IN_LINENO[$IN_N]=$lineno
    IN_MATCHED[$IN_N]=0
    IN_COVERED[$IN_N]=0
    IN_N=$((IN_N + 1))
  done < "$INTENDED"
}

# _in_applies <i> <key> — the entry's port and calls glob fit this call.
_in_applies() {
  if [ "${IN_PORT[$1]}" != '*' ] && [ "${IN_PORT[$1]}" != "$NAME" ]; then
    return 1
  fi
  case "$2" in
    ${IN_CALLS[$1]}) return 0 ;;
  esac
  return 1
}

# _lines_ok <i> <body file> — every changed line of the diff fits the entry.
_lines_ok() {
  local ere=${IN_LINES[$1]}
  if [ "$ere" = "-" ]; then return 0; fi
  [ -s "$2" ] || return 1
  if $C grep -E -v -e "$ere" "$2" > /dev/null; then
    return 1
  fi
  return 0
}

# _cover <key> <view> <body file> — whether an entry covers this difference;
# COV_LINE and COV_REASON name the first that does, and every one that does is
# marked as having covered something.
_cover() {
  local i=0 found=0
  COV_LINE=""
  COV_REASON=""
  while [ "$i" -lt "$IN_N" ]; do
    if _in_applies "$i" "$1"; then
      case "$2" in
        ${IN_VIEW[$i]})
          if _lines_ok "$i" "$3"; then
            IN_COVERED[$i]=$((IN_COVERED[i] + 1))
            if [ "$found" -eq 0 ]; then
              found=1
              COV_LINE=${IN_LINENO[$i]}
              COV_REASON=${IN_REASON[$i]}
            fi
          fi
          ;;
      esac
    fi
    i=$((i + 1))
  done
  [ "$found" -eq 1 ]
}

# --- the world ------------------------------------------------------------------

# _path_taken <t> — <t> or a <t>.* exists; TAKEN names it.
_path_taken() {
  local x
  for x in "$1" "$1".*; do
    if [ -e "$x" ] || [ -L "$x" ]; then
      TAKEN=$x
      return 0
    fi
  done
  return 1
}

# _home_build <path> — a release copy of --home on <path>, as tests/run.sh makes
# it (_run_release_home). R_DETAIL says why not.
_home_build() {
  local h=$1 version list gitdir
  if [ ! -f "$HOME_SRC/scripts/lib/version.sh" ]; then
    R_DETAIL="--home is not a framework checkout: $HOME_SRC"
    return 1
  fi
  version=$(sed -n 's/^JIG_VERSION="\([^"]*\)".*/\1/p' "$HOME_SRC/scripts/lib/version.sh") || version=""
  if [ -z "$version" ]; then
    R_DETAIL="--home has no JIG_VERSION: $HOME_SRC"
    return 1
  fi
  _mkdir_top "$h" || { R_DETAIL="could not make $h"; return 1; }
  if [ -n "$TRACKED_TOP" ]; then HOME_TOPS="$HOME_TOPS$TRACKED_TOP$NL"; fi
  list="$SCR/home.files"
  (
    cd "$HOME_SRC" || exit 1
    # -z: a name git would quote (core.quotePath) is read as it is on disk.
    git ls-files -z --cached --others --exclude-standard > "$list.all" || exit 1
    : > "$list"
    : > "$list.links"
    while IFS= read -r -d '' f; do
      if [ -L "$f" ]; then
        printf '%s\n' "$f" >> "$list.links"
      elif [ -f "$f" ]; then
        printf '%s\n' "$f" >> "$list"
      fi
    done < "$list.all"
    tar -cf - -T "$list" | (cd "$h" && tar -xf -) || exit 1
    while IFS= read -r f; do
      mkdir -p "$h/$(dirname "$f")" && ln -s "$(readlink "$f")" "$h/$f" || exit 1
    done < "$list.links"
  ) > /dev/null || { R_DETAIL="could not copy $HOME_SRC to $h"; return 1; }
  gitdir="$SCR/home-git"
  mkdir -p "$gitdir"
  if ! {
    HOME="$gitdir" GIT_CONFIG_NOSYSTEM=1 git -C "$h" -c user.name=jig-tests -c user.email=tests@jig.invalid init -q . \
      && HOME="$gitdir" GIT_CONFIG_NOSYSTEM=1 git -C "$h" symbolic-ref HEAD refs/heads/main \
      && HOME="$gitdir" GIT_CONFIG_NOSYSTEM=1 git -C "$h" add -A \
      && HOME="$gitdir" GIT_CONFIG_NOSYSTEM=1 git -C "$h" -c user.name=jig-tests -c user.email=tests@jig.invalid commit -q --no-verify -m "release $version" \
      && HOME="$gitdir" GIT_CONFIG_NOSYSTEM=1 git -C "$h" -c user.name=jig-tests -c user.email=tests@jig.invalid tag -a "v$version" -m "v$version"
  } > /dev/null 2>&1; then
    R_DETAIL="could not commit the release copy on $h"
    return 1
  fi
  return 0
}

# _ensure_home <path> — the JIG_HOME of the recording is there: a live framework
# copy as it is, an absent path built once per run. R_DETAIL says why not.
_ensure_home() {
  local h=$1
  case "$HOMES_OK" in *"$NL$h$NL"*) return 0 ;; esac
  case "$HOMES_BAD" in
    *"$NL$h$NL"*)
      R_DETAIL="JIG_HOME is not available: $h"
      return 1
      ;;
  esac
  if [ -d "$h" ] && [ -f "$h/scripts/jig" ]; then
    HOMES_OK="$HOMES_OK$h$NL"
    printf 'note     JIG_HOME %s exists and is used as it is, not built from --home\n' "$h"
    return 0
  fi
  if [ -e "$h" ] || [ -L "$h" ]; then
    HOMES_BAD="$HOMES_BAD$h$NL"
    R_DETAIL="path taken: JIG_HOME $h exists and is not a framework copy"
    return 1
  fi
  if _home_build "$h"; then
    HOMES_OK="$HOMES_OK$h$NL"
    return 0
  fi
  HOMES_BAD="$HOMES_BAD$h$NL"
  return 1
}

# _world_restore_slow <call dir> <t> — tree.before of the call, put back on its own
# paths one file at a time (a process per file). The fallback of _world_restore.
# R_DETAIL says why not.
_world_restore_slow() {
  local call=$1 t=$2 type mode ref path full parent
  while IFS="$TAB" read -r -d '' type mode ref path || [ -n "$type" ]; do
    case "$path" in
      "<T>" | "<T>/"* | "<T>."*) full="$t${path#"<T>"}" ;;
      *)
        R_DETAIL="replay: tree.before holds a path outside <T>: $path"
        return 1
        ;;
    esac
    case "$type" in
      d) mkdir -p -- "$full" || { R_DETAIL="replay: could not make $full"; return 1; } ;;
      f)
        parent=${full%/*}
        if [ ! -d "$parent" ]; then mkdir -p -- "$parent" || { R_DETAIL="replay: could not make $parent"; return 1; }; fi
        if [ "$ref" = "-" ] || ! git --git-dir="$REC/store.git" cat-file blob "$ref" > "$full" 2> /dev/null < /dev/null; then
          R_DETAIL="replay: no blob for $path"
          return 1
        fi
        case "$mode" in
          755) chmod 755 "$full" ;;
          *) chmod 644 "$full" ;;
        esac
        ;;
      l)
        parent=${full%/*}
        if [ ! -d "$parent" ]; then mkdir -p -- "$parent" || { R_DETAIL="replay: could not make $parent"; return 1; }; fi
        ln -s -- "$ref" "$full" || { R_DETAIL="replay: could not link $full"; return 1; }
        ;;
      *)
        R_DETAIL="replay: unknown record type in tree.before: $type"
        return 1
        ;;
    esac
  done < "$call/tree.before"
  return 0
}

# _esc_note <escaped prefix> <original component> — a component to be renamed back.
_esc_note() {
  local i=0
  while [ "$i" -lt "${#ESC_P[@]}" ]; do
    if [ "${ESC_P[$i]}" = "$1" ]; then return 0; fi
    i=$((i + 1))
  done
  ESC_P[${#ESC_P[@]}]=$1
  ESC_N[${#ESC_N[@]}]=$2
}

# _esc_rel_v <var> <relative path> — the path with every component that is `.git`
# (in any case) renamed to $RESV, which git will check out; _esc_note keeps what to
# rename back.
_esc_rel_v() {
  local rest=$2 out="" c last=0
  case "$2" in
    *[.][gG][iI][tT]*) ;;
    *)
      printf -v "$1" '%s' "$2"
      return 0
      ;;
  esac
  while [ "$last" -eq 0 ]; do
    case "$rest" in
      */*)
        c=${rest%%/*}
        rest=${rest#*/}
        ;;
      *)
        c=$rest
        last=1
        ;;
    esac
    case "$c" in
      [.][gG][iI][tT])
        out="${out:+$out/}$RESV"
        _esc_note "$out" "$c"
        ;;
      *) out="${out:+$out/}$c" ;;
    esac
  done
  printf -v "$1" '%s' "$out"
}

# _world_restore <call dir> <t> — tree.before of the call, put back on its own
# paths in a few processes: an index of every file and link built in one
# `update-index --index-info`, one `checkout-index`, one `mkdir -p` for the
# directories. git will not write a `.git` component, so those are written under
# $RESV and renamed back afterwards, deepest first. Falls back to
# _world_restore_slow when the index cannot be built. R_DETAIL says why not.
_world_restore() {
  local call=$1 t=$2 parent=${2%/*} type mode ref path full rel esc m n=0 i d maxd id lrel
  local idx="$SCR/restore.index" info="$SCR/restore.info" dirs="$SCR/restore.dirs"
  local lnk="$SCR/lnk"
  RESV=".git~parity-$$"
  ESC_P=()
  ESC_N=()
  rm -rf "$lnk" "$idx"
  mkdir -p "$lnk"
  : > "$lnk/list"
  while IFS="$TAB" read -r -d '' type mode ref path || [ -n "$type" ]; do
    case "$path" in
      "<T>" | "<T>/"* | "<T>."*) full="$t${path#"<T>"}" ;;
      *)
        R_DETAIL="replay: tree.before holds a path outside <T>: $path"
        return 1
        ;;
    esac
    rel=${full#"$parent/"}
    case "$rel" in
      *"$RESV"*)
        R_DETAIL="replay: a recorded path holds the reserved name $RESV: $path"
        return 1
        ;;
    esac
    _esc_rel_v esc "$rel"
    case "$type" in
      d) printf '%s\000' "$parent/$esc" >&7 ;;
      f)
        if [ "$ref" = "-" ]; then
          R_DETAIL="replay: no blob for $path"
          return 1
        fi
        case "$mode" in
          755) m=100755 ;;
          *) m=100644 ;;
        esac
        printf '%s %s\t%s\000' "$m" "$ref" "$esc" >&6
        ;;
      l)
        n=$((n + 1))
        printf '%s' "$ref" > "$lnk/$n"
        printf '%s\n' "$lnk/$n" >> "$lnk/list"
        printf '%s\000' "$esc" >&8
        ;;
      *)
        R_DETAIL="replay: unknown record type in tree.before: $type"
        return 1
        ;;
    esac
  done < "$call/tree.before" 6> "$info" 7> "$dirs" 8> "$lnk/rel"
  if [ "$n" -gt 0 ]; then
    git --git-dir="$REPLAY/store.git" hash-object -w --no-filters --stdin-paths < "$lnk/list" > "$lnk/ids" 2> /dev/null \
      || return 2
    exec 9< "$lnk/ids"
    exec 5< "$lnk/rel"
    while IFS= read -r -u 9 id; do
      IFS= read -r -d '' -u 5 lrel || { exec 9<&- 5<&-; return 2; }
      printf '120000 %s\t%s\000' "$id" "$lrel" >> "$info"
    done
    exec 9<&- 5<&-
  fi
  if [ -s "$info" ]; then
    GIT_DIR="$REPLAY/store.git" GIT_INDEX_FILE="$idx" GIT_ALTERNATE_OBJECT_DIRECTORIES="$REC/store.git/objects" \
      git update-index -z --add --index-info < "$info" > /dev/null 2>&1 || return 2
  fi
  if [ -s "$dirs" ]; then
    xargs -0 mkdir -p -- < "$dirs" || { R_DETAIL="replay: could not make the directories of the world"; return 1; }
  fi
  if [ -s "$info" ]; then
    GIT_DIR="$REPLAY/store.git" GIT_WORK_TREE="$SCR" GIT_INDEX_FILE="$idx" GIT_ALTERNATE_OBJECT_DIRECTORIES="$REC/store.git/objects" \
      git -c core.symlinks=true -c core.filemode=true -c core.autocrlf=false \
      checkout-index -a -f --prefix="$parent/" > /dev/null 2>&1 \
      || { R_DETAIL="replay: could not check out the files of the world"; return 1; }
  fi
  # The `.git` components, deepest first (an escaped parent is still escaped
  # while its children are renamed).
  maxd=0
  i=0
  while [ "$i" -lt "${#ESC_P[@]}" ]; do
    d=${ESC_P[$i]//[!\/]/}
    if [ "${#d}" -gt "$maxd" ]; then maxd=${#d}; fi
    i=$((i + 1))
  done
  while [ "$maxd" -ge 0 ]; do
    i=0
    while [ "$i" -lt "${#ESC_P[@]}" ]; do
      d=${ESC_P[$i]//[!\/]/}
      if [ "${#d}" -eq "$maxd" ]; then
        case "${ESC_P[$i]}" in
          */*) mv -- "$parent/${ESC_P[$i]}" "$parent/${ESC_P[$i]%/*}/${ESC_N[$i]}" || { R_DETAIL="replay: could not rename ${ESC_P[$i]}"; return 1; } ;;
          *) mv -- "$parent/${ESC_P[$i]}" "$parent/${ESC_N[$i]}" || { R_DETAIL="replay: could not rename ${ESC_P[$i]}"; return 1; } ;;
        esac
      fi
      i=$((i + 1))
    done
    maxd=$((maxd - 1))
  done
  return 0
}

# --- the comparison -------------------------------------------------------------

# _view <view> <recorded file> <port's file> — notes a difference.
_view() {
  local view=$1 a=$2 b=$3 enc body
  if _same "$a" "$b"; then return 0; fi
  _enc_name_v enc "$view"
  mkdir -p "$CDIR"
  if [ ! -f "$a" ]; then a=/dev/null; fi
  if [ ! -f "$b" ]; then b=/dev/null; fi
  diff -a -u -L recorded -L port "$a" "$b" > "$CDIR/$enc.diff" || true
  body="$SCR/body.$DVN"
  tail -n +3 "$CDIR/$enc.diff" | $C sed -n 's/^[-+]//p' > "$body"
  DV_VIEW[$DVN]=$view
  DV_BODY[$DVN]=$body
  DVN=$((DVN + 1))
}

# _files_list <call dir> <out> — the files under norm/files, relative.
_files_list() {
  if [ -d "$1/norm/files" ]; then
    (cd "$1/norm/files" && find . -type f -print) | $C sed 's|^\./||' | $C sort > "$2"
  else
    : > "$2"
  fi
}

# _write_shim <port> — the program the recorder runs: the port's own variables,
# then the port.
_write_shim() {
  local envs shimenv
  {
    printf '#!/usr/bin/env bash\n'
    for envs in ${PORT_ENVS[@]+"${PORT_ENVS[@]}"}; do
      shimenv=${envs%%=*}
      printf 'export %s=%q\n' "$shimenv" "${envs#*=}"
    done
    printf 'exec %q "$@"\n' "$1"
  } > "$SHIM"
}

# _tree_ref_v <var> <tree lines file> <path> — the blob id of a regular file in a
# tree (its records as lines), or empty.
_tree_ref_v() {
  local got
  got=$(P="$3" $C awk -F '\t' '
    {
      r = substr($0, index($0, "\t") + 1)
      r = substr(r, index(r, "\t") + 1)
      k = index(r, "\t")
      if ($1 == "f" && substr(r, k + 1) == ENVIRON["P"]) { print substr(r, 1, k - 1); exit }
    }' "$2") || got=""
  printf -v "$1" '%s' "$got"
}

# _stream_target_v <var> <call dir> <stream: stdout|stderr> <t> — where the call's
# stream went when it went to a file of the world: the one regular file the call
# modified whose content after is its content before plus the stream's bytes (a shell
# `>` made the file before the call, so it is in tree.before). Empty when no file
# fits or several do.
_stream_target_v() {
  local call=$2 s=$3 letter path b a hit="" n=0
  printf -v "$1" '%s' ""
  [ -s "$call/$s" ] || return 0
  [ -s "$call/changes" ] || return 0
  if [ ! -f "$SCR/ta.lines" ]; then
    $C tr '\000' '\n' < "$call/tree.after" > "$SCR/ta.lines"
  fi
  while IFS="$TAB" read -r -d '' letter path || [ -n "$letter" ]; do
    [ "$letter" = M ] || continue
    case "$path" in "<T>" | "<T>/"* | "<T>."*) ;; *) continue ;; esac
    case "$path" in *"$NL"*) continue ;; esac
    _tree_ref_v b "$SCR/tb.lines" "$path"
    _tree_ref_v a "$SCR/ta.lines" "$path"
    if [ -z "$b" ] || [ -z "$a" ] || [ "$b" = "-" ] || [ "$a" = "-" ]; then continue; fi
    git --git-dir="$REC/store.git" cat-file blob "$b" > "$SCR/st.before" 2> /dev/null < /dev/null || continue
    git --git-dir="$REC/store.git" cat-file blob "$a" > "$SCR/st.after" 2> /dev/null < /dev/null || continue
    cat "$SCR/st.before" "$call/$s" > "$SCR/st.joined"
    if cmp -s "$SCR/st.joined" "$SCR/st.after"; then
      n=$((n + 1))
      hit=$path
    fi
  done < "$call/changes"
  if [ "$n" -eq 1 ]; then
    printf -v "$1" '%s' "$4${hit#"<T>"}"
  fi
}

# _process_call <key> — replay one call and compare. R_STATUS is ok, DIFF,
# intended, skip or ERROR; R_DETAIL the text for the report line. The world is
# removed by the caller.
_process_call() {
  local key=$1 call file rest test seq concurrent rerr stdin clock streams
  local T JH PATHV ROOTV CACHEV rtest rcall cwd rc rec stdin_src p unc ints i v
  local rexit pexit enc rout rerrf rawtarget
  local envarr argva extra
  call="$REC/calls/$key"
  file=${key%%/*}
  rest=${key#*/}
  test=${rest%%/*}
  seq=${rest#*/}
  R_STATUS=""
  R_DETAIL=""
  DVN=0
  CDIR="$RBASE/$key"
  rm -f "$SCR/ta.lines"

  for p in meta argv cwd env tree.before subst; do
    if [ ! -f "$call/$p" ]; then
      R_STATUS=ERROR
      R_DETAIL="recording is incomplete: no $p"
      return 0
    fi
  done
  _meta_v concurrent "$call/meta" concurrent
  _meta_v rerr "$call/meta" recorder_error
  _meta_v stdin "$call/meta" stdin
  _meta_v clock "$call/meta" clock
  _meta_v streams "$call/meta" streams
  _meta_v rexit "$call/meta" exit
  if [ "$concurrent" = yes ]; then
    R_STATUS=skip
    R_DETAIL="concurrent"
    return 0
  fi
  if [ -n "$rerr" ]; then
    R_STATUS=skip
    R_DETAIL="recorder_error=$rerr"
    return 0
  fi
  if [ "$stdin" = tty ]; then
    R_STATUS=skip
    R_DETAIL="stdin was a terminal"
    return 0
  fi
  if [ "$clock" = real ]; then
    R_STATUS=skip
    R_DETAIL="clock was not pinned"
    return 0
  fi
  $C tr '\000' '\n' < "$call/tree.before" > "$SCR/tb.lines"
  if grep -q "^o$TAB" "$SCR/tb.lines"; then
    R_STATUS=skip
    R_DETAIL="tree.before holds a fifo or a socket"
    return 0
  fi

  envarr=()
  while IFS= read -r -d '' rec || [ -n "$rec" ]; do
    case "$rec" in
      [A-Za-z_]*=*) envarr[${#envarr[@]}]=$rec ;;
    esac
  done < "$call/env"
  # The originals, in the form the recorded run was given them (see _given_v).
  _env_v T JIG_TEST_TMP
  if [ -z "$T" ]; then _subst_first_v T "$call/subst" '<T>'; fi
  _env_v JH JIG_HOME
  if [ -z "$JH" ]; then _given_v JH "$call/subst" '<JIG_HOME>' path; fi
  _env_v CACHEV JIG_TEST_CACHE
  if [ -z "$CACHEV" ]; then _subst_first_v CACHEV "$call/subst" '<CACHE>'; fi
  _given_v PATHV "$call/subst" '<PATH>' list
  _given_v ROOTV "$call/subst" '<ROOT>' path
  case "$T" in
    /?*) ;;
    *)
      R_STATUS=ERROR
      R_DETAIL="replay: the recording has no absolute <T>"
      return 0
      ;;
  esac
  case "$T" in
    *"$NL"* | */)
      R_STATUS=ERROR
      R_DETAIL="replay: unusable <T>: $T"
      return 0
      ;;
  esac

  if _path_taken "$T"; then
    R_STATUS=ERROR
    R_DETAIL="replay: path taken: $TAKEN"
    return 0
  fi
  if [ -n "$JH" ]; then
    if ! _ensure_home "$JH"; then
      R_STATUS=ERROR
      R_DETAIL="replay: $R_DETAIL"
      return 0
    fi
  fi

  # From here on something is made: the caller removes it.
  WORLD_T=$T
  _mkdir_top "${T%/*}" || { R_STATUS=ERROR; R_DETAIL="replay: could not make the parent of $T"; return 0; }
  if [ -n "$TRACKED_TOP" ]; then WORLD_TOPS="$WORLD_TOPS$TRACKED_TOP$NL"; fi
  if [ -n "$CACHEV" ] && [ ! -e "$CACHEV" ] && [ ! -L "$CACHEV" ]; then
    # The recording names this path in both its forms only when it existed.
    case "$CACHEV" in
      /?*)
        _mkdir_top "$CACHEV" || true
        if [ -n "$TRACKED_TOP" ]; then WORLD_TOPS="$WORLD_TOPS$TRACKED_TOP$NL"; fi
        ;;
    esac
  fi
  rc=0
  _world_restore "$call" "$T" || rc=$?
  if [ "$rc" -eq 2 ]; then
    rc=0
    _world_restore_slow "$call" "$T" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    R_STATUS=ERROR
    return 0
  fi

  IFS= read -r -d '' cwd < "$call/cwd" || true
  if [ ! -d "$cwd" ]; then
    R_STATUS=ERROR
    R_DETAIL="replay: the working directory is not in the world: $cwd"
    return 0
  fi
  argva=()
  while IFS= read -r -d '' rec || [ -n "$rec" ]; do
    argva[${#argva[@]}]=$rec
  done < "$call/argv"
  stdin_src=/dev/null
  if [ "$stdin" = data ]; then
    stdin_src="$call/stdin"
    if [ ! -f "$stdin_src" ]; then
      R_STATUS=ERROR
      R_DETAIL="recording is incomplete: no stdin"
      return 0
    fi
  fi
  if [ -z "$PATHV" ]; then PATHV=$PATH; fi
  printf 'PATH=%s\000' "$PATHV" > "$SCR/base-env"
  extra=()
  if [ -n "$ROOTV" ]; then extra[0]="JIG_RECORD_ROOT=$ROOTV"; fi

  p=$PORT
  case "$p" in
    "<JIG_HOME>/"*)
      if [ -z "$JH" ]; then
        R_STATUS=ERROR
        R_DETAIL="replay: the port is in <JIG_HOME> and the recording has none"
        return 0
      fi
      p="$JH${p#"<JIG_HOME>"}"
      ;;
  esac
  _write_shim "$p"
  rtest="$test.$seq"
  rcall="$REPLAY/calls/$file/$rtest/0001"
  # Where the streams go: the file of the world the recorded call wrote to when one
  # can be inferred, else scratch files. Always appended to, as a shell `>>` would.
  rout="$SCR/replay.out"
  rerrf="$SCR/replay.err"
  : > "$rout"
  : > "$rerrf"
  rawtarget=""
  _stream_target_v rawtarget "$call" stdout "$T"
  if [ -n "$rawtarget" ]; then rout=$rawtarget; fi
  if [ "$streams" != merged ]; then
    rawtarget=""
    _stream_target_v rawtarget "$call" stderr "$T"
    if [ -n "$rawtarget" ] && [ "$rawtarget" != "$rout" ]; then rerrf=$rawtarget; fi
  fi
  rc=0
  if [ "$streams" = merged ]; then
    (
      cd "$cwd" || exit 97
      exec env -i ${envarr[@]+"${envarr[@]}"} \
        JIG_RECORD_DIR="$REPLAY" JIG_RECORD_TEST="$file::$rtest" JIG_RECORD_BASE_ENV="$SCR/base-env" \
        ${extra[@]+"${extra[@]}"} JIG_TEST_TMP="$T" \
        "$BASH" "$RECORDER" record "$SHIM" ${argva[@]+"${argva[@]}"}
    ) 4<&- < "$stdin_src" >> "$rout" 2>&1 || rc=$?
  else
    (
      cd "$cwd" || exit 97
      exec env -i ${envarr[@]+"${envarr[@]}"} \
        JIG_RECORD_DIR="$REPLAY" JIG_RECORD_TEST="$file::$rtest" JIG_RECORD_BASE_ENV="$SCR/base-env" \
        ${extra[@]+"${extra[@]}"} JIG_TEST_TMP="$T" \
        "$BASH" "$RECORDER" record "$SHIM" ${argva[@]+"${argva[@]}"}
    ) 4<&- < "$stdin_src" >> "$rout" 2>> "$rerrf" || rc=$?
  fi
  if [ ! -f "$rcall/meta" ]; then
    R_STATUS=ERROR
    R_DETAIL="replay: the recorder made no record of the call (exit $rc)"
    return 0
  fi
  _meta_v rerr "$rcall/meta" recorder_error
  if [ -n "$rerr" ]; then
    R_STATUS=ERROR
    R_DETAIL="replay: recorder_error=$rerr"
    return 0
  fi
  _meta_v pexit "$rcall/meta" exit

  # The world must be the recorded one before a verdict means anything.
  if ! _same "$call/tree.before" "$rcall/tree.before"; then
    R_STATUS=ERROR
    R_DETAIL="replay: tree.before differs"
    return 0
  fi
  if ! _same "$call/norm/git.before" "$rcall/norm/git.before"; then
    R_STATUS=ERROR
    R_DETAIL="replay: git.before differs"
    return 0
  fi

  # What the port did, against what the recording says.
  if [ "$rexit" != "$pexit" ]; then
    mkdir -p "$CDIR"
    printf '%s\n' "$rexit" > "$SCR/exit.rec"
    printf '%s\n' "$pexit" > "$SCR/exit.port"
    _view exit "$SCR/exit.rec" "$SCR/exit.port"
    printf '%s -> %s\n' "$rexit" "$pexit" > "$SCR/exit.body"
    DV_BODY[DVN - 1]="$SCR/exit.body"
  fi
  _view stdout "$call/norm/stdout" "$rcall/norm/stdout"
  if [ "$streams" != merged ]; then
    _view stderr "$call/norm/stderr" "$rcall/norm/stderr"
  fi
  _view changes "$call/norm/changes" "$rcall/norm/changes"
  _view git.after "$call/norm/git.after" "$rcall/norm/git.after"
  _files_list "$call" "$SCR/files.rec"
  _files_list "$rcall" "$SCR/files.port"
  $C sort -u "$SCR/files.rec" "$SCR/files.port" > "$SCR/files.all"
  while IFS= read -r p; do
    _view "files/$p" "$call/norm/files/$p" "$rcall/norm/files/$p"
  done < "$SCR/files.all"

  # The entries that fit this call have been matched, whatever it differs in.
  i=0
  while [ "$i" -lt "$IN_N" ]; do
    if _in_applies "$i" "$key"; then
      IN_MATCHED[$i]=$((IN_MATCHED[i] + 1))
    fi
    i=$((i + 1))
  done

  if [ "$DVN" -eq 0 ]; then
    R_STATUS=ok
    return 0
  fi
  unc=""
  ints=""
  i=0
  while [ "$i" -lt "$DVN" ]; do
    v=${DV_VIEW[$i]}
    if _cover "$key" "$v" "${DV_BODY[$i]}"; then
      ints="${ints:+$ints; }$v: line $COV_LINE — $COV_REASON"
    else
      unc="${unc:+$unc, }$v"
    fi
    i=$((i + 1))
  done
  if [ -n "$unc" ]; then
    R_STATUS=DIFF
    R_DETAIL=$unc
  else
    R_STATUS=intended
    R_DETAIL=$ints
  fi
  return 0
}

# --- selection ------------------------------------------------------------------

# _select <list file> — the keys of the calls this run was asked for, in order.
_select() {
  local p key file rest test a0 f ff ft ok
  find "$REC/calls" -mindepth 3 -maxdepth 3 -type d -name '[0-9][0-9][0-9][0-9]' -print 2> /dev/null \
    | $C sort > "$SCR/all.list" || true
  : > "$1"
  while IFS= read -r p; do
    key=${p#"$REC/calls/"}
    file=${key%%/*}
    rest=${key#*/}
    test=${rest%%/*}
    if [ "${#FILTERS[@]}" -gt 0 ]; then
      ok=0
      for f in "${FILTERS[@]}"; do
        ff=${f%%::*}
        ft=${f#*::}
        if [ "$ff" = "$file" ]; then
          if [ -z "$ft" ] || [ "$ft" = "$test" ]; then ok=1; fi
        fi
      done
      [ "$ok" -eq 1 ] || continue
    fi
    if [ "${#COMMANDS[@]}" -gt 0 ]; then
      a0=""
      if [ -f "$p/argv" ]; then
        IFS= read -r -d '' a0 < "$p/argv" || true
      fi
      ok=0
      for f in "${COMMANDS[@]}"; do
        if [ "$a0" = "$f" ]; then ok=1; fi
      done
      [ "$ok" -eq 1 ] || continue
    fi
    printf '%s\n' "$key" >> "$1"
  done < "$SCR/all.list"
}

# --- the command ----------------------------------------------------------------

cmd_check() {
  local fmt p n i key rcall sel=0 n_eq=0 n_int=0 n_diff=0 n_skip=0 n_err=0 n_stale=0 rc=0 compared
  FILTERS=()
  COMMANDS=()
  PORT_ENVS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --recordings) [ $# -ge 2 ] || _die2 "--recordings requires a value"; REC=$2; shift 2 ;;
      --port) [ $# -ge 2 ] || _die2 "--port requires a value"; PORT=$2; shift 2 ;;
      --name) [ $# -ge 2 ] || _die2 "--name requires a value"; NAME=$2; shift 2 ;;
      --port-env)
        [ $# -ge 2 ] || _die2 "--port-env requires a value"
        case "$2" in
          [A-Za-z_]*=*) ;;
          *) _die2 "--port-env wants NAME=VALUE: $2" ;;
        esac
        n=${2%%=*}
        case "$n" in
          *[!A-Za-z0-9_]*) _die2 "--port-env wants NAME=VALUE: $2" ;;
        esac
        PORT_ENVS[${#PORT_ENVS[@]}]=$2
        shift 2
        ;;
      --intended) [ $# -ge 2 ] || _die2 "--intended requires a value"; INTENDED=$2; shift 2 ;;
      --report) [ $# -ge 2 ] || _die2 "--report requires a value"; REPORT_OPT=$2; shift 2 ;;
      --home) [ $# -ge 2 ] || _die2 "--home requires a value"; HOME_SRC=$2; shift 2 ;;
      --command) [ $# -ge 2 ] || _die2 "--command requires a value"; COMMANDS[${#COMMANDS[@]}]=$2; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      -*) _die2 "unknown option: $1" ;;
      *::*) FILTERS[${#FILTERS[@]}]=$1; shift ;;
      *) _die2 "a filter is <file>::<test> or <file>::, not: $1" ;;
    esac
  done
  [ -n "$REC" ] || _die2 "--recordings is required"
  [ -n "$PORT" ] || _die2 "--port is required"
  [ -d "$REC" ] || _die2 "not a record directory: $REC"
  REC=$(cd "$REC" && pwd -P)
  fmt=""
  if [ -f "$REC/FORMAT" ]; then
    IFS= read -r fmt < "$REC/FORMAT" || true
  fi
  [ "$fmt" = "jig-recording 2" ] || _die2 "$REC is not a jig-recording 2 directory (FORMAT says: ${fmt:-nothing})"
  case "$PORT" in
    "<JIG_HOME>/"* | /*) ;;
    */*) PORT="$PWD/$PORT" ;;
  esac
  case "$PORT" in
    "<JIG_HOME>/"*) ;;
    /*) [ -e "$PORT" ] || _die2 "the port is not there: $PORT" ;;
  esac
  [ -n "$NAME" ] || NAME=${PORT##*/}
  [ -n "$INTENDED" ] || INTENDED="$TOOL_ROOT/tests/parity/intended.tsv"
  if [ -n "$HOME_SRC" ]; then
    [ -d "$HOME_SRC" ] || _die2 "--home is not a directory: $HOME_SRC"
    HOME_SRC=$(cd "$HOME_SRC" && pwd -P)
  else
    HOME_SRC=$TOOL_ROOT
  fi
  [ -f "$RECORDER" ] || _die2 "the recorder is not there: $RECORDER"
  _load_intended

  SCR=$(mktemp -d "${TMPDIR:-/tmp}/jig-parity.XXXXXX") || _die2 "could not make a scratch directory"
  SCR=$(cd "$SCR" && pwd -P)
  trap _cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  REPLAY="$SCR/replay"
  mkdir -p "$REPLAY"
  printf 'jig-recording 2\n' > "$REPLAY/FORMAT"
  git init --bare -q "$REPLAY/store.git" || _die2 "could not make the replay store"
  if [ -n "$REPORT_OPT" ]; then
    case "$REPORT_OPT" in
      /*) RBASE=$REPORT_OPT ;;
      *) RBASE="$PWD/$REPORT_OPT" ;;
    esac
    # The report goes into a directory of its own: one that holds anything is
    # refused, never emptied (the tool removes only what it made).
    if [ -e "$RBASE" ] || [ -L "$RBASE" ]; then
      if [ ! -d "$RBASE" ] || [ -L "$RBASE" ]; then
        _die2 "the report directory is not a directory: $RBASE"
      fi
      for p in "$RBASE"/* "$RBASE"/.[!.]* "$RBASE"/..?*; do
        if [ -e "$p" ] || [ -L "$p" ]; then
          _die2 "the report directory is not empty: $RBASE"
        fi
      done
    fi
    mkdir -p "$RBASE" || _die2 "could not make the report directory: $RBASE"
  else
    RBASE="$SCR/report"
    mkdir -p "$RBASE"
  fi

  SHIM="$SCR/port-shim"

  _select "$SCR/calls.list"

  while IFS= read -r key <&4; do
    sel=$((sel + 1))
    _process_call "$key"
    _world_remove
    p=${key#*/}
    rcall="$REPLAY/calls/${key%%/*}/${p%%/*}.${p#*/}"
    # A call with a difference or an error keeps what shows it.
    if [ -n "$REPORT_OPT" ]; then
      case "$R_STATUS" in
        DIFF | intended | ERROR)
          mkdir -p "$CDIR"
          if [ "$R_STATUS" = ERROR ]; then printf '%s\n' "$R_DETAIL" > "$CDIR/error.txt"; fi
          if [ -d "$rcall/0001" ]; then cp -R "$rcall/0001" "$CDIR/replay" 2> /dev/null || true; fi
          ;;
      esac
    fi
    case "$R_STATUS" in
      ok)
        printf '%-9s%s\n' ok "$key"
        n_eq=$((n_eq + 1))
        ;;
      DIFF)
        printf '%-9s%s  (%s)\n' DIFF "$key" "$R_DETAIL"
        n_diff=$((n_diff + 1))
        ;;
      intended)
        printf '%-9s%s  (%s)\n' intended "$key" "$R_DETAIL"
        n_int=$((n_int + 1))
        ;;
      skip)
        printf '%-9s%s  (%s)\n' skip "$key" "$R_DETAIL"
        n_skip=$((n_skip + 1))
        ;;
      *)
        printf '%-9s%s  (%s)\n' ERROR "$key" "$R_DETAIL"
        n_err=$((n_err + 1))
        ;;
    esac
    # Without --report nothing of the call is kept.
    if [ -z "$REPORT_OPT" ]; then
      rm -rf "$CDIR"
    fi
    rm -rf "$rcall"
  done 4< "$SCR/calls.list"

  if [ "$sel" -eq 0 ]; then
    printf 'parity: no calls selected\n'
    exit 1
  fi

  i=0
  while [ "$i" -lt "$IN_N" ]; do
    if [ "${IN_MATCHED[$i]}" -gt 0 ] && [ "${IN_COVERED[$i]}" -eq 0 ]; then
      printf '%-9s%s:%s  (matched %s calls, covered no difference)\n' stale "$INTENDED" "${IN_LINENO[$i]}" "${IN_MATCHED[$i]}"
      n_stale=$((n_stale + 1))
    fi
    i=$((i + 1))
  done

  printf '\nparity: %d calls selected: %d equal, %d intended, %d differ, %d skipped, %d errors; %d stale entries\n' \
    "$sel" "$n_eq" "$n_int" "$n_diff" "$n_skip" "$n_err" "$n_stale"
  compared=$((n_eq + n_int + n_diff))
  if [ "$compared" -eq 0 ]; then
    printf 'parity: no call was compared\n'
    rc=1
  fi
  if [ "$n_diff" -gt 0 ] || [ "$n_err" -gt 0 ] || [ "$n_stale" -gt 0 ]; then
    rc=1
  fi
  exit "$rc"
}

main() {
  local sub="${1:-}"
  [ $# -eq 0 ] || shift
  case "$sub" in
    check) cmd_check "$@" ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
