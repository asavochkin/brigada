# brg run — the global exec lock, the queue, detached runners, results
# as messages, --sync, timeout, cancel, dead runners.

. "$TESTS_DIR/brg_lib.sh"

# Runners live in their own process groups (they must survive the harness), so
# the per-test group kill does not reach them: every test kills them itself.
run_cleanup() {
  local f r g
  [ -n "${B:-}" ] || return 0
  for f in "$B"/tasks/*/shared/runs/R[0-9]*; do
    [ -f "$f" ] || continue
    case ${f##*/} in *.*) continue ;; esac
    r=$(hdr "$f" Runner)
    g=$(hdr "$f" Pgid)
    [ -n "$g" ] && kill -KILL -- -"$g" 2>/dev/null
    [ -n "$r" ] && kill -KILL "$r" 2>/dev/null
  done
  return 0
}

# A (claude-1) leads task T001, Bn (codex-1); inboxes empty. wait_timeout: claude 3, codex 2.
run_setup() {
  trap run_cleanup EXIT
  new_proj
  A=$(join_as claude opus)
  Bn=$(join_as codex gpt)
  task_new_as "$A" "Прогоны"
  D=$(tdir T001)
  for x in "$A" "$Bn"; do
    ack_all "$x"
    ack_all "$x" "$D"
  done
}
rhdr() { hdr "$D/shared/runs/$1" "$2"; } # RID KEY
# run_status_is RID STATUS
run_status_is() { [ "$(rhdr "$1" Status)" = "$2" ]; }
run_has_runner() { [ -n "$(rhdr "$1" Runner 2>/dev/null)" ]; }
run_final() { case $(rhdr "$1" Status) in done | failed | timeout | killed | cancelled) return 0 ;; esac; return 1; }

# The result reaches the initiator through wait. Detached run
# returns at once and does not hold the caller's pipe (`brg run … | cat`).
test_run_detached_returns_fast_and_reports_via_wait() {
  local out t0 t1 f
  run_setup
  t0=$(date -u +%s)
  out=$(bash "$BRG" run --as "$Bn" -- bash -c 'echo начало; printf "\033[31mкрасный\033[0m\n"; sleep 2; echo конец; exit 3' 2>&1 | cat)
  t1=$(date -u +%s)
  [ $((t1 - t0)) -le 1 ] || fail "brg run | cat took $((t1 - t0)) s — the runner holds the pipe?"
  assert_contains "$out" "── R001 запущен (очередь пуста)."
  assert_contains "$out" "лог: .brigada/tasks/T001/shared/runs/R001.log"
  assert_contains "$out" "Результат (статус, код, хвост лога) придёт тебе сообщением в wait"
  assert_eq "── NEXT: продолжай другую работу; закончив шаг — bash $BRG wait --as $Bn" "$(printf '%s\n' "$out" | tail -n 1)"
  assert_eq "$Bn" "$(rhdr R001 Agent)"
  assert_eq T001 "$(rhdr R001 Task)"
  assert_eq detached "$(rhdr R001 Mode)"
  assert_eq 1800 "$(rhdr R001 Timeout)" "run_timeout default"
  wait_for 2 run_status_is R001 running || fail "not running: $(rhdr R001 Status)"
  [ -n "$(rhdr R001 Pgid)" ] || fail "no Pgid"
  # the result arrives as a waking system message to the initiator only
  out=$(brg wait --as "$Bn" --timeout 8)
  assert_contains "$out" "── T001 · 1 новое"
  assert_contains "$out" "[система] brg → $Bn"
  assert_contains "$out" "R001 · failed (код 3) · "
  assert_contains "$out" "Лог: .brigada/tasks/T001/shared/runs/R001.log"
  assert_contains "$out" "── последние строки лога:"
  assert_contains "$out" "    начало"
  assert_contains "$out" "    красный
" # escape sequences stripped
  assert_not_contains "$out" $'\033'
  assert_contains "$out" "    конец"
  assert_eq failed "$(rhdr R001 Status)"
  assert_eq 3 "$(rhdr R001 Exit)"
  assert_file_exists "$D/shared/runs/R001.notified"
  assert_eq "" "$(ls -A "$B/run/execq")" "queue empty"
  assert_eq "" "$(ls -A "$B/run/locks")" "exec lock released"
  assert_contains "$(brg wait --as "$A" --timeout 0)" "── нет новых" "not for others"
  f=$D/shared/runs/R001.log
  assert_contains "$(cat "$f")" "конец"
  assert_contains "$(metrics_of "$Bn" run.end)" "id=R001 status=failed exit=3"
  # A harness may kill the whole process group of its tool call once it is done:
  # the runner (own process group, nohup) survives and finishes the job.
  set -m
  (bash "$BRG" run --as "$Bn" -- 'sleep 1; echo выжил >survived' >"$P/front.out" 2>&1; sleep 30) &
  pg=$!
  set +m
  wait_for 3 run_has_runner R002 || fail "R002 not started: $(cat "$P/front.out")"
  kill -TERM -- -"$pg"
  wait "$pg" 2>/dev/null
  wait_for 4 run_final R002 || fail "the runner died with the caller's process group"
  assert_eq done "$(rhdr R002 Status)"
  assert_eq выжил "$(cat "$P/survived")"
}

