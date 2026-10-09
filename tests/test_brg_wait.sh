# brg wait: delivery, addressing, at-least-once, takeover, signals, orphans, stop, cap.

. "$TESTS_DIR/brg_lib.sh"

# two agents with an empty inbox: A, Bn
two_agents() {
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  ack_all "$A" # join notices are quiet (Wake: no): mark them handled
}

test_wait_timeout() {
  local out t0 t1
  two_agents
  t0=$(date -u +%s)
  out=$(brg wait --as "$A" --timeout 1)
  assert_eq 0 "$?" "exit code"
  t1=$(date -u +%s)
  assert_eq "── нет новых (1 с) · ход не завершай · NEXT: bash $BRG wait --as $A --timeout 1" "$out"
  [ $((t1 - t0)) -ge 1 ] || fail "returned before timeout"
  [ $((t1 - t0)) -le 3 ] || fail "timeout overshoot: $((t1 - t0)) s"
  # default timeout comes from config by harness (codex: 2)
  out=$(brg wait --as "$Bn")
  assert_eq "── нет новых (2 с) · ход не завершай · NEXT: bash $BRG wait --as $Bn" "$out"
  assert_file_not_exists "$B/run/wait/${A%%.*}.pid" "pid file released"
  assert_file_not_exists "$B/run/wait/${A%%.*}.hb" "hb file released"
  assert_contains "$(metrics_of "$A" wait.start)" "timeout=1 pid="
  assert_contains "$(metrics_of "$A" wait)" "result=timeout delivered=0 timeout=1"
}

test_delivery_addressing() {
  local c out
  two_agents
  c=$(join_as opencode)
  ack_all "$A"
  ack_all "$Bn"
  send_as "$A" "всем от A"
  send_as "$A" "лично Bn" --to "${Bn%%.*}"
  send_as "$A" "лично c" --to "${c%%.*}"
  send_as "$A" "человеку" --to human
  send_as "$c" "ответ A" --to "${A%%.*},${Bn%%.*}" --re 4
  out=$(brg wait --as "$Bn")
  assert_contains "$out" "── lobby · 3 новых ───"
  assert_contains "$out" "#4 ${A%%.*} → all · "
  assert_contains "$out" "  всем от A"
  assert_contains "$out" "#5 ${A%%.*} → ${Bn%%.*} · "
  assert_contains "$out" "#8 ${c%%.*} → ${A%%.*},${Bn%%.*} · re #4 · "
  assert_not_contains "$out" "лично c"
  assert_not_contains "$out" "человеку"
  assert_eq "── NEXT: обработай, затем: bash $BRG wait --as $Bn" "$(printf '%s\n' "$out" | tail -n 1)"
  out=$(brg wait --as "$A" --timeout 1)
  assert_contains "$out" "── lobby · 1 новое ───"
  assert_contains "$out" "#8 ${c%%.*} → ${A%%.*},${Bn%%.*}"
  assert_not_contains "$out" "всем от A" # own messages are not delivered
  # a third party only gets what is meant for it; the rest is acknowledged silently
  out=$(brg wait --as "$c" --timeout 1)
  assert_contains "$out" "лично c"
  assert_not_contains "$out" "лично Bn"
  assert_not_contains "$out" "человеку"
  out=$(brg wait --as "$c" --timeout 0)
  assert_contains "$out" "── нет новых (0 с)"
  assert_eq "8/8" "$(cursor "$c")"
}

# DESIGN §5.3: issued → Pending; acknowledged only by the next wait.
test_at_least_once_acked_pending() {
  local out
  two_agents
  send_as "$Bn" "раз"
  send_as "$Bn" "два"
  assert_eq "2/2" "$(cursor "$A")"
  out=$(brg wait --as "$A")
  assert_contains "$out" "  раз"
  assert_contains "$out" "  два"
  assert_eq "2/4" "$(cursor "$A")" "issued, not yet acknowledged"
  assert_contains "$(brg read --as "$A")" "  два" # the batch can be re-read
  send_as "$Bn" "три"
  out=$(brg wait --as "$A")
  assert_contains "$out" "  три"
  assert_not_contains "$out" "  раз"
  assert_eq "4/5" "$(cursor "$A")" "previous batch acknowledged by the next wait"
  out=$(brg wait --as "$A" --timeout 0)
  assert_contains "$out" "── нет новых"
  assert_eq "5/5" "$(cursor "$A")"
}

