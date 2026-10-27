# Agents launched by brg (DESIGN §5.5): brg spawn, the supervisor and its wait (HOLD, FORCE,
# ROLLBACK, flags), the turn wrapper, the rollbacks, the lock, rights, activity and tokens,
# the board. The harness is tests/fake_opencode — no LLM, no real opencode.

. "$TESTS_DIR/brg_lib.sh"
. "$TESTS_DIR/spawn_lib.sh"

NL=$'\n'

# 1. spawn: the profile, the first prompt (stdin), a turn that sends and ends → frozen;
# who; Session from the stream; tokens from export, with a child session
test_spawn_first_turn_freezes() {
  local o p k
  sp_proj
  script 1 <<'EOF'
brg send --as $ME <<<'привет от агента'
task bash .brigada/bin/brg status --as $ME
sleep 1.2
EOF
  sp_spawn --note "проверка запуска"
  assert_contains "$SPOUT" "S001 → opencode-1 (provider/model) запущен · права: full — агент может всё, что можешь ты"
  assert_eq "S001" "$(hdr "$B/agents/opencode-1" Spawn)" "Spawn: in the profile"
  wait_turn S001 1
  wait_state S001 frozen
  k=$(full opencode-1)
  p=$(cat "$FK/run.1/prompt")
  assert_contains "$p" "Твоё имя — $k, передавай его в --as"
  assert_contains "$p" "Человек: «проверка запуска»"
  assert_contains "$p" "── подключён: $k"
  o=${p#*── вывод join}
  assert_not_contains "$o" "ход не завершай" "the join output of a launched agent"
  assert_contains "$o" "── NEXT: прочитай README.md (раздел «Тебя запустил brg») и PROTOCOL.md; закончив шаг — заверши ход"
  assert_contains "$(cat "$FK/run.1/argv")" "--auto"
  wait_for 15 [ -f "$B/run/wait/opencode-1.pid" ] || fail "no supervisor's wait"
  sleep 0.3
  assert_contains "$(brg who)" "opencode-1 · opencode · provider/model · ждёт (запущен brg, S001)"
  assert_eq "$(cat "$FK/run.1/session")" "$(rec S001 Session)" "Session from the stream"
  assert_contains "$(cat "$(msg_file 2)")" "привет от агента"
  # the child session of the task tool: export of both
  wait_for 25 rec_is S001 Tokens-Source export || fail "no export: $(cat "$B/run/spawn/S001/spawn")"
  assert_eq 1 "$(rec S001 Sub-Sessions)" "Sub-Sessions"
  assert_eq $((4 * 100 + 1000)) "$(rec S001 Tokens-In)" "tokens: main (4 steps) + child"
  assert_contains "$(cat "$B/run/spawn/S001/activity.tail")" "bash: bash .brigada/bin/brg send"
  sp_assert_clean
}

# 2. a message wakes it: the prompt with the batch and «brg разбудил тебя», --session; the
# next wait acknowledges, nothing comes twice; quotes, $, backquotes, Cyrillic as they are
test_spawn_wake_with_message() {
  local t sid
  sp_proj
  script 1 <<'EOF'
sleep 1.2
EOF
  sp_spawn
  wait_turn S001 1
  wait_state S001 frozen
  sid=$(rec S001 Session)
  t='кавычки "x" '"'"'y'"'"' $HOME `uname` \n кириллица'
  brg say --to opencode-1 "$t" >/dev/null
  wait_run 2
  wait_turn S001 2
  assert_contains "$(cat "$FK/run.2/prompt")" "── brg разбудил тебя (S001, ход 2) — ты $(full opencode-1)"
  assert_contains "$(cat "$FK/run.2/prompt")" "  $t"
  assert_contains "$(cat "$FK/run.2/argv")" "--session$NL$sid"
  wait_state S001 frozen
  wait_for 15 cursor_is opencode-1 2/2 || fail "cursor: $(cursor opencode-1)"
  sleep 1.5
  assert_eq 2 "$(runs)" "nothing twice"
  sp_assert_clean
}

# 3, 4. a crash: crashed, one message to the lead per series; no turn without something new;
# a new message — one turn with the old and the new batch; a dead provider — a turn per
# message, not more; «Разбудить» — the rolled back batch (FORCE); a new series — a new message
test_spawn_crash_hold_and_series() {
  local c n
  sp_proj
  c=$(join_as claude)
  task_new_as "$c" "задача" >/dev/null
  script 1 <<'EOF'
sleep 1.2
EOF
  script <<'EOF'
error провайдер лежит
EOF
  sp_spawn
  wait_turn S001 1
  wait_state S001 frozen
  printf 'первое\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_turn S001 2
  wait_state S001 crashed
  assert_eq "провайдер лежит" "$(rec S001 Last-Error)"
  n=$(awk '/ход 2 упал — провайдер лежит/' "$(tdir T001)"/messages/*.msg | wc -l | tr -d ' ')
  assert_eq 1 "$n" "one message to the lead"
  sleep 2
  assert_eq 2 "$(runs)" "no turn without something new"
  printf 'второе\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_turn S001 3
  assert_contains "$(cat "$FK/run.3/prompt")" "первое"
  assert_contains "$(cat "$FK/run.3/prompt")" "второе"
  wait_state S001 crashed
  printf 'третье\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_turn S001 4
  wait_state S001 crashed
  sleep 1.5
  assert_eq 4 "$(runs)" "a turn per message, not more"
  n=$(awk '/упал — провайдер лежит/' "$(tdir T001)"/messages/*.msg | wc -l | tr -d ' ')
  assert_eq 1 "$n" "one message per series"
  # «Разбудить»: the rolled back batch comes with FORCE
  script 5 <<'EOF'
sleep 1.2
EOF
  assert_contains "$(brg spawn wake S001)" "разбужу"
  wait_turn S001 5
  assert_contains "$(cat "$FK/run.5/prompt")" "человек попросил продолжить"
  assert_contains "$(cat "$FK/run.5/prompt")" "третье"
  wait_state S001 frozen
  assert_eq "" "$(rec S001 Hold)" "a good turn ends the series"
  # a new crash after a good turn: a new message
  printf 'четвёртое\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_turn S001 6
  wait_state S001 crashed
  n=$(awk '/упал — провайдер лежит/' "$(tdir T001)"/messages/*.msg | wc -l | tr -d ' ')
  assert_eq 2 "$n" "a new series — a new message"
  sp_assert_clean
}

# 5. a tail wait: a wait left in the background outlives the turn — the batch it took after the
# turn (or caught in delivery) comes again with the supervisor's wait, a later one — as usual;
# a late background wait → superseded, rollback, again (not detached)
prompts_with() { local n=0 f; for f in "$FK"/run.*/prompt; do grep -q "$1" "$f" && n=$((n + 1)); done; echo "$n"; }
prompts_with_ge() { [ "$(prompts_with "$1")" -ge "$2" ]; }
test_spawn_tail_wait() {
  local c n
  sp_proj
  c=$(join_as claude)
  task_new_as "$c" "задача" >/dev/null
  script 1 <<'EOF'
bgwait
sh sleep 0.3
EOF
  export FAKE_OC_BG_DELIVER_DELAY=2
  sp_spawn
  unset FAKE_OC_BG_DELIVER_DELAY
  wait_for 20 [ -f "$FK/run.1/bgwait.pid" ] || fail "no bgwait"
  wait_for 15 [ -f "$B/run/wait/opencode-1.pid" ] || fail "no wait of the agent"
  printf 'до надзора\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_for 30 prompts_with_ge 'до надзора' 1 || fail "the batch of the tail wait is lost: $(cat "$FK/run.1/bgwait.out")"
  wait_state S001 frozen
  printf 'после\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_for 25 prompts_with_ge 'после' 1 || fail "the next batch is lost"
  wait_state S001 frozen
  sleep 1.5
  assert_eq 1 "$(prompts_with 'до надзора')" "no duplicate"
  # a late background wait: starts after the supervisor's wait
  n=$(($(runs) + 1))
  script "$n" <<'EOF'
bgwait 1.5
EOF
  script <<'EOF'
sleep 1.2
EOF
  printf 'поздний\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_for 25 [ -f "$FK/run.$n/bgwait.pid" ] || fail "no late bgwait"
  wait_for 25 grep -qs SUPERSEDED "$FK/run.$n/bgwait.out" || fail "the late wait was not superseded: $(cat "$FK/run.$n/bgwait.out" 2>&1)"
  wait_state S001 frozen
  assert_eq "S001" "$(hdr "$B/agents/opencode-1" Spawn)" "not detached"
  printf 'потом\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_for 25 prompts_with_ge 'потом' 1 || fail "the batch after the late wait is lost"
  sp_assert_clean
}

# 6. races of delivery (BRG_TEST_DELIVER_DELAY): the tail wait caught between its output and
# its cursor while the supervisor's wait starts — nothing lost, no duplicate after; detach
# while the supervisor's wait delivers — nothing lost
test_spawn_delivery_races() {
  local c
  sp_proj
  c=$(join_as claude)
  script 1 <<'EOF'
bgwait
sleep 1.5
EOF
  export FAKE_OC_BG_DELIVER_DELAY=3
  sp_spawn
  unset FAKE_OC_BG_DELIVER_DELAY
  wait_for 20 [ -f "$B/run/wait/opencode-1.pid" ] || fail "no wait of the agent"
  printf 'в зазоре\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_turn S001 2 20
  assert_contains "$(cat "$FK/run.2/prompt")" "в зазоре"
  wait_state S001 frozen
  sleep 2
  assert_eq 2 "$(runs)" "no duplicate after"
  sp_assert_clean
  # detach while the supervisor's wait is delivering
  sp_proj
  c=$(join_as claude)
  script 1 <<'EOF'
sleep 1.2
EOF
  export BRG_TEST_DELIVER_DELAY=2
  sp_spawn
  unset BRG_TEST_DELIVER_DELAY
  wait_turn S001 1
  wait_state S001 frozen
  printf 'при detach\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_for 15 grep -q 'при detach' "$B/run/spawn/S001/prompt.next.tmp" || fail "the supervisor's wait did not deliver"
  brg spawn detach S001 >/dev/null
  wait_state S001 detached
  assert_eq 1 "$(runs)" "no turn after detach"
  assert_contains "$(brg read --as "$(full opencode-1)")" "при detach" "the batch is not lost"
  c=$(cursor opencode-1)
  [ "${c%/*}" = "${c#*/}" ] && [ "${c%/*}" -lt 3 ] || fail "rolled back: Pending = Acked, #3 not acknowledged: $c"
  sp_assert_clean
}

# 6 (cont.). a late background wait supersedes the supervisor's one and is caught in delivery —
# the supervisor takes over with a rollback after its death: nothing lost; the supervisor dies
# while its wait delivers — the new one (spawn wake) rolls back: nothing lost
test_spawn_delivery_races_superseded_and_recovery() {
  local c n
  sp_proj
  c=$(join_as claude)
  script 1 <<'EOF'
bgwait 1
EOF
  script <<'EOF'
sleep 1.2
EOF
  export FAKE_OC_BG_DELIVER_DELAY=2
  sp_spawn
  unset FAKE_OC_BG_DELIVER_DELAY
  wait_for 25 [ -f "$FK/run.1/bgwait.out" ] || fail "no late bgwait"
  sleep 0.3
  printf 'вытеснитель\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_for 30 prompts_with_ge 'вытеснитель' 1 || fail "lost: $(cat "$FK/run.1/bgwait.out")"
  wait_state S001 frozen
  sleep 1.5
  assert_eq 1 "$(prompts_with 'вытеснитель')" "no duplicate"
  sp_assert_clean
  # the supervisor dies while its wait delivers
  sp_proj
  c=$(join_as claude)
  script <<'EOF'
sleep 1.2
EOF
  export BRG_TEST_DELIVER_DELAY=2
  sp_spawn
  unset BRG_TEST_DELIVER_DELAY
  wait_turn S001 1
  wait_state S001 frozen
  printf 'при смерти надзора\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_for 15 grep -q 'при смерти надзора' "$B/run/spawn/S001/prompt.next.tmp" || fail "the supervisor's wait did not deliver"
  kill -KILL "$(sv_pid S001)"
  sleep 3
  n=$(runs)
  assert_eq 1 "$n" "no turn without a supervisor"
  brg spawn wake S001 >/dev/null
  wait_for 30 prompts_with_ge 'при смерти надзора' 1 || fail "lost with the supervisor"
  sp_assert_clean
}

# 7. wait --busy in a turn gets messages itself; the supervisor does not wait meanwhile;
# after the turn — frozen
test_spawn_busy_wait_in_turn() {
  local c
  sp_proj
  c=$(join_as claude)
  task_new_as "$c" "задача" >/dev/null
  script 1 <<'EOF'
wait --busy подагент
sleep 1.2
EOF
  sp_spawn
  wait_for 20 [ -f "$B/run/busy/opencode-1" ] || fail "no busy mark"
  assert_eq running "$(rec S001 State)"
  printf 'в ходе\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_turn S001 1
  assert_contains "$(cat "$FK/run.1/tool.1.out")" "в ходе"
  assert_contains "$(cat "$FK/run.1/tool.1.out")" "── NEXT: обработай, затем: bash .brigada/bin/brg wait --as $(full opencode-1) --busy \"подагент\""
  wait_state S001 frozen
  sleep 1.5
  assert_eq 1 "$(runs)" "the batch of wait --busy is not delivered again"
  c=$(cat "$(tdir T001)/seq")
  assert_eq "$c/$c" "$(tcursor opencode-1 T001)"
  sp_assert_clean
}

# 8. the plain wait of a launched agent does not block: empty — «заверши ход» at once, NEXT
# last; the second empty one — harder; something new — the batch
test_spawn_plain_wait() {
  local o c
  sp_proj
  c=$(join_as claude)
  script 1 <<'EOF'
wait
wait
sh sleep 2
wait
sleep 1.2
EOF
  sp_spawn
  wait_for 20 [ -f "$FK/run.1/tool.3.pid" ] || fail "no third tool"
  printf 'новое\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_turn S001 1
  o=$(cat "$FK/run.1/tool.1.out")
  assert_contains "$o" "── нет новых · ты свободен — заверши ход: brg разбудит тебя, когда будет новое"
  assert_eq "── NEXT: заверши ход" "$(printf '%s\n' "$o" | tail -n 1)"
  assert_contains "$(cat "$FK/run.1/tool.2.out")" "ты уже свободен — заверши ход сейчас"
  assert_eq "── NEXT: заверши ход" "$(tail -n 1 "$FK/run.1/tool.2.out")"
  [ -n "$(metrics_of opencode-1 wait.idle_repeat)" ] || fail "no metric wait.idle_repeat"
  assert_contains "$(cat "$FK/run.1/tool.4.out")" "новое"
  assert_contains "$(cat "$FK/run.1/tool.4.out")" "── NEXT: обработай, затем: заверши ход — brg разбудит тебя"
  sp_assert_clean
}

# 9. the phrases of waiting: nothing tells a launched agent not to end its turn or to wait in a
# plain wait; with a mark — wait --busy "I001"
test_spawn_phrases() {
  local c o k
  sp_proj
  c=$(join_as claude)
  task_new_as "$c" "задача" >/dev/null
  printf 'описание\n' | brg item add --as "$c" --title "работа" --paths src >/dev/null
  script 1 <<'EOF'
brg item claim I001 --as $ME --paths none
brg busy --as $ME проверка
brg busy --as $ME --off
brg item done I001 --as $ME --note готово
brg send --as $ME <<<'сообщение'
brg status --as $ME
sh bash .brigada/bin/brg pause
brg send --as $ME <<<'на паузе'
sh bash .brigada/bin/brg resume
sh bash .brigada/bin/brg stop opencode-1
brg send --as $ME <<<'на стопе'
brg item add --as $ME --title x --desc y
sh bash .brigada/bin/brg resume
sleep 1.2
EOF
  sp_spawn
  wait_turn S001 1 20
  k=$(full opencode-1)
  o=$(cat "$FK"/run.1/tool.*.out)
  o="$o${NL}$(sed -n '/── вывод join/,$p' "$FK/run.1/prompt")"
  assert_not_contains "$o" "ход не завершай"
  assert_not_contains "$o" "жди в wait"
  assert_not_contains "$o" "жди (wait)"
  assert_contains "$(cat "$FK/run.1/tool.1.out")" "wait --as $k --busy \"I001\""
  assert_contains "$(cat "$FK/run.1/tool.2.out")" "── NEXT: поручи работу подагенту; он блокирует тебя — вернувшись, заверши ход"
  # the busy line of a launched agent: its own advice, no supervisor id glued in (C14)
  assert_contains "$(cat "$FK/run.1/tool.2.out")" "или busy --off. Подагент блокирует тебя — вернувшись, заверши ход"
  assert_not_contains "$(cat "$FK/run.1/tool.2.out")" "S001Подагент"
  assert_not_contains "$(cat "$FK/run.1/tool.2.out")" "вызывай wait, когда он вернётся"
  assert_contains "$(cat "$FK/run.1/tool.4.out")" "заверши ход — brg разбудит тебя"
  assert_contains "$(cat "$FK/run.1/tool.6.out")" "Ты запущен brg (S001, ход 1): свободен — заверши ход"
  assert_contains "$(cat "$FK/run.1/tool.8.out")" "── ПАУЗА: человек поставил на паузу бригаду. Новую работу не начинай; сдай сделанное и заверши ход — brg разбудит тебя"
  assert_contains "$(cat "$FK/run.1/tool.11.out")" "── STOP: человек остановил тебя (opencode-1)"
  assert_contains "$(cat "$FK/run.1/tool.12.out")" "── NEXT: заверши ход (стоп снимет человек; если стоп прервал твою работу — brg разбудит тебя после его снятия)"
  sp_assert_clean
}

# 10. STOP: a frozen agent → stopped, resume → no wake (the last turn ok); STOP in the middle
# of a turn → the turn ends (Turn-Stopped: 1), resume → one FORCE wake with «стоп снят»
test_spawn_stop() {
  local c
  sp_proj
  c=$(join_as claude)
  task_new_as "$c" "задача" >/dev/null
  script 1 <<'EOF'
sleep 1.2
EOF
  sp_spawn
  wait_turn S001 1
  wait_state S001 frozen
  brg stop >/dev/null
  wait_state S001 stopped
  brg resume >/dev/null
  wait_state S001 frozen
  sleep 1.5
  assert_eq 1 "$(runs)" "resume does not wake after a good turn"
  script 2 <<'EOF'
wait --busy работа
sleep 1.2
EOF
  brg say --to opencode-1 "поработай" >/dev/null
  wait_for 20 [ -f "$B/run/busy/opencode-1" ] || fail "no busy wait"
  brg stop >/dev/null
  wait_turn S001 2
  assert_contains "$(cat "$FK/run.2/tool.1.out")" "── STOP"
  assert_eq 1 "$(rec S001 Turn-Stopped)" "Turn-Stopped"
  wait_state S001 stopped
  brg resume >/dev/null
  wait_turn S001 3
  assert_contains "$(cat "$FK/run.3/prompt")" "── стоп снят человеком: проверь status"
  wait_state S001 frozen
  sleep 1.5
  assert_eq 3 "$(runs)" "one wake"
  sp_assert_clean
}

# 11. the pause: an agent's message does not wake, the human's does; resume — «пауза снята»
test_spawn_pause() {
  local c
  sp_proj
  c=$(join_as claude)
  script 1 <<'EOF'
sleep 1.2
EOF
  sp_spawn
  wait_turn S001 1
  wait_state S001 frozen
  brg pause >/dev/null
  printf 'от агента\n' | brg send --as "$c" --to opencode-1 >/dev/null
  sleep 2
  assert_eq 1 "$(runs)" "an agent's message does not wake on a pause"
  brg say --to opencode-1 "от человека" >/dev/null
  wait_turn S001 2
  assert_contains "$(cat "$FK/run.2/prompt")" "от человека"
  assert_contains "$(cat "$FK/run.2/prompt")" "пауза продолжается"
  wait_state S001 frozen
  wait_for 15 [ -f "$B/run/wait/opencode-1.pid" ] || fail "no supervisor's wait"
  sleep 0.5
  brg resume >/dev/null
  wait_turn S001 3
  assert_contains "$(cat "$FK/run.3/prompt")" "── пауза снята"
  sp_assert_clean
}

# 12. HOLD and a change of the task: a crashed agent + task new --as human → exactly one turn
# with «новая задача» and the lead; task cancel --as human → one more
# prompts_have TEXT… — every TEXT is in the prompts of runs 2 and later (the lobby message and
# «ты lead» are written one after the other: they may wake two turns, not one)
prompts_have() {
  local all= f t
  for f in "$FK"/run.*/prompt; do
    case $f in */run.1/prompt) continue ;; esac
    [ -f "$f" ] && all="$all$(cat "$f")"
  done
  for t in "$@"; do case $all in *"$t"*) ;; *) return 1 ;; esac; done
}