# Environment of the command: cwd = project root, the caller's locale (brg itself
# runs with LC_ALL=C), BRG_RUN; a single argument goes through bash -c.
test_run_environment() {
  local out
  run_setup
  mkdir -p "$P/sub"
  out=$(cd "$P/sub" && LC_ALL=en_US.UTF-8 BRG_TICK=0.1 bash .././.brigada/bin/brg run --as "$Bn" --sync -- 'pwd; echo "lc=$LC_ALL run=$BRG_RUN"; echo a | cat')
  assert_contains "$out" "  $P
"
  assert_contains "$out" "  lc=en_US.UTF-8 run=R001"
  assert_contains "$out" "  a"
  out=$(unset LC_ALL; brg run --as "$Bn" --sync -- printf '%s|%s\n' "two words" 'x$y')
  assert_contains "$out" "  two words|x\$y"
  assert_contains "$out" "R002 · done (код 0)"
  assert_eq "printf '%s|%s\n' 'two words' 'x\$y'" "$(rhdr R002 Command)"
  out=$(unset LC_ALL; brg run --as "$Bn" --sync -- 'echo "[${LC_ALL-unset}]"')
  assert_contains "$out" "  [unset]"
}

# A second run waits for the exec lock; runs execute one at a time
# in request order.
test_run_queue_one_at_a_time_in_order() {
  local out i
  run_setup
  out=$(brg run --as "$Bn" -- 'echo "A start" >>order; sleep 1.5; echo "A end" >>order')
  assert_contains "$out" "── R001 запущен"
  wait_for 2 run_status_is R001 running || fail "R001 did not start"
  out=$(brg run --as "$A" -- 'echo "B start" >>order; sleep 0.3; echo "B end" >>order')
  assert_contains "$out" "── R002 в очереди: перед ним 1 — выполняется R001 · $Bn"
  out=$(brg run --as "$Bn" -- 'echo "C" >>order')
  assert_contains "$out" "── R003 в очереди: перед ним 2 — выполняется R001 · $Bn"
  assert_contains "$out" "ждут: R002 · $A · echo \"B start\""
  assert_eq queued "$(rhdr R002 Status)"
  out=$(brg run list)
  assert_contains "$out" "── выполняется: R001 · running"
  assert_contains "$out" "── в очереди (2): R002 · $A"
  wait_for 8 run_final R003 || fail "R003 did not finish"
  assert_eq "A start
A end
B start
B end
C" "$(cat "$P/order")" "one at a time, in order"
  [ "$(rhdr R002 Started-Epoch)" -ge "$(rhdr R001 Finished-Epoch)" ] || fail "R002 started before R001 finished"
  for i in R001 R002 R003; do assert_eq done "$(rhdr $i Status)"; done
  assert_contains "$(brg wait --as "$A" --timeout 1)" "R002 · done (код 0)"
  out=$(brg wait --as "$Bn" --timeout 1)
  assert_contains "$out" "R001 · done (код 0)"
  assert_contains "$out" "R003 · done (код 0)"
}

# Timeout: the whole process group of the command is killed, status timeout.
test_run_timeout_kills_the_group() {
  local out c1 c2
  run_setup
  brg run --as "$Bn" --timeout 1 -- 'sleep 30 & echo $! >child1; (sleep 30 & echo $! >child2; wait) & sleep 30' >/dev/null || fail run
  wait_for 2 test -s "$P/child2" || fail "command did not start"
  c1=$(cat "$P/child1")
  c2=$(cat "$P/child2")
  is_alive "$c1" || fail "child1 not running"
  wait_for 6 run_final R001 || fail "no timeout"
  assert_eq timeout "$(rhdr R001 Status)"
  wait_for 2 is_dead "$c1" || fail "background child survived the timeout"
  wait_for 2 is_dead "$c2" || fail "grandchild survived the timeout"
  out=$(brg wait --as "$Bn" --timeout 2)
  assert_contains "$out" "R001 · timeout: остановлен по лимиту 1 с"
  assert_eq "" "$(ls -A "$B/run/locks")"
  # leftovers of a command that exited normally are stopped too
  brg run --as "$Bn" -- 'sleep 30 & echo $! >child3; echo ok' >/dev/null || fail run
  wait_for 4 run_final R002 || fail "R002 did not finish"
  assert_eq done "$(rhdr R002 Status)"
  wait_for 3 is_dead "$(cat "$P/child3")" || fail "a leftover background process survived"
}

# hb_loop FILE PID — keep writing "PID now" into FILE every 0.3 s (a live runner's
# heartbeat); sets HBP
hb_loop() {
  (
    while :; do
      printf '%s %s\n' "$2" "$(date -u +%s)" >"$1.tmp" && mv -f "$1.tmp" "$1"
      sleep 0.3
    done
  ) &
  HBP=$!
  track_pid $HBP
}

# The exec lock is held for a whole command: a live owner whose heartbeat is fresh
# is never broken by age (unlike the other locks, lock_stale = 3 s here); a dead
# owner is broken at once, a live one silent for longer than runner_stale too.
test_exec_lock_live_owner_not_broken_by_age() {
  local sp out
  run_setup
  printf 'runner_stale: 3\n' >>"$B/config"
  sleep 60 &
  sp=$!
  track_pid $sp
  mkdir "$B/run/locks/exec.lock"
  printf '%s %s\n' $sp $(($(date -u +%s) - 1000)) >"$B/run/locks/exec.lock/owner"
  hb_loop "$B/run/locks/exec.lock/hb" $sp
  out=$(brg run --as "$Bn" -- 'echo пошло')
  assert_contains "$out" "R001 "
  sleep 5 # > lock_stale and runner_stale (3 s) + the 20-tries age check
  assert_eq queued "$(rhdr R001 Status)" "exec lock broken by age"
  assert_eq "$sp" "$(awk '{ print $1 }' "$B/run/locks/exec.lock/owner")" "exec lock owner"
  is_alive $sp || fail "owner touched"
  # the owner dies → the lock is broken at once and the run goes
  kill -KILL $HBP
  kill -KILL $sp
  wait $sp 2>/dev/null
  wait_for 4 run_final R001 || fail "run did not proceed after the owner died"
  assert_eq done "$(rhdr R001 Status)"
  assert_contains "$(metrics_of "$Bn" lock.break)" "lock=exec.lock"
  assert_contains "$(metrics_of "$Bn" lock.break)" "why=dead"
  # other locks keep their age rule (regression guard of the shared lock code)
  sleep 30 &
  sp=$!
  track_pid $sp
  mkdir "$B/run/locks/chan.lobby.lock"
  printf '%s %s\n' $sp $(($(date -u +%s) - 1000)) >"$B/run/locks/chan.lobby.lock/owner"
  send_as "$A" "через старую блокировку живого владельца" --channel lobby
}

