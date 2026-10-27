# Helpers for the tests of agents launched by brg (DESIGN §5.5): test_brg_spawn.sh and the
# server tests in test_brg_serve.sh. Sourced after brg_lib.sh. bash 3.2.
# The harness is tests/fake_opencode (spawn.opencode.bin in the project's config); the real
# opencode is never run. Supervisors and wrappers live in their own process groups, so every
# test stops them itself (sp_cleanup, by pids from its own records only — never by a pattern);
# BRG_SPAWN_TEST_MAXLIFE and the removal of the project are the safety net.

FAKE=$TESTS_DIR/fake_opencode
unset OPENCODE_SESSION_ID BRG_SPAWN BRG_SPAWN_WAIT BRG_SPAWN_ID BRG_SPAWN_HOLD BRG_SPAWN_FORCE BRG_SPAWN_ROLLBACK \
  BRG_SPAWN_EXECVER BRG_TEST_DELIVER_DELAY BRG_CMD_LC BRG_CMD_LC_SET OPENCODE
export BRG_SPAWN_STEP=0.2 BRG_SPAWN_TEST_MAXLIFE=150

# sp_proj — a project (new_proj) whose brg launches the fake; FK = its FAKE_OC_DIR
sp_proj() {
  new_proj
  cat >>"$B/config" <<EOF
spawn.opencode.bin: $FAKE
spawn_stale: 6
spawn.wait_timeout: 30
EOF
  FK=$(mk_tmpdir)
  export FAKE_OC_DIR=$FK
  SP_PROJ_DIRS="${SP_PROJ_DIRS:-} $B"
  trap 'sp_cleanup' EXIT
}

# sp_spawn [args] — brg spawn opencode --model provider/model [args]; SPOUT — its output
sp_spawn() {
  SPOUT=$(cd "$P" && bash "$BRG" spawn opencode --model provider/model "$@" 2>&1) || fail "spawn: $SPOUT"
}

# rec S KEY — a header of the record S
rec() { hdr "$B/run/spawn/$1/spawn" "$2"; }
rec_is() { [ "$(rec "$1" "$2")" = "$3" ]; }
# wait_state S STATE [SECS]
wait_state() {
  wait_for "${3:-25}" rec_is "$1" State "$2" || fail "$1: State $(rec "$1" State), expected $2
$(cat "$B/run/spawn/$1/supervisor.log" 2>/dev/null | tail -n 5)"
}
# runs — how many times the fake harness ran
runs() { local n=0 d; for d in "$FK"/run.*; do [ -d "$d" ] && n=$((n + 1)); done; echo "$n"; }
runs_ge() { [ "$(runs)" -ge "$1" ]; }
# wait_run N [SECS] — run N of the fake started
wait_run() { wait_for "${2:-25}" runs_ge "$1" || fail "the harness did not start run $1 (runs: $(runs))"; }
# turn_done S N — turn N of S is over (the supervisor wrote its result)
turn_done() { [ "$(rec "$1" Turn)" = "$2" ] && [ -n "$(rec "$1" Turn-Result)" ]; }
wait_turn() { wait_for "${3:-30}" turn_done "$1" "$2" || fail "$1: turn $2 did not end (Turn $(rec "$1" Turn), State $(rec "$1" State))"; }
# full NAME — the full name (base.key) of an agent
full() { printf '%s.%s\n' "$1" "$(hdr "$B/agents/$1" Key)"; }
# sv_pid S — the pid of the supervisor (the owner of its lock)
sv_pid() { local o=; [ -f "$B/run/locks/spawn.$1.lock/owner" ] && IFS= read -r o <"$B/run/locks/spawn.$1.lock/owner"; echo "${o%% *}"; }
# script [N] — the scenario of run N (all runs without N) from stdin
script() { cat >"$FK/script${1:+.$1}"; }

# sp_pids DIR — pids from the records of one .brigada: supervisors (lock owners), wrappers
# (turn.pid, turn.hb), runs of the fake and its tools
sp_pids() {
  local b=$1 d f p x
  for d in "$b"/run/spawn/S[0-9]*; do
    [ -d "$d" ] || continue
    for f in "$b/run/locks/spawn.${d##*/}.lock/owner" "$d/turn.pid" "$d/turn.hb"; do
      [ -f "$f" ] || continue
      IFS= read -r x <"$f"
      p=${x%% *}
      case $p in '' | *[!0-9]*) ;; *) echo "$p" ;; esac
    done
  done
}
sp_fake_pids() {
  local f p
  for f in "$1"/run.*/pid "$1"/run.*/tool.*.pid "$1"/run.*/bgwait.pid "$1"/export.*/pid; do
    [ -f "$f" ] || continue
    IFS= read -r p <"$f"
    case $p in '' | *[!0-9]*) ;; *) echo "$p" ;; esac
  done
}
all_dead() { local p; for p in "$@"; do kill -0 "$p" 2>/dev/null && return 1; done; return 0; }

# sp_cleanup — stop what this test started: turns (turn.stop: the wrapper INTs the harness),
# supervisors (TERM to the lock owner), then KILL what is left; only pids of our records
sp_cleanup() {
  local b d p ps= i=0
  for b in ${SP_PROJ_DIRS:-}; do
    for d in "$b"/run/spawn/S[0-9]*; do
      [ -d "$d" ] && : >"$d/turn.stop" 2>/dev/null
    done
    for p in $(sp_pids "$b"); do ps="$ps $p"; done
  done
  [ -n "${FK:-}" ] && for p in $(sp_fake_pids "$FK"); do ps="$ps $p"; done
  for b in ${SP_PROJ_DIRS:-}; do
    for d in "$b"/run/locks/spawn.*.lock; do
      [ -f "$d/owner" ] || continue
      IFS= read -r p <"$d/owner"
      kill -TERM "${p%% *}" 2>/dev/null
    done
  done
  while ! all_dead $ps && [ $i -lt 60 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  # still alive (only those: a pid long dead is never signalled): the group of a tool, then KILL
  for p in $ps; do
    kill -0 "$p" 2>/dev/null || continue
    kill -TERM -- -"$p" 2>/dev/null
    kill -KILL "$p" 2>/dev/null
  done
  return 0
}
# sp_assert_clean — nothing of this test's records is alive (after sp_cleanup)
sp_assert_clean() {
  local b p left=
  sp_cleanup
  sleep 0.3
  for b in ${SP_PROJ_DIRS:-}; do
    for p in $(sp_pids "$b"); do kill -0 "$p" 2>/dev/null && left="$left $p"; done
  done
  for p in $(sp_fake_pids "${FK:-/nonexistent}"); do kill -0 "$p" 2>/dev/null && left="$left $p"; done
  [ -z "$left" ] || fail "processes left:$left"
}
# cursor_is NAME A/P — the lobby cursor of NAME (evaluated on every try of wait_for)
cursor_is() { [ "$(cursor "$1")" = "$2" ]; }
