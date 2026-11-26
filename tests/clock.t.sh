#!/bin/sh
# tests/clock.t.sh — the clock seam (scripts/lib/common.sh, "the clock").
#
# Every reading of the current time goes through jig_now_* / jig_today, which a
# test pins with JIG_NOW=<seconds since the epoch>. Pinned here: the helpers
# themselves, the refusal of a malformed JIG_NOW, a sentinel that fails on any
# `date` reading "now" outside the seam that is not marked `real clock:`, and one
# real command that prints the pinned time.
# shellcheck shell=bash
# The scripts these tests write are single-quoted on purpose: their expansions
# happen when the written script runs, not here.
# shellcheck disable=SC2016

# _clock_run <body> — run <body> in bash with common.sh loaded; stdout in OUT,
# stderr in ERR, status in RC. The caller's environment (JIG_NOW, TZ) applies.
_clock_run() {
  {
    printf '#!/usr/bin/env bash\nset -eu\nunset JIG_PROJECT\n'
    printf '. "%s/scripts/lib/common.sh"\n' "$JIG_HOME"
    printf '%s\n' "$1"
  } > clock.sh
  set +e
  bash clock.sh > out.txt 2> err.txt
  RC=$?
  set -e
  OUT=$(cat out.txt)
  ERR=$(cat err.txt)
}

test_clock_unpinned_reads_the_real_clock() {
  local before after
  before=$(date +%s)
  JIG_NOW='' _clock_run 'jig_now_epoch_v e; jig_now_utc_v u; printf "%s\n%s\n%s\n%s\n" "$e" "$u" "$(jig_now_utc)" "$(jig_today)"'
  after=$(date +%s)
  assert_eq 0 "$RC" "$ERR"
  local e u u2 d
  { read -r e; read -r u; read -r u2; read -r d; } <<EOT
$OUT
EOT
  [ "$e" -ge $((before - 2)) ] && [ "$e" -le $((after + 2)) ] || fail "epoch $e not within 2 s of the real clock"
  for u in "$u" "$u2"; do
    case "$u" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
      *) fail "not a UTC timestamp: [$u]" ;;
    esac
  done
  case "$d" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) fail "not a date: [$d]" ;;
  esac
}

test_clock_unset_and_empty_jig_now_are_the_real_clock() {
  (unset JIG_NOW; _clock_run 'jig_now_epoch_v e; printf "%s\n" "$e"'
   assert_eq 0 "$RC" "$ERR"
   [ "$OUT" -gt 1700000000 ] || fail "unset: [$OUT]")
  JIG_NOW='' _clock_run 'jig_now_epoch_v e; printf "%s\n" "$e"'
  assert_eq 0 "$RC" "$ERR"
  [ "$OUT" -gt 1700000000 ] || fail "empty: [$OUT]"
}

test_clock_pinned_answers_that_instant() {
  JIG_NOW=1700000000 TZ=UTC _clock_run 'jig_now_epoch_v e; jig_now_utc_v u
printf "%s\n%s\n%s\n%s\n" "$e" "$u" "$(jig_now_utc)" "$(jig_today)"'
  assert_eq 0 "$RC" "$ERR"
  assert_eq "1700000000
2023-11-14T22:13:20Z
2023-11-14T22:13:20Z
2023-11-14" "$OUT"
}

test_clock_pinned_today_is_the_local_date() {
  # 22:13 UTC on the 14th is already the 15th at UTC+9.
  JIG_NOW=1700000000 TZ=JST-9 _clock_run 'jig_today'
  assert_eq 0 "$RC" "$ERR"
  assert_eq 2023-11-15 "$OUT"
  JIG_NOW=1700000000 TZ=JST-9 _clock_run 'jig_now_utc'
  assert_eq 2023-11-14T22:13:20Z "$OUT"
}

test_clock_now_date_formats_with_and_without_utc() {
  JIG_NOW=1700000000 TZ=JST-9 _clock_run 'jig_now_date +%H:%M; jig_now_date -u +%H:%M; jig_now_date "+%Y-%m-%d %H:%M:%S %z"'
  assert_eq 0 "$RC" "$ERR"
  assert_eq "07:13
22:13
2023-11-15 07:13:20 +0900" "$OUT"
}

