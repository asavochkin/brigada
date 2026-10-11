# One role (DESIGN §6.1): the lead facilitates and talks to the human; there is always
# one. The human gives a task himself (task new --as human) and appoints a lead (lead
# give --as human); brg chooses the lead of such a task; with nobody on the line Lead:
# stays empty and the first agent that comes on the line (wait, join, lead take) takes it.

. "$TESTS_DIR/brg_lib.sh"

# hand_task LEAD — a task made by hand (as if created under a running wait) with Lead: LEAD
# (maybe empty) and activated; the files of a task created by task new
hand_task() {
  local d=$B/tasks/T001-manual
  mkdir -p "$d/messages" "$d/cursors" "$d/items" "$d/reservations" "$d/shared"
  printf 'постановка\n' >"$d/brief.md"
  printf '0\n' >"$d/seq"
  printf 'Id: T001\nTitle: Manual\nStatus: active\nLead: %s\nCreated: 2026-01-01T00:00:00Z\nCreated-Epoch: 1767225600\nCreated-By: human\n' "$1" >"$d/task"
  printf 'T001-manual\n' >"$B/tasks/active"
}

# set_joined NAME EPOCH — Joined-Epoch of an agent (the order of the choice of a lead)
set_joined() {
  sed "s/^Joined-Epoch: .*/Joined-Epoch: $2/" "$B/agents/${1%%.*}" >"$B/agents/.t" && mv "$B/agents/.t" "$B/agents/${1%%.*}"
}

# close_as NAME — close the active task (the unread for the lead is shown first: repeat)
close_as() {
  printf '# итог\n' >"$B/tasks/$(cat "$B/tasks/active")/summary.md"
  brg task close --as "$1" >/dev/null 2>&1 || brg task close --as "$1" >/dev/null 2>&1 || fail "close as $1"
}

# lead_of ID — the Lead: header of a task
lead_of() { hdr "$(tdir "$1")/task" Lead; }

# nobody_online — every agent silent for long (asleep): none is on the line
nobody_online() {
  local x
  for x in "$@"; do dropped "$x" 100; done
}