test_spawn_hold_task_change() {
  local n
  sp_proj
  script <<'EOF'
error провайдер лежит
EOF
  sp_spawn
  wait_turn S001 1
  wait_state S001 crashed
  sleep 1
  printf 'постановка\n' | brg task new --as human --title "задача" >/dev/null
  wait_for 30 prompts_have "новая задача T001 от человека" "ты lead задачи T001" ||
    fail "the new task and «ты lead» did not wake the crashed agent"
  wait_state S001 crashed
  sleep 1.5
  n=$(runs)
  [ "$n" -ge 2 ] && [ "$n" -le 3 ] || fail "turns for the new task: $((n - 1)) (at most one per waking message)"
  brg task cancel --as human >/dev/null
  wait_turn S001 $((n + 1))
  assert_contains "$(cat "$FK/run.$((n + 1))/prompt")" "отменена"
  wait_state S001 crashed
  sleep 1.5
  assert_eq $((n + 1)) "$(runs)" "exactly one turn"
  sp_assert_clean
}

# 13. spawn rm during a turn: the fake gets SIGINT (130, not KILL), its tools stop; leave; the
# lead goes to the other agent; no processes left
test_spawn_rm_during_turn() {
  local c tp
  sp_proj
  c=$(join_as claude)
  script 1 <<'EOF'
sleep 30
EOF
  sp_spawn
  wait_for 20 [ -f "$FK/run.1/tool.1.pid" ] || fail "no tool"
  printf 'постановка\n' | brg task new --as human --title "задача" >/dev/null
  brg lead give opencode-1 --as human >/dev/null
  assert_eq opencode-1 "$(hdr "$(tdir T001)/task" Lead)"
  tp=$(cat "$FK/run.1/tool.1.pid")
  assert_contains "$(brg spawn rm S001)" "надзор уберёт агента — идущий ход остановится"
  wait_state S001 removed 15
  assert_eq INT "$(cat "$FK/run.1/sig" 2>/dev/null)" "SIGINT to the harness"
  assert_eq interrupted "$(rec S001 Turn-Result)"
  [ -n "$(hdr "$B/agents/opencode-1" Left)" ] || fail "no leave"
  assert_eq "$(base_of "$c")" "$(hdr "$(tdir T001)/task" Lead)" "the lead goes to the other agent"
  wait_for 15 is_dead "$tp" || fail "the tool of the fake is alive"
  sp_assert_clean
}