# A live pid is not proof of life — the exec lock of an owner whose
# heartbeat stopped (a hung runner, or its pid reused by another process) is
# broken after runner_stale, without signalling that pid.
test_exec_lock_live_pid_without_heartbeat_is_broken_after_threshold() {
  local sp out t0 t1
  run_setup
  printf 'runner_stale: 3\n' >>"$B/config"
  sleep 60 &
  sp=$!
  track_pid $sp
  mkdir "$B/run/locks/exec.lock"
  printf '%s %s\n' $sp "$(date -u +%s)" >"$B/run/locks/exec.lock/owner" # no hb file at all
  printf 'R077 %s\n' "${D##*/}" >"$B/run/locks/exec.lock/run"
  t0=$(date -u +%s)
  out=$(brg run --as "$Bn" -- 'echo пошло')
  assert_contains "$out" "R001 в очереди: перед ним 1"
  sleep 2
  assert_eq queued "$(rhdr R001 Status)" "broken before the threshold"
  wait_for 8 run_final R001 || fail "the next run hangs behind a silent owner with a live pid"
  t1=$(date -u +%s)
  [ $((t1 - t0)) -ge 3 ] || fail "broken after $((t1 - t0)) s, before runner_stale"
  assert_eq done "$(rhdr R001 Status)"
  is_alive $sp || fail "the foreign pid was signalled"
  assert_contains "$(metrics_of "$Bn" lock.break)" "why=hb"
  # the same with a heartbeat that stops: fresh while it beats, broken after it stops
  mkdir "$B/run/locks/exec.lock"
  printf '%s %s\n' $sp $(($(date -u +%s) - 1000)) >"$B/run/locks/exec.lock/owner"
  hb_loop "$B/run/locks/exec.lock/hb" $sp
  brg run --as "$Bn" -- 'echo второй' >/dev/null || fail run2
  sleep 5
  assert_eq queued "$(rhdr R002 Status)" "broken while the heartbeat was fresh"
  kill -KILL $HBP
  wait_for 8 run_final R002 || fail "not broken after the heartbeat stopped"
  assert_eq done "$(rhdr R002 Status)"
  is_alive $sp || fail "the foreign pid was signalled"
}

# The same for the queue — an entry with a live foreign pid and no
# heartbeat does not block the queue forever.
test_queue_entry_live_pid_without_heartbeat_is_dropped_after_threshold() {
  local sp out
  run_setup
  printf 'runner_stale: 3\n' >>"$B/config"
  sleep 60 &
  sp=$!
  track_pid $sp
  mkdir -p "$B/run/execq"
  printf '%s R000 %s\n' $sp "${D##*/}" >"$B/run/execq/000000"
  out=$(brg run --as "$Bn" -- 'echo пошло')
  assert_contains "$out" "R001 в очереди: перед ним 1 — R000"
  assert_contains "$out" "(раннер не отвечает)"
  sleep 2
  assert_eq queued "$(rhdr R001 Status)" "dropped before the threshold"
  wait_for 8 run_final R001 || fail "the queue hangs behind an entry with a live pid"
  assert_eq done "$(rhdr R001 Status)"
  assert_file_not_exists "$B/run/execq/000000"
  is_alive $sp || fail "the foreign pid was signalled"
  assert_contains "$(metrics_of "$Bn" execq.drop)" "run=R000 pid=$sp why=hb"
  # a live entry that keeps beating holds its place
  hb_loop "$B/run/execq/000000" "$sp R000 ${D##*/}"
  brg run --as "$Bn" -- 'echo второй' >/dev/null || fail run2
  sleep 5
  assert_eq queued "$(rhdr R002 Status)" "a beating entry was dropped"
  kill -KILL $HBP
  wait_for 8 run_final R002 || fail "not dropped after the heartbeat stopped"
  assert_eq done "$(rhdr R002 Status)"
}

# A real runner that hangs (SIGSTOP) is judged dead by the next one in the
# queue, its run settled as killed; when it wakes up it finds the exec lock taken,
# stops its command and keeps the verdict.
test_hung_runner_is_replaced_and_stops_after_waking() {
  local r g out
  run_setup
  printf 'runner_stale: 3\n' >>"$B/config"
  brg run --as "$Bn" -- 'sleep 20; echo first >>order' >/dev/null || fail run1
  wait_for 3 run_status_is R001 running || fail "R001 did not start"
  r=$(rhdr R001 Runner)
  g=$(rhdr R001 Pgid)
  kill -STOP "$r"
  brg run --as "$A" -- 'echo second >>order' >/dev/null || fail run2
  wait_for 12 run_final R002 || fail "R002 stuck behind a hung runner"
  assert_eq done "$(rhdr R002 Status)"
  assert_eq killed "$(rhdr R001 Status)"
  assert_contains "$(rhdr R001 Note)" "раннер (pid $r) не подавал признаков жизни"
  assert_contains "$(rhdr R001 Note)" "во время выполнения (pid жив"
  out=$(brg wait --as "$Bn" --timeout 2)
  assert_contains "$out" "R001 · killed: раннер (pid $r) не подавал признаков жизни"
  kill -CONT "$r"
  wait_for 8 is_dead "$r" || fail "the woken runner did not leave"
  kill -0 -- -"$g" 2>/dev/null && fail "the woken runner did not stop its command"
  assert_eq killed "$(rhdr R001 Status)" "the verdict was overwritten"
  assert_contains "$(rhdr R001 Note)" "позже раннер ожил"
  assert_eq second "$(cat "$P/order")"
  assert_contains "$(brg wait --as "$Bn" --timeout 1)" "── нет новых" "a second message about R001"
  assert_eq "" "$(ls -A "$B/run/execq")"
}