# Killed before printing → the messages come again.
test_kill_before_output_redelivers() {
  local out
  two_agents
  start_wait "$A" "$P/w1" --timeout 20
  kill -STOP $WP
  send_as "$Bn" "важное"
  kill -KILL $WP
  kill -CONT $WP 2>/dev/null
  wait $WP 2>/dev/null
  assert_eq "" "$(cat "$P/w1")" "nothing printed"
  assert_eq "2/2" "$(cursor "$A")" "nothing issued"
  assert_file_exists "$B/run/wait/${A%%.*}.pid" "stale pid file after KILL"
  out=$(brg wait --as "$A" --timeout 2)
  assert_contains "$out" "  важное"
  assert_contains "$(metrics_of "$A" wait.start)" "pid=$WP" # killed one has a start line only
}

# Output failed (closed stdout) → not issued → delivered again.
test_failed_output_is_not_issued() {
  local out
  two_agents
  send_as "$Bn" "не дошло"
  bash "$BRG" wait --as "$A" --timeout 2 >&- 2>/dev/null
  assert_eq "2/2" "$(cursor "$A")"
  assert_contains "$(metrics_of "$A" wait)" "result=epipe"
  out=$(brg wait --as "$A" --timeout 2)
  assert_contains "$out" "  не дошло"
}

test_message_during_wait_is_delivered_quickly() {
  local t0 t1
  two_agents
  start_wait "$A" "$P/w" --timeout 20
  t0=$(date -u +%s)
  send_as "$Bn" "пинг"
  wait_pid $WP 3 || fail "wait did not return on message"
  t1=$(date -u +%s)
  assert_contains "$(cat "$P/w")" "  пинг"
  [ $((t1 - t0)) -le 2 ] || fail "slow delivery: $((t1 - t0)) s"
}

# Takeover is signal-free: the new wait claims the pid file, the old one notices
# within a tick and prints SUPERSEDED.
test_takeover_supersedes_old_wait() {
  local p1 p2 t0 t1
  two_agents
  export BRG_TICK=0.5
  start_wait "$A" "$P/w1" --timeout 20
  p1=$WP
  t0=$(date -u +%s)
  start_wait "$A" "$P/w2" --timeout 3
  p2=$WP
  wait_pid $p1 2 || fail "old wait survived the takeover"
  t1=$(date -u +%s)
  [ $((t1 - t0)) -le 1 ] || fail "SUPERSEDED took $((t1 - t0)) s (> 2 ticks)"
  assert_eq "── SUPERSEDED: тебя заменил более новый wait. НЕ вызывай wait повторно." "$(cat "$P/w1")"
  is_alive $p2 || fail "new wait died"
  pid_is "$A" $p2 || fail "pid file must name the new wait"
  send_as "$Bn" "после takeover"
  wait_pid $p2 3 || fail "new wait did not deliver"
  assert_contains "$(cat "$P/w2")" "  после takeover"
  assert_contains "$(metrics_of "$A" wait)" "result=superseded delivered=0 timeout=20 pid=$p1"
}

# A stale pid file naming an unrelated live process: nobody signals it.
test_takeover_does_not_touch_foreign_pid() {
  local sp out
  two_agents
  sleep 30 &
  sp=$!
  track_pid $sp
  printf '%s\n' $sp >"$B/run/wait/${A%%.*}.pid"
  printf '%s %s\n' $sp "$(date -u +%s)" >"$B/run/wait/${A%%.*}.hb" # even a fresh heartbeat
  out=$(brg wait --as "$A" --timeout 1)
  assert_contains "$out" "── нет новых (1 с)"
  is_alive $sp || fail "an unrelated process was signalled"
}

