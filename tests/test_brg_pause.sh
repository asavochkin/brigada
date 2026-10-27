# The human's pause (DESIGN §9): unlike a stop it does not end the agent's turn. The
# agent keeps waiting, starts no new work (item add|claim|reassign, item review --start
# refuse; run and handing in work), and its wait wakes only for the human's messages and
# for the end of the pause, which delivers everything accumulated in that very wait.

. "$TESTS_DIR/brg_lib.sh"

# the first line of an agent command on a general pause
PAUSE_BANNER="── ПАУЗА: человек поставил на паузу бригаду. Новую работу не начинай; сдай сделанное и жди (wait)."

# three agents with empty inboxes and a task led by A (claude-1): A, Bn (codex-1), C (opencode-1)
paused_setup() {
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  C=$(join_as opencode)
  task_new_as "$A" "Пауза"
  D=$(tdir T001)
  ack_all "$A"
  ack_all "$Bn"
  ack_all "$C"
  for x in "$A" "$Bn" "$C"; do ack_all "$x" "$D"; done
}

# out_last N TEXT — the last N lines
out_last() { printf '%s\n' "$2" | tail -n "$1"; }

test_pause_and_resume_commands() {
  local out
  paused_setup
  out=$(brg pause)
  assert_eq 0 "$?"
  assert_contains "$out" "── ПАУЗА для всех"
  assert_contains "$out" "say паузу не снимает"
  assert_file_exists "$B/run/paused"
  assert_contains "$(metrics_of human pause)" "target=all"
  out=$(brg pause "${Bn%%.*}")
  assert_contains "$out" "── ПАУЗА для ${Bn%%.*}"
  assert_contains "$out" "Внимание: уже стоит общая пауза"
  assert_file_exists "$B/run/paused.${Bn%%.*}"
  out=$(brg pause "$C")
  assert_file_exists "$B/run/paused.${C%%.*}" "the key of a full name is dropped"
  out=$(brg pause nobody-1 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет такого агента: nobody-1"
  out=$(brg pause --bogus 2>&1)
  assert_eq 1 "$?"
  # who: the pause is shown, general and personal
  out=$(brg who)
  assert_contains "$out" "── ПАУЗА: бригада на паузе (снять: bash $BRG resume)"
  assert_contains "$out" "${Bn%%.*} · codex · m · работает (пауза)"
  # doctor lists the flags next to the stops
  out=$(brg doctor 2>&1)
  assert_contains "$out" "бригада на паузе (pause)"
  assert_contains "$out" "на паузе агенты: "
  # resume <name> lifts only that agent's own; the general pause stands — and says so
  out=$(brg resume "${Bn%%.*}")
  assert_contains "$out" "── пауза снята для ${Bn%%.*}."
  assert_contains "$out" "Стоит общая пауза — снять: bash $BRG resume"
  assert_file_not_exists "$B/run/paused.${Bn%%.*}"
  assert_file_exists "$B/run/paused"
  assert_file_exists "$B/run/paused.${C%%.*}"
  # plain resume lifts the general and all personal ones
  out=$(brg resume)
  assert_contains "$out" "── пауза снята."
  assert_not_contains "$out" "── стоп снят"
  assert_file_not_exists "$B/run/paused"
  assert_file_not_exists "$B/run/paused.${C%%.*}"
  out=$(brg resume)
  assert_contains "$out" "ни стопа, ни паузы не стояло"
  # both at once: both lines
  brg stop >/dev/null
  brg pause >/dev/null
  out=$(brg resume)
  assert_contains "$out" "── стоп снят."
  assert_contains "$out" "── пауза снята."
  assert_contains "$(metrics_of human resume)" "target=all"
}

# work_refuse: item add|claim|reassign and item review --start; NEXT is wait (the agent
# keeps its loop); handing in, talking and run still work; the banner is the first line
test_pause_refuses_starting_work_but_not_the_rest() {
  local out
  paused_setup
  printf 'о\n' | brg item add --as "$A" --title "Первая" >/dev/null || fail add1
  printf 'о\n' | brg item add --as "$A" --title "Вторая" >/dev/null || fail add2
  printf 'о\n' | brg item add --as "$A" --title "Третья" >/dev/null || fail add3
  brg item claim I3 --as "$Bn" --paths none >/dev/null || fail claim3
  brg item claim I1 --as "$Bn" --paths src >/dev/null || fail claim
  brg pause >/dev/null
  out=$(brg item claim I2 --as "$Bn" --paths lib 2>&1)
  assert_eq 1 "$?"
  assert_eq "$PAUSE_BANNER" "$(printf '%s\n' "$out" | head -n 1)"
  assert_contains "$out" "── ОШИБКА: человек поставил на паузу бригаду — item claim не выполнено: на паузе новую работу не начинают"
  assert_contains "$out" "Паузу снимает человек: brg resume или с доски; сообщение (say) её не снимает"
  assert_eq "── NEXT: bash $BRG wait --as $Bn --busy \"I001\"" "$(out_last 1 "$out")" "the NEXT is wait (with the mark that stands), not 'end the turn'"
  assert_eq todo "$(hdr "$D/items/I002" Status)"
  out=$(printf 'о\n' | brg item add --as "$Bn" --title "Новая" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "item add не выполнено: на паузе"
  assert_file_not_exists "$D/items/I004"
  out=$(brg item reassign I1 --as "$A" --to "${C%%.*}" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "item reassign не выполнено: на паузе"
  out=$(brg item review I1 --as "$C" --start 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "item review --start не выполнено: на паузе"
  assert_eq "" "$(hdr "$D/items/I001" Reviewing)"
  # the rest works (with the banner): the subagent's check of the work already begun (run),
  # handing in, talking, reading
  out=$(brg run --as "$Bn" --sync -- true 2>&1)
  assert_eq 0 "$?" "run is allowed on a pause: $out"
  assert_eq "$PAUSE_BANNER" "$(printf '%s\n' "$out" | head -n 1)"
  out=$(printf 'сдаю\n' | brg send --as "$Bn" --to "${A%%.*}")
  assert_eq 0 "$?"
  assert_eq "$PAUSE_BANNER" "$(printf '%s\n' "$out" | head -n 1)"
  out=$(brg item done I1 --as "$Bn" --note "готово")
  assert_eq 0 "$?" "item done is allowed on a pause"
  assert_eq "$PAUSE_BANNER" "$(printf '%s\n' "$out" | head -n 1)"
  out=$(brg item list --as "$Bn")
  assert_eq "$PAUSE_BANNER" "$(printf '%s\n' "$out" | head -n 1)"
  out=$(brg item release I3 --as "$Bn" 2>&1)
  assert_eq 0 "$?" "release is allowed: $out"
  # wait and status tell about the pause themselves — no banner line before
  out=$(brg status --as "$Bn")
  assert_not_contains "$(printf '%s\n' "$out" | head -n 1)" "── ПАУЗА"
  assert_contains "$out" "── ПАУЗА: человек поставил на паузу бригаду."
  assert_eq "── NEXT: bash $BRG wait --as $Bn" "$(out_last 1 "$out")"
  assert_eq 1 "$(printf '%s\n' "$out" | awk '/^── ПАУЗА/ { n++ } END { print n + 0 }')" "status: the pause once"
  # a personal pause: only that agent; STOP is the stronger banner
  brg resume >/dev/null
  brg pause "${C%%.*}" >/dev/null
  out=$(brg item claim I2 --as "$C" --paths lib 2>&1)
  assert_eq 1 "$?"
  assert_eq "── ПАУЗА: человек поставил на паузу тебя (${C%%.*}). Новую работу не начинай; сдай сделанное и жди (wait)." "$(printf '%s\n' "$out" | head -n 1)"
  out=$(brg item claim I2 --as "$Bn" --paths lib)
  assert_eq 0 "$?" "other agents work"
  assert_not_contains "$out" "ПАУЗА"
  brg stop "${C%%.*}" >/dev/null
  out=$(brg item claim I1 --as "$C" --paths none 2>&1)
  assert_contains "$out" "── STOP: человек остановил тебя"
  assert_not_contains "$out" "ПАУЗА:"
  assert_contains "$out" "item claim не выполнено: при стопе"
  assert_contains "$out" "── NEXT: заверши ход"
}

# join tells the newcomer; a returning agent too
test_pause_join_and_who_notes() {
  local out
  paused_setup
  brg pause >/dev/null
  out=$(brg join --harness codex --model m)
  assert_contains "$out" "ВНИМАНИЕ: бригада на паузе (человек): новую работу не начинай, жди в wait"
  brg resume >/dev/null
  brg pause "${A%%.*}" >/dev/null
  out=$(brg status --as "$A")
  assert_contains "$out" "── ПАУЗА: человек поставил на паузу тебя (${A%%.*})."
  out=$(brg who)
  assert_contains "$out" "${A%%.*} · claude · m · работает (пауза)"
  assert_not_contains "$(printf '%s\n' "$out" | awk '/^── ПАУЗА/')" "бригада на паузе"
}

# While the pause stands only the human wakes the wait; what the agents wrote comes with
# his message (everything accumulated, nothing filtered), with a line before NEXT.
test_pause_only_the_human_wakes() {
  local out
  paused_setup
  export BRG_TICK=0.2
  brg pause >/dev/null
  start_wait "$A" "$P/wa" --timeout 20
  send_as "$Bn" "от агента: раз" --to "${A%%.*}"
  send_as "$C" "от агента: два" --to all
  sleep 1
  is_alive "$WP" || fail "the wait woke for an agent's message: $(cat "$P/wa")"
  brg say --to "${A%%.*}" "ответ человека" >/dev/null
  wait_pid "$WP" 3 || fail "the human's message did not wake the paused wait"
  out=$(cat "$P/wa")
  assert_contains "$out" "от агента: раз"
  assert_contains "$out" "от агента: два"
  assert_contains "$out" "ответ человека"
  assert_contains "$out" "→ ${A%%.*}"
  assert_eq "── NEXT: обработай, затем: bash $BRG wait --as $A --timeout 20" "$(out_last 1 "$out")"
  assert_eq "пауза продолжается: отвечай человеку, новую работу не начинай" "$(out_last 2 "$out" | head -n 1)"
  # the delivered batch is acknowledged by the next wait; the pause timeout names the pause
  out=$(brg wait --as "$A" --timeout 1)
  assert_eq "── пауза · нет новых от человека (1 с) · ход не завершай · NEXT: bash $BRG wait --as $A --timeout 1" "$out"
  assert_contains "$(metrics_of "$A" wait)" "result=timeout"
  # a message from the human to another agent does not wake this one
  start_wait "$A" "$P/wa2" --timeout 20
  brg say --to "${Bn%%.*}" "не тебе" >/dev/null
  sleep 1
  is_alive "$WP" || fail "the wait woke for a message to another agent: $(cat "$P/wa2")"
  kill -TERM "$WP"
  wait_pid "$WP" 3 || fail "wait hung"
}

# The end of the pause wakes the wait at once, with «пауза снята» and everything the agents
# wrote meanwhile in that same wait (pass 1 of the paused ticks had moved CH_SEEN past it).
test_pause_lift_delivers_accumulated_in_the_same_wait() {
  local out
  paused_setup
  export BRG_TICK=0.2
  brg pause >/dev/null
  start_wait "$A" "$P/wa" --timeout 20
  send_as "$Bn" "накопилось: раз" --to "${A%%.*}"
  send_as "$C" "накопилось: два" --to all
  sleep 1
  is_alive "$WP" || fail "woke on a pause"
  brg resume >/dev/null
  wait_pid "$WP" 3 || fail "the end of the pause did not wake the wait"
  out=$(cat "$P/wa")
  assert_eq "── пауза снята: человек снял паузу — новую работу можно начинать." "$(printf '%s\n' "$out" | head -n 1)"
  assert_contains "$out" "накопилось: раз"
  assert_contains "$out" "накопилось: два"
  assert_not_contains "$out" "пауза продолжается"
  assert_eq "── NEXT: обработай, затем: bash $BRG wait --as $A --timeout 20" "$(out_last 1 "$out")"
  assert_contains "$(metrics_of "$A" wait)" "result=msg"
  # nothing accumulated: only the line and NEXT
  out=$(brg wait --as "$A" --timeout 0)
  brg pause >/dev/null
  start_wait "$A" "$P/wa2" --timeout 20
  sleep 0.6
  brg resume >/dev/null
  wait_pid "$WP" 3 || fail "empty lift: no wake"
  assert_eq "── пауза снята: человек снял паузу — новую работу можно начинать.
── NEXT: обработай, затем: bash $BRG wait --as $A --timeout 20" "$(cat "$P/wa2")"
  assert_contains "$(metrics_of "$A" wait)" "result=pause_end"
  # a wait started on the pause ends the same way when the pause is lifted before the first tick
  brg pause >/dev/null
  start_wait "$A" "$P/wa3" --timeout 20
  send_as "$Bn" "позднее" --to "${A%%.*}"
  sleep 0.6
  brg resume >/dev/null
  wait_pid "$WP" 3 || fail "no wake"
  assert_contains "$(cat "$P/wa3")" "позднее"
  assert_eq "── пауза снята: человек снял паузу — новую работу можно начинать." "$(head -n 1 "$P/wa3")"
}

# A personal pause: only that agent waits on it; the others are woken as usual, and
# resume <name> ends it.
test_pause_personal_affects_only_that_agent() {
  local out
  paused_setup
  export BRG_TICK=0.2
  brg pause "${A%%.*}" >/dev/null
  start_wait "$A" "$P/wa" --timeout 20
  start_wait "$Bn" "$P/wb" --timeout 20
  pb=$WP
  pa=$(cat "$B/run/wait/${A%%.*}.pid")
  send_as "$C" "всем" --to all
  wait_pid "$pb" 3 || fail "an agent not on pause was not woken"
  assert_contains "$(cat "$P/wb")" "всем"
  sleep 0.6
  is_alive "$pa" || fail "the paused agent woke: $(cat "$P/wa")"
  brg resume "${A%%.*}" >/dev/null
  wait_for 3 is_dead "$pa" || fail "resume <name> did not end the pause"
  assert_contains "$(cat "$P/wa")" "── пауза снята"
  assert_contains "$(cat "$P/wa")" "всем"
}

# A deadline summary does not wake a paused wait, and its marker is not claimed beforehand;
# it comes with the batch that wakes (the human's message / the end of the pause).
test_pause_deadline_does_not_wake() {
  local out
  paused_setup
  export BRG_TICK=0.2
  printf 'вопрос\n' | brg send --as "$A" --to "${Bn%%.*}" --reply-by 1s >/dev/null || fail send
  brg pause >/dev/null
  sleep 2.2 # the deadline is over
  out=$(brg wait --as "$A" --timeout 1)
  assert_eq "── пауза · нет новых от человека (1 с) · ход не завершай · NEXT: bash $BRG wait --as $A --timeout 1" "$out"
  [ -z "$(ls "$B/run/deadlines/" 2>/dev/null | awk '/\.done$/')" ] || fail "the marker was claimed on a pause: $(ls "$B/run/deadlines/")"
  # the human's message wakes: the summary is in that batch
  start_wait "$A" "$P/wa" --timeout 20
  brg say --to "${A%%.*}" "слово человека" >/dev/null
  wait_pid "$WP" 3 || fail "no wake"
  out=$(cat "$P/wa")
  assert_contains "$out" "── дедлайн по #1 ("
  assert_contains "$out" "слово человека"
  # and at the end of the pause (another deadline)
  printf 'вопрос 2\n' | brg send --as "$A" --to "${Bn%%.*}" --reply-by 1s >/dev/null || fail send2
  sleep 2.2
  start_wait "$A" "$P/wa2" --timeout 20
  brg resume >/dev/null
  wait_pid "$WP" 3 || fail "no wake on resume"
  out=$(cat "$P/wa2")
  assert_contains "$out" "── дедлайн по #"
  assert_contains "$out" "ответили:"
}

# What the system addressed to the agent (the result of its run) waits for the end of the pause.
test_pause_run_result_waits_for_the_end() {
  local out
  paused_setup
  export BRG_TICK=0.2
  brg pause >/dev/null
  start_wait "$A" "$P/wa" --timeout 20
  out=$(brg run --as "$A" -- true 2>&1)
  assert_contains "$out" "R001"
  wait_for 8 awk '/^Status: done/ { f = 1 } END { exit !f }' "$D/shared/runs/R001" || fail "the run did not finish"
  sleep 0.6
  is_alive "$WP" || fail "the run result woke a paused wait: $(cat "$P/wa")"
  brg resume >/dev/null
  wait_pid "$WP" 3 || fail "no wake on resume"
  out=$(cat "$P/wa")
  assert_contains "$out" "[система] brg → ${A%%.*}"
  assert_contains "$out" "R001"
}

# The cap of the output on a pause: the rest comes after the pause or with the next message of the human
test_pause_output_cap_text() {
  local i out
  paused_setup
  printf 'wait_output_max: 500\n' >>"$B/config"
  export BRG_TICK=0.2
  brg pause >/dev/null
  start_wait "$A" "$P/wa" --timeout 20
  i=1
  while [ $i -le 3 ]; do
    send_as "$Bn" "агент $i: $(awk 'BEGIN { for (i = 0; i < 120; i++) printf "x" }')" --to "${A%%.*}"
    i=$((i + 1))
  done
  brg say --to "${A%%.*}" "человек" >/dev/null
  wait_pid "$WP" 3 || fail "no wake"
  out=$(cat "$P/wa")
  assert_contains "$out" "не вошло (лимит вывода): придут после снятия паузы или со следующим сообщением человека; посмотреть:"
  assert_not_contains "$out" "придут следующим wait сразу"
}

# say does not lift the pause (it only wakes the waits); an agent's task new is refused under
# the general pause and its own one (another agent's does not matter); the human's lifts the
# general pause (DESIGN §6, §9)
test_pause_say_keeps_it_and_task_new_is_refused() {
  local out
  paused_setup
  brg pause >/dev/null
  out=$(brg say "привет")
  assert_contains "$out" "Стоит общая пауза: сообщение разбудило ждущих, но пауза не снята"
  assert_file_exists "$B/run/paused"
  brg resume >/dev/null
  brg pause "${Bn%%.*}" >/dev/null
  out=$(brg say --to "${Bn%%.*}" "лично")
  assert_contains "$out" "На паузе: ${Bn%%.*} — сообщение их разбудило, но пауза не снята"
  assert_file_exists "$B/run/paused.${Bn%%.*}"
  brg task cancel --as human >/dev/null || fail cancel
  # another agent's pause does not block
  out=$(printf 'x\n' | brg task new --as "$A" --title "Чужая пауза")
  assert_eq 0 "$?" "another agent's pause does not block"
  assert_file_exists "$B/run/paused.${Bn%%.*}"
  brg task cancel --as human >/dev/null || fail cancel2
  # the general pause
  brg pause >/dev/null
  out=$(printf 'x\n' | brg task new --as "$A" --title "После паузы" 2>&1)
  assert_eq 1 "$?" "refused under the general pause"
  assert_eq "── ПАУЗА: человек поставил на паузу бригаду. Новую работу не начинай; сдай сделанное и жди (wait)." "$(printf '%s\n' "$out" | head -n 1)"
  assert_contains "$out" "── ОШИБКА: человек поставил на паузу бригаду — task new не выполнено: на паузе задачу не создают, паузу снимает только человек"
  assert_contains "$out" "снять паузу — brg resume, или дать задачу самому — task new --as human, или с доски (brg board)."
  assert_eq "── NEXT: скажи человеку в чате, что задачу не создать, пока стоит пауза; затем bash $BRG wait --as $A" "$(printf '%s\n' "$out" | tail -n 1)"
  assert_file_exists "$B/run/paused"
  assert_file_not_exists "$B/tasks/active"
  # the author's own pause
  brg resume >/dev/null
  brg pause "${A%%.*}" >/dev/null
  out=$(printf 'x\n' | brg task new --as "$A" --title "После паузы" 2>&1)
  assert_contains "$out" "── ОШИБКА: человек поставил на паузу тебя (${A%%.*}) — task new не выполнено"
  assert_contains "$out" "снять твою паузу — brg resume ${A%%.*}."
  assert_file_exists "$B/run/paused.${A%%.*}"
  # the human's task lifts the general pause only
  brg pause >/dev/null
  out=$(printf 'x\n' | brg task new --as human --title "От человека")
  assert_eq 0 "$?"
  assert_contains "$out" "Общая пауза снята."
  assert_file_not_exists "$B/run/paused"
  assert_file_exists "$B/run/paused.${A%%.*}" "personal pauses stay"
}

# The human's own commands that wake a paused wait: say, task cancel --as human, lead give --as human
test_pause_human_commands_wake() {
  local out w
  paused_setup
  export BRG_TICK=0.2
  brg pause >/dev/null
  start_wait "$Bn" "$P/wb" --timeout 20
  brg lead give "${Bn%%.*}" --as human >/dev/null || fail "lead give"
  wait_pid "$WP" 3 || fail "lead give --as human did not wake a paused wait"
  assert_contains "$(cat "$P/wb")" "lead задачи T001: ${A%%.*} → ${Bn%%.*} (передал human)"
  start_wait "$Bn" "$P/wb2" --timeout 20
  brg task cancel --as human >/dev/null || fail "cancel"
  wait_pid "$WP" 3 || fail "task cancel --as human did not wake a paused wait"
  assert_contains "$(cat "$P/wb2")" "прекрати правки"
}

# The snapshot of the board carries the pause (the page shows a banner / a chip)
test_pause_in_the_board_snapshot() {
  local out
  paused_setup
  brg board --once >/dev/null
  out=$(cat "$B/run/board/data.js")
  assert_contains "$out" '"pause":false'
  assert_contains "$out" '"paused":false'
  brg pause >/dev/null
  brg pause "${Bn%%.*}" >/dev/null
  brg board --once >/dev/null
  out=$(cat "$B/run/board/data.js")
  assert_contains "$out" '"pause":true'
  assert_contains "$out" '"name":"codex-1"'
  case $out in *'"name":"codex-1"'*'"paused":true'*) ;; *) fail "no personal pause of codex-1 in the snapshot" ;; esac
}

# A general pause lets an agent take the empty Lead (the role starts no work), but the
# announcement wakes nobody; it comes after the pause with everything else
test_pause_self_assigned_lead_is_announced_after_the_pause() {
  local out pa pb
  paused_setup
  export BRG_TICK=0.2
  dropped "$A"
  dropped "$Bn"
  dropped "$C"
  brg task cancel --as human >/dev/null || fail cancel
  printf 'x\n' | brg task new --as human --title "Пустая" >/dev/null || fail "task new"
  assert_eq "" "$(hdr "$(tdir T002)/task" Lead)"
  ack_all "$A"
  ack_all "$Bn"
  ack_all "$A" "$(tdir T002)"
  ack_all "$Bn" "$(tdir T002)"
  brg pause >/dev/null
  start_wait "$A" "$P/wa" --timeout 20
  pa=$WP
  start_wait "$Bn" "$P/wb" --timeout 20
  pb=$WP
  assert_eq "${A%%.*}" "$(hdr "$(tdir T002)/task" Lead)" "the first wait took the lead on a general pause"
  sleep 0.8
  is_alive "$pa" || fail "the announcement woke the new lead on a pause: $(cat "$P/wa")"
  is_alive "$pb" || fail "the announcement woke another agent on a pause: $(cat "$P/wb")"
  brg resume >/dev/null
  wait_pid "$pa" 3 || fail "A: no wake on resume"
  wait_pid "$pb" 3 || fail "B: no wake on resume"
  assert_contains "$(cat "$P/wa")" "${A%%.*} — lead задачи T002 (назначен brg: первый на связи)"
  assert_contains "$(cat "$P/wb")" "${A%%.*} — lead задачи T002"
  assert_eq "── пауза снята: человек снял паузу — новую работу можно начинать." "$(head -n 1 "$P/wb")"
}