# run show / run list / status check the runner: a dead one is settled
# (killed, the initiator told), a silent one with a live pid is flagged; run
# cancel settles a silent runner itself.
test_run_views_diagnose_dead_and_silent_runners() {
  local r g out
  run_setup
  printf 'runner_stale: 3\n' >>"$B/config"
  brg run --as "$Bn" -- 'sleep 30' >/dev/null || fail run1
  wait_for 3 run_status_is R001 running || fail "R001 did not start"
  r=$(rhdr R001 Runner)
  g=$(rhdr R001 Pgid)
  kill -STOP "$r"
  sleep 4.5
  out=$(brg run show R1)
  assert_contains "$out" "── R001 · running"
  assert_contains "$out" "ВНИМАНИЕ: раннер (pid $r) не подаёт признаков жизни"
  assert_contains "$out" "run cancel R001"
  assert_contains "$(brg run list)" "R001 · running"
  assert_contains "$(brg run list)" "раннер не отвечает"
  assert_contains "$(brg status --as "$Bn")" "раннер не отвечает"
  assert_eq running "$(rhdr R001 Status)" "a view changed a silent run"
  # dead: settled by the first look
  kill -KILL "$r"
  kill -CONT "$r" 2>/dev/null
  wait_for 2 is_dead "$r"
  out=$(brg run show R1)
  assert_contains "$out" "── R001 · killed"
  assert_contains "$out" "Примечание: раннер (pid $r) умер во время выполнения; команда могла остаться работать (группа процессов $g)"
  kill -KILL -- -"$g" 2>/dev/null
  assert_contains "$(brg wait --as "$Bn" --timeout 2)" "R001 · killed: раннер (pid $r) умер"
  # status: my queued run whose runner died
  sleep 60 &
  sp=$!
  track_pid $sp
  rm -rf "$B/run/locks/exec.lock"
  mkdir "$B/run/locks/exec.lock"
  printf '%s %s\n' $sp "$(date -u +%s)" >"$B/run/locks/exec.lock/owner"
  hb_loop "$B/run/locks/exec.lock/hb" $sp
  brg run --as "$A" -- 'echo в очереди' >/dev/null || fail run2
  wait_for 3 run_has_runner R002 || fail "R002 has no runner"
  sleep 0.5
  kill -KILL "$(rhdr R002 Runner)"
  sleep 0.3
  out=$(brg status --as "$A")
  assert_contains "$out" "Мои прогоны с умершим раннером: R002 — отмечены killed"
  assert_eq killed "$(rhdr R002 Status)"
  assert_contains "$(rhdr R002 Note)" "умер в очереди"
  assert_contains "$(brg wait --as "$A" --timeout 2)" "R002 · killed"
  # run cancel of a silent runner settles it here; the runner, woken, stops its command
  kill -KILL $HBP
  kill -KILL $sp
  rm -rf "$B/run/locks/exec.lock"
  brg run --as "$Bn" -- 'sleep 30' >/dev/null || fail run3
  wait_for 3 run_status_is R003 running || fail "R003 did not start"
  r=$(rhdr R003 Runner)
  g=$(rhdr R003 Pgid)
  kill -STOP "$r"
  sleep 4.5
  out=$(brg run cancel R3 --as "$Bn")
  assert_contains "$out" "── R003 · killed: остановлен командой run cancel ($Bn); раннер не отвечал"
  kill -CONT "$r"
  wait_for 8 is_dead "$r" || fail "the woken runner did not leave"
  kill -0 -- -"$g" 2>/dev/null && fail "the woken runner did not stop its command"
  assert_eq killed "$(rhdr R003 Status)"
  assert_eq "" "$(ls -A "$B/run/locks")" "exec lock left behind"
}