# Signals come from the harness/human: "прерван" + NEXT, not SUPERSEDED.
test_signals_mean_interrupted() {
  local p
  two_agents
  start_wait "$A" "$P/w" --timeout 20
  kill -TERM $WP
  wait_pid $WP 3 || fail "wait ignored TERM"
  assert_eq "── прерван сигналом TERM · NEXT: bash $BRG wait --as $A --timeout 20" "$(cat "$P/w")"
  assert_contains "$(metrics_of "$A" wait)" "result=term"
  start_wait "$A" "$P/w" --timeout 20
  kill -HUP $WP
  wait_pid $WP 3 || fail "wait ignored HUP"
  assert_eq "── прерван сигналом HUP · NEXT: bash $BRG wait --as $A --timeout 20" "$(cat "$P/w")"
  # INT: start with job control (async jobs of a non-interactive shell ignore INT)
  set -m
  bash "$BRG" wait --as "$A" --timeout 20 >"$P/w" 2>&1 &
  p=$!
  set +m
  track_pid "$p"
  wait_for 3 pid_is "$A" "$p" || fail "wait did not start"
  kill -INT "$p"
  wait_for 3 is_dead "$p" || fail "wait ignored INT"
  assert_eq "── прерван сигналом INT · NEXT: bash $BRG wait --as $A --timeout 20" "$(cat "$P/w")"
  # a signal to a wait that was already replaced: it is superseded, do not call again
  export BRG_TICK=5
  start_wait "$A" "$P/w1" --timeout 20
  p=$WP
  start_wait "$A" "$P/w2" --timeout 20
  kill -TERM $p
  wait_pid $p 3 || fail "old wait ignored TERM"
  assert_contains "$(cat "$P/w1")" "── SUPERSEDED"
  kill -TERM $WP
  wait_pid $WP 3 || fail "new wait ignored TERM"
}

test_exits_when_parent_dies() {
  local pp cp
  two_agents
  bash -c 'bash "$1" wait --as "$2" --timeout 30 >"$3" 2>&1 & echo $! >"$4"; wait' \
    _ "$BRG" "$A" "$P/out" "$P/child.pid" &
  pp=$!
  track_pid $pp
  wait_for 3 test -s "$P/child.pid" || fail "child not started"
  cp=$(cat "$P/child.pid")
  track_pid "$cp"
  wait_for 3 pid_is "$A" "$cp" || fail "wait did not start"
  kill -KILL $pp
  wait $pp 2>/dev/null
  wait_for 3 is_dead "$cp" || fail "orphaned wait still alive"
  assert_contains "$(metrics_of "$A" wait.start)" "ppid=$pp"
  assert_contains "$(metrics_of "$A" wait)" "result=orphan"
  assert_file_not_exists "$B/run/wait/${A%%.*}.pid"
}

# A parent out of reach (EPERM: a sandbox; via the test hook) counts as alive: no
# false orphan — the wait keeps going and ends by its timeout with NEXT:.
test_parent_out_of_reach_is_not_orphan() {
  local pp cp out
  two_agents
  bash -c 'BRG_TEST_EPERM_PIDS=$$ bash "$1" wait --as "$2" --timeout 3 >"$3" 2>&1 & echo $! >"$4"; wait' \
    _ "$BRG" "$A" "$P/out" "$P/child.pid" &
  pp=$!
  track_pid $pp
  wait_for 3 test -s "$P/child.pid" || fail "child not started"
  cp=$(cat "$P/child.pid")
  track_pid "$cp"
  wait_for 3 pid_is "$A" "$cp" || fail "wait did not start"
  kill -KILL $pp
  wait $pp 2>/dev/null
  sleep 1
  is_alive "$cp" || fail "a parent out of reach taken for dead"
  wait_for 5 is_dead "$cp" || fail "wait did not end by its timeout"
  out=$(cat "$P/out")
  assert_contains "$out" "── нет новых (3 с)"
  assert_eq "── нет новых (3 с) · ход не завершай · NEXT: bash $BRG wait --as $A --timeout 3" "$(printf '%s\n' "$out" | tail -n 1)"
  assert_contains "$(metrics_of "$A" wait)" "result=timeout"
  assert_not_contains "$(metrics_of "$A" wait)" "result=orphan"
}

