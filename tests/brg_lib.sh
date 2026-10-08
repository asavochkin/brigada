# Helpers for tests/test_brg_*.sh (sourced by each of them). bash 3.2.

BRG_SRC=$ROOT/bin/brg
export BRG_TICK=0.1
unset BRG_AS BRG_PLATFORM

# new_proj — fresh project with an initialized .brigada and short timeouts.
# Sets P (project), B (.brigada), BRG (installed brg).
new_proj() {
  P=$(mk_tmpdir)
  bash "$BRG_SRC" init "$P" >/dev/null || fail "init"
  B=$P/.brigada
  BRG=$B/bin/brg
  cat >"$B/config" <<'EOF'
wait_timeout.default: 3
wait_timeout.claude: 3
wait_timeout.opencode: 3
wait_timeout.codex: 2
heartbeat: 1
asleep_after: 60
gone_after: 120
lock_stale: 3
msg_max_bytes: 8192
wait_output_max: 20000
runner_dead_grace: 0
EOF
}

brg() { bash "$BRG" "$@"; }

# join_as HARNESS [MODEL] → prints the assigned name
join_as() {
  brg join --harness "$1" --model "${2:-m}" | sed -n 's/^── подключён: \([^ ]*\) .*/\1/p'
}

# send_as NAME TEXT [send options...]
send_as() {
  local n=$1 t=$2
  shift 2
  printf '%s\n' "$t" | brg send --as "$n" "$@" >/dev/null || fail "send as $n: $t"
}

# msg_file N → path of lobby message N
msg_file() { printf '%s/lobby/messages/%06d.msg' "$B" "$1"; }

# hdr FILE KEY → header value
hdr() { awk -v k="$2" 'index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit } /^$/ { exit }' "$1"; }

# cursor NAME → "Acked/Pending"
cursor() {
  local f=$B/lobby/cursors/$1
  [ -f "$f" ] || { echo "-"; return; }
  printf '%s/%s\n' "$(hdr "$f" Acked)" "$(hdr "$f" Pending)"
}

# pid_is NAME PID — the wait pid file names PID
pid_is() {
  local p=
  [ -f "$B/run/wait/$1.pid" ] && IFS= read -r p <"$B/run/wait/$1.pid"
  [ "$p" = "$2" ]
}

# metrics lines of AGENT with COMMAND (grep-free)
metrics_of() { awk -v a="$1" -v c="$2" '$2 == a && $3 == c' "$B/run/metrics.log"; }

# start_wait NAME OUT [args...] — background wait; sets WP
start_wait() {
  local n=$1 o=$2
  shift 2
  bash "$BRG" wait --as "$n" "$@" >"$o" 2>&1 &
  WP=$!
  track_pid $WP
  wait_for 3 pid_is "$n" $WP || fail "wait $n did not start"
}

# ack_all NAME [CHANNEL_DIR] — mark everything in the channel (default lobby) as
# handled by NAME: an "empty inbox" without delivering quiet join/leave notices.
ack_all() {
  local d=${2:-$B/lobby} s
  s=$(cat "$d/seq")
  printf 'Acked: %s\nPending: %s\n' "$s" "$s" >"$d/cursors/$1"
}

# task_new_as NAME TITLE [BRIEF] [options...] — create a task, fail on error
task_new_as() {
  local n=$1 t=$2 b=${3:-постановка от человека}
  shift 3 2>/dev/null || shift $#
  printf '%s\n' "$b" | brg task new --as "$n" --title "$t" "$@" >/dev/null || fail "task new as $n: $t"
}

# tdir ID → task directory (tasks/ID or tasks/ID-slug)
tdir() {
  local f
  for f in "$B/tasks/$1" "$B/tasks/$1"-*; do
    [ -f "$f/task" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

# tmsg ID N → path of message N in task ID's channel
tmsg() { printf '%s/messages/%06d.msg' "$(tdir "$1")" "$2"; }

# tcursor NAME ID → "Acked/Pending" in task ID's channel
tcursor() {
  local f
  f=$(tdir "$2")/cursors/$1
  [ -f "$f" ] || { echo "-"; return; }
  printf '%s/%s\n' "$(hdr "$f" Acked)" "$(hdr "$f" Pending)"
}

# dead_pid — a pid that is surely dead (a reaped child of ours)
dead_pid() {
  local p
  (exit 0) &
  p=$!
  wait $p
  echo $p
}