test_clock_pinned_leading_zeros_are_decimal() {
  # 08 and 09 are not octal digits; a leading zero must not turn them into errors.
  JIG_NOW=0000000009 _clock_run 'jig_now_epoch_v e; printf "%s\n" "$e"'
  assert_eq 0 "$RC" "$ERR"
  assert_eq 9 "$OUT"
}

test_clock_says_when_date_cannot_format_the_pinned_time() {
  mkdir -p stub
  printf '#!/bin/sh\nexit 1\n' > stub/date
  chmod +x stub/date
  local fn
  for fn in 'jig_today' 'jig_now_utc_v e' 'jig_now_date -u +%Y'; do
    JIG_NOW=1700000000 _clock_run "PATH=\"\$PWD/stub:\$PATH\"; $fn; printf 'reached\n'"
    [ "$RC" -ne 0 ] || fail "[$fn] went on when date failed"
    assert_not_contains "$OUT" reached "[$fn] went on when date failed"
    assert_contains "$ERR" "date cannot format JIG_NOW=1700000000"
  done
}

# A day is counted from its midnight, so a pinned run counts the same whatever
# the real time of day (BSD `date -j -f` fills a missing time from the real clock).
test_clock_days_since_a_date_do_not_follow_the_real_hour() {
  local fn
  for fn in _task_days_since _hk_days_since; do
    # 2023-11-14 00:30 UTC: one day after the 13th, not yet one after its noon.
    JIG_NOW=1699921800 TZ=UTC _clock_run ". \"$JIG_HOME/scripts/lib/task.sh\"; . \"$JIG_HOME/scripts/lib/housekeeping.sh\"; $fn 2023-11-13; $fn 2023-11-14"
    assert_eq 0 "$RC" "$ERR"
    assert_eq "1
0" "$OUT" "$fn at 00:30"
    # 2023-11-14 23:30 UTC: still one day after the 13th.
    JIG_NOW=1700004600 TZ=UTC _clock_run ". \"$JIG_HOME/scripts/lib/task.sh\"; . \"$JIG_HOME/scripts/lib/housekeeping.sh\"; $fn 2023-11-13"
    assert_eq 1 "$OUT" "$fn at 23:30"
  done
}

test_clock_refuses_a_malformed_jig_now() {
  local v fn
  for v in abc -5 1.5 ' 1700000000' '17000000000000000' '0x10'; do
    for fn in 'jig_now_epoch_v e' 'jig_now_utc_v e' 'jig_now_date +%Y' 'jig_today' 'jig_now_utc' 'jig_now_check'; do
      JIG_NOW=$v _clock_run "$fn; printf 'reached\n'"
      [ "$RC" -ne 0 ] || fail "[$fn] accepted JIG_NOW=[$v]"
      assert_not_contains "$OUT" reached "[$fn] went on with JIG_NOW=[$v]"
      assert_contains "$ERR" "JIG_NOW must be seconds since the epoch, got '$v'"
    done
  done
}

# --- the sentinel ----------------------------------------------------------------