# 14. spawn detach of a frozen agent: Spawn: off, NEXT — a plain wait, which blocks; the
# command to open its session
test_spawn_detach() {
  local o k
  sp_proj
  script 1 <<'EOF'
sleep 1.2
EOF
  sp_spawn
  wait_turn S001 1
  wait_state S001 frozen
  o=$(brg spawn detach S001)
  assert_contains "$o" "--session $(rec S001 Session)"
  assert_contains "$o" "продолжай: status, затем wait"
  wait_state S001 detached
  assert_eq "" "$(hdr "$B/agents/opencode-1" Spawn)" "Spawn: off"
  k=$(full opencode-1)
  o=$(brg status --as "$k")
  assert_contains "$o" "Тебя забрали в окно (S001)"
  o=$(printf '%s\n' "$o" | tail -n 1)
  assert_contains "$o" "── NEXT: bash "
  assert_contains "$o" " wait --as $k"
  assert_not_contains "$o" "заверши ход"
  start_wait "$k" "$(mk_tmpdir)/w"
  sleep 1
  is_alive "$WP" || fail "the wait of a detached agent must block"
  sp_assert_clean
}

# 15. the death of the supervisor: kill -9 in a turn → spawn wake runs no second turn while the
# wrapper lives (also «asleep»: an old turn.hb of a live wrapper); a crashed turn → the batch
# comes after the recovery; two spawn wake at once → one supervisor
test_spawn_supervisor_death() {
  local c sp wp
  sp_proj
  c=$(join_as claude)
  script 1 <<'EOF'
sleep 3
error упал после сна
EOF
  script 2 <<'EOF'
sleep 1.2
EOF
  sp_spawn
  wait_for 20 [ -f "$FK/run.1/tool.1.pid" ] || fail "no tool"
  sp=$(sv_pid S001)
  kill -KILL "$sp"
  wait_for 3 is_dead "$sp" || fail "the supervisor outlived KILL"
  wp=$(cat "$B/run/spawn/S001/turn.pid")
  kill -STOP "$wp"
  printf '%s 1000\n' "$wp" >"$B/run/spawn/S001/turn.hb" # an old heartbeat of a live wrapper
  printf 'во время хода\n' | brg send --as "$c" --to opencode-1 >/dev/null
  assert_contains "$(brg spawn wake S001)" "надзор не отвечал — запущен заново"
  sleep 2
  kill -CONT "$wp"
  wait_turn S001 2 20
  [ ! -e "$FK/overlap" ] || fail "two turns of one session at once"
  assert_contains "$(cat "$FK/run.2/prompt")" "во время хода" "the batch comes after the recovery"
  assert_contains "$(cat "$FK/run.2/prompt")" "человек попросил продолжить"
  wait_state S001 frozen
  # two wakes at once of a dead supervisor: one supervisor
  sp=$(sv_pid S001)
  kill -KILL "$sp"
  wait_for 3 is_dead "$sp" || fail "the supervisor outlived KILL"
  sleep 0.5
  brg spawn wake S001 >/dev/null &
  brg spawn wake S001 >/dev/null
  wait
  wait_turn S001 3 15
  wait_state S001 frozen
  sleep 1
  sp=$(sv_pid S001)
  is_alive "$sp" || fail "no supervisor"
  assert_eq 3 "$(awk '/надзор S001 \(opencode-1\): pid/' "$B/run/spawn/S001/supervisor.log" | wc -l | tr -d ' ')" "one supervisor per wake"
  sleep 2
  assert_eq 3 "$(runs)" "one wake from two"
  sp_assert_clean
}