# lead_msgs ID — the number of announcements «… — lead задачи» From: brg in the task channel
lead_msgs() {
  local f n=0
  for f in "$(tdir "$1")"/messages/*.msg; do
    [ -f "$f" ] || continue
    [ "$(hdr "$f" From)" = brg ] || continue
    case $(cat "$f") in *"— lead задачи"*) n=$((n + 1)) ;; esac
  done
  echo "$n"
}

test_task_of_an_older_version_with_host_is_read() {
  local out d
  new_proj
  A=$(join_as claude)
  task_new_as "$A" "Старая"
  d=$(tdir T001)
  # a task written by brg ≤ 0.6: a Host: header between Status and Lead
  awk '{ print } /^Status: / { print "Host: codex-9" }' "$d/task" >"$d/task.new" && mv "$d/task.new" "$d/task"
  assert_eq codex-9 "$(hdr "$d/task" Host)"
  out=$(brg task show)
  assert_contains "$out" "lead ${A%%.*} · создана "
  assert_not_contains "$out" "codex-9"
  assert_not_contains "$(brg who)" "codex-9"
  assert_not_contains "$(brg status --as "$A")" "codex-9"
  assert_contains "$(brg task list)" "T001 · active · «Старая» · lead ${A%%.*} · "
  # a write drops the ignored header; the cancel rights are the lead's
  brg lead give claude-1 --as "$A" >/dev/null
  printf 'x\n' | brg task new --as human --title "Новая" --cancel-current >/dev/null || fail "task new"
  assert_eq "" "$(hdr "$d/task" Host)"
  assert_contains "$(cat "$B/common/history.md")" " · lead ${A%%.*} · отменил human"
}

test_host_commands_refuse_with_a_hint() {
  local out
  new_proj
  A=$(join_as claude)
  for x in give take; do
    out=$(brg host $x --as "$A" 2>&1)
    assert_eq 1 "$?"
    assert_contains "$out" "роли host больше нет: связь с человеком — у lead'а"
    assert_contains "$out" "lead give <имя> --as $A"
    assert_contains "$out" "lead take --as $A"
    assert_eq "── NEXT: bash $BRG wait --as $A" "$(printf '%s\n' "$out" | tail -n 1)"
  done
  assert_not_contains "$(brg help)" "host"
  assert_not_contains "$(brg task --help)" "host"
  assert_not_contains "$(brg lead --help)" "host"
}

# --as human: no agent is needed, no NEXT, From: human in the lobby, the lead is chosen by brg
test_task_new_as_human_creates_and_notifies() {
  local out d f
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  ack_all "$A"
  ack_all "$Bn"
  brg pause >/dev/null
  : >"$B/run/paused.${Bn%%.*}"
  out=$(printf 'Постановка\nвторая строка\n' | brg task new --as human --title "От человека")
  assert_eq 0 "$?"
  assert_contains "$out" "── создана задача T001 «От человека» от человека · lead: ${A%%.*}."
  assert_contains "$out" "Общая пауза снята."
  assert_not_contains "$out" "NEXT"
  assert_file_not_exists "$B/run/paused"
  assert_file_exists "$B/run/paused.${Bn%%.*}" "a personal pause stays"
  d=$(tdir T001)
  assert_eq "${A%%.*}" "$(hdr "$d/task" Lead)"
  assert_eq human "$(hdr "$d/task" Created-By)"
  assert_eq $'Постановка\nвторая строка' "$(cat "$d/brief.md")"
  # the lobby: from the human, to all, wakes
  f=$(msg_file "$(cat "$B/lobby/seq")")
  assert_eq human "$(hdr "$f" From)"
  assert_eq all "$(hdr "$f" To)"
  assert_eq system "$(hdr "$f" Kind)"
  assert_eq "" "$(hdr "$f" Wake)"
  assert_contains "$(cat "$f")" "новая задача T001 от человека: «От человека» · lead: ${A%%.*}. Прочитай постановку: .brigada/tasks/T001/brief.md"
  assert_contains "$(cat "$f")" "вопросы ему: send --to human --ask"
  # the task channel: to the lead alone — «ты lead»
  f=$(tmsg T001 1)
  assert_eq brg "$(hdr "$f" From)"
  assert_eq "${A%%.*}" "$(hdr "$f" To)"
  assert_contains "$(cat "$f")" "${A%%.*}, ты lead задачи T001 (назначил brg)"
  out=$(brg wait --as "$A" --timeout 1)
  assert_contains "$out" "ты lead задачи T001 (назначил brg)"
  assert_contains "$out" "новая задача T001 от человека"
  # the other agent is told about the task, not about the lead
  out=$(brg wait --as "$Bn" --timeout 1)
  assert_contains "$out" "новая задача T001 от человека"
  assert_not_contains "$out" "ты lead задачи"
  assert_contains "$(metrics_of human task.new)" "id=T001 cancel_current=0"
  # an active task: refused without --cancel-current, no agent-style NEXT
  out=$(printf 'другая\n' | brg task new --as human --title "Вторая" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "уже есть активная задача T001 «От человека» (lead ${A%%.*})"
  assert_contains "$out" "--cancel-current"
  assert_not_contains "$out" "NEXT"
  out=$(printf 'x\n' | brg task new --as human 2>&1)
  assert_eq 1 "$?"
  assert_not_contains "$out" "NEXT"
}

test_task_new_as_human_without_agents_leaves_the_lead_empty() {
  local out
  new_proj
  out=$(printf 'x\n' | brg task new --as human --title "Некому")
  assert_eq 0 "$?"
  assert_contains "$out" "lead: нет — назначится первому, кто выйдет на связь"
  assert_contains "$out" "Агентов на связи нет"
  assert_eq "" "$(lead_of T001)"
  assert_contains "$(cat "$(msg_file 1)")" "lead: нет — назначится первому, кто выйдет на связь"
  assert_file_not_exists "$(tmsg T001 1)" "nobody to address in the task channel"
  assert_contains "$(brg task show)" "lead — нет (назначится первому, кто выйдет на связь) · создана "
  assert_contains "$(brg who)" "── задача T001 «Некому» · lead — нет (назначится первому, кто выйдет на связь)"
  assert_contains "$(brg task list)" "T001 · active · «Некому» · lead — нет (назначится первому, кто выйдет на связь) · "
}

# the choice of the lead of a task given by the human (deterministic, under the task lock)
test_choice_prefers_the_last_lead_if_on_the_line() {
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  task_new_as "$A" "Первая"
  brg lead give "${Bn%%.*}" --as "$A" >/dev/null || fail give
  close_as "$Bn"
  # Bn led the last task and is on the line (working: it has just called brg)
  printf 'x\n' | brg task new --as human --title "Вторая" >/dev/null || fail "task new"
  assert_eq "${Bn%%.*}" "$(lead_of T002)"
  # the previous lead is not on the line (asleep): the others are asked
  close_as "$Bn"
  dropped "$Bn"
  printf 'x\n' | brg task new --as human --title "Третья" >/dev/null || fail "task new 3"
  assert_eq "${A%%.*}" "$(lead_of T003)"
}

# waits_up NAME… — a plain wait of each (they end with every new-task message: restart them)
waits_up() {
  local n i=0
  for n in "$@"; do
    i=$((i + 1))
    ack_all "$n" # nothing unread: the wait must not end at once
    [ ! -f "$B/tasks/active" ] || ack_all "$n" "$B/tasks/$(cat "$B/tasks/active")"
    start_wait "$n" "$P/w.$i.$RANDOM" --timeout 20
  done
}
waits_down() {
  local n p
  for n in "$@"; do
    p=
    [ -f "$B/run/wait/${n%%.*}.pid" ] && p=$(cat "$B/run/wait/${n%%.*}.pid")
    [ -z "$p" ] || kill -TERM "$p" 2>/dev/null
  done
  sleep 0.5
}

test_choice_free_before_busy_then_the_earlier_joined() {
  local c x
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  c=$(join_as opencode)
  set_joined "$A" 1000
  set_joined "$Bn" 2000
  set_joined "$c" 3000
  task_new_as "$A" "Занятость"
  export BRG_TICK=0.2
  # A (the last lead) is out; Bn works (a busy mark), C is free: the free one leads, though
  # Bn joined earlier — and the marks are judged before --cancel-current clears them
  dropped "$A"
  for x in "$Bn" "$c"; do
    ack_all "$x"
    ack_all "$x" "$(tdir T001)"
  done
  start_wait "$Bn" "$P/wb" --timeout 20 --busy "работа"
  start_wait "$c" "$P/wc" --timeout 20
  printf 'x\n' | brg task new --as human --title "Новая" --cancel-current >/dev/null || fail "task new"
  assert_eq "${c%%.*}" "$(lead_of T002)"
  # both free: the earlier joined leads (A, the previous lead, is still out)
  brg lead give "${A%%.*}" --as human >/dev/null || fail "give A"
  waits_down "$Bn" "$c"
  waits_up "$Bn" "$c"
  printf 'x\n' | brg task new --as human --title "Ещё" --cancel-current >/dev/null || fail "task new 3"
  assert_eq "${Bn%%.*}" "$(lead_of T003)" "equal footing: the earlier joined"
  # an earlier Joined-Epoch beats the name
  set_joined "$c" 500
  brg lead give "${A%%.*}" --as human >/dev/null || fail "give A 2"
  waits_down "$Bn" "$c"
  waits_up "$Bn" "$c"
  printf 'x\n' | brg task new --as human --title "И ещё" --cancel-current >/dev/null || fail "task new 4"
  assert_eq "${c%%.*}" "$(lead_of T004)" "Joined-Epoch before the name"
  # the previous lead on the line wins over everybody
  waits_down "$Bn" "$c"
  waits_up "$Bn" "$c"
  printf 'x\n' | brg task new --as human --title "И снова" --cancel-current >/dev/null || fail "task new 5"
  assert_eq "${c%%.*}" "$(lead_of T005)" "the previous lead (c) is on the line"
  waits_down "$Bn" "$c"
}

test_choice_working_between_two_waits_is_on_the_line() {
  local c now
  new_proj
  printf 'asleep_after: 900\ngone_after: 3000\n' >>"$B/config"
  A=$(join_as claude)
  Bn=$(join_as codex)
  c=$(join_as opencode)
  # A: no wait, a brg call just now (working) — on the line; C: a recent call, but the last
  # wait ended long ago («не на связи»); Bn: silent for long
  now=$(date -u +%s)
  printf '%s\n' $((now - 5)) >"$B/run/seen/${A%%.*}"
  printf '%s\n' $((now - 5)) >"$B/run/wait/${A%%.*}.last"
  printf '%s\n' $((now - 5)) >"$B/run/seen/${c%%.*}"
  printf '%s\n' $((now - 200)) >"$B/run/wait/${c%%.*}.last"
  printf '%s\n' $((now - 500)) >"$B/run/seen/${Bn%%.*}"
  printf '%s\n' $((now - 500)) >"$B/run/wait/${Bn%%.*}.last"
  assert_contains "$(brg who)" "${c%%.*} · opencode · m · работает · активен "
  assert_contains "$(brg who)" "не на связи"
  set_joined "$c" 1
  set_joined "$A" 2
  printf 'x\n' | brg task new --as human --title "Между wait" >/dev/null || fail "task new"
  assert_eq "${A%%.*}" "$(lead_of T001)" "working without «не на связи» is on the line; the others are not"
}

test_choice_skips_personal_pause_and_stop() {
  local c d
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  c=$(join_as opencode)
  d=$(join_as claude)
  set_joined "$c" 1000
  set_joined "$d" 2000
  task_new_as "$A" "Пропуск"
  close_as "$A"
  # the last lead (A) is paused, Bn is stopped: C leads (D joined later)
  brg pause "${A%%.*}" >/dev/null
  brg stop "${Bn%%.*}" >/dev/null
  printf 'x\n' | brg task new --as human --title "Выбор" >/dev/null || fail "task new"
  assert_eq "${c%%.*}" "$(lead_of T002)"
  # everybody is paused or stopped: nobody
  close_as "$c"
  brg pause "${c%%.*}" >/dev/null
  brg pause "${d%%.*}" >/dev/null
  printf 'x\n' | brg task new --as human --title "Никого" >/dev/null || fail "task new 3"
  assert_eq "" "$(lead_of T003)"
}

# the first agent on the line takes the empty Lead: in wait, at once (before the pid file)
test_wait_takes_the_empty_lead() {
  local out f
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  nobody_online "$A" "$Bn"
  printf 'x\n' | brg task new --as human --title "Пустая" >/dev/null || fail "task new"
  assert_eq "" "$(lead_of T001)"
  ack_all "$Bn"
  out=$(brg wait --as "$A" --timeout 2)
  assert_eq "${A%%.*}" "$(lead_of T001)"
  f=$(tmsg T001 1)
  assert_eq brg "$(hdr "$f" From)"
  assert_eq all "$(hdr "$f" To)"
  assert_eq system "$(hdr "$f" Kind)"
  assert_eq "" "$(hdr "$f" Wake)" "wakes everybody"
  assert_contains "$(cat "$f")" "${A%%.*} — lead задачи T001 (назначен brg: первый на связи). ${A%%.*}: постановка — .brigada/tasks/T001/brief.md; начни с PROTOCOL.md, раздел 4."
  # the new lead gets the announcement in that very wait (a message From: brg, not its own)
  assert_contains "$out" "[система] brg → all"
  assert_contains "$out" "${A%%.*} — lead задачи T001 (назначен brg: первый на связи)"
  # another agent's wait: not a lead any more, it sees who leads
  out=$(brg wait --as "$Bn" --timeout 2)
  assert_eq "${A%%.*}" "$(lead_of T001)"
  assert_contains "$out" "${A%%.*} — lead задачи T001"
  assert_eq 1 "$(lead_msgs T001)"
  assert_contains "$(metrics_of "$A" lead.auto)" "id=T001"
}

test_wait_does_not_take_the_lead_for_a_stopped_or_paused_agent() {
  local out
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  nobody_online "$A" "$Bn"
  printf 'x\n' | brg task new --as human --title "Пустая" >/dev/null || fail "task new"
  brg stop "${A%%.*}" >/dev/null
  out=$(brg wait --as "$A" --timeout 1)
  assert_contains "$out" "── STOP"
  assert_eq "" "$(lead_of T001)" "a stopped agent does not take the lead (it would get STOP at once)"
  brg resume "${A%%.*}" >/dev/null
  brg pause "${A%%.*}" >/dev/null
  out=$(brg wait --as "$A" --timeout 1)
  assert_contains "$out" "пауза продолжается" "the paused wait woke for the human's message only"
  assert_eq "" "$(lead_of T001)" "nor an agent on a personal pause"
  # another agent does; the paused one takes nothing after resume: it is a participant already
  out=$(brg wait --as "$Bn" --timeout 1)
  assert_eq "${Bn%%.*}" "$(lead_of T001)"
  brg resume "${A%%.*}" >/dev/null
  brg wait --as "$A" --timeout 0 >/dev/null
  assert_eq "${Bn%%.*}" "$(lead_of T001)"
}

# the race of two waits for an empty lead: exactly one lead, one announcement
test_two_waits_race_for_the_empty_lead() {
  local i
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  for i in 1 2 3; do
    nobody_online "$A" "$Bn"
    printf 'x\n' | brg task new --as human --title "Гонка $i" >/dev/null || fail "task new $i"
    assert_eq "" "$(lead_of "T00$i")"
    bash "$BRG" wait --as "$A" --timeout 1 >"$P/ra" 2>&1 &
    pa=$!
    bash "$BRG" wait --as "$Bn" --timeout 1 >"$P/rb" 2>&1 &
    pb=$!
    track_pid $pa
    track_pid $pb
    wait_pid $pa 6 || fail "A hung"
    wait_pid $pb 6 || fail "B hung"
    case $(lead_of "T00$i") in "${A%%.*}" | "${Bn%%.*}") ;; *) fail "no lead after the race $i: [$(lead_of "T00$i")]" ;; esac
    assert_eq 1 "$(lead_msgs "T00$i")" "one announcement in the race $i"
    printf '# итог\n' >"$(tdir "T00$i")/summary.md"
    brg task cancel --as human >/dev/null || fail "cancel $i"
  done
}

# a task made under a running wait (it was not «on the line» when the task was created)
# gets its lead from that wait at the next tick
test_running_wait_takes_the_lead_of_a_task_made_under_it() {
  local out
  new_proj
  A=$(join_as claude)
  export BRG_TICK=0.2
  start_wait "$A" "$P/wa" --timeout 20
  hand_task ""
  wait_pid "$WP" 4 || fail "the running wait did not notice the task without a lead: $(cat "$P/wa")"
  assert_eq "${A%%.*}" "$(lead_of T001)"
  out=$(cat "$P/wa")
  assert_contains "$out" "${A%%.*} — lead задачи T001 (назначен brg: первый на связи)"
}

test_join_takes_the_empty_lead_after_the_cursors() {
  local out d
  new_proj
  A=$(join_as claude)
  nobody_online "$A"
  printf 'x\n' | brg task new --as human --title "Пустая" >/dev/null || fail "task new"
  out=$(brg join --harness codex --model m)
  d=$(printf '%s\n' "$out" | sed -n 's/^── подключён: \([^ ]*\) .*/\1/p')
  assert_eq "${d%%.*}" "$(lead_of T001)"
  assert_contains "$out" "Активная задача: T001 «Пустая» · lead ${d%%.*} · твоя роль: lead"
  assert_contains "$out" "── ты lead задачи T001: lead у неё не было, brg назначил тебя — ты первый на связи."
  assert_contains "$out" "send --to human --ask"
  assert_eq "── NEXT: прочитай постановку .brigada/tasks/T001/brief.md и PROTOCOL.md, раздел 4; закончив шаг — bash $BRG wait --as $d" "$(printf '%s\n' "$out" | tail -n 1)"
  # the announcement lies behind the cursor: the new lead's first wait delivers it
  assert_eq 1 "$(lead_msgs T001)"
  out=$(brg wait --as "$d" --timeout 2)
  assert_contains "$out" "${d%%.*} — lead задачи T001 (назначен brg: первый на связи)"
  # a join of one who is paused personally (join --as after leave) takes nothing
  brg leave --as "$d" >/dev/null
  brg lead take --as "$A" >/dev/null 2>&1
  nobody_online "$A"
  printf '# итог\n' >"$(tdir T001)/summary.md"
  brg task cancel --as human >/dev/null
  printf 'x\n' | brg task new --as human --title "Ещё пустая" >/dev/null
  assert_eq "" "$(lead_of T002)"
  brg pause "${d%%.*}" >/dev/null
  out=$(brg join --as "$d" --harness codex)
  assert_eq "" "$(lead_of T002)" "a paused agent does not take the lead in join"
  assert_not_contains "$out" "ты lead задачи"
}