# A runner killed with -9 while executing: its exec lock is broken as a dead
# owner's, the run is marked killed, its initiator told; the next run goes.
test_dead_runner_releases_lock() {
  local r g out
  run_setup
  brg run --as "$Bn" -- 'sleep 30' >/dev/null || fail run
  wait_for 3 run_status_is R001 running || fail "R001 did not start"
  brg run --as "$A" -- 'echo второй' >/dev/null || fail run2
  sleep 0.5
  assert_eq queued "$(rhdr R002 Status)"
  r=$(rhdr R001 Runner)
  g=$(rhdr R001 Pgid)
  kill -KILL "$r"
  wait_for 4 run_final R002 || fail "the next run did not proceed: R002 $(rhdr R002 Status)"
  assert_eq done "$(rhdr R002 Status)"
  assert_eq killed "$(rhdr R001 Status)"
  assert_contains "$(rhdr R001 Note)" "раннер (pid $r) умер во время выполнения; команда могла остаться работать (группа процессов $g)"
  out=$(brg wait --as "$Bn" --timeout 2)
  assert_contains "$out" "R001 · killed: раннер (pid $r) умер во время выполнения"
  assert_contains "$(brg wait --as "$A" --timeout 2)" "R002 · done (код 0)"
  kill -KILL -- -"$g" 2>/dev/null # the orphaned command
  # a runner killed while queued: its entry is dropped, the run marked killed
  brg run --as "$Bn" -- 'sleep 30' >/dev/null || fail run3
  wait_for 3 run_status_is R003 running || fail "R003 did not start"
  brg run --as "$A" -- 'echo четвёртый' >/dev/null || fail run4
  brg run --as "$A" -- 'echo пятый' >/dev/null || fail run5
  sleep 0.3
  kill -KILL "$(rhdr R004 Runner)"
  brg run cancel R003 --as "$Bn" >/dev/null || fail cancel
  wait_for 4 run_final R005 || fail "R005 stuck behind a dead queued runner"
  assert_eq killed "$(rhdr R004 Status)"
  assert_contains "$(rhdr R004 Note)" "умер в очереди"
  assert_eq done "$(rhdr R005 Status)"
  assert_eq "" "$(ls -A "$B/run/execq")"
}