# 16. the lock: spawn rm while the supervisor waits out a stop → the supervisor does it (flag);
# join --as with a live supervisor → refused at once; doctor — no ✗ for a live supervisor; an
# update of brg between turns → exec into the new code, the lock kept, no rollback
test_spawn_lock_and_update() {
  local o t0 sp k
  sp_proj
  script 1 <<'EOF'
sleep 1.2
EOF
  sp_spawn
  wait_turn S001 1
  wait_state S001 frozen
  # join --as: refused, no hanging
  t0=$(date -u +%s)
  dropped opencode-1
  o=$(brg join --as opencode-1 --harness opencode 2>&1)
  assert_contains "$o" "надзор жив: brg spawn detach S001"
  [ $(($(date -u +%s) - t0)) -le 3 ] || fail "join --as hung"
  o=$(bash "$BRG" doctor 2>&1)
  assert_not_contains "$o" "✗ блокировка spawn"
  assert_not_contains "$o" "✗ надзор"
  assert_contains "$o" "brg spawn: запусков 1, живых надзоров 1"
  # the update: a new bin/brg (another version) and VERSION
  sp=$(sv_pid S001)
  sed 's/^BRG_VERSION=.*/BRG_VERSION=9.9.9-test/' "$ROOT/bin/brg" >"$B/bin/brg.new" && mv "$B/bin/brg.new" "$B/bin/brg"
  printf '9.9.9-test\n' >"$B/VERSION"
  script 2 <<'EOF'
sleep 1.2
EOF
  brg say --to opencode-1 "после обновления" >/dev/null
  wait_turn S001 2
  wait_for 20 grep -q 'надзор продолжает на новом коде' "$B/run/spawn/S001/supervisor.log" || fail "no exec: $(cat "$B/run/spawn/S001/supervisor.log")"
  wait_for 15 grep -q 'продолжает после обновления brg' "$B/run/spawn/S001/supervisor.log" || fail "the new image did not start"
  assert_eq "$sp" "$(sv_pid S001)" "the same supervisor (pid), the lock kept"
  wait_state S001 frozen
  sleep 1.5
  assert_eq 2 "$(runs)" "no rollback after exec"
  brg say --to opencode-1 "ещё" >/dev/null
  wait_turn S001 3
  assert_contains "$(cat "$FK/run.3/prompt")" "ещё"
  assert_not_contains "$(cat "$FK/run.3/prompt")" "после обновления"
  wait_state S001 frozen
  # spawn rm while stopped: the supervisor serves the flag
  brg stop >/dev/null
  wait_state S001 stopped
  assert_contains "$(brg spawn rm S001)" "надзор уберёт агента"
  wait_state S001 removed
  [ -n "$(hdr "$B/agents/opencode-1" Left)" ] || fail "no leave"
  brg resume >/dev/null
  sp_assert_clean
}

# 17. no result file: a wait that dies at once (the agent Left, or Spawn: off the profile) —
# no hot loop of forks; removed / detached
test_spawn_no_result_file() {
  local n
  sp_proj
  script 1 <<'EOF'
sh sleep 1.5
sh printf 'Left: 1\n' >>.brigada/agents/opencode-1
EOF
  sp_spawn
  wait_state S001 removed 15
  n=$(metrics_of opencode-1 wait | awk '/result=error/' | wc -l | tr -d ' ')
  [ "$n" -le 2 ] || fail "a hot loop: $n failed waits"
  sp_assert_clean
  sp_proj
  script 1 <<'EOF'
sh sleep 1.5
sh grep -v '^Spawn: ' .brigada/agents/opencode-1 >.brigada/agents/x.tmp && mv .brigada/agents/x.tmp .brigada/agents/opencode-1
EOF
  sp_spawn
  wait_state S001 detached 15
  sleep 2
  n=$(metrics_of opencode-1 wait | awk '/result=error/' | wc -l | tr -d ' ')
  [ "$n" -le 2 ] || fail "a hot loop: $n failed waits"
  sp_assert_clean
}

# 18. rights: project → no --auto; a refusal in stderr → activity, Last-Error, the snapshot;
# spawn rights S001 full of a frozen agent → a turn with --auto and a line on the rights
test_spawn_rights() {
  local t
  sp_proj
  script 1 <<'EOF'
perm read (../секрет.env)
sleep 1.2
EOF
  script 4 <<'EOF'
error провайдер лежит
EOF
  script <<'EOF'
sleep 1.2
EOF
  sp_spawn --rights project
  assert_contains "$SPOUT" "права: project — правила OpenCode по умолчанию: в проекте можно всё — любые команды, правки, сеть, git push; вне проекта и .env — отказ"
  wait_turn S001 1
  wait_state S001 frozen
  assert_not_contains "$(cat "$FK/run.1/argv")" "--auto"
  assert_eq "отказ в правах: read (../секрет.env)" "$(rec S001 Last-Error)"
  assert_contains "$(cat "$B/run/spawn/S001/activity.tail")" "permission	отказ в правах: read (../секрет.env)"
  brg board --once >/dev/null
  assert_contains "$(cat "$B/run/board/data.js")" '"last_error":"отказ в правах: read (../секрет.env)"'
  assert_contains "$(brg who)" "отказ в правах: read (../секрет.env)"
  # a good turn after it: the refusal stays visible until the rights change
  brg say --to opencode-1 "дальше" >/dev/null
  wait_turn S001 2
  wait_state S001 frozen
  assert_eq "read (../секрет.env)" "$(rec S001 Perm-Denied)" "the refusal stays"
  brg board --once >/dev/null
  assert_contains "$(cat "$B/run/board/data.js")" '"perm_denied":"read (../секрет.env)"'
  # the rights change without a wake: the record at once, no turn
  t=$(brg spawn rights S001 full)
  assert_contains "$t" "права S001: full — со следующего хода; разбудить сейчас — «Разбудить»"
  wait_for 3 rec_is S001 Rights full || fail "the record not updated in 3 s"
  assert_eq "" "$(rec S001 Perm-Denied)" "cleared by the new rights"
  assert_contains "$(rec S001 Rights-Note)" "человек расширил права до full"
  sleep 3
  assert_eq 2 "$(runs)" "no wake from the rights"
  # the note survives a restart of the supervisor and a crashed turn
  kill -KILL "$(sv_pid S001)"
  sleep 0.5
  brg say --to opencode-1 "проверь" >/dev/null
  brg spawn wake S001 >/dev/null
  wait_turn S001 3
  assert_contains "$(cat "$FK/run.3/argv")" "--auto"
  assert_contains "$(cat "$FK/run.3/prompt")" "── человек расширил права до full"
  wait_state S001 frozen
  assert_eq "" "$(rec S001 Rights-Note)" "a good turn takes it off"
  # a crashed turn keeps it
  brg spawn rights S001 project >/dev/null
  wait_for 3 rec_is S001 Rights project || fail "project not applied"
  brg say --to opencode-1 "ещё" >/dev/null
  wait_turn S001 4
  wait_state S001 crashed
  assert_contains "$(cat "$FK/run.4/prompt")" "── человек изменил права на project"
  assert_contains "$(rec S001 Rights-Note)" "изменил права на project" "kept after a crash"
  brg say --to opencode-1 "снова" >/dev/null
  wait_turn S001 5
  assert_contains "$(cat "$FK/run.5/prompt")" "── человек изменил права на project"
  assert_not_contains "$(cat "$FK/run.5/argv")" "--auto"
  wait_state S001 frozen
  assert_eq "" "$(rec S001 Rights-Note)"
  sp_assert_clean
}