test_lead_take_when_there_is_no_lead() {
  local out
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  nobody_online "$A" "$Bn"
  printf 'x\n' | brg task new --as human --title "Пустая" >/dev/null || fail "task new"
  out=$(brg lead take --as "$Bn")
  assert_eq 0 "$?"
  assert_contains "$out" "── lead задачи T001: нет → ${Bn%%.*}."
  assert_eq "${Bn%%.*}" "$(lead_of T001)"
  assert_contains "$(cat "$(tmsg T001 1)")" "lead задачи T001: нет → ${Bn%%.*} (взял ${Bn%%.*}: lead не было)"
}

test_lead_leaves_and_nobody_is_on_the_line() {
  local out
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  task_new_as "$A" "Уход"
  nobody_online "$Bn"
  out=$(brg leave --as "$A")
  assert_contains "$out" "Ты был lead задачи T001: lead назначится первому, кто выйдет на связь"
  assert_eq "" "$(lead_of T001)"
  assert_contains "$(cat "$(msg_file "$(cat "$B/lobby/seq")")")" "${A%%.*} отключился (был lead задачи T001 — lead назначится первому, кто выйдет на связь"
  out=$(brg wait --as "$Bn" --timeout 1)
  assert_eq "${Bn%%.*}" "$(lead_of T001)" "the first wait takes the role"
  assert_contains "$out" "${Bn%%.*} — lead задачи T001"
}

