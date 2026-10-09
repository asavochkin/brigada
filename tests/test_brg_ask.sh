# Questions to the human (DESIGN §9.2): send --ask, the markers in run/asks/, their
# closing by a reply (send/say --re) and by task close/cancel; who, status, the board.

. "$TESTS_DIR/brg_lib.sh"

# ask_setup — A (claude-1, lead of T001), C (opencode-1); D — the task dir
ask_setup() {
  new_proj
  A=$(join_as claude opus)
  C=$(join_as opencode m)
  task_new_as "$A" "Вопросы"
  D=$(tdir T001)
}
# file_has FILE TEXT — FILE contains TEXT
file_has() { case $(cat "$1" 2>/dev/null) in *"$2"*) return 0 ;; esac; return 1; }
# ask_as NAME TEXT [send options...] → prints the message number
ask_as() {
  local n=$1 t=$2
  shift 2
  printf '%s\n' "$t" | brg send --as "$n" --to human --ask "$@" | sed -n 's/^── отправлено #\([0-9]*\) .*/\1/p'
}

test_ask_needs_human() {
  local out
  ask_setup
  out=$(printf 'q\n' | brg send --as "$C" --to "${A%%.*}" --ask 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "--ask — вопрос человеку: нужен --to human"
  assert_contains "$out" "── NEXT:"
  out=$(printf 'q\n' | brg send --as "$C" --ask 2>&1)
  assert_eq 1 "$?" "--to all is not the human"
  assert_eq "" "$(ls -A "$B/run/asks" 2>/dev/null)" "no marker"
  out=$(printf 'q\n' | brg send --as "$C" --to "human,${A%%.*}" --ask)
  assert_eq 0 "$?" "the human among others"
  assert_contains "$out" "Вопрос человеку #1 открыт"
  assert_eq yes "$(hdr "$(tmsg T001 1)" Ask)"
  assert_file_exists "$B/run/asks/T001.1"
  assert_contains "$(brg send --help)" "[--ask]"
  assert_contains "$(brg say --help)" "[--re N]"
}

# A question is open until a message with Re: N in its channel — from an agent or
# the human; a reply to something else does not close it.
test_ask_open_and_closed_by_replies() {
  local q1 q2 q3 out
  ask_setup
  q1=$(ask_as "$C" "Можно закрыть приложение на порту 8080?")
  q2=$(ask_as "$C" "Какую базу брать для тестов?")
  assert_eq 1 "$q1"
  assert_eq 2 "$q2"
  assert_file_exists "$B/run/asks/T001.1"
  out=$(brg who)
  assert_contains "$out" "── ждут ответа человека: ${C%%.*} #1 (T001, "
  assert_contains "$out" ", ${C%%.*} #2 (T001, "
  assert_contains "$(brg status --as "$C")" "Мои вопросы человеку (открыты): #1 (T001, "
  assert_not_contains "$(brg status --as "$A")" "вопросы человеку"
  # a reply to another message does not close it
  send_as "$A" "просто сообщение"
  send_as "$A" "обсуждаем" --re 3
  assert_file_exists "$B/run/asks/T001.2"
  assert_file_exists "$B/run/asks/T001.1"
  # the agent forwards the answer: closed
  out=$(printf 'человек разрешил\n' | brg send --as "$C" --re 1)
  assert_contains "$out" "Вопрос человеку #1 закрыт"
  assert_file_not_exists "$B/run/asks/T001.1"
  assert_contains "$(metrics_of "$C" send | tail -n 1)" "closed=1"
  # the human answers from the terminal
  out=$(brg say --re 2 "SQLite")
  assert_eq 0 "$?"
  assert_contains "$out" "· re #2."
  assert_contains "$out" "Вопрос #2 закрыт"
  assert_eq 2 "$(hdr "$(tmsg T001 "$(cat "$D/seq")")" Re)"
  assert_file_not_exists "$B/run/asks/T001.2"
  assert_not_contains "$(brg who)" "ждут ответа"
  # say --re: the message must exist in the channel (the other one is named)
  out=$(brg say --re 99 "x" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "в канале T001 нет сообщения #99"
  q3=$(ask_as "$C" "В lobby?" --channel lobby)
  assert_file_exists "$B/run/asks/lobby.$q3"
  out=$(brg say --re "$q3" "да" 2>&1)
  if [ -f "$(tmsg T001 "$q3")" ]; then :; else
    assert_contains "$out" "#$q3 есть в lobby — ответ туда: добавь --channel lobby"
  fi
  brg say --channel lobby --re "$q3" "да" >/dev/null || fail "say --channel lobby --re"
  assert_file_not_exists "$B/run/asks/lobby.$q3"
}

# Closing or cancelling the task drops its open questions; lobby ones stay.
test_ask_dropped_by_task_close_and_cancel() {
  local q
  ask_setup
  ask_as "$C" "Вопрос в задаче" >/dev/null
  q=$(ask_as "$C" "Вопрос в lobby" --channel lobby)
  printf 'итог\n' >"$D/summary.md"
  brg task close --as "$A" >/dev/null 2>&1 || brg task close --as "$A" >/dev/null || fail close
  assert_file_not_exists "$B/run/asks/T001.1"
  assert_file_exists "$B/run/asks/lobby.$q"
  assert_contains "$(brg who)" "── ждут ответа человека: ${C%%.*} #$q (lobby, "
  task_new_as "$A" "Вторая"
  ask_as "$C" "Вопрос во второй" >/dev/null
  printf 'x\n' | brg task new --as "$A" --title "Третья" --cancel-current >/dev/null || fail "cancel-current"
  assert_eq "" "$(ls "$B/run/asks" | awk '/^T002\./')" "markers of the cancelled task"
  assert_file_exists "$B/run/asks/lobby.$q"
  # a stale marker of a finished task (a race with close) is not shown
  printf 'Channel: T002\nId: 1\nFrom: x\nEpoch: 1\n' >"$B/run/asks/T002.1"
  assert_not_contains "$(brg who)" "T002"
}

# The board: the open questions (message records + chan), a 3-character prefix of
# each key and never the key; the terminal of brg board names each new question once.
test_ask_on_the_board() {
  local out k bp q
  ask_setup
  ask_as "$C" "Можно ли закрыть работающее приложение для smoke-теста? Оно держит порт 8080 и мешает тестам" >/dev/null
  out=$(brg board --once)
  assert_contains "$out" "── вопрос человеку от ${C%%.*} (#1, T001): Можно ли закрыть работающее приложение для smoke-теста? Оно держит порт 8080 и мешает тестам — ответь в его чате или: brg say --to ${C%%.*} --re 1 …"
  out=$(cat "$B/run/board/data.js")
  assert_contains "$out" '"asks":[{"f":"000001.msg","h":{"Id":"1","Channel":"T001"'
  assert_contains "$out" '"Ask":"yes"'
  assert_contains "$out" '"chan":"T001"}]'
  for x in "$A" "$C"; do
    k=${x#*.}
    assert_contains "$out" "\"kp\":\"${k:0:3}\""
    assert_not_contains "$out" "$k" "the full key leaks onto the board"
  done
  # a long first line is cut to 120 characters
  ask_as "$C" "$(awk 'BEGIN { for (i = 0; i < 130; i++) printf "ж" }')" --channel lobby >/dev/null
  out=$(brg board --once)
  assert_contains "$out" "(#$(cat "$B/lobby/seq"), lobby): $(awk 'BEGIN { for (i = 0; i < 119; i++) printf "ж" }')… — ответь в его чате или: brg say --to ${C%%.*} --channel lobby --re"
  # the loop: each question once, a new one when it comes
  out=$(mk_tmpdir)/out
  bash "$BRG" board --interval 1 >"$out" 2>&1 &
  bp=$!
  track_pid $bp
  wait_for 5 test -f "$B/run/board/data.js" || fail "no data.js"
  sleep 2
  q=$(ask_as "$C" "Третий вопрос")
  wait_for 4 file_has "$out" "Третий вопрос" || fail "the new question is not shown"
  sleep 2
  kill -TERM $bp
  wait_pid $bp 5 || fail "board did not exit"
  assert_eq 3 "$(awk '/^── вопрос человеку от/' "$out" | wc -l | tr -d ' ')" "each question once"
  assert_eq 1 "$(awk '/Третий вопрос/' "$out" | wc -l | tr -d ' ')"
  # answered: off the board
  brg say --re "$q" "ок" >/dev/null || fail say
  brg board --once >/dev/null || fail board
  out=$(cat "$B/run/board/data.js")
  out=${out#*\"asks\":[}
  out=${out%%\"meta\":*}
  assert_not_contains "$out" "Третий вопрос" "an answered question is not among asks"
  assert_contains "$out" "\"chan\":\"lobby\"" "the open one stays"
}

# Only the human or the author closes a question: another addressee's reply does not.
test_ask_closed_only_by_human_or_author() {
  local q out
  ask_setup
  q=$(ask_as "$C" "Человек, codex: чей формат дат берём?" --to "human,${A%%.*}")
  out=$(printf 'я бы взял ISO\n' | brg send --as "$A" --re "$q")
  assert_eq 0 "$?"
  assert_not_contains "$out" "закрыт"
  assert_file_exists "$B/run/asks/T001.$q" "another addressee does not close it"
  assert_contains "$(brg who)" "${C%%.*} #$q (T001, "
  out=$(printf 'человек: ISO\n' | brg send --as "$C" --re "$q")
  assert_contains "$out" "Вопрос человеку #$q закрыт"
  assert_file_not_exists "$B/run/asks/T001.$q"
}

# A question outside the default channel (lobby while a task is active): every hint
# names --channel; a reply to the same number in the wrong channel is warned about.
test_ask_hints_name_the_channel() {
  local q out
  ask_setup
  for x in 1 2 3 4 5 6; do send_as "$A" "сообщение $x"; done
  out=$(printf 'Вопрос из lobby\n' | brg send --as "$C" --to human --ask --channel lobby)
  q=$(printf '%s\n' "$out" | sed -n 's/^── отправлено #\([0-9]*\) .*/\1/p')
  assert_contains "$out" "перешли суть бригаде: bash $BRG send --as $C --channel lobby --re $q <<'BRG_EOF'"
  out=$(brg who)
  assert_contains "$out" "── ждут ответа человека: ${C%%.*} #$q (lobby, "
  assert_contains "$out" "   bash $BRG say --to ${C%%.*} --channel lobby --re $q \"ответ\""
  out=$(brg status --as "$C")
  assert_contains "$out" "   #$q: bash $BRG send --as $C --channel lobby --re $q <<'BRG_EOF' … BRG_EOF"
  # a reply to #q of the task channel (not a question): warned, the question stays open
  out=$(printf 'ответ не туда\n' | brg send --as "$C" --re "$q")
  assert_contains "$out" "Внимание: #$q в T001 — не открытый вопрос, а открытый вопрос #$q — в lobby: ответ на него — с --channel lobby."
  assert_file_exists "$B/run/asks/lobby.$q"
  out=$(brg say --re "$q" "тоже не туда")
  assert_contains "$out" "открытый вопрос #$q — в lobby"
  brg say --channel lobby --re "$q" "да" >/dev/null || fail "say --channel lobby"
  assert_file_not_exists "$B/run/asks/lobby.$q"
}

# The first line of a question is cut to 120 characters exactly, on a mixed line too.
test_ask_first_line_cut_mixed() {
  local a118 out
  ask_setup
  a118=$(awk 'BEGIN { for (i = 0; i < 118; i++) printf "a" }')
  ask_as "$C" "${a118}жbcccccccccc" >/dev/null
  out=$(brg board --once)
  # 120 characters with the mark: 118 × a, ж, … (the ж is not lost before b)
  assert_contains "$out" "(#1, T001): ${a118}ж… — ответь в его чате"
  ask_as "$C" "$(awk 'BEGIN { for (i = 0; i < 125; i++) printf "€" }')" >/dev/null
  out=$(brg board --once)
  assert_contains "$out" "(#2, T001): $(awk 'BEGIN { for (i = 0; i < 119; i++) printf "€" }')… — ответь"
}
