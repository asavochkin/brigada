# Test helpers; sourced by tests/run.sh into each test file's process. bash 3.2.
# Each test_* function runs in its own subshell; `fail` ends the current test.

# Per-file temp root (removed on exit); every mk_tmpdir lives inside it.
_t_init() {
  local base=${TMPDIR:-/tmp}
  base=${base%/}
  while :; do
    T_ROOT=$base/brg-tests.$$.$RANDOM
    mkdir "$T_ROOT" 2>/dev/null && break
  done
  trap '_t_cleanup' EXIT
  trap 'exit 130' INT TERM
}
_t_cleanup() {
  [ -n "${_T_CUR_PG:-}" ] && kill -TERM -- -"$_T_CUR_PG" 2>/dev/null
  [ -n "$T_ROOT" ] && rm -rf "$T_ROOT"
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  [ -n "${T_FAILMARK:-}" ] && : >>"$T_FAILMARK" # also counts when called from $(...)
  exit 1
}

assert_eq() { # expected actual [msg]
  [ "$1" = "$2" ] || fail "${3:-assert_eq}: ожидалось [$1], получено [$2]"
}
assert_contains() { # haystack needle [msg]
  case $1 in *"$2"*) ;; *) fail "${3:-assert_contains}: нет [$2] в:
$1" ;; esac
}
assert_not_contains() { # haystack needle [msg]
  case $1 in *"$2"*) fail "${3:-assert_not_contains}: есть [$2] в:
$1" ;; esac
}
assert_file_exists() { # path [msg]
  [ -e "$1" ] || fail "${2:-assert_file_exists}: нет файла $1"
}
assert_file_not_exists() { # path [msg]
  [ ! -e "$1" ] || fail "${2:-assert_file_not_exists}: файл существует $1"
}

# Fresh temp directory (removed with T_ROOT).
mk_tmpdir() {
  local d
  while :; do
    d=$T_ROOT/tmp.$RANDOM$RANDOM
    mkdir "$d" 2>/dev/null && break
  done
  printf '%s\n' "$d"
}

# Background processes to kill after the test, whatever its outcome.
track_pid() { printf '%s\n' "$1" >>"$T_PIDS"; }

is_alive() { kill -0 "$1" 2>/dev/null; }
is_dead() { ! kill -0 "$1" 2>/dev/null; }

# wait_for SECS CMD... — poll CMD every 0.1 s until it succeeds.
wait_for() {
  local n=$(($1 * 10))
  shift
  while [ $n -gt 0 ]; do
    "$@" && return 0
    sleep 0.1
    n=$((n - 1))
  done
  "$@"
}

# wait_pid PID SECS — reap a background child; 1 if it outlived SECS (then TERMed).
# Sets WAIT_RC. For non-children use: wait_for SECS is_dead PID.
wait_pid() {
  local pid=$1 n=$((${2:-5} * 10)) k mark=$T_ROOT/.wp.$1
  rm -f "$mark"
  (
    while [ $n -gt 0 ]; do
      sleep 0.1
      kill -0 "$pid" 2>/dev/null || exit 0
      n=$((n - 1))
    done
    : >"$mark"
    kill -TERM "$pid" 2>/dev/null
  ) &
  k=$!
  wait "$pid"
  WAIT_RC=$?
  kill "$k" 2>/dev/null
  wait "$k" 2>/dev/null
  [ ! -e "$mark" ]
}

_t_kill_tracked() {
  local p left=
  [ -s "$T_PIDS" ] || return 0
  for p in $(cat "$T_PIDS"); do
    kill -TERM "$p" 2>/dev/null && left="$left $p"
  done
  [ -n "$left" ] || return 0
  sleep 0.3
  for p in $left; do kill -KILL "$p" 2>/dev/null; done
  return 0
}

# _t_run_one FILE_BASE FUNC RESULTS — run one test with a watchdog, print PASS/FAIL.
# The test runs in its own process group (set -m), so the group kill after it
# also removes any stray children.
_t_run_one() {
  local base=$1 fn=$2 results=$3 out rc t0 t1 tp wp limit=${TEST_TIMEOUT:-60}
  out=$T_ROOT/out.$fn
  T_PIDS=$T_ROOT/pids.$fn
  T_FAILMARK=$T_ROOT/failed.$fn
  : >"$T_PIDS"
  rm -f "$T_FAILMARK" "$T_ROOT/timeout.$fn"
  t0=$(date -u +%s)
  set -m
  (set +m; trap - INT TERM; "$fn"; exit 0) </dev/null >"$out" 2>&1 &
  tp=$!
  _T_CUR_PG=$tp
  (
    i=0
    while [ $i -lt "$limit" ]; do
      sleep 1
      kill -0 "$tp" 2>/dev/null || exit 0
      i=$((i + 1))
    done
    : >"$T_ROOT/timeout.$fn"
    kill -TERM -- -"$tp" 2>/dev/null
  ) </dev/null >/dev/null 2>&1 &
  wp=$!
  set +m
  wait "$tp" 2>/dev/null
  rc=$?
  kill -TERM -- -"$wp" 2>/dev/null
  wait "$wp" 2>/dev/null
  kill -TERM -- -"$tp" 2>/dev/null # strays left in the test's group
  _T_CUR_PG=
  _t_kill_tracked
  t1=$(date -u +%s)
  [ -e "$T_FAILMARK" ] && rc=1
  if [ -e "$T_ROOT/timeout.$fn" ]; then
    echo "FAIL $base:$fn (TIMEOUT ${limit}s)"
    sed 's/^/    /' "$out"
    echo FAIL >>"$results"
  elif [ "$rc" -eq 0 ]; then
    echo "PASS $base:$fn ($((t1 - t0))s)"
    echo PASS >>"$results"
  else
    echo "FAIL $base:$fn (exit $rc)"
    sed 's/^/    /' "$out"
    echo FAIL >>"$results"
  fi
}
