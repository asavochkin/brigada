# Tasks (new/close/cancel/show/list), the task channel, roles, join --as.

. "$TESTS_DIR/brg_lib.sh"

# three agents with empty inboxes: A (claude-1), Bn (codex-1), C (opencode-1)
three_agents() {
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  C=$(join_as opencode)
  ack_all "$A"
  ack_all "$Bn"
  ack_all "$C"
}

test_task_new_layout_brief_and_lobby_notice() {
  local out d brief
  three_agents
  brief='Логин падает при пустом пароле: $HOME и `x` — дословно.

Почини и добавь тест.'
  out=$(brg task new --as "$A" --title "Починить логин в Auth-Module!" <<BRG_EOF
$brief
BRG_EOF
)
  assert_eq 0 "$?" "exit code"
  assert_contains "$out" "── создана задача T001 «Починить логин в Auth-Module!»: ты host и lead."
  assert_contains "$out" "Каталог: .brigada/tasks/T001-auth-module/"
  assert_eq "── NEXT: продолжай; закончив шаг — bash $BRG wait --as $A" "$(printf '%s\n' "$out" | tail -n 1)"
  d=$B/tasks/T001-auth-module
  for x in messages cursors items reservations shared; do
    [ -d "$d/$x" ] || fail "нет $x"
  done
  assert_eq "$brief" "$(cat "$d/brief.md")" "brief verbatim"
  assert_eq 0 "$(cat "$d/seq")"
  assert_eq T001-auth-module "$(cat "$B/tasks/active")"
  assert_eq T001 "$(hdr "$d/task" Id)"
  assert_eq "Починить логин в Auth-Module!" "$(hdr "$d/task" Title)"
  assert_eq active "$(hdr "$d/task" Status)"
  assert_eq "${A%%.*}" "$(hdr "$d/task" Host)"
  assert_eq "${A%%.*}" "$(hdr "$d/task" Lead)"
  assert_eq "${A%%.*}" "$(hdr "$d/task" Created-By)"
  # the announcement: lobby, system, to all, wakes
  f=$(msg_file 4)
  assert_eq system "$(hdr "$f" Kind)"
  assert_eq "${A%%.*}" "$(hdr "$f" From)"
  assert_eq all "$(hdr "$f" To)"
  assert_eq "" "$(hdr "$f" Wake)"
  assert_contains "$(cat "$f")" "новая задача T001: «Починить логин в Auth-Module!» · host и lead: ${A%%.*}. Прочитай постановку: .brigada/tasks/T001-auth-module/brief.md"
  assert_contains "$(metrics_of "$A" task.new)" "id=T001 cancel_current=0"
}