# 19. the key is not in the snapshot, spawn show|list, activity, the last text
test_spawn_key_masked() {
  local k kp f
  sp_proj
  script 1 <<'EOF'
sleep 1.2
EOF
  sp_spawn
  wait_turn S001 1
  wait_state S001 frozen
  k=$(full opencode-1)
  kp=$(hdr "$B/agents/opencode-1" Key)
  kp=opencode-1.${kp:0:3}…
  script 2 <<EOF
brg status --as $k
text моё имя — $k, запомни
sleep 1.2
EOF
  brg say --to opencode-1 "назовись" >/dev/null
  wait_turn S001 2
  wait_state S001 frozen
  brg board --once >/dev/null
  for f in "$B/run/board/data.js" "$B/run/spawn/S001/activity.tail" "$B/run/spawn/S001/activity.log" "$B/run/spawn/S001/spawn" "$B/run/spawn/S001/prompt.head"; do
    assert_not_contains "$(cat "$f")" "$k" "the key in ${f##*/}"
  done
  assert_contains "$(cat "$B/run/spawn/S001/activity.tail")" "моё имя — $kp"
  assert_not_contains "$(brg spawn show S001)" "$k"
  assert_not_contains "$(brg spawn list)" "$k"
  assert_contains "$(brg spawn show S001)" "$kp"
  sp_assert_clean
}

# 21. joining: join --as of a launched agent after it dropped out → Spawn: off, detached; join
# under BRG_SPAWN from another session → «ты подагент»; from the same — «join не нужен»;
# wait --as of the participant from its subagent → refused, code 0, NEXT
test_spawn_join_rules() {
  local o sid k
  sp_proj
  script 1 <<'EOF'
sleep 1.2
EOF
  sp_spawn
  wait_turn S001 1
  wait_state S001 frozen
  sid=$(rec S001 Session)
  k=$(full opencode-1)
  o=$(cd "$P" && BRG_SPAWN=S001 OPENCODE_SESSION_ID=ses_other bash "$BRG" join --harness opencode --model m 2>&1)
  assert_contains "$o" "ты подагент участника opencode-1 — к бригаде не подключайся, выполни поручение"
  o=$(cd "$P" && BRG_SPAWN=S001 OPENCODE_SESSION_ID=$sid bash "$BRG" join --harness opencode --model m 2>&1)
  assert_contains "$o" "join не нужен: тебя подключил brg (S001)"
  o=$(cd "$P" && OPENCODE_SESSION_ID=ses_other bash "$BRG" wait --as "$k")
  assert_eq 0 $? "wait: code 0"
  assert_contains "$o" "ты подагент участника opencode-1"
  assert_eq "── NEXT: выполни поручение и верни результат" "$(printf '%s\n' "$o" | tail -n 1)"
  assert_eq frozen "$(rec S001 State)" "the supervisor's wait is untouched"
  # the supervisor dies, the agent drops out: join --as takes it into a window
  kill -KILL "$(sv_pid S001)"
  wait_for 15 [ ! -e "$B/run/wait/opencode-1.pid" ] || true
  sleep 1
  dropped opencode-1
  o=$(rejoin_as opencode-1 opencode)
  [ -n "$o" ] || fail "join --as refused: $(brg join --as opencode-1 --harness opencode 2>&1)"
  assert_eq "" "$(hdr "$B/agents/opencode-1" Spawn)" "Spawn: off"
  assert_eq detached "$(rec S001 State)"
  sp_assert_clean
}

# 22. a mixed brigade: a manual agent (a blocking wait) and a launched one talk; the launched
# agent in a long turn is "on the line" for the choice of the lead
test_spawn_mixed_brigade() {
  local c o w
  sp_proj
  c=$(join_as claude)
  w=$(mk_tmpdir)/w
  script 1 <<'EOF'
sleep 1.2
EOF
  script 2 <<'EOF'
brg send --as $ME --to claude-1 <<<'ответ запущенного'
sleep 1.2
EOF
  script 3 <<'EOF'
sleep 8
EOF
  sp_spawn
  wait_turn S001 1
  wait_state S001 frozen
  ack_all "$c"
  start_wait "$c" "$w"
  printf 'вопрос запущенному\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_turn S001 2
  wait_pid "$WP" 25 || fail "the manual wait did not return"
  assert_contains "$(cat "$w")" "ответ запущенного"
  # a long turn: the lead (claude-1) leaves — the launched agent in its turn becomes the lead
  printf 'постановка\n' | brg task new --as "$c" --title "задача" >/dev/null
  brg say --to opencode-1 "долгая работа" >/dev/null
  wait_for 20 [ -f "$FK/run.3/tool.1.pid" ] || fail "no long turn"
  printf '%s\n' "$(($(date -u +%s) - 1000))" >"$B/run/wait/opencode-1.last"
  brg leave --as "$c" >/dev/null
  assert_eq opencode-1 "$(hdr "$(tdir T001)/task" Lead)" "the launched agent in a long turn is on the line"
  assert_contains "$(brg who)" "ход 3 идёт"
  sp_assert_clean
}

# 23. tokens: export with --standalone; a background task (sessionID: …) counted; a timeout of
# the export stops the fake itself (not head); a failed export → stream
test_spawn_tokens() {
  local f
  sp_proj
  script 1 <<'EOF'
task-bg bash .brigada/bin/brg who
sleep 1.2
EOF
  sp_spawn
  wait_turn S001 1
  wait_for 25 rec_is S001 Tokens-Source export || fail "no export"
  assert_eq 1 "$(rec S001 Sub-Sessions)" "the background child"
  assert_eq $((3 * 100 + 1000)) "$(rec S001 Tokens-In)"
  for f in "$FK"/export.*/argv; do assert_contains "$(cat "$f")" "session export --standalone ses_"; done
  sp_assert_clean
  # the export hangs: INT to the fake itself, then stream
  sp_proj
  script 1 <<'EOF'
sleep 1.2
EOF
  export FAKE_OC_EXPORT_SLEEP=30 BRG_SPAWN_EXPORT_TIMEOUT=2
  sp_spawn
  unset FAKE_OC_EXPORT_SLEEP BRG_SPAWN_EXPORT_TIMEOUT
  wait_turn S001 1
  wait_for 25 [ -f "$FK/export.1/sig" ] || fail "the export was not stopped"
  assert_eq INT "$(cat "$FK/export.1/sig")" "SIGINT to the export itself"
  wait_for 15 rec_is S001 Tokens-Source stream || fail "not stream"
  assert_eq 200 "$(rec S001 Tokens-In)" "the stream of the main session"
  sp_assert_clean
  # the export fails: stream
  sp_proj
  script 1 <<'EOF'
sleep 1.2
EOF
  export FAKE_OC_EXPORT_FAIL=1
  sp_spawn
  unset FAKE_OC_EXPORT_FAIL
  wait_turn S001 1
  wait_for 25 [ -d "$FK/export.1" ] || fail "no export"
  sleep 1
  assert_eq stream "$(rec S001 Tokens-Source)"
  brg board --once >/dev/null
  assert_contains "$(cat "$B/run/board/data.js")" '"tokens_source":"stream"'
  sp_assert_clean
}