test_stop_and_resume() {
  local out t0 t1
  two_agents
  out=$(brg stop)
  assert_contains "$out" "── STOP: все wait вернут STOP"
  assert_file_exists "$B/run/stopped"
  send_as "$Bn" "почта при стопе"
  t0=$(date -u +%s)
  out=$(brg wait --as "$A" --timeout 10)
  t1=$(date -u +%s)
  assert_eq "── STOP: человек остановил бригаду. Заверши ход." "$out"
  [ $((t1 - t0)) -le 1 ] || fail "STOP was not immediate"
  assert_eq "2/2" "$(cursor "$A")" "STOP issues nothing"
  out=$(brg resume)
  assert_contains "$out" "── стоп снят."
  assert_file_not_exists "$B/run/stopped"
  out=$(brg wait --as "$A" --timeout 2)
  assert_contains "$out" "  почта при стопе"
  brg wait --as "$A" --timeout 0 >/dev/null
  # per-agent stop reaches a running wait within a tick, without signals
  start_wait "$Bn" "$P/wb" --timeout 20
  start_wait "$A" "$P/wa" --timeout 20
  out=$(brg stop "${A%%.*}")
  assert_contains "$out" "── STOP для ${A%%.*}"
  wait_pid $WP 2 || fail "running wait ignored the stop flag"
  assert_eq "── STOP: человек остановил тебя (${A%%.*}). Заверши ход." "$(cat "$P/wa")"
  pid_is "$Bn" "$(cat "$B/run/wait/${Bn%%.*}.pid")" && is_alive "$(cat "$B/run/wait/${Bn%%.*}.pid")" || fail "other agent's wait stopped too"
  assert_contains "$(brg wait --as "$A" --timeout 5)" "── STOP: человек остановил тебя"
  brg resume "${A%%.*}" >/dev/null
  assert_contains "$(brg wait --as "$A" --timeout 0)" "── нет новых"
  out=$(brg stop nobody 2>&1)
  assert_eq 1 "$?"
  # global stop reaches running waits; say lifts it
  brg stop >/dev/null
  wait_for 3 test -s "$P/wb" || fail "B's wait ignored global stop"
  assert_eq "── STOP: человек остановил бригаду. Заверши ход." "$(cat "$P/wb")"
  brg say "продолжаем" >/dev/null
  assert_contains "$(brg wait --as "$A" --timeout 2)" "  продолжаем"
  assert_contains "$(awk '$3 == "stop"' "$B/run/metrics.log")" "target=${A%%.*}"
}

# Output is capped; the rest stays unissued and comes with the next wait at once.
test_output_cap() {
  local i out t0 t1
  two_agents
  printf 'wait_output_max: 500\n' >>"$B/config"
  i=1
  while [ $i -le 8 ]; do
    send_as "$Bn" "сообщение номер $i: $(awk 'BEGIN { for (i = 0; i < 60; i++) printf "x" }')"
    i=$((i + 1))
  done
  out=$(brg wait --as "$A")
  assert_contains "$out" "  сообщение номер 1:"
  first=$out
  assert_not_contains "$out" "сообщение номер 8:"
  assert_contains "$out" "в lobby не вошло (лимит вывода): придут следующим wait сразу; посмотреть: bash $BRG read --as $A --since "
  n=$(printf '%s\n' "$out" | LC_ALL=C awk '/^#[0-9]+ / || /^  / { n += length($0) + 1 } END { print n + 0 }')
  [ "$n" -le 500 ] || fail "messages not capped: $n bytes"
  assert_eq "── NEXT: обработай, затем: bash $BRG wait --as $A" "$(printf '%s\n' "$out" | tail -n 1)"
  last=$(printf '%s\n' "$out" | awk '/^#[0-9]+ / { n = substr($1, 2) } END { print n }')
  assert_eq "2/$last" "$(cursor "$A")" "Pending = last shown"
  t0=$(date -u +%s)
  out=$(brg wait --as "$A")
  t1=$(date -u +%s)
  [ $((t1 - t0)) -le 1 ] || fail "the rest did not come at once"
  assert_contains "$out" "#$((last + 1)) "
  all="$first
$out"
  i=1
  while [ $i -lt 5 ]; do
    case $all in *"сообщение номер 8:"*) break ;; esac
    out=$(brg wait --as "$A" --timeout 1)
    all="$all
$out"
    i=$((i + 1))
  done
  i=1
  while [ $i -le 8 ]; do
    assert_eq 1 "$(printf '%s\n' "$all" | awk -v s="  сообщение номер $i:" 'index($0, s) == 1' | wc -l | tr -d ' ')" "message $i exactly once"
    i=$((i + 1))
  done
  # a single message bigger than the cap is still shown
  printf 'wait_output_max: 10\n' >>"$B/config"
  brg wait --as "$A" --timeout 0 >/dev/null # ack the last batch
  send_as "$Bn" "одно большое сообщение"
  assert_contains "$(brg wait --as "$A" --timeout 1)" "одно большое сообщение"
}