test_task_slug_and_title_rules() {
  local out
  new_proj
  A=$(join_as claude)
  task_new_as "$A" "Только кириллица"
  assert_eq T001 "$(cat "$B/tasks/active")" "empty slug → bare id"
  [ -f "$B/tasks/T001/task" ] || fail "no tasks/T001"
  out=$(printf 'x\n' | brg task new --as "$A" --title "   " 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нужен --title"
  # a too long title is not refused: cut (at a UTF-8 boundary) and marked, with a warning
  out=$(printf 'x\n' | brg task new --as "$A" --cancel-current --title "a$(awk 'BEGIN { for (i = 0; i < 300; i++) printf "щ" }')" 2>&1)
  assert_eq 0 "$?"
  assert_contains "$out" "Внимание: --title длиннее 200 байт (601) — сохранено обрезанным, с пометкой «…(обрезано)». Подробности — в постановке."
  assert_eq "a$(awk 'BEGIN { for (i = 0; i < 88; i++) printf "щ" }') …(обрезано)" "$(hdr "$(tdir T002)/task" Title)"
  out=$(brg task new --as "$A" --title "t" </dev/null 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "пустая постановка"
  out=$(printf 'x\n' | brg task new --title "t" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нужно имя агента"
  # a brief larger than a message is fine (up to 64 KB)
  awk 'BEGIN { for (i = 0; i < 300; i++) print "строка постановки номер " i }' >"$P/brief.txt"
  out=$(brg task new --as "$A" --title "Большая постановка" --cancel-current --file "$P/brief.txt")
  assert_contains "$out" "── создана задача T003 «Большая постановка»"
  assert_eq "$(cat "$P/brief.txt")" "$(cat "$(tdir T003)/brief.md")"
}

# After task new both waiting agents get the system
# message within one wait cycle, and their next wait listens to the task channel.
test_task_new_reaches_both_waiting_agents() {
  local pb pc t0 t1 out
  three_agents
  export BRG_TICK=0.2
  start_wait "$Bn" "$P/wb" --timeout 20
  pb=$WP
  start_wait "$C" "$P/wc" --timeout 20
  pc=$WP
  t0=$(date -u +%s)
  task_new_as "$A" "Общая задача"
  wait_pid $pb 3 || fail "B's wait did not return"
  wait_pid $pc 3 || fail "C's wait did not return"
  t1=$(date -u +%s)
  [ $((t1 - t0)) -le 2 ] || fail "slow: $((t1 - t0)) s"
  for x in wb wc; do
    assert_contains "$(cat "$P/$x")" "── lobby · 1 новое"
    assert_contains "$(cat "$P/$x")" "[система] ${A%%.*} → all"
    assert_contains "$(cat "$P/$x")" "новая задача T001: «Общая задача»"
  done
  # the next wait listens to T001 too, from the start of the channel
  send_as "$A" "суть задачи для всех"
  assert_eq T001 "$(hdr "$(tmsg T001 1)" Channel)" "send goes to the task by default"
  out=$(brg wait --as "$Bn" --timeout 2)
  assert_contains "$out" "── T001 · 1 новое"
  assert_contains "$out" "#1 ${A%%.*} → all"
  assert_contains "$out" "  суть задачи для всех"
  assert_eq "0/1" "$(tcursor "$Bn" T001)"
  out=$(brg wait --as "$C" --timeout 2)
  assert_contains "$out" "  суть задачи для всех"
}

# A running wait picks up the new channel set when the task appears/disappears.
test_running_wait_switches_channels() {
  local out
  three_agents
  export BRG_TICK=0.2
  task_new_as "$A" "Первая"
  brg wait --as "$Bn" --timeout 0 >/dev/null # "новая задача"
  start_wait "$Bn" "$P/wb" --timeout 20
  printf 'итог\n' >"$(tdir T001)/summary.md"
  brg task close --as "$A" >/dev/null || fail "close"
  wait_pid $WP 3 || fail "wait did not return on close"
  assert_contains "$(cat "$P/wb")" "задача T001 «Первая» закрыта (lead ${A%%.*}). Итог: итог."
  # after close: lobby only; send defaults to lobby
  out=$(printf 'в лобби\n' | brg send --as "$A")
  assert_contains "$out" "→ all (lobby)"
  out=$(printf 'x\n' | brg send --as "$A" --channel T001 2>&1)
  assert_eq 1 "$?" "closed task channel is not writable"
  assert_contains "$out" "задача T001 не активна (done)"
  assert_contains "$(brg wait --as "$Bn" --timeout 1)" "  в лобби"
}

test_second_task_refused_then_cancel_current() {
  local out d1 h
  three_agents
  task_new_as "$A" "Первая задача"
  d1=$(tdir T001)
  printf 'x\n' >"$d1/reservations/fake"
  out=$(printf 'другая\n' | brg task new --as "$Bn" --title "Вторая" 2>&1)
  assert_eq 1 "$?" "second task without --cancel-current"
  assert_contains "$out" "уже есть активная задача T001 «Первая задача» (host ${A%%.*}, lead ${A%%.*})"
  assert_contains "$out" "--cancel-current"
  assert_contains "$out" "── NEXT:"
  assert_eq T001 "$(cat "$B/tasks/active")"
  assert_eq "" "$(ls "$B/tasks" | awk '/^T002/')" "nothing created"
  out=$(printf 'другая\n' | brg task new --as "$Bn" --title "Вторая" --cancel-current)
  assert_contains "$out" "── задача T001 отменена: всем отправлено «прекрати правки»."
  assert_contains "$out" "── создана задача T002 «Вторая»"
  assert_eq cancelled "$(hdr "$d1/task" Status)"
  assert_eq "${Bn%%.*}" "$(hdr "$d1/task" Closed-By)"
  assert_eq "" "$(ls -A "$d1/reservations")" "reservations released"
  assert_eq "$(basename "$(tdir T002)")" "$(cat "$B/tasks/active")"
  h=$(cat "$B/common/history.md")
  assert_contains "$h" "- T001 · cancelled · «Первая задача» · "
  assert_contains "$h" " · host ${A%%.*} · lead ${A%%.*} · отменил ${Bn%%.*} · итог: — · .brigada/tasks/T001/"
  # C gets "cancelled" first, then "new task", in one batch
  out=$(brg wait --as "$C" --timeout 1)
  assert_contains "$out" "── lobby · 3 новых"
  assert_contains "$out" "задача T001 «Первая задача» отменена (${Bn%%.*}): прекрати правки, не продолжай работу по ней."
  assert_contains "$out" "новая задача T002: «Вторая» · host и lead: ${Bn%%.*}"
  case $out in *"отменена"*"новая задача T002"*) ;; *) fail "order: $out" ;; esac
}

test_task_close_rules_and_history() {
  local out d h
  three_agents
  task_new_as "$A" "Закрываемая"
  d=$(tdir T001)
  out=$(brg task close --as "$Bn" 2>&1)
  assert_eq 1 "$?" "close by non-lead"
  assert_contains "$out" "закрыть задачу T001 может только lead (${A%%.*})"
  out=$(brg task close --as "$A" 2>&1)
  assert_eq 1 "$?" "close without summary.md"
  assert_contains "$out" "нет итога: .brigada/tasks/T001/summary.md пуст или не создан"
  assert_contains "$out" "── NEXT:"
  printf '\n  \n\t\n' >"$d/summary.md"
  out=$(brg task close --as "$A" 2>&1)
  assert_eq 1 "$?" "close with a blank summary.md"
  assert_eq active "$(hdr "$d/task" Status)"
  printf '# Итог\n\n**Логин чинится:** пустой пароль отвергается.\n\nПодробности…\n' >"$d/summary.md"
  out=$(brg task close --as "$A")
  assert_eq 0 "$?"
  assert_contains "$out" "── задача T001 «Закрываемая» закрыта."
  assert_eq "── NEXT: bash $BRG wait --as $A" "$(printf '%s\n' "$out" | tail -n 1)"
  assert_eq done "$(hdr "$d/task" Status)"
  assert_eq "${A%%.*}" "$(hdr "$d/task" Closed-By)"
  assert_file_not_exists "$B/tasks/active"
  h=$(cat "$B/common/history.md")
  assert_contains "$h" "# История задач"
  assert_contains "$h" "- T001 · done · «Закрываемая» · $(hdr "$d/task" Created) → $(hdr "$d/task" Closed) · host ${A%%.*} · lead ${A%%.*} · итог: Логин чинится:** пустой пароль отвергается. · .brigada/tasks/T001/summary.md"
  assert_contains "$(brg wait --as "$C" --timeout 1)" "задача T001 «Закрываемая» закрыта (lead ${A%%.*}). Итог: Логин чинится:** пустой пароль отвергается."
  out=$(brg task close --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет активной задачи"
  # claimed items block closing unless --force
  task_new_as "$A" "С подзадачей"
  d=$(tdir T002)
  printf 'Id: I001\nStatus: claimed\n\nтело\n' >"$d/items/I001"
  printf 'итог\n' >"$d/summary.md"
  out=$(brg task close --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "подзадачи ещё в работе (claimed): I001"
  out=$(brg task close --as "$A" --force)
  assert_contains "$out" "закрыта с --force; подзадачи I001 отменены"
  assert_eq cancelled "$(hdr "$d/items/I001" Status)"
  assert_eq 2 "$(awk '/^- T00/' "$B/common/history.md" | wc -l | tr -d ' ')"
}

# task close and the lead's unread mail — "refusal = delivery" (DESIGN §6): what
# would wake the lead's wait is shown by close itself (stdout, before the summary.md
# check) and counts as delivered: Pending moves, Acked stays; the repeated close
# passes; the next wait does not repeat it. Quiet and own messages do not block.
test_close_shows_unread_mail_and_refuses() {
  local out d
  three_agents
  task_new_as "$A" "Закрытие"
  d=$(tdir T001)
  for x in "$A" "$Bn" "$C"; do ack_all "$x" "$d"; done
  printf 'о\n' | brg item add --as "$A" --title "Своя" >/dev/null || fail add
  send_as "$A" "моё всем"
  brg item claim I1 --as "$Bn" --paths src >/dev/null || fail claim # quiet notice
  out=$(brg task close --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет итога" "own and quiet messages do not block"
  assert_eq "0/0" "$(tcursor "$A" T001)" "nothing issued"
  # a personal message to the lead: shown on stdout, refused before summary.md
  send_as "$Bn" "важное: разброс по сидам" --to "${A%%.*}"
  brg task close --as "$A" >"$P/o" 2>"$P/e"
  assert_eq 1 "$?"
  out=$(cat "$P/o")
  assert_contains "$out" "── T001 · 2 новых"
  assert_contains "$out" "${Bn%%.*} взял I001" "quiet ones come along"
  assert_contains "$out" "#4 ${Bn%%.*} → ${A%%.*}"
  assert_contains "$out" "  важное: разброс по сидам"
  assert_not_contains "$out" "моё всем"
  out=$(cat "$P/e")
  assert_contains "$out" "── ОШИБКА: задача T001 не закрыта: тебе пришли сообщения (выше, 2) — учти их и повтори task close"
  assert_not_contains "$out" "нет итога" "the unread check comes first"
  assert_eq "── NEXT: учти сообщения выше (ответь, если нужно; поправь summary.md), затем повтори: bash $BRG task close --as $A" "$(printf '%s\n' "$out" | tail -n 1)"
  assert_eq "0/4" "$(tcursor "$A" T001)" "Pending moved, Acked kept"
  assert_contains "$(metrics_of "$A" task.close.unread)" "shown=2"
  # the next wait confirms the shown batch and does not repeat it
  out=$(brg wait --as "$A" --timeout 0)
  assert_contains "$out" "── нет новых"
  assert_not_contains "$out" "разброс по сидам"
  assert_eq "4/4" "$(tcursor "$A" T001)"
  # shown = delivered: the repeat goes on to the next check
  out=$(brg task close --as "$A" 2>&1)
  assert_contains "$out" "нет итога"
  # --force does not skip it
  printf 'итог\n' >"$d/summary.md"
  send_as "$C" "ещё одно"
  out=$(brg task close --as "$A" --force 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "  ещё одно"
  assert_contains "$out" "затем повтори: bash $BRG task close --as $A --force"
  assert_eq active "$(hdr "$d/task" Status)"
  # item done wakes the lead: one more refusal, then close passes
  brg item done I1 --as "$Bn" --note "готово" >/dev/null || fail done
  out=$(brg task close --as "$A" --force 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "завершил I001 «Своя»: готово"
  out=$(brg task close --as "$A")
  assert_eq 0 "$?"
  assert_contains "$out" "── задача T001 «Закрытие» закрыта."
  # the next wait confirms what close showed and does not repeat it
  out=$(brg wait --as "$A" --timeout 1)
  assert_contains "$out" "── нет новых"
  assert_eq "6/6" "$(tcursor "$A" T001)"
}

# Lobby counts too (the lead's wait listens there), with the output cap: several
# refusals in a row, each moves Pending; nothing is lost.
test_close_unread_in_lobby_and_cap() {
  local out d i all=
  three_agents
  printf 'wait_output_max: 300\n' >>"$B/config"
  task_new_as "$A" "Кап"
  d=$(tdir T001)
  printf 'итог\n' >"$d/summary.md"
  for i in 1 2 3 4 5 6; do send_as "$Bn" "письмо-$i: $(printf '%060d' 0)" --to "${A%%.*}" --channel lobby; done
  for i in 1 2 3 4 5 6 7; do
    out=$(brg task close --as "$A" 2>/dev/null) && break
    all="$all$out"
    assert_contains "$out" "── lobby · "
  done
  [ "$i" -gt 2 ] || fail "the cap did not split the output ($i)"
  assert_eq done "$(hdr "$d/task" Status)"
  for i in 1 2 3 4 5 6; do assert_contains "$all" "  письмо-$i:"; done
  assert_contains "$all" "не вошло (лимит вывода): покажет следующий task close"
}

# A lead's wait running in the background races with close: whatever either of
# them shows is never lost (at-least-once; duplicates allowed). The wait ticks
# slower here, so that close wins some of the races.
test_close_vs_running_wait_loses_nothing() {
  local i k=0 wp all
  three_agents
  task_new_as "$A" "Гонка"
  ack_all "$A" "$(tdir T001)"
  : >"$P/close"
  : >"$P/waits"
  BRG_TICK=0.4 start_wait "$A" "$P/w0" --timeout 30
  wp=$WP
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    send_as "$Bn" "msg-$i" --to "${A%%.*}"
    brg task close --as "$A" >>"$P/close" 2>/dev/null && fail "closed without summary.md"
    if [ -s "$P/w$k" ]; then
      wait "$wp"
      cat "$P/w$k" >>"$P/waits"
      k=$((k + 1))
      BRG_TICK=0.4 start_wait "$A" "$P/w$k" --timeout 30
      wp=$WP
    fi
  done
  brg wait --as "$A" --timeout 1 >>"$P/waits" # supersedes the background one
  wait "$wp"
  cat "$P/w$k" >>"$P/waits"
  assert_contains "$(cat "$P/close")" "  msg-" "close never won a race"
  assert_contains "$(cat "$P/waits")" "  msg-" "wait never won a race"
  all=$(cat "$P/close" "$P/waits")
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do assert_contains "$all" "  msg-$i"$'\n'; done
}

test_task_cancel_permissions_and_human() {
  local out
  three_agents
  task_new_as "$A" "Отменяемая"
  out=$(brg task cancel --as "$C" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "отменить задачу T001 может host (${A%%.*}), lead (${A%%.*}) или человек"
  out=$(brg task cancel 2>&1)
  assert_eq 1 "$?" "no --as: not silently the human"
  assert_contains "$out" "нужно имя агента"
  out=$(brg task cancel --as human)
  assert_eq 0 "$?"
  assert_contains "$out" "── задача T001 «Отменяемая» отменена"
  assert_not_contains "$out" "NEXT"
  assert_eq human "$(hdr "$(tdir T001)/task" Closed-By)"
  assert_eq human "$(hdr "$(msg_file 5)" From)"
  out=$(brg wait --as "$A" --timeout 1)
  assert_contains "$out" "#5 [система] human → all"
  assert_contains "$out" "прекрати правки"
  task_new_as "$A" "Вторая"
  brg lead give "${Bn%%.*}" --as "$A" >/dev/null || fail "lead give"
  out=$(brg task cancel --as "$Bn") # the lead may cancel too
  assert_contains "$out" "отменена"
  assert_contains "$(cat "$B/common/history.md")" "отменил ${Bn%%.*}"
}

test_task_show_list_who() {
  local out
  three_agents
  out=$(brg task show 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "активной задачи нет"
  assert_contains "$(brg task list)" "── задач ещё не было"
  task_new_as "$A" "Show me" "первая строка
вторая строка"
  out=$(brg task show --as "$Bn")
  assert_contains "$out" "── T001 «Show me» · active"
  assert_contains "$out" "host ${A%%.*} · lead ${A%%.*} · создана "
  assert_contains "$out" "Твоя роль: участник"
  assert_contains "$out" "План: нет"
  assert_contains "$out" "первая строка
вторая строка"
  assert_contains "$out" "── NEXT:"
  mkdir -p "$(tdir T001)/shared"
  printf 'план\n' >"$(tdir T001)/shared/plan.md"
  assert_contains "$(brg task show T1)" "План: .brigada/tasks/T001-show-me/shared/plan.md"
  out=$(brg task show T9 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет задачи T009"
  assert_contains "$(brg task list)" "T001 · active · «Show me» · host ${A%%.*} · lead ${A%%.*} · "
  assert_contains "$(brg who)" "── задача T001 «Show me» · host ${A%%.*} · lead ${A%%.*}"
  out=$(brg task 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нужна подкоманда"
}

test_status_shows_task_role_and_deadlines() {
  local out
  three_agents
  out=$(brg status --as "$A")
  assert_contains "$out" "Активная задача: нет"
  task_new_as "$A" "Статус"
  printf 'вопрос\n' | brg send --as "$A" --reply-by 1h >/dev/null || fail send
  send_as "$Bn" "мой ответ" --re 1
  out=$(brg status --as "$A")
  assert_contains "$out" "Активная задача: T001 «Статус» · host ${A%%.*} · lead ${A%%.*} · твоя роль: host и lead"
  assert_contains "$out" "Постановка: .brigada/tasks/T001/brief.md · план: .brigada/tasks/T001/shared/plan.md (пока нет"
  assert_contains "$out" "История переписки задачи: bash $BRG read --as $A --channel T001 --since 0"
  assert_contains "$out" "T001: новых для тебя 1"
  assert_contains "$out" "Мой дедлайн по #1 (T001): до "
  assert_contains "$out" "ответили: ${Bn%%.*} · ждём: ${C%%.*}"
  assert_contains "$(brg status --as "$C")" "твоя роль: участник"
}

# An agent joining mid-task starts from the end of the task channel; members
# present at creation start from the beginning. join shows the task and history.
test_agent_joining_mid_task() {
  local d out
  three_agents
  task_new_as "$A" "Посреди"
  send_as "$A" "старое 1"
  send_as "$A" "старое 2"
  out=$(brg join --harness claude --model m)
  d=$(printf '%s\n' "$out" | sed -n 's/^── подключён: \([^ ]*\) .*/\1/p')
  assert_eq claude-2 "$(base_of "$d")"
  assert_contains "$out" "── подключён: $d "
  assert_contains "$out" "Активная задача: T001 «Посреди» · host ${A%%.*} · lead ${A%%.*} · твоя роль: участник"
  assert_contains "$out" "Постановка: .brigada/tasks/T001/brief.md"
  assert_contains "$out" "История переписки задачи: bash $BRG read --as $d --channel T001 --since 0"
  assert_contains "$out" "Правила совместной работы: .brigada/PROTOCOL.md"
  assert_eq "2/2" "$(tcursor "$d" T001)" "latecomer starts from the end"
  send_as "$A" "новое"
  out=$(brg wait --as "$d" --timeout 1)
  assert_contains "$out" "  новое"
  assert_not_contains "$out" "старое"
  out=$(brg read --as "$d" --channel T001 --since 0)
  assert_contains "$out" "  старое 1"
  assert_contains "$out" "  старое 2"
  # Bn was there when the task was created: gets the task channel from #1
  out=$(brg wait --as "$Bn" --timeout 1)
  assert_contains "$out" "новая задача T001"
  assert_contains "$out" "  старое 1"
  assert_contains "$out" "  новое"
}

test_send_default_channel_and_re_hint() {
  local out
  three_agents
  send_as "$A" "в лобби до задачи"
  assert_eq lobby "$(hdr "$(msg_file 4)" Channel)"
  task_new_as "$A" "Каналы"
  out=$(printf 'в задачу\n' | brg send --as "$Bn")
  assert_contains "$out" "── отправлено #1 → all (T001)"
  out=$(printf 'явно в лобби\n' | brg send --as "$Bn" --channel lobby)
  assert_contains "$out" "── отправлено #6 → all (lobby)"
  out=$(printf 'тоже в задачу\n' | brg send --as "$Bn" --channel t1)
  assert_contains "$out" "→ all (T001)"
  # --re is per channel: a lobby id without --channel gets a hint
  out=$(printf 're\n' | brg send --as "$C" --re 4 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "в канале T001 нет сообщения #4"
  assert_contains "$out" "#4 есть в lobby — ответ туда: добавь --channel lobby"
  out=$(brg say "от человека")
  assert_contains "$out" "от human → all (T001)"
  out=$(brg say --channel lobby "в лобби от человека")
  assert_contains "$out" "(lobby)"
  # read without --channel: every listened channel; --since: the task channel
  out=$(brg read --as "$C")
  assert_contains "$out" "── lobby · после #3:"
  assert_contains "$out" "── T001 · после #0:"
  assert_contains "$out" "  в задачу"
  assert_contains "$out" "  явно в лобби"
  out=$(brg read --as "$C" --since 1)
  assert_contains "$out" "── T001 · после #1:"
  assert_not_contains "$out" "явно в лобби"
}

test_tail_merges_lobby_and_task() {
  local out p
  three_agents
  task_new_as "$A" "Хвост"
  send_as "$Bn" "сообщение в задаче"
  out=$(brg tail)
  assert_contains "$out" "lobby #4 [система] ${A%%.*} → all · "
  assert_contains "$out" "T001 #1 ${Bn%%.*} → all · "
  out=$(brg tail T001)
  assert_contains "$out" "#1 ${Bn%%.*} → all · "
  assert_not_contains "$out" "lobby"
  # -f follows the switch to a new task
  BRG_TICK=0.2 bash "$BRG" tail -f >"$P/tail" 2>&1 &
  p=$!
  track_pid $p
  wait_for 3 test -s "$P/tail" || fail "tail -f printed nothing"
  printf 'новая\n' | brg task new --as "$A" --title "Следующая" --cancel-current >/dev/null || fail "task new"
  send_as "$C" "в новой задаче"
  wait_for 4 awk '/^T002 #1 / { f = 1 } END { exit !f }' "$P/tail" || fail "tail -f did not follow T002: $(cat "$P/tail")"
  kill -TERM $p
  wait_pid $p 3 || fail "tail -f did not stop"
}

test_lead_and_host_give_take() {
  local out d
  three_agents
  task_new_as "$A" "Роли"
  d=$(tdir T001)
  out=$(brg lead take --as "$Bn" 2>&1)
  assert_eq 1 "$?" "take while the lead is active"
  assert_contains "$out" "lead ${A%%.*} активен (working) — взять роль можно, только если он asleep или gone"
  start_wait "$A" "$P/wa" --timeout 20
  out=$(brg lead take --as "$Bn" 2>&1)
  assert_eq 1 "$?" "take while the lead is waiting"
  assert_contains "$out" "активен (waiting)"
  kill -TERM $WP
  wait_pid $WP 3 || fail "wait hung"
  out=$(brg lead give "${C%%.*}" --as "$Bn" 2>&1)
  assert_eq 1 "$?" "give by a non-lead"
  assert_contains "$out" "передать lead может только текущий lead (${A%%.*})"
  # asleep lead → take passes
  printf '%s\n' $(($(date -u +%s) - 90)) >"$B/run/seen/${A%%.*}" # > asleep_after (60)
  out=$(brg lead take --as "$Bn")
  assert_eq 0 "$?"
  assert_contains "$out" "── lead задачи T001: ${A%%.*} → ${Bn%%.*}."
  assert_contains "$out" "Теперь ты ведёшь работу"
  assert_eq "${Bn%%.*}" "$(hdr "$d/task" Lead)"
  assert_eq "${A%%.*}" "$(hdr "$d/task" Host)"
  f=$(tmsg T001 1)
  assert_eq system "$(hdr "$f" Kind)"
  assert_contains "$(cat "$f")" "lead задачи T001: ${A%%.*} → ${Bn%%.*} (взял ${Bn%%.*}: ${A%%.*} — asleep)"
  assert_contains "$(brg lead take --as "$Bn")" "ты уже lead"
  # give: to a gone agent refused, to a live one passes; the new lead is woken
  brg leave --as "$C" >/dev/null
  out=$(brg lead give "${C%%.*}" --as "$Bn" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "${C%%.*} — gone"
  out=$(brg lead give "${A%%.*}" --as "$Bn")
  assert_contains "$out" "── lead задачи T001: ${Bn%%.*} → ${A%%.*}."
  assert_contains "$(brg wait --as "$A" --timeout 1)" "lead задачи T001: ${Bn%%.*} → ${A%%.*} (передал ${Bn%%.*})"
  # host: give/take the same way
  out=$(brg host give "${Bn%%.*}" --as "$A")
  assert_contains "$out" "── host задачи T001: ${A%%.*} → ${Bn%%.*}."
  assert_eq "${Bn%%.*}" "$(hdr "$d/task" Host)"
  out=$(brg host take --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "host ${Bn%%.*} активен"
  # a gone (left) lead can be replaced
  brg lead give "${Bn%%.*}" --as "$A" >/dev/null || fail "give back"
  brg leave --as "$Bn" >/dev/null
  out=$(brg lead take --as "$A")
  assert_contains "$out" "${Bn%%.*} → ${A%%.*}"
  assert_contains "$(cat "$(tmsg T001 5)")" "(взял ${A%%.*}: ${Bn%%.*} — gone)"
  out=$(brg lead give 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "кому передать"
}

# The host/lead leaving wakes everyone (others may take the role); an ordinary
# participant's leave stays quiet.
test_leave_of_role_holder_wakes() {
  local out pb
  three_agents
  task_new_as "$A" "Уход"
  ack_all "$Bn"
  ack_all "$C"
  export BRG_TICK=0.2
  brg leave --as "$C" >/dev/null
  assert_eq no "$(hdr "$(msg_file 5)" Wake)" "participant's leave is quiet"
  start_wait "$Bn" "$P/wb" --timeout 20
  pb=$WP
  out=$(brg leave --as "$A")
  assert_contains "$out" "Ты был host и lead задачи T001"
  f=$(msg_file 6)
  assert_eq "" "$(hdr "$f" Wake)" "role holder's leave wakes"
  assert_contains "$(cat "$f")" "${A%%.*} отключился (был host и lead задачи T001 — роль может взять любой: bash $BRG host take, bash $BRG lead take --as <имя>)"
  wait_pid $pb 3 || fail "B's wait was not woken by the lead's leave"
  out=$(cat "$P/wb")
  assert_contains "$out" "#5 [система] ${C%%.*} → all"
  assert_contains "$out" "#6 [система] ${A%%.*} → all"
  assert_contains "$out" "lead take --as <имя>"
  out=$(brg lead take --as "$Bn")
  assert_contains "$out" "── lead задачи T001: ${A%%.*} → ${Bn%%.*}."
}

test_task_new_lifts_stop() {
  local out
  three_agents
  brg stop >/dev/null
  : >"$B/run/stopped.${A%%.*}"
  : >"$B/run/stopped.${C%%.*}"
  out=$(printf 'x\n' | brg task new --as "$A" --title "После стопа")
  assert_contains "$out" "Общий стоп снят."
  assert_contains "$out" "Стоп, поставленный тебе человеком, снят"
  assert_not_contains "$out" "── STOP" "task new lifts the stop: no banner"
  assert_file_not_exists "$B/run/stopped"
  assert_file_not_exists "$B/run/stopped.${A%%.*}" "the host's own stop is lifted"
  assert_file_exists "$B/run/stopped.${C%%.*}" "other per-agent stops stay"
}

# STOP_BANNER — the first line of an agent command while the brigade is stopped
STOP_BANNER="── STOP: человек остановил бригаду. Новую работу не начинай: сдай сделанное, если нужно (send, item done), и заверши ход."
# stop_lines TEXT — how many lines of TEXT start with "── STOP"
stop_lines() { printf '%s\n' "$1" | awk '/^── STOP/ { n++ } END { print n + 0 }'; }
# stop_refused OUT RC WHAT — WHAT (stdout+stderr OUT, code RC) refused by the general stop
stop_refused() {
  assert_eq 1 "$2" "refused: $3"
  assert_eq "$STOP_BANNER" "$(printf '%s\n' "$1" | head -n 1)" "$3"
  assert_eq 1 "$(stop_lines "$1")" "$3"
  assert_contains "$1" "── ОШИБКА: человек остановил бригаду — $3 не выполнено: при стопе новую работу не начинают"
  assert_eq "── NEXT: заверши ход (стоп снимет человек и напишет тебе «продолжай»)" "$(printf '%s\n' "$1" | tail -n 1)" "$3"
}

# The human's stop is seen by any agent command, not only by wait (DESIGN §9):
# the first line says STOP; commands that start work (item add|claim|reassign,
# run) refuse with NEXT "end the turn"; handing in and talking still work; wait
# and status say STOP exactly once; task new lifts it; after resume all works.
test_stop_seen_by_every_command() {
  local out d
  three_agents
  task_new_as "$A" "Стоп"
  d=$(tdir T001)
  for x in "$A" "$Bn" "$C"; do ack_all "$x" "$d"; done
  printf 'о\n' | brg item add --as "$A" --title "Взятая" >/dev/null || fail add1
  printf 'о\n' | brg item add --as "$A" --title "Свободная" >/dev/null || fail add2
  brg item claim I1 --as "$Bn" --paths src >/dev/null || fail claim
  brg stop >/dev/null
  # send: STOP first, and the message goes out
  out=$(printf 'сдаю\n' | brg send --as "$Bn" --to "${A%%.*}")
  assert_eq 0 "$?" "send works under stop"
  assert_eq "$STOP_BANNER" "$(printf '%s\n' "$out" | head -n 1)"
  assert_eq 1 "$(stop_lines "$out")"
  assert_contains "$out" "── отправлено"
  # starting work is refused: STOP, the refusal, NEXT — end the turn (not wait)
  out=$(brg item claim I2 --as "$Bn" --paths lib 2>&1)
  stop_refused "$out" $? "item claim"
  out=$(brg item add --as "$Bn" --title "Новая" --desc "о" 2>&1)
  stop_refused "$out" $? "item add"
  out=$(brg item reassign I1 --as "$A" --to "${C%%.*}" 2>&1)
  stop_refused "$out" $? "item reassign"
  out=$(brg run --as "$Bn" -- true 2>&1)
  stop_refused "$out" $? "run"
  assert_eq todo "$(hdr "$d/items/I002" Status)"
  assert_file_not_exists "$d/items/I003"
  assert_eq "${Bn%%.*}" "$(hdr "$d/items/I001" Assignee)"
  assert_file_not_exists "$d/shared/runs/R001"
  # handing in works (with the banner)
  out=$(brg item done I1 --as "$Bn" --note "сделано")
  assert_eq 0 "$?" "item done under stop"
  assert_eq "$STOP_BANNER" "$(printf '%s\n' "$out" | head -n 1)"
  # reading too
  assert_eq "$STOP_BANNER" "$(brg item list --as "$Bn" | head -n 1)"
  # wait and status: STOP exactly once
  out=$(brg wait --as "$A" --timeout 5)
  assert_eq "── STOP: человек остановил бригаду. Заверши ход." "$out"
  out=$(brg status --as "$A")
  assert_eq 1 "$(stop_lines "$out")" "status: one STOP"
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "── STOP: человек остановил"
  out=$(brg status --as "${A%%.*}")
  assert_eq 1 "$(stop_lines "$out")" "status without the key: one STOP"
  # a per-agent stop: only that agent sees it
  brg resume >/dev/null
  brg stop "${C%%.*}" >/dev/null
  out=$(printf 'x\n' | brg send --as "$C" --to "${A%%.*}")
  assert_eq "── STOP: человек остановил тебя (${C%%.*}). Новую работу не начинай: сдай сделанное, если нужно (send, item done), и заверши ход." "$(printf '%s\n' "$out" | head -n 1)"
  out=$(brg item claim I2 --as "$C" --paths lib 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "── ОШИБКА: человек остановил тебя (${C%%.*}) — item claim не выполнено"
  out=$(brg item claim I2 --as "$Bn" --paths lib)
  assert_eq 0 "$?" "others work"
  assert_eq 0 "$(stop_lines "$out")"
  # after resume everything works again, without the banner
  brg resume "${C%%.*}" >/dev/null
  out=$(printf 'о\n' | brg item add --as "$C" --title "После стопа")
  assert_eq 0 "$?"
  assert_eq 0 "$(stop_lines "$out")"
  out=$(brg run --as "$C" --sync -- true)
  assert_eq 0 "$?"
  assert_eq 0 "$(stop_lines "$out")"
  wait_for 5 is_dead "$(hdr "$d/shared/runs/R001" Runner)" || fail "runner alive"
}

test_join_as_returns_under_the_same_name() {
  local out old k
  three_agents
  task_new_as "$A" "Возврат"
  send_as "$A" "до ухода"
  brg wait --as "$Bn" --timeout 0 >/dev/null
  brg wait --as "$Bn" --timeout 0 >/dev/null
  assert_eq "1/1" "$(tcursor "$Bn" T001)"
  brg leave --as "$Bn" >/dev/null
  send_as "$A" "пока его не было"
  # another harness: refused
  out=$(brg join --as "$Bn" --harness claude 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "агент ${Bn%%.*} подключался из харнесса codex, а ты — claude"
  out=$(brg join --as ghost-3 --harness codex 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет агента ghost-3"
  # the same harness (after leave — at once): Left lifted, model kept unless given,
  # cursors kept, a new key; the full name is accepted too
  old=$Bn
  out=$(brg join --as "$Bn" --harness codex-cli)
  assert_eq 0 "$?"
  k=$(hdr "$B/agents/${Bn%%.*}" Key)
  Bn=${Bn%%.*}.$k
  [ "$Bn" != "$old" ] || fail "the key did not change"
  assert_contains "$out" "── переподключён: $Bn (codex · m · "
  assert_contains "$out" "Активная задача: T001 «Возврат»"
  assert_eq "── NEXT: bash $BRG wait --as $Bn" "$(printf '%s\n' "$out" | tail -n 1)"
  assert_eq "" "$(hdr "$B/agents/${Bn%%.*}" Left)"
  [ -n "$(hdr "$B/agents/${Bn%%.*}" Rejoined)" ] || fail "no Rejoined"
  assert_eq m "$(hdr "$B/agents/${Bn%%.*}" Model)"
  assert_eq 1 "$(awk '/^Key: /' "$B/agents/${Bn%%.*}" | wc -l | tr -d ' ')" "one Key"
  assert_eq "1/1" "$(tcursor "$Bn" T001)" "cursor kept"
  # the old key no longer works
  out=$(brg wait --as "$old" --timeout 0)
  assert_eq 0 "$?"
  assert_contains "$out" "ключ устарел или с ошибкой"
  out=$(brg wait --as "$Bn" --timeout 1)
  assert_contains "$out" "  пока его не было"
  assert_not_contains "$out" "до ухода"
  assert_contains "$(cat "$(msg_file 6)")" "${Bn%%.*} переподключён новой сессией (codex, m, "
  assert_contains "$(cat "$(msg_file 6)")" "прежний ключ недействителен"
  assert_not_contains "$(cat "$(msg_file 6)")" "$k"
  # a live wait under that name: refused
  start_wait "$Bn" "$P/wb" --timeout 20
  out=$(brg join --as "$Bn" --harness codex --model new 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "имя ${Bn%%.*} занято: его wait сейчас работает (pid $WP)"
  assert_contains "$out" "Если ключ потерян — дождись конца этого wait (обычно ≤ 2 с) и повтори"
  assert_not_contains "$out" "status --as"
  kill -TERM $WP
  wait_pid $WP 3 || fail "wait hung"
  # the wait just ended: the agent is active — refused until it drops out
  out=$(brg join --as "${Bn%%.*}" --harness codex --model new 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "${Bn%%.*} активен (последний вызов "
  assert_contains "$out" "он в последней строке NEXT"
  assert_contains "$out" "иначе подожди "
  assert_contains "$out" "── NEXT: bash $BRG join --harness codex --model new (новое имя)"
  brg wait --as "$Bn" --timeout 0 >/dev/null # the key still works
  dropped "$Bn"
  out=$(brg join --as "${Bn%%.*}" --harness codex --model new)
  assert_contains "$out" "── переподключён: ${Bn%%.*}."
  assert_contains "$out" " (codex · new · "
  assert_eq new "$(hdr "$B/agents/${Bn%%.*}" Model)"
}

# A returning agent that had left joins mid-task (from the end); one that never
# left was a member all along (from the start of the task channel).
test_join_as_task_cursor_start() {
  local out
  three_agents
  brg leave --as "$C" >/dev/null
  task_new_as "$A" "Курсоры"
  send_as "$A" "раннее"
  brg join --as "$C" --harness opencode >/dev/null || fail "rejoin C"
  assert_eq "1/1" "$(tcursor "$C" T001)"
  dropped "$Bn"
  Bn=$(rejoin_as "$Bn" codex)
  [ -n "$Bn" ] || fail "rejoin Bn"
  assert_eq "-" "$(tcursor "$Bn" T001)"
  out=$(brg wait --as "$Bn" --timeout 1)
  assert_contains "$out" "  раннее"
}

# The last word sent to the task right before close/cancel is
# not lost — the channel is drained (from Acked, at-least-once) before a wait
# stops listening to it. Reproduction: the wait is frozen (SIGSTOP) across
# send + close, then resumed.
drain_case() { # HOW: close | cancel | cancel-current
  local out pb
  three_agents
  export BRG_TICK=0.2
  task_new_as "$A" "Сливаемая"
  brg wait --as "$Bn" --timeout 0 >/dev/null # "новая задача"
  start_wait "$Bn" "$P/wb" --timeout 20
  pb=$WP
  kill -STOP $pb
  send_as "$A" "ФИНАЛ: всё смёрджено"
  send_as "$A" "лично C, не для B" --to "${C%%.*}"
  case $1 in
    close)
      printf 'итог\n' >"$(tdir T001)/summary.md"
      brg task close --as "$A" >/dev/null || fail close
      ;;
    cancel) brg task cancel --as "$A" >/dev/null || fail cancel ;;
    cancel-current) task_new_as "$Bn" "Новая" "x" --cancel-current ;;
  esac
  kill -CONT $pb
  wait_pid $pb 3 || fail "wait did not return"
  out=$(cat "$P/wb")
  case $1 in
    close) assert_contains "$out" "── T001 (закрыта) · 1 новое" ;;
    *) assert_contains "$out" "── T001 (отменена) · 1 новое" ;;
  esac
  assert_contains "$out" "  ФИНАЛ: всё смёрджено"
  assert_not_contains "$out" "лично C"
  case $1 in
    close) assert_contains "$out" "задача T001 «Сливаемая» закрыта" ;;
    cancel) assert_contains "$out" "задача T001 «Сливаемая» отменена" ;;
  esac
  assert_eq "0/2" "$(tcursor "$Bn" T001)" "issued (up to the scanned end), not yet confirmed"
  # read re-shows the issued batch of the finished task
  assert_contains "$(brg read --as "$Bn")" "  ФИНАЛ: всё смёрджено"
  # the next wait confirms it and drops the channel
  brg wait --as "$Bn" --timeout 0 >/dev/null
  assert_eq "2/2" "$(tcursor "$Bn" T001)" "drained"
  assert_not_contains "$(brg status --as "$Bn")" "T001"
}
test_drain_on_close() { drain_case close; }
test_drain_on_cancel() { drain_case cancel; }
test_drain_on_cancel_current() {
  local out
  drain_case cancel-current
  # T002 is listened to as usual
  send_as "$Bn" "в новой"
  out=$(brg wait --as "$A" --timeout 1)
  assert_contains "$out" "── T002 · 1 новое"
}

# An agent that was busy (no wait) while the lead sent the last word and closed
# gets it on its next wait; one that never listened to the task gets nothing;
# one back after leave skips finished tasks.
test_drain_after_close_for_busy_agents() {
  local out d
  three_agents
  task_new_as "$A" "Занятые"
  brg wait --as "$Bn" --timeout 0 >/dev/null # Bn listens to T001 (cursor 0/0)
  brg wait --as "$C" --timeout 0 >/dev/null
  brg leave --as "$C" >/dev/null
  send_as "$A" "последнее слово"
  printf 'итог\n' >"$(tdir T001)/summary.md"
  brg task close --as "$A" >/dev/null || fail close
  d=$(join_as opencode) # a newcomer: no cursor in T001
  out=$(brg wait --as "$Bn" --timeout 1)
  assert_contains "$out" "── T001 (закрыта) · 1 новое"
  assert_contains "$out" "  последнее слово"
  assert_contains "$(brg status --as "$Bn")" "T001 (закрыта): новых для тебя 0 · выдано последним wait"
  C=$(rejoin_as "$C" opencode)
  [ -n "$C" ] || fail rejoin
  assert_eq "1/1" "$(tcursor "$C" T001)" "back after leave: finished task skipped"
  ack_all "$C"
  ack_all "$d"
  send_as "$A" "в лобби"
  for x in "$C" "$d"; do
    out=$(brg wait --as "$x" --timeout 1)
    assert_contains "$out" "  в лобби"
    assert_not_contains "$out" "последнее слово"
  done
}

# Rehearsal fixes (revised by the human): review is a recommendation, not a rule —
# task close does not look at reviews; item review stays as a tool.
test_close_does_not_require_reviews() {
  local out d
  three_agents
  task_new_as "$A" "Без ревью"
  d=$(tdir T001)
  printf 'описание\n' | brg item add --as "$A" --title "Код" >/dev/null || fail "item add"
  brg item claim I1 --as "$Bn" --paths "src/a" >/dev/null || fail claim
  out=$(brg item done I1 --as "$Bn" --note "сделано")
  assert_eq 0 "$?"
  assert_not_contains "$(cat "$(tmsg T001 "$(cat "$d/seq")")")" "ревью" "the done notice does not demand a review"
  printf 'итог\n' >"$d/summary.md"
  brg wait --as "$A" --timeout 0 >/dev/null # the lead takes the "done" notice first
  out=$(brg task close --as "$A")
  assert_eq 0 "$?" "closed without a review"
  assert_contains "$out" "── задача T001 «Без ревью» закрыта."
  assert_eq done "$(hdr "$d/task" Status)"
  out=$(brg task close --as "$A" --skip-review x 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "неизвестный параметр: --skip-review"
  assert_not_contains "$(brg task --help)" "ревью"
}