# 24. --count 2; spawn list|show; an agent cannot spawn; refusals: no binary, an unsupported
# harness, MSYS, --model -x
test_spawn_commands_and_refusals() {
  local o k
  sp_proj
  script <<'EOF'
sleep 1.2
EOF
  sp_spawn --count 2
  assert_contains "$SPOUT" "S001 → opencode-1"
  assert_contains "$SPOUT" "S002 → opencode-2"
  wait_turn S001 1
  wait_turn S002 1
  o=$(brg spawn list)
  assert_contains "$o" "S001 · opencode-1 · opencode/provider/model · права full · ждёт · ход 1 (ok)"
  assert_contains "$o" "S002 · opencode-2"
  o=$(brg spawn show opencode-2)
  assert_contains "$o" "── S002 · opencode-2 · ждёт"
  assert_contains "$o" "── активность (последние 20):"
  k=$(full opencode-1)
  o=$(cd "$P" && bash "$BRG" spawn opencode --model m --as "$k" 2>&1)
  assert_contains "$o" "запускает агентов только человек; попроси его: send --to human --ask"
  o=$(cd "$P" && BRG_SPAWN=S001 bash "$BRG" spawn opencode --model m 2>&1)
  assert_contains "$o" "запускает агентов только человек"
  o=$(cd "$P" && BRG_SPAWN=S001 bash "$BRG" spawn rm S002 2>&1)
  assert_contains "$o" "запускает агентов только человек"
  o=$(cd "$P" && bash "$BRG" spawn claude --model m 2>&1)
  assert_contains "$o" "харнесс claude пока не поддерживается"
  o=$(cd "$P" && BRG_PLATFORM=MSYS bash "$BRG" spawn opencode --model m 2>&1)
  assert_contains "$o" "на MSYS пока не поддерживается"
  o=$(cd "$P" && bash "$BRG" spawn opencode --model -x 2>&1)
  assert_contains "$o" "--model — имя модели"
  printf 'spawn.opencode.bin: /nonexistent/opencode\n' >>"$B/config"
  o=$(cd "$P" && bash "$BRG" spawn opencode --model m 2>&1)
  assert_contains "$o" "не найден бинарь харнесса opencode"
  assert_eq 2 "$(ls "$B/run/spawn" | wc -l | tr -d ' ')" "nothing launched by the refusals"
  sp_assert_clean
}

# 25. the board: the snapshot with spawn and activity; evil data from the stream escaped
test_spawn_board_snapshot() {
  local d
  sp_proj
  printf 'text злые "кавычки" </script> \001\002 и \342\200\250 разрыв\nsleep 1.2\n' >"$FK/script.1"
  sp_spawn
  wait_turn S001 1
  wait_state S001 frozen
  brg board --once >/dev/null
  d=$(cat "$B/run/board/data.js")
  assert_contains "$d" '"spawn":{"id":"S001","harness":"opencode","model":"provider/model","rights":"full","state":"frozen"'
  assert_contains "$d" '"supervisor_alive":true'
  assert_contains "$d" '"activity":"'
  assert_contains "$d" 'злые \"кавычки\" </script>'
  assert_contains "$d" '\u2028'
  assert_not_contains "$d" $'\342\200\250' "a raw U+2028"
  assert_not_contains "$d" $'\001' "a raw control byte"
  assert_contains "$d" '"spawn":{"supported":["opencode"],"available":["opencode"]}'
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$d" | python3 -I -c 'import sys, json; s = sys.stdin.read(); s = s[s.index("=") + 1:].strip().rstrip(";"); json.loads(s)' ||
      fail "data.js is not JSON"
  fi
  sp_assert_clean
}


# В1 (validation): the rollback owed after a crashed turn survives a STOP — the batch comes with
# the wake after resume; a detach during such a turn (live supervisor) and a detach after the
# supervisor died mid-turn (the orphaned turn crashed) give the batch to the window agent
test_spawn_rollback_survives_stop_and_detach() {
  local k o
  sp_proj
  script 1 <<'XEOF'
sleep 1.2
XEOF
  script 2 <<'XEOF'
sleep 2
error boom
XEOF
  script <<'XEOF'
sleep 1.2
XEOF
  sp_spawn
  wait_turn S001 1
  wait_state S001 frozen
  brg say --to opencode-1 "MESSAGE-ONE" >/dev/null
  wait_run 2
  brg stop >/dev/null
  wait_turn S001 2
  assert_eq crash "$(rec S001 Turn-Result)"
  wait_state S001 stopped
  brg resume >/dev/null
  wait_turn S001 3
  assert_contains "$(cat "$FK/run.3/prompt")" "MESSAGE-ONE" "the batch of the crashed turn after the stop"
  sp_assert_clean
  # detach asked during a turn that crashes
  sp_proj
  script 1 <<'XEOF'
sleep 1.2
XEOF
  script 2 <<'XEOF'
sleep 2
error boom
XEOF
  sp_spawn
  wait_turn S001 1
  wait_state S001 frozen
  brg say --to opencode-1 "MESSAGE-TWO" >/dev/null
  wait_run 2
  brg spawn detach S001 >/dev/null
  wait_state S001 detached
  k=$(full opencode-1)
  o=$(cd "$P" && bash "$BRG" wait --as "$k" --timeout 2)
  assert_contains "$o" "MESSAGE-TWO" "the window agent gets the batch"
  sp_assert_clean
  # the supervisor dies mid-turn, the orphaned turn crashes, then detach (supervisor dead)
  sp_proj
  script 1 <<'XEOF'
sleep 1.2
XEOF
  script 2 <<'XEOF'
sleep 2
error boom
XEOF
  sp_spawn
  wait_turn S001 1
  wait_state S001 frozen
  brg say --to opencode-1 "MESSAGE-FOUR" >/dev/null
  wait_for 20 [ -f "$FK/run.2/tool.1.pid" ] || fail "no turn 2"
  kill -KILL "$(sv_pid S001)"
  wait_for 30 [ -f "$B/run/spawn/S001/turn.2.exit" ] || fail "the orphaned turn did not end"
  o=$(brg spawn detach S001 2>&1)
  assert_contains "$o" "забран"
  k=$(full opencode-1)
  o=$(cd "$P" && bash "$BRG" wait --as "$k" --timeout 2)
  assert_contains "$o" "MESSAGE-FOUR" "the window agent gets the batch"
  sp_assert_clean
}

# В2 (validation): a silent supervisor (its pid alive, no heartbeat: stopped here) — wake starts
# a new one that takes the lock over once the silence is proven; the old one, woken, leaves
test_spawn_silent_supervisor_replaced() {
  local sp o
  sp_proj
  script <<'XEOF'
sleep 1.2
XEOF
  sp_spawn
  wait_turn S001 1
  wait_state S001 frozen
  sp=$(sv_pid S001)
  kill -STOP "$sp"
  wait_for 30 eval '[ -n "$(brg spawn list | awk "/надзор не отвечает/")" ]' || { kill -CONT "$sp"; fail "not seen as silent"; }
  o=$(brg spawn wake S001)
  assert_contains "$o" "надзор не отвечает (pid жив, признаков жизни нет) — запущен новый"
  wait_for 40 turn_done S001 2 || { kill -CONT "$sp"; fail "no turn after the new supervisor: $(tail -n 5 "$B/run/spawn/S001/supervisor.log")"; }
  [ "$(sv_pid S001)" != "$sp" ] || { kill -CONT "$sp"; fail "the lock is still the old one's"; }
  kill -CONT "$sp"
  wait_for 30 is_dead "$sp" || fail "the old supervisor did not leave after it woke"
  wait_state S001 frozen
  assert_contains "$(brg spawn list)" "S001 · opencode-1"
  assert_not_contains "$(brg spawn list)" "надзор не отвечает"
  sp_assert_clean
}