test_heartbeat_and_liveness_files() {
  local s0 s1
  two_agents
  printf '%s\n' 1000 >"$B/run/seen/${A%%.*}"
  start_wait "$A" "$P/w" --timeout 4
  wait_for 3 test -f "$B/run/wait/${A%%.*}.hb" || fail "no hb file"
  assert_eq "$WP" "$(awk '{ print $1 }' "$B/run/wait/${A%%.*}.hb")"
  s0=$(cat "$B/run/seen/${A%%.*}")
  [ "$s0" -gt 1000 ] || fail "wait start did not update Last-Seen"
  sleep 2.2
  s1=$(cat "$B/run/seen/${A%%.*}")
  [ "$s1" -gt "$s0" ] || fail "heartbeat did not update Last-Seen ($s0 → $s1)"
  assert_contains "$(brg who)" "${A%%.*} · claude · m · waiting"
  wait_pid $WP 6 || fail "wait hung"
  assert_file_not_exists "$B/run/wait/${A%%.*}.hb"
  assert_contains "$(brg who)" "${A%%.*} · claude · m · working"
}

test_wait_argument_errors_print_next() {
  local out
  two_agents
  out=$(brg wait --as "$A" --timeout soon)
  assert_eq 0 "$?" "wait always exits 0"
  assert_contains "$out" "── ОШИБКА: --timeout — целое число секунд: soon"
  assert_eq "── NEXT: bash $BRG wait --as $A" "$(printf '%s\n' "$out" | tail -n 1)"
  out=$(brg wait --as "$A" --frob)
  assert_eq "── NEXT: bash $BRG wait --as $A" "$(printf '%s\n' "$out" | tail -n 1)"
  out=$(brg wait --as "$A" --timeout)
  assert_contains "$out" "--timeout требует значение"
  assert_eq "── NEXT: bash $BRG wait --as $A" "$(printf '%s\n' "$out" | tail -n 1)"
  out=$(brg wait)
  assert_contains "$out" "нужно имя агента"
  assert_eq "── NEXT: bash $BRG wait --as <имя>" "$(printf '%s\n' "$out" | tail -n 1)"
  out=$(BRG_AS=$A bash "$BRG" wait --timeout 0)
  assert_contains "$out" "── нет новых (0 с)"
  out=$(brg wait --as ghost-7)
  assert_contains "$out" "неизвестный агент: ghost-7"
  assert_eq "── NEXT: bash $BRG join --harness <харнесс> --model <модель>" "$(printf '%s\n' "$out" | tail -n 1)"
}

test_leave_during_wait() {
  two_agents
  start_wait "$A" "$P/w" --timeout 20
  brg leave --as "$A" >/dev/null
  wait_pid $WP 2 || fail "wait of a left agent kept running"
  assert_eq "── LEFT: агент ${A%%.*} отключён (brg leave). Заверши ход." "$(cat "$P/w")"
}

# Quiet system notices (Wake: no — join/leave) do not wake a wait; they come
# with the next waking batch. Task events and ordinary messages wake.
test_quiet_join_does_not_wake() {
  local pa pb c out
  two_agents
  ack_all "$Bn"
  export BRG_TICK=0.2
  start_wait "$A" "$P/wa" --timeout 20
  pa=$WP
  start_wait "$Bn" "$P/wb" --timeout 20
  pb=$WP
  c=$(join_as opencode)
  assert_eq no "$(hdr "$(msg_file 3)" Wake)"
  sleep 1
  is_alive $pa || fail "A's wait woke up on a join: $(cat "$P/wa")"
  is_alive $pb || fail "B's wait woke up on a join: $(cat "$P/wb")"
  assert_eq "" "$(cat "$P/wa" "$P/wb")"
  assert_contains "$(brg status --as "$A")" "lobby: новых для тебя 1 (из них тихих 1"
  send_as "$c" "привет, я новенький"
  wait_pid $pa 3 || fail "A's wait did not return on a message"
  wait_pid $pb 3 || fail "B's wait did not return on a message"
  for out in "$(cat "$P/wa")" "$(cat "$P/wb")"; do
    assert_contains "$out" "── lobby · 2 новых"
    assert_contains "$out" "#3 [система] ${c%%.*} → all"
    assert_contains "$out" "${c%%.*} подключился (opencode, m, "
    assert_contains "$out" "#4 ${c%%.*} → all"
  done
  assert_eq "2/4" "$(cursor "$A")"
  # nothing for me at all (a private message to someone else) is acknowledged at once
  send_as "$c" "только B" --to "${Bn%%.*}"
  assert_contains "$(brg wait --as "$A" --timeout 1)" "── нет новых"
  assert_eq "5/5" "$(cursor "$A")"
}