# --sync: waits here and prints the result; no message afterwards. --timeout
# above wait_timeout is refused.
test_run_sync() {
  local out rc
  run_setup
  out=$(brg run --as "$A" --sync -- 'echo синхронно; exit 4')
  rc=$?
  assert_eq 4 "$rc" "exit code of the command"
  assert_contains "$out" "── R001 запущен (очередь пуста). Жду результат здесь (не дольше 3 с)…"
  assert_contains "$out" "── R001 · failed (код 4) · "
  assert_contains "$out" "  синхронно"
  assert_contains "$out" "Лог целиком: .brigada/tasks/T001/shared/runs/R001.log"
  assert_not_contains "$out" "также отправлен"
  assert_eq "── NEXT: продолжай; закончив шаг — bash $BRG wait --as $A" "$(printf '%s\n' "$out" | tail -n 1)"
  assert_eq sync "$(rhdr R001 Mode)"
  assert_eq 3 "$(rhdr R001 Timeout)" "default: the wait timeout"
  assert_contains "$(brg wait --as "$A" --timeout 1)" "── нет новых" "no message after a sync result"
  assert_file_not_exists "$D/shared/runs/R001.sync"
  out=$(brg run --as "$A" --sync -- true)
  assert_eq 0 "$?"
  out=$(brg run --as "$A" --sync --timeout 1m -- true 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "--sync допускает --timeout не больше 3 с"
  assert_contains "$out" "убери --sync"
  # not done within the wait timeout (queue included): falls back to a message
  brg run --as "$Bn" -- 'sleep 2.5' >/dev/null || fail run
  out=$(brg run --as "$A" --sync -- 'echo после очереди; sleep 1')
  assert_contains "$out" "── R004 не завершился за 3 с (сейчас: " # queued or running, by timing
  assert_contains "$out" ") — результат придёт тебе сообщением в wait."
  out=$(brg wait --as "$A" --timeout 5)
  assert_contains "$out" "R004 · done (код 0)"
  assert_contains "$out" "    после очереди"
}

test_run_cancel() {
  local out
  run_setup
  C=$(join_as opencode gpt)
  brg run --as "$Bn" -- 'sleep 30' >/dev/null || fail run1
  brg run --as "$Bn" -- 'echo не должно' >/dev/null || fail run2
  wait_for 3 run_status_is R001 running || fail "R001 did not start"
  out=$(brg run cancel R1 --as "$C" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "отменить R001 может только его инициатор ($Bn) или lead ($A)"
  # the lead cancels a queued run: cancelled, the initiator told
  out=$(brg run cancel R2 --as "$A")
  assert_contains "$out" "── R002 · cancelled: отменён до запуска ($A)"
  assert_contains "$out" "Инициатор $Bn получит сообщение об отмене."
  # the initiator cancels its running one: killed, no message to itself
  out=$(brg run cancel R1 --as "$Bn")
  assert_contains "$out" "── R001 · killed: остановлен командой run cancel ($Bn)"
  out=$(brg wait --as "$Bn" --timeout 1)
  assert_contains "$out" "R002 · cancelled: отменён до запуска ($A)"
  assert_not_contains "$out" "R001"
  assert_eq "" "$(cat "$D/shared/runs/R002.log")" "never ran"
  out=$(brg run cancel R1 --as "$Bn" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "R001 уже завершён: killed"
  out=$(brg run show R1)
  assert_contains "$out" "── R001 · killed"
  assert_contains "$out" "Отменил: $Bn"
  assert_eq "" "$(ls -A "$B/run/execq")"
  assert_eq "" "$(ls -A "$B/run/locks")"
}

test_run_arguments_and_task_rules() {
  local out
  new_proj
  trap run_cleanup EXIT
  A=$(join_as claude)
  out=$(brg run --as "$A" -- true 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет активной задачи — run работает в задаче"
  task_new_as "$A" "Аргументы"
  D=$(tdir T001)
  out=$(brg run --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нужна команда"
  assert_contains "$out" "── NEXT:"
  out=$(brg run --as "$A" --timeout 5x -- true 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "--timeout — 90, 90s, 10m, 1h"
  out=$(brg run --as "$A" --item I7 -- true 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет подзадачи I007 в задаче T001"
  out=$(brg run -- true 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нужно имя агента"
  out=$(brg run show R9 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет прогона R009"
  # an item link; without "--" the command starts at the first non-option
  printf 'x\n' | brg item add --as "$A" --title "С прогоном" >/dev/null || fail "item add"
  out=$(brg run --as "$A" --item 1 --sync echo привязан)
  assert_contains "$out" "R001 · done (код 0)"
  assert_eq I001 "$(rhdr R001 Item)"
  assert_contains "$(brg item show I1)" "Прогоны: R001 (done, код 0)"
  out=$(brg run show R1 --as "$A")
  assert_contains "$out" "── R001 · done · код 0 · "
  assert_contains "$out" " · $A · задача T001 · подзадача I001"
  assert_contains "$out" "Команда: echo привязан · лимит 3 с · режим sync"
  assert_contains "$out" "  привязан"
  # status shows my runs in progress
  brg run --as "$A" -- 'sleep 2' >/dev/null || fail run
  assert_contains "$(brg status --as "$A")" "Мои прогоны (результат придёт сообщением): R002 · "
}

# task close refuses while the task has runs in the queue or running;
# --force stops them (the close notice lists them; no separate result messages).
test_task_close_refuses_with_runs_force_stops_them() {
  local out
  run_setup
  brg run --as "$Bn" -- 'sleep 30' >/dev/null || fail run1
  brg run --as "$A" -- 'echo never' >/dev/null || fail run2
  wait_for 3 run_status_is R001 running || fail "R001 did not start"
  printf 'итог\n' >"$D/summary.md"
  out=$(brg task close --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "прогоны задачи ещё идут: R001 ($Bn, running: sleep 30), R002 ($A, queued: echo never)"
  assert_contains "$out" "task close --as $A --force"
  assert_eq active "$(hdr "$D/task" Status)"
  out=$(brg task close --as "$A" --force)
  assert_contains "$out" "── задача T001 «Прогоны» закрыта."
  assert_contains "$out" "Прогоны задачи остановлены: R001 — killed, R002 — cancelled"
  assert_eq killed "$(rhdr R001 Status)"
  assert_eq "$A" "$(rhdr R001 By)"
  assert_eq "при закрытии задачи T001 (--force)" "$(rhdr R001 How)"
  assert_eq cancelled "$(rhdr R002 Status)"
  assert_eq "" "$(cat "$D/shared/runs/R002.log")" "never ran"
  wait_for 3 is_dead "$(rhdr R001 Runner)" || fail "runner alive"
  kill -0 -- -"$(rhdr R001 Pgid)" 2>/dev/null && fail "command alive"
  out=$(brg wait --as "$Bn" --timeout 2)
  assert_contains "$out" "Закрыта с --force: прогоны остановлены — R001 ($Bn, running: sleep 30), R002 ($A, queued: echo never)."
  assert_not_contains "$out" "R001 · killed"
  assert_contains "$(brg run show R1)" "Отменил: $A (при закрытии задачи T001 (--force))"
  # without runs in progress close just works; a finished run does not count
  task_new_as "$A" "Вторая"
  D=$(tdir T002)
  brg run --as "$A" --sync -- true >/dev/null || fail run3
  printf 'итог\n' >"$D/summary.md"
  brg task close --as "$A" >/dev/null || fail "close with a finished run"
}

# task cancel (and new --cancel-current) stops the task's runs the way
# run cancel does.
test_task_cancel_stops_runs() {
  local out
  run_setup
  brg run --as "$Bn" -- 'sleep 30' >/dev/null || fail run1
  brg run --as "$Bn" -- 'echo never' >/dev/null || fail run2
  wait_for 3 run_status_is R001 running || fail "R001 did not start"
  out=$(brg task cancel --as human)
  assert_contains "$out" "── задача T001 «Прогоны» отменена"
  assert_contains "$out" "Прогоны задачи остановлены: R001 — killed, R002 — cancelled"
  assert_eq human "$(rhdr R001 By)"
  assert_eq "при отмене задачи T001" "$(rhdr R001 How)"
  assert_eq cancelled "$(rhdr R002 Status)"
  kill -0 -- -"$(rhdr R001 Pgid)" 2>/dev/null && fail "command alive"
  out=$(brg wait --as "$Bn" --timeout 2)
  assert_contains "$out" "Прогоны задачи остановлены: R001 ($Bn, running: sleep 30), R002 ($Bn, queued: echo never)."
  assert_not_contains "$out" "R002 · cancelled"
  assert_eq "" "$(ls -A "$B/run/execq")"
  # --cancel-current
  task_new_as "$A" "Вторая"
  D=$(tdir T002)
  brg run --as "$A" -- 'sleep 30' >/dev/null || fail run3
  wait_for 3 run_status_is R003 running || fail "R003 did not start"
  out=$(printf 'новая\n' | brg task new --as "$A" --title "Третья" --cancel-current)
  assert_contains "$out" "── задача T002 отменена"
  assert_contains "$out" "Прогоны задачи остановлены: R003 — killed"
  assert_eq "при отмене задачи T002" "$(rhdr R003 How)"
  assert_eq killed "$(rhdr R003 Status)"
}

# The result of a run whose task was closed meanwhile goes to lobby (README): the
# notification path itself, driven directly (close refuses or stops runs, so this
# happens only in races).
test_run_result_after_task_closed_goes_to_lobby() {
  local out
  run_setup
  brg run --as "$Bn" --sync -- 'echo поздно' >/dev/null
  wait_for 3 is_dead "$(rhdr R001 Runner)" || fail "runner alive" # it may still be delivering
  rm -f "$D/shared/runs/R001.notified"
  printf 'итог\n' >"$D/summary.md"
  brg task close --as "$A" >/dev/null || fail close
  brg wait --as "$Bn" --timeout 0 >/dev/null # "closed"
  BRG_SOURCE_ONLY=1 bash -c '. "$1"; cfg_load; run_notify "$2"' _ "$BRG" "$D/shared/runs/R001" || fail notify
  out=$(brg wait --as "$Bn" --timeout 2)
  assert_contains "$out" "── lobby · 1 новое"
  assert_contains "$out" "R001 · done (код 0)"
  assert_contains "$out" "задача T001 уже завершена"
}

# ── liveness in a sandbox (DESIGN §4.2, §7.3): EPERM means alive; a dead pid
# means dead only once the heartbeat is silent for runner_dead_grace ──────────

# pid_alive: EPERM (pid 1 of a non-root user on Darwin/Linux) is alive, a reaped
# child and 0 are dead, the test hook makes any listed pid answer EPERM.
test_pid_alive() {
  local out c
  new_proj
  c=$(dead_pid)
  out=$(BRG_SOURCE_ONLY=1 bash -c '
    . "$1"
    t() { pid_alive "$2"; echo "$1=$?:$PA_WHY"; }
    t self "$$"
    t child "$2"
    t zero 0
    t zeros 00
    t word x
    t empty ""
    BRG_TEST_EPERM_PIDS="7 $2"
    t hook "$2"
    BRG_TEST_EPERM_PIDS="*"
    t star "$2"
    t star0 0' _ "$BRG" "$c")
  assert_eq "self=0:alive
child=1:dead
zero=1:dead
zeros=1:dead
word=1:dead
empty=1:dead
hook=0:eperm
star=0:eperm
star0=1:dead" "$out" "pid_alive verdicts"
  case $(uname -s) in Darwin | Linux) ;; *) return 0 ;; esac
  [ "${EUID:-0}" != 0 ] || return 0 # root may signal pid 1
  out=$(BRG_SOURCE_ONLY=1 bash -c '. "$1"; pid_alive 1; echo "$?:$PA_WHY"' _ "$BRG")
  assert_eq "0:eperm" "$out" "pid 1 (EPERM, parsed from the kill error)"
}

# The exec lock and a queue entry of a runner out of reach (EPERM, via the test
# hook on a dead pid): kept while their heartbeat is fresh, though the pid "is
# dead" for kill and the lock is older than lock_stale; judged silent (why=hb)
# once the heartbeat stops.
test_exec_lock_and_queue_of_eperm_runner_kept_while_beating() {
  local dp
  run_setup
  printf 'runner_stale: 3\n' >>"$B/config"
  dp=$(dead_pid)
  export BRG_TEST_EPERM_PIDS=$dp
  mkdir "$B/run/locks/exec.lock"
  printf '%s %s\n' "$dp" $(($(date -u +%s) - 1000)) >"$B/run/locks/exec.lock/owner"
  printf 'R077 %s\n' "${D##*/}" >"$B/run/locks/exec.lock/run"
  hb_loop "$B/run/locks/exec.lock/hb" "$dp"
  brg run --as "$Bn" -- 'echo пошло' >/dev/null || fail run1
  sleep 5 # > lock_stale and runner_stale (3 s)
  assert_eq queued "$(rhdr R001 Status)" "the exec lock of a live (EPERM) runner was broken"
  assert_eq "$dp" "$(awk '{ print $1 }' "$B/run/locks/exec.lock/owner")" "exec lock owner"
  assert_contains "$(brg run list)" "R001 · queued"
  kill -KILL $HBP
  wait_for 8 run_final R001 || fail "not broken after the heartbeat stopped"
  assert_eq done "$(rhdr R001 Status)"
  assert_contains "$(metrics_of "$Bn" lock.break)" "why=hb"
  assert_not_contains "$(metrics_of "$Bn" lock.break)" "why=dead"
  # a queue entry
  mkdir -p "$B/run/execq"
  hb_loop "$B/run/execq/000000" "$dp R000 ${D##*/}"
  brg run --as "$Bn" -- 'echo второй' >/dev/null || fail run2
  sleep 5
  assert_eq queued "$(rhdr R002 Status)" "a beating EPERM entry was dropped"
  assert_file_exists "$B/run/execq/000000"
  kill -KILL $HBP
  wait_for 8 run_final R002 || fail "not dropped after the heartbeat stopped"
  assert_eq done "$(rhdr R002 Status)"
  assert_contains "$(metrics_of "$Bn" execq.drop)" "run=R000 pid=$dp why=hb"
}

# runner_dead_grace > 0: a dead pid (a pid namespace may hide a live runner) whose
# heartbeat is fresh keeps its exec lock and its run; once the heartbeat is older
# than the grace the lock is broken (why=dead) and views settle the run (killed).
# Out of reach (EPERM) it stays alive for the views.
test_dead_runner_pid_waits_for_silent_heartbeat() {
  local dp t0 t1 r g out
  run_setup
  printf 'runner_dead_grace: 3\n' >>"$B/config"
  dp=$(dead_pid)
  mkdir "$B/run/locks/exec.lock"
  printf '%s %s\n' "$dp" $(($(date -u +%s) - 1000)) >"$B/run/locks/exec.lock/owner"
  printf 'R077 %s\n' "${D##*/}" >"$B/run/locks/exec.lock/run"
  hb_loop "$B/run/locks/exec.lock/hb" "$dp"
  brg run --as "$Bn" -- 'echo пошло' >/dev/null || fail run1
  sleep 4.5 # > grace and lock_stale (3 s)
  assert_eq queued "$(rhdr R001 Status)" "broken while the heartbeat was fresh"
  kill -KILL $HBP
  t0=$(date -u +%s)
  wait_for 8 run_final R001 || fail "not broken after the heartbeat stopped"
  t1=$(date -u +%s)
  [ $((t1 - t0)) -ge 2 ] || fail "broken after $((t1 - t0)) s, before runner_dead_grace"
  assert_eq done "$(rhdr R001 Status)"
  assert_contains "$(metrics_of "$Bn" lock.break)" "why=dead"
  # views: a runner killed while its heartbeat (kept by hb_loop) is fresh
  brg run --as "$Bn" -- 'sleep 30' >/dev/null || fail run2
  wait_for 3 run_status_is R002 running || fail "R002 did not start"
  r=$(rhdr R002 Runner)
  g=$(rhdr R002 Pgid)
  hb_loop "$B/run/locks/exec.lock/hb" "$r"
  kill -KILL "$r"
  wait_for 2 is_dead "$r"
  out=$(brg run show R2)
  assert_contains "$out" "── R002 · running"
  assert_not_contains "$out" "ВНИМАНИЕ"
  assert_contains "$(brg run list)" "R002 · running"
  kill -KILL $HBP
  sleep 3.5
  out=$(BRG_TEST_EPERM_PIDS=$r brg run show R2)
  assert_contains "$out" "── R002 · running" "an EPERM runner settled by a view"
  out=$(brg run show R2)
  assert_contains "$out" "── R002 · killed"
  assert_contains "$out" "раннер (pid $r) умер во время выполнения"
  kill -KILL -- -"$g" 2>/dev/null
  rm -rf "$B/run/locks/exec.lock"
}

# The watching runner judges a dead pid only after watching without a gap for
# runner_dead_grace: a gap (sleep of the machine, SIGSTOP) — even one too short to
# matter for runner_stale — restarts the count, since every heartbeat looks old
# after it. If gaps keep coming, the runner_stale verdict still applies. One-shot
# checks need only the old heartbeat. Driven directly (BRG_SOURCE_ONLY).
test_dead_verdict_needs_continuous_watch() {
  local dp now out
  new_proj
  dp=$(dead_pid)
  now=$(date -u +%s)
  mkdir -p "$B/run/locks/exec.lock" "$B/run/execq"
  printf '%s %s\n' "$dp" $((now - 100)) >"$B/run/locks/exec.lock/owner"
  printf '%s %s\n' "$dp" $((now - 20)) >"$B/run/locks/exec.lock/hb"
  printf '%s R000 T001 %s\n' "$dp" $((now - 20)) >"$B/run/execq/000000"
  out=$(BRG_SOURCE_ONLY=1 bash -c '
    . "$1"
    cfg_load
    RUNNER_DEAD_GRACE=5
    check() { # LABEL — exec lock and queue verdicts
      local s=
      lock_stale_check "$LOCKS/exec.lock" 1 s noage && echo "$1 lock:stale:$LS_WHY" || echo "$1 lock:held"
      execq_scan
      echo "$1 queue:$EQ_N"
    }
    get_now
    HB_OBS=$((NOW - 2)) HB_OBS_D=$((NOW - 2)) HB_LAST=$((NOW - 1))
    check short
    HB_OBS=$((NOW - 30)) HB_OBS_D=$((NOW - 30)) HB_LAST=$((NOW - 3)) # a 3 s gap
    hb_obs_tick
    check gap
    HB_OBS=$((NOW - 30)) HB_OBS_D=$((NOW - 30)) HB_LAST=$NOW
    hb_obs_tick
    check long
    HB_OBS= HB_OBS_D= # a one-shot check
    check oneshot' _ "$BRG")
  assert_contains "$out" "short lock:held"
  assert_contains "$out" "short queue:1"
  assert_contains "$out" "gap lock:held"
  assert_contains "$out" "gap queue:1"
  assert_contains "$out" "long lock:stale:dead"
  assert_contains "$out" "long queue:0" # dropped
  assert_contains "$out" "oneshot lock:stale:dead"
  assert_file_not_exists "$B/run/execq/000000"
  # gaps keep restarting the count, but the heartbeat is older than runner_stale
  printf '%s R000 T001 %s\n' "$dp" $((now - 20)) >"$B/run/execq/000000"
  out=$(BRG_SOURCE_ONLY=1 bash -c '
    . "$1"
    cfg_load
    RUNNER_DEAD_GRACE=5 RUNNER_STALE=10
    get_now
    HB_OBS=$((NOW - 30)) HB_OBS_D=$((NOW - 1)) HB_LAST=$NOW
    hb_obs_tick
    s=
    lock_stale_check "$LOCKS/exec.lock" 1 s noage && echo "lock:stale:$LS_WHY" || echo "lock:held"
    execq_scan
    echo "queue:$EQ_N"' _ "$BRG")
  assert_eq "lock:stale:dead
queue:0" "$out" "runner_stale verdict for a dead pid"
  assert_contains "$(cat "$B/run/metrics.log")" "execq.drop run=R000 pid=$dp why=dead"
  # one-shot, fresh heartbeat: alive
  printf '%s R000 T001 %s\n' "$dp" "$(date -u +%s)" >"$B/run/execq/000000"
  printf '%s %s\n' "$dp" "$(date -u +%s)" >"$B/run/locks/exec.lock/hb"
  out=$(BRG_SOURCE_ONLY=1 bash -c '
    . "$1"
    cfg_load
    RUNNER_DEAD_GRACE=5
    s=
    lock_stale_check "$LOCKS/exec.lock" 1 s noage && echo "lock:stale" || echo "lock:held"
    execq_scan
    echo "queue:$EQ_N"' _ "$BRG")
  assert_eq "lock:held
queue:1" "$out" "a one-shot check with a fresh heartbeat"
}