# a crash with no task (the lead is nobody): the message goes to the human, not back to the agent
test_spawn_crash_note_to_human() {
  local f
  sp_proj
  script 1 <<'XEOF'
error boom
XEOF
  script <<'XEOF'
sleep 1.2
XEOF
  sp_spawn
  wait_turn S001 1
  wait_state S001 crashed
  f=$(msg_file 2)
  assert_contains "$(cat "$f")" "ход 1 упал — boom"
  assert_eq human "$(hdr "$f" To)"
  brg say --to opencode-1 "дальше" >/dev/null
  wait_turn S001 2
  assert_not_contains "$(cat "$FK/run.2/prompt")" "ход 1 упал" "not in its own prompt"
  sp_assert_clean
}


# r8 (validation): a message that came during a turn which then crashed wakes the agent — it
# was not seen by that turn; and only once (no new messages — no more turns)
test_spawn_crash_wakes_for_unseen() {
  local c
  sp_proj
  c=$(join_as claude)
  script 1 <<'XEOF'
sleep 1.2
XEOF
  script 2 <<'XEOF'
sleep 2
error boom
XEOF
  script <<'XEOF'
sleep 1.2
XEOF
  sp_spawn
  wait_turn S001 1
  wait_state S001 frozen
  printf 'первое\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_for 20 [ -f "$FK/run.2/tool.1.pid" ] || fail "no turn 2"
  printf 'во время хода\n' | brg send --as "$c" --to opencode-1 >/dev/null
  wait_turn S001 2
  assert_eq crash "$(rec S001 Turn-Result)"
  wait_turn S001 3
  assert_contains "$(cat "$FK/run.3/prompt")" "во время хода" "the unseen message wakes"
  assert_contains "$(cat "$FK/run.3/prompt")" "первое" "with the rolled back batch"
  wait_state S001 frozen
  sleep 2
  assert_eq 3 "$(runs)" "no more turns without new messages"
  sp_assert_clean
}


# ── 0.9.1 ──
# count_act KIND TEXT — lines of activity.log of KIND that contain TEXT
count_act() { [ -f "$B/run/spawn/S001/activity.log" ] || { echo 0; return; }; awk -F '\t' -v k="$1" -v t="$2" '$2 == k && index($3, t) { n++ } END { print n + 0 }' "$B/run/spawn/S001/activity.log"; }
act_has() { [ "$(count_act "$1" "$2")" -ge 1 ]; }

# the activity as the turn goes: lines in activity.tail and in the snapshot before the end of the
# turn; none twice after it; a half-written line counted once
test_spawn_live_activity() {
  sp_proj
  script 1 <<'XEOF'
text первый шаг
sh sleep 4
half половинчатая строка
sleep 1.2
XEOF
  sp_spawn
  wait_for 20 act_has text "первый шаг" || fail "no live line"
  assert_eq running "$(rec S001 State)" "seen before the end of the turn"
  assert_contains "$(cat "$B/run/spawn/S001/activity.tail")" "первый шаг"
  brg board --once >/dev/null
  assert_contains "$(cat "$B/run/board/data.js")" "первый шаг"
  wait_turn S001 1
  wait_state S001 frozen
  assert_eq 1 "$(count_act text 'первый шаг')" "no duplicate"
  assert_eq 1 "$(count_act text 'половинчатая строка')" "a half-written line once"
  assert_eq 1 "$(count_act tool 'sleep 4')"
  assert_eq 1 "$(count_act end 'ход 1: ok')"
  assert_eq 1 "$(rec S001 Last-Text-Turn)"
  sp_assert_clean
}

# the harness killed in the middle of a line: the rest parsed at the end without failing; an
# error event in an intermediate parse — the provider's text, the turn crashes
test_spawn_live_error_and_cut_line() {
  local fp
  sp_proj
  script 1 <<'XEOF'
errorev провайдер сломался
sh sleep 4
exit 1
XEOF
  sp_spawn
  wait_for 20 act_has error "провайдер сломался" || fail "the error was not parsed during the turn"
  wait_turn S001 1
  assert_eq crash "$(rec S001 Turn-Result)"
  assert_eq "провайдер сломался" "$(rec S001 Last-Error)" "the provider's text, not the exit code"
  sp_assert_clean
  sp_proj
  script 1 <<'XEOF'
text до обрыва
halfhang оборванная
XEOF
  sp_spawn
  wait_for 20 [ -f "$FK/run.1/half" ] || fail "no half line"
  sleep 3.5 # an intermediate parse sees the half line and leaves it
  fp=$(cat "$FK/run.1/pid")
  kill -KILL "$fp"
  wait_turn S001 1
  assert_eq crash "$(rec S001 Turn-Result)"
  assert_eq 1 "$(count_act text 'до обрыва')"
  assert_eq 1 "$(count_act end 'ход 1: crash')"
  sp_assert_clean
}

# kill -9 of the supervisor between the lines of the activity and the state of the parse, and
# between the count of the tokens and the outcome: after the recovery — every line once, the
# tokens once, one end line, one note to the lead
test_spawn_kill9_parse_and_tokens() {
  local c sp
  sp_proj
  script 1 <<'XEOF'
text раз
sh sleep 5
text два
sleep 1.2
XEOF
  export BRG_SPAWN_TEST_DELAY_PARSE=4
  sp_spawn
  unset BRG_SPAWN_TEST_DELAY_PARSE
  wait_for 20 act_has text "раз" || fail "no line"
  sp=$(sv_pid S001)
  kill -KILL "$sp" # asleep between the lines of the activity and turn.1.parse
  sleep 0.5
  brg spawn wake S001 >/dev/null
  wait_turn S001 1 40
  wait_state S001 frozen
  assert_eq 1 "$(count_act text 'раз')" "no duplicate after kill -9"
  assert_eq 1 "$(count_act text 'два')"
  assert_eq 1 "$(count_act end 'ход 1:')"
  assert_eq 500 "$(rec S001 Tokens-Main-In)" "5 steps of the main session"
  sp_assert_clean
  # between stream.tok and the outcome
  sp_proj
  c=$(join_as claude)
  task_new_as "$c" "задача" >/dev/null
  script 1 <<'XEOF'
text раз
error упал
XEOF
  script <<'XEOF'
sleep 1.2
XEOF
  export BRG_SPAWN_TEST_DELAY_TOK=4
  sp_spawn
  unset BRG_SPAWN_TEST_DELAY_TOK
  wait_for 20 grep -q '^1 ' "$B/run/spawn/S001/stream.tok" || fail "stream.tok not counted"
  sp=$(sv_pid S001)
  kill -KILL "$sp" # asleep after the count, before the outcome
  sleep 0.5
  assert_eq running "$(rec S001 State)"
  brg spawn wake S001 >/dev/null
  wait_for 40 rec_is S001 Turn-Result crash || fail "no outcome after the recovery"
  assert_eq "1 100" "$(cut -d" " -f1,2 "$B/run/spawn/S001/stream.tok")" "the turn counted once"
  assert_eq 100 "$(rec S001 Tokens-Main-In)"
  assert_eq 1 "$(count_act end 'ход 1:')" "one end line"
  assert_eq 1 "$(awk '/ход 1 упал/' "$(tdir T001)"/messages/*.msg | wc -l | tr -d ' ')" "one note to the lead"
  sp_assert_clean
}