# Rehearsal fixes: on a timeout ("нет новых") with an active task, wait prints one
# line of its state before NEXT — the lead does not have to poll who / item list.
test_timeout_digest_of_the_task() {
  local out d c
  two_agents
  c=$(join_as opencode)
  out=$(brg wait --as "$A" --timeout 0)
  assert_eq "── нет новых (0 с) · ход не завершай · NEXT: bash $BRG wait --as $A --timeout 0" "$out" "no task: no digest"
  task_new_as "$A" "Сводка"
  d=$(tdir T001)
  ack_all "$A"
  ack_all "$A" "$d"
  out=$(brg wait --as "$A" --timeout 0)
  assert_eq "T001: подзадач пока нет
── нет новых (0 с) · ход не завершай · NEXT: bash $BRG wait --as $A --timeout 0" "$out"
  for x in "Первая" "Вторая" "Третья" "Четвёртая" "Пятая"; do
    printf 'd\n' | brg item add --as "$A" --title "$x" >/dev/null || fail "item add $x"
  done
  brg item claim I2 --as "$Bn" --paths src/b >/dev/null || fail claim2
  brg item claim I3 --as "$c" --paths src/c >/dev/null || fail claim3
  brg item claim I4 --as "$c" --paths none >/dev/null || fail claim4
  brg item claim I5 --as "$Bn" --paths src/e >/dev/null || fail claim5
  brg item done I3 --as "$c" >/dev/null || fail done3
  brg item done I4 --as "$c" >/dev/null || fail done4
  brg item done I5 --as "$Bn" >/dev/null || fail done5
  brg item review I5 --as "$A" --verdict ok --comment ок >/dev/null || fail review5
  mkdir -p "$d/shared/runs"
  printf 'Id: R001\nStatus: running\n\n' >"$d/shared/runs/R001"
  printf 'Id: R002\nStatus: done\n\n' >"$d/shared/runs/R002"
  printf 'x\n' >"$d/shared/runs/R001.log"
  ack_all "$A"
  ack_all "$A" "$d"
  out=$(brg wait --as "$A" --timeout 0)
  # stages (DESIGN §7.1.1): handed in without a review — on review, "--paths none" too
  assert_eq "T001: todo 1 · в работе I002 ${Bn%%.*} · на проверке I003, I004 · готово I005 · прогонов идёт 1
── нет новых (0 с) · ход не завершай · NEXT: bash $BRG wait --as $A --timeout 0" "$out"
  # every stage: a reviewer marked (names in parens), changes → правки, --no-review → готово
  brg item review I3 --as "$A" --start >/dev/null || fail start3
  brg item review I3 --as "$Bn" --start >/dev/null || fail start3b
  brg item review I4 --as "$Bn" --verdict changes --comment "поправь" >/dev/null || fail review4
  printf 'd\n' | brg item add --as "$A" --title "Шестая" --no-review >/dev/null || fail "item add 6"
  brg item claim I6 --as "$Bn" --paths none >/dev/null || fail claim6
  brg item done I6 --as "$Bn" >/dev/null || fail done6
  ack_all "$A"
  ack_all "$A" "$d"
  out=$(brg wait --as "$A" --timeout 0)
  assert_eq "T001: todo 1 · в работе I002 ${Bn%%.*} · на проверке I003 (${A%%.*}, ${Bn%%.*}) · правки I004 ${c%%.*} · готово I005, I006 · прогонов идёт 1
── нет новых (0 с) · ход не завершай · NEXT: bash $BRG wait --as $A --timeout 0" "$out"
  # delivered messages: no digest
  send_as "$Bn" "есть новости"
  out=$(brg wait --as "$A" --timeout 1)
  assert_contains "$out" "  есть новости"
  assert_not_contains "$out" "T001: todo"
}