test_lead_give_as_human() {
  local out f
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  task_new_as "$A" "Назначение"
  ack_all "$A" "$(tdir T001)"
  ack_all "$Bn" "$(tdir T001)"
  out=$(brg lead give "${Bn%%.*}" --as human)
  assert_eq 0 "$?"
  assert_contains "$out" "── lead задачи T001: ${A%%.*} → ${Bn%%.*}."
  assert_not_contains "$out" "NEXT"
  assert_eq "${Bn%%.*}" "$(lead_of T001)"
  f=$(tmsg T001 1)
  assert_eq human "$(hdr "$f" From)"
  assert_eq all "$(hdr "$f" To)"
  assert_eq "" "$(hdr "$f" Wake)"
  assert_contains "$(cat "$f")" "lead задачи T001: ${A%%.*} → ${Bn%%.*} (передал human)"
  assert_contains "$(brg wait --as "$A" --timeout 1)" "lead задачи T001: ${A%%.*} → ${Bn%%.*} (передал human)"
  # already the lead: no message
  out=$(brg lead give "${Bn%%.*}" --as human)
  assert_contains "$out" "── ${Bn%%.*} уже lead задачи T001"
  assert_file_not_exists "$(tmsg T001 2)"
  # the full name is fine; a gone agent is not
  brg leave --as "$A" >/dev/null
  out=$(brg lead give "${A%%.*}" --as human 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "gone: передавать роль некому"
  assert_not_contains "$out" "NEXT"
  # a task without a lead too (nobody is on the line when it is made)
  nobody_online "$Bn"
  brg task cancel --as human >/dev/null
  printf 'x\n' | brg task new --as human --title "Без lead" >/dev/null || fail "task new"
  assert_eq "" "$(lead_of T002)"
  out=$(brg lead give "${Bn%%.*}" --as human)
  assert_contains "$out" "── lead задачи T002: нет → ${Bn%%.*}."
  assert_contains "$(cat "$(tmsg T002 1)")" "lead задачи T002: нет → ${Bn%%.*} (передал human)"
  # take is not for the human
  out=$(brg lead take --as human 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "человек назначает lead'а так: "
  # no active task
  brg task cancel --as human >/dev/null
  out=$(brg lead give "${Bn%%.*}" --as human 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет активной задачи"
}

test_task_cancel_by_lead_or_human_only() {
  local out
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  task_new_as "$A" "Отмена"
  out=$(brg task cancel --as "$Bn" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "отменить задачу T001 может lead или человек (lead ${A%%.*})"
  assert_contains "$out" "Предложи отмену lead: bash $BRG send --as $Bn --to ${A%%.*}"
  out=$(brg task cancel --as "$A")
  assert_eq 0 "$?"
  assert_contains "$out" "── задача T001 «Отмена» отменена"
  # no lead: only the human (and a closing needs one)
  hand_task ""
  out=$(brg task cancel --as "$Bn" 2>&1)
  assert_contains "$out" "отменить задачу T001 может lead или человек (lead — нет"
  out=$(brg task close --as "$Bn" 2>&1)
  assert_contains "$out" "закрыть задачу T001 может только lead, а у неё его нет"
  assert_contains "$out" "lead take --as $Bn"
}

# a general stop: nobody is on the line (their turns are over), the lead stays empty until
# an agent wakes — the new task lifts the stop after the choice
test_choice_under_a_general_stop_leaves_the_lead_empty() {
  local out
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  task_new_as "$A" "Стоп"
  brg stop >/dev/null
  out=$(printf 'x\n' | brg task new --as human --title "После стопа" --cancel-current) || fail "task new"
  assert_contains "$out" "Общий стоп снят. Остановленные агенты завершили ход — напиши им в харнессе «продолжай»."
  assert_eq "" "$(lead_of T002)" "a stopped agent is not chosen"
  assert_file_not_exists "$B/run/stopped" "the new task lifted the stop"
  # the first agent that wakes takes the role
  assert_contains "$(brg wait --as "$Bn" --timeout 1)" "${Bn%%.*} — lead задачи T002"
  assert_eq "${Bn%%.*}" "$(lead_of T002)"
  # a lead leaving under a general stop: nobody is chosen either
  brg stop >/dev/null
  brg leave --as "$Bn" >/dev/null
  assert_eq "" "$(lead_of T002)"
}

# the change of the lead on leave is also a quiet line in the task channel
test_leave_of_the_lead_writes_to_the_task_channel() {
  local f
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  task_new_as "$A" "Канал"
  brg leave --as "$A" >/dev/null
  f=$(tmsg T001 1)
  assert_eq "${A%%.*}" "$(hdr "$f" From)"
  assert_eq no "$(hdr "$f" Wake)" "no second wake: the lobby message woke everybody"
  assert_contains "$(cat "$f")" "lead задачи T001: ${A%%.*} → ${Bn%%.*} (${A%%.*} отключился)"
  assert_eq "" "$(hdr "$(msg_file "$(cat "$B/lobby/seq")")" Wake)" "the lobby message wakes"
}

# a wait that dies in lead_self (the message cannot be written) leaves no pid file behind
test_wait_dying_in_lead_self_releases_its_pid_file() {
  local out
  new_proj
  A=$(join_as claude)
  export BRG_TICK=0.2
  start_wait "$A" "$P/wa" --timeout 20
  hand_task ""
  chmod a-w "$B/tasks/T001-manual/messages"
  wait_pid "$WP" 4 || { chmod u+w "$B/tasks/T001-manual/messages"; fail "the wait did not end"; }
  chmod u+w "$B/tasks/T001-manual/messages"
  [ ! -f "$B/run/wait/${A%%.*}.pid" ] || [ "$(cat "$B/run/wait/${A%%.*}.pid")" != "$WP" ] || fail "the dead wait left its pid file"
  out=$(cat "$P/wa")
  assert_contains "$out" "── ОШИБКА: не удалось записать"
  assert_contains "$out" "── NEXT:"
}