# whose refusal: the main session's (stderr + a refused tool_use) and a subagent's (stderr only)
test_spawn_whose_refusal() {
  sp_proj
  script 1 <<'XEOF'
perm read (/p/main.env)
sh sleep 4
perm-sub external_directory (/q/sub/*)
sleep 1.2
XEOF
  sp_spawn --rights project
  wait_turn S001 1
  wait_state S001 frozen
  assert_eq "external_directory (/q/sub/*) (подагент)" "$(rec S001 Perm-Denied)"
  assert_contains "$(cat "$B/run/spawn/S001/activity.log")" "отказ в правах: read (/p/main.env); отказ в правах (подагент): external_directory (/q/sub/*)"
  assert_contains "$(brg spawn show S001)" "отказ в правах (подагент): external_directory (/q/sub/*)"
  sp_assert_clean
  # the main session's refusal in an early chunk is still the agent's
  sp_proj
  script 1 <<'XEOF'
perm read (/p/early.env)
sh sleep 4
sleep 1.2
XEOF
  sp_spawn --rights project
  wait_turn S001 1
  assert_eq "read (/p/early.env)" "$(rec S001 Perm-Denied)"
  sp_assert_clean
}

# the context — of the last step with tokens (a failed step with zeros keeps it); tokens of the
# main session and subagents apart; no cost when the provider has no prices; Last-Text-Turn
test_spawn_context_tokens_cost() {
  local o
  sp_proj
  script 1 <<'XEOF'
task bash .brigada/bin/brg who
stepzero
sleep 1.2
XEOF
  export FAKE_OC_COST=0
  sp_spawn
  unset FAKE_OC_COST
  wait_turn S001 1
  wait_for 25 rec_is S001 Tokens-Source export || fail "no export"
  assert_eq 118 "$(rec S001 Context)" "100+10+2+5+1 of the last step with tokens"
  assert_eq 300 "$(rec S001 Tokens-Main-In)" "3 steps with tokens"
  assert_eq 1000 "$(rec S001 Tokens-Sub-In)"
  assert_eq 1300 "$(rec S001 Tokens-In)"
  assert_eq 1 "$(rec S001 Last-Text-Turn)"
  o=$(brg spawn list)
  assert_contains "$o" "основная 300/30, подагенты 1000/100"
  assert_contains "$o" "контекст 118"
  assert_not_contains "$o" '$'
  assert_not_contains "$(brg spawn show S001)" "Cost:"
  brg board --once >/dev/null
  assert_contains "$(cat "$B/run/board/data.js")" '"context":118'
  assert_contains "$(cat "$B/run/board/data.js")" '"main_in":300,"main_out":30,"sub_in":1000,"sub_out":100'
  assert_contains "$(cat "$B/run/board/data.js")" '"last_text_turn":1'
  sp_assert_clean
}


# lines the supervisor writes itself during a turn (a change of rights) survive the next parse;
# the end line survives a kill -9 between it and the outcome in the record
test_spawn_own_lines_survive_parse() {
  local sp
  sp_proj
  script 1 <<'XEOF'
text начало
sh sleep 6
text конец
sleep 1.2
XEOF
  sp_spawn --rights project
  wait_for 20 act_has text "начало" || fail "no live line"
  brg spawn rights S001 full >/dev/null
  wait_for 10 act_has turn "права: full" || fail "no line on the rights"
  wait_turn S001 1
  wait_state S001 frozen
  assert_eq 1 "$(count_act turn 'права: full')" "the line on the rights survives the parses"
  assert_eq 1 "$(count_act text 'конец')"
  sp_assert_clean
  sp_proj
  script 1 <<'XEOF'
text один
sleep 1.2
XEOF
  export BRG_SPAWN_TEST_DELAY_END=5
  sp_spawn
  unset BRG_SPAWN_TEST_DELAY_END
  wait_for 25 act_has end "ход 1:" || fail "no end line"
  assert_eq running "$(rec S001 State)"
  sp=$(sv_pid S001)
  kill -KILL "$sp" # asleep between the end line and the outcome
  sleep 0.5
  brg spawn wake S001 >/dev/null
  wait_for 40 rec_is S001 Turn-Result ok || fail "no outcome after the recovery"
  assert_eq 1 "$(count_act end 'ход 1:')" "the end line is not cut off, not twice"
  assert_eq 1 "$(count_act text 'один')"
  sp_assert_clean
}

# the main session after an export = the export + the stream since its START: a turn that passed
# while the export ran is not lost
test_spawn_export_stream_snapshot() {
  sp_proj
  script <<'XEOF'
sleep 1.2
XEOF
  export FAKE_OC_EXPORT_SLEEP=4
  sp_spawn
  unset FAKE_OC_EXPORT_SLEEP
  wait_turn S001 1
  wait_for 20 [ -d "$FK/export.1" ] || fail "no export"
  brg say --to opencode-1 "ещё ход, пока идёт экспорт" >/dev/null
  wait_turn S001 2
  wait_for 25 rec_is S001 Tokens-Source export || fail "no export result"
  sleep 1
  assert_eq 400 "$(rec S001 Tokens-Main-In)" "2 turns × 2 steps: the turn during the export is counted"
  sp_assert_clean
}

# 27. after all of it: no live pid from turn.pid, turn.hb, the hb of the locks of any record
test_spawn_zz_nothing_left() {
  local b left= p
  for b in "$T_ROOT"/tmp.*/.brigada; do
    [ -d "$b/run/spawn" ] || continue
    for p in $(sp_pids "$b"); do kill -0 "$p" 2>/dev/null && left="$left $p"; done
  done
  [ -z "$left" ] || fail "alive after the tests:$left"
}

# spawn --model of the full 120 bytes: the join inside spawn keeps it whole — the profile and
# the record name the same model (the limits are one, nothing is cut silently)
test_spawn_model_120_bytes() {
  local m out
  sp_proj
  m=p/$(awk 'BEGIN { for (i = 0; i < 118; i++) printf "m" }')
  script 1 <<'EOF2'
sleep 0.2
EOF2
  sp_spawn --model "$m"
  assert_not_contains "$SPOUT" "обрезано"
  assert_eq "$m" "$(rec S001 Model)" "the record"
  assert_eq "$m" "$(hdr "$B/agents/opencode-1" Model)" "the profile"
  out=$(cd "$P" && bash "$BRG" spawn opencode --model "${m}x" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "--model длиннее 120 символов"
  wait_turn S001 1
}

# An old supervisor (the 0.9.2 code, from git) running when the project gets the current code:
# it serves the wake-up of its old wait (wait.res of the old code), then execs the current
# code with --continue, which takes over its record, and the next turns run on the new code.
# Skipped without git or without the 0.9.2 commit (a copy of the repository without history).
test_spawn_old_supervisor_execs_the_current_code() {
  local old sp
  old=$(git -C "$ROOT" show 699e45e:bin/brg 2>/dev/null) || {
    echo "SKIP: нет git или коммита 0.9.2"
    return 0
  }
  sp_proj
  printf '%s\n' "$old" >"$B/bin/brg.old" && mv "$B/bin/brg.old" "$B/bin/brg"
  printf '0.9.2\n' >"$B/VERSION"
  script 1 <<'EOF2'
sleep 1.2
EOF2
  sp_spawn
  wait_turn S001 1
  wait_state S001 frozen
  wait_for 15 [ -f "$B/run/wait/opencode-1.pid" ] || fail "no supervisor's wait (old code)"
  # the export of turn 1 is over: an export in progress holds the exec back (sv_maybe_exec)
  wait_for 25 rec_is S001 Tokens-Source export || fail "no export of turn 1"
  sp=$(sv_pid S001)
  # the update: the current code under another version
  sed 's/^BRG_VERSION=.*/BRG_VERSION=9.9.9-test/' "$ROOT/bin/brg" >"$B/bin/brg.new" && mv "$B/bin/brg.new" "$B/bin/brg"
  printf '9.9.9-test\n' >"$B/VERSION"
  script 2 <<'EOF2'
sleep 1.2
EOF2
  brg say --to opencode-1 "после обновления" >/dev/null
  wait_turn S001 2
  assert_contains "$(cat "$FK/run.2/prompt")" "после обновления" "the old wait's result was served"
  wait_for 20 grep -q 'надзор продолжает на новом коде' "$B/run/spawn/S001/supervisor.log" || fail "no exec: $(cat "$B/run/spawn/S001/supervisor.log")"
  wait_for 15 grep -q 'продолжает после обновления brg' "$B/run/spawn/S001/supervisor.log" || fail "the new image did not start"
  assert_eq "$sp" "$(sv_pid S001)" "the same supervisor (pid), the lock kept"
  wait_state S001 frozen
  sleep 1.2
  assert_eq 2 "$(runs)" "no rollback after exec"
  script 3 <<'EOF2'
sleep 1.2
EOF2
  brg say --to opencode-1 "на новом коде" >/dev/null
  wait_turn S001 3
  assert_contains "$(cat "$FK/run.3/prompt")" "на новом коде"
  assert_not_contains "$(cat "$FK/run.3/prompt")" "после обновления"
  wait_state S001 frozen
  brg spawn rm S001 >/dev/null
  wait_state S001 removed
  sp_assert_clean
}