# _clock_scan <dir> — file:line of every `date` under <dir> that reads the current
# time (no -d, -r or -j input) and is neither inside the seam (common.sh, from
# "# --- the clock" to jig_today) nor marked `real clock:` on its own line or the
# line above. Prose, comments, `--date=`, `date` as a word or a variable are not
# commands and are not matched.
_clock_scan() {
  find "$1" -type f -exec awk '
      FNR == 1 { inseam = 0; prev = "" }
      /^# --- the clock/ { inseam = 1 }
      {
        line = $0
        if (!inseam && line !~ /^[ \t]*#/ && line !~ /real clock:/ && prev !~ /real clock:/ && reads(line))
          printf "%s:%d: %s\n", FILENAME, FNR, line
        if (line ~ /^jig_today\(\)/) inseam = 0
        prev = line
      }
      # reads(l) — 1 when <l> runs `date` for the current time.
      function reads(l,   rest, off, i, pre, post, c, args, stripped) {
        rest = l; off = 0
        while ((i = index(rest, "date")) > 0) {
          pre = substr(rest, 1, i - 1); post = substr(rest, i + 4)
          rest = substr(rest, i + 4)
          c = substr(post, 1, 1)
          if (c != "" && c !~ /[ \t)`;|&]/) continue
          sub(/[ \t]+$/, "", pre)
          if (!(pre == "" || pre ~ /(\$\(|`|\||&|;|\(|\{|!)$/ || pre ~ /(^|[ \t])(then|do|else|elif)$/)) continue
          if (c == ")" && pre !~ /(\$\(|`)$/) continue
          args = post
          sub(/[)`|;&].*$/, "", args)
          if (args ~ /(^|[ \t])-(-date|[A-Za-z]*[drj])([ \t=]|$)/) continue
          return 1
        }
        return 0
      }' {} +
}

test_clock_no_date_reads_the_clock_outside_the_seam() {
  local found
  found=$(_clock_scan "$JIG_HOME/scripts")
  [ -z "$found" ] || fail "a date reads the current time outside the seam and is not marked 'real clock:':
$found"
}

test_clock_sentinel_catches_what_it_should_and_only_that() {
  mkdir -p planted
  cat > planted/bad.sh <<'EOT'
a=$(date +%s)
b=`date -u +%Y`
if [ x ]; then date +%s; fi
c=$(date -u +%Y-%m-%dT%H:%M:%SZ)
x=$(( $(date +%s) + 3 ))
echo a | date '+%F'
EOT
  cat > planted/good.sh <<'EOT'
# date +%s in a comment
echo "up to date with origin"
x=$(date -u -d "@$n" +%s)
y=$(date -u -r "$n" +%s)
z=$(date -u -j -f '%Y-%m-%d' "$d" +%s)
d=$(fm_get "$file" date)
fm_set "$f" date "$v"
git log --date=short
local id type date supersedes
printf '%s\n' "$date"
now=$(date +%s) # real clock: a wait
# real clock: a wait
w=$(( $(date +%s) + 3 ))
case $k in date) ;; esac
EOT
  assert_eq 6 "$(_clock_scan planted/bad.sh | wc -l | tr -d ' ')" "planted lines caught"
  assert_eq "" "$(_clock_scan planted/good.sh)" "false positives"
  # The same on a tree shaped like the real one: one more planted read is found.
  mkdir -p tree/lib
  cp "$JIG_HOME/scripts/lib/common.sh" tree/lib/common.sh
  assert_eq "" "$(_clock_scan tree)" "the seam itself"
  printf 'now=$(date +%%s)\n' >> tree/lib/common.sh
  assert_contains "$(_clock_scan tree)" "common.sh:$(wc -l < tree/lib/common.sh | tr -d ' '): now=\$(date +%s)"
}

# --- one real command ------------------------------------------------------------

# The dispatcher refuses a malformed JIG_NOW before any command runs: a stamp
# read through $(...) alone would only end its own subshell.
test_clock_a_command_refuses_a_malformed_jig_now_before_it_writes() {
  fixture_jig_repo
  set +e
  JIG_NOW=abc jig task new clock-probe > t.out 2> t.err
  RC=$?
  set -e
  [ "$RC" -ne 0 ] || fail "task new ran under JIG_NOW=abc"
  assert_contains "$(cat t.err)" "JIG_NOW must be seconds since the epoch, got 'abc'"
  [ ! -e .ai/workspace/tasks/clock-probe ] || fail "task new wrote its workspace"
}

test_clock_a_json_read_refuses_a_malformed_jig_now_in_its_envelope() {
  fixture_jig_repo
  set +e
  JIG_NOW=abc jig queue list --json > q.out 2> q.err
  RC=$?
  set -e
  assert_eq 1 "$RC" "$(cat q.err)"
  assert_contains "$(cat q.out)" "\"error\":{\"code\":\"failed\",\"message\":\"JIG_NOW must be seconds since the epoch, got 'abc'\"}"
}

test_clock_a_json_read_prints_the_pinned_time() {
  fixture_jig_repo
  JIG_NOW=1700000000 jig queue list --json > q.out 2> q.err
  assert_contains "$(cat q.out)" '"generated_at":"2023-11-14T22:13:20Z"'
}
