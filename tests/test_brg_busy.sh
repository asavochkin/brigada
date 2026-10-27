# The busy mark (DESIGN §5.4, §5.2): "ждёт" = free, wait --busy / busy / claim / review --start
# = "работает"; NEXT carries --busy while the mark stands; the mark is valid for the active task only.

. "$TESTS_DIR/brg_lib.sh"

# a task T001 led by A (claude, opus); Bn (codex, gpt), C (opencode, gpt); inboxes empty
busy_setup() {
  new_proj
  A=$(join_as claude opus)
  Bn=$(join_as codex gpt)
  C=$(join_as opencode gpt)
  task_new_as "$A" "Пометки"
  D=$(tdir T001)
  for x in "$A" "$Bn" "$C"; do
    ack_all "$x"
    ack_all "$x" "$D"
  done
}
mfile() { printf '%s/run/busy/%s' "$B" "${1%%.*}"; }
mk() { hdr "$(mfile "$1")" "$2"; } # NAME KEY — a header of the mark
last_line() { printf '%s\n' "$1" | tail -n 1; }
# set_since NAME EPOCH — rewrite Since of the mark (to check that it is kept)
set_since() {
  awk -v s="$2" '/^Since: / { print "Since: " s; next } { print }' "$(mfile "$1")" >"$(mfile "$1").x" && mv "$(mfile "$1").x" "$(mfile "$1")"
}
item_add_as() { printf '%s\n' "${3:-описание}" | brg item add --as "$1" --title "$2" >/dev/null || fail "item add as $1: $2"; }
line_of() { printf '%s\n' "$1" | awk -v n="${2%%.*}" 'index($0, n " ") == 1'; } # the who line of an agent

# «Б1» (the mechanical check): wait commands of NEXT are built in one place
test_next_wait_built_only_in_next_wait() {
  local out
  out=$(awk '/wait --as \$ASN|wait --as \$AS_HINT/ { print NR ": " $0 }' "$BRG_SRC")
  assert_eq "" "$out" "a NEXT with wait --as outside next_wait"
}

test_wait_busy_sets_mark_and_next_repeats_it() {
  local out
  busy_setup
  out=$(brg wait --as "$A" --busy "финальная валидация" --timeout 0)
  assert_contains "$out" "Ты отмечен «работает: финальная валидация». Подагент закончил и ты свободен — следующий wait без --busy."
  assert_eq "── нет новых (0 с) · ход не завершай · NEXT: bash $BRG wait --as $A --busy \"финальная валидация\" --timeout 0" "$(last_line "$out")"
  assert_eq T001 "$(mk "$A" Task)"
  assert_eq "финальная валидация" "$(mk "$A" Note)"
  assert_eq wait "$(mk "$A" Via)"
  assert_eq "" "$(mk "$A" Item)"
  [ "$(mk "$A" Since)" -gt 0 ] || fail "no Since"
  # a plain wait is the explicit "free": the mark goes, NEXT has no --busy
  out=$(brg wait --as "$A" --timeout 0)
  assert_file_not_exists "$(mfile "$A")"
  assert_eq "── нет новых (0 с) · ход не завершай · NEXT: bash $BRG wait --as $A --timeout 0" "$(last_line "$out")"
  assert_not_contains "$out" "отмечен"
}

# --busy without a caption: a bare --busy in NEXT (never --busy "")
test_wait_busy_without_caption() {
  local out
  busy_setup
  out=$(brg wait --as "$A" --busy --timeout 0)
  assert_eq "── нет новых (0 с) · ход не завершай · NEXT: bash $BRG wait --as $A --busy --timeout 0" "$(last_line "$out")"
  assert_contains "$out" "Ты отмечен «работает». Подагент"
  assert_eq "" "$(mk "$A" Note)"
  # --busy followed by an option: still without a caption
  out=$(brg wait --as "$A" --busy --timeout 0 | tail -n 1)
  assert_contains "$out" "wait --as $A --busy --timeout 0"
  out=$(brg send --as "$A" --to human <<<"привет")
  assert_eq "── NEXT: продолжай; закончив шаг — bash $BRG wait --as $A --busy" "$(last_line "$out")"
  # an empty caption given as an argument is the same
  out=$(brg wait --as "$A" --busy "" --timeout 0)
  assert_contains "$out" "NEXT: bash $BRG wait --as $A --busy --timeout 0"
}

test_busy_caption_is_cut_not_refused() {
  local out
  busy_setup
  out=$(brg wait --as "$A" --busy "три слова вот" --timeout 0)
  assert_contains "$out" "Внимание: подпись сокращена до «три слова»"
  assert_eq "три слова" "$(mk "$A" Note)"
  out=$(brg wait --as "$A" --busy 'a"b $HOME `x` 100% it'"'"'s \z' --timeout 0)
  assert_contains "$out" "Внимание: подпись сокращена до «a b»"
  assert_eq "a b" "$(mk "$A" Note)"
  assert_eq "── нет новых (0 с) · ход не завершай · NEXT: bash $BRG wait --as $A --busy \"a b\" --timeout 0" "$(last_line "$out")"
  # 48 bytes at a UTF-8 boundary (the cut never splits a character)
  out=$(brg wait --as "$A" --busy "ааааааааааааааааааааааааааааааа бб" --timeout 0)
  assert_contains "$out" "Внимание: подпись сокращена"
  [ ${#out} -gt 0 ] || fail "no output"
  [ "$(printf '%s' "$(mk "$A" Note)" | wc -c | tr -d ' ')" -le 48 ] || fail "caption longer than 48 bytes: $(mk "$A" Note)"
  assert_eq "аааааааааааааааааааааааа" "$(mk "$A" Note)" "24 letters = 48 bytes, cut at a character"
  # only separators: a mark without a caption
  out=$(brg wait --as "$A" --busy '"$"' --timeout 0)
  assert_eq "" "$(mk "$A" Note)"
  assert_contains "$out" "Внимание: в подписи остались только недопустимые символы"
  assert_contains "$(last_line "$out")" "wait --as $A --busy --timeout 0"
}

test_busy_since_item_kept_only_for_the_same_valid_caption() {
  local out
  busy_setup
  brg wait --as "$A" --busy "ревью" --timeout 0 >/dev/null
  set_since "$A" 1000
  brg wait --as "$A" --busy "ревью" --timeout 0 >/dev/null
  assert_eq 1000 "$(mk "$A" Since)" "the same caption keeps Since"
  brg wait --as "$A" --busy "другое" --timeout 0 >/dev/null
  [ "$(mk "$A" Since)" -gt 1000 ] || fail "a new caption keeps the old Since"
  # claim: Note and Item are the item; a wait --busy "I001" after it keeps Item and Since
  item_add_as "$A" "Первая"
  brg item claim I001 --as "$A" --paths src/a >/dev/null || fail claim
  assert_eq I001 "$(mk "$A" Item)"
  assert_eq claim "$(mk "$A" Via)"
  set_since "$A" 1000
  brg wait --as "$A" --busy "I001" --timeout 0 >/dev/null
  assert_eq 1000 "$(mk "$A" Since)"
  assert_eq I001 "$(mk "$A" Item)" "Item kept with the same caption"
  assert_eq wait "$(mk "$A" Via)" "Via is always wait"
  # a stale mark (another task) is not carried over
  brg busy --as "$A" "ручная" >/dev/null
  assert_eq busy "$(mk "$A" Via)"
  awk '/^Task: / { print "Task: T099"; next } { print }' "$(mfile "$A")" >"$(mfile "$A").x" && mv "$(mfile "$A").x" "$(mfile "$A")"
  set_since "$A" 1000
  brg wait --as "$A" --busy "ручная" --timeout 0 >/dev/null
  [ "$(mk "$A" Since)" -gt 1000 ] || fail "a stale mark gave Since"
  assert_eq T001 "$(mk "$A" Task)"
  assert_eq wait "$(mk "$A" Via)" "wait --busy always writes Via: wait"
}

# «Б1»: every NEXT carries --busy while the mark stands, errors included
test_next_of_every_command_carries_busy() {
  local out n
  busy_setup
  item_add_as "$A" "Первая"
  brg wait --as "$A" --busy "финальная валидация" --timeout 0 >/dev/null
  n="wait --as $A --busy \"финальная валидация\""
  out=$(brg send --as "$A" --to human <<<"x")
  assert_contains "$(last_line "$out")" "$n"
  out=$(brg read --as "$A")
  assert_contains "$(last_line "$out")" "$n"
  out=$(brg status --as "$A")
  assert_contains "$(last_line "$out")" "$n"
  out=$(brg item show I001 --as "$A")
  assert_contains "$(last_line "$out")" "$n"
  out=$(brg item list --as "$A")
  assert_contains "$(last_line "$out")" "$n"
  out=$(brg task show --as "$A")
  assert_contains "$(last_line "$out")" "$n"
  out=$(brg run list --as "$A")
  assert_contains "$(last_line "$out")" "$n"
  # errors: after need_agent and before it (AS_HINT), parse errors of wait itself
  out=$(brg item claim I099 --as "$A" --paths x 2>&1)
  assert_contains "$out" "── ОШИБКА"
  assert_contains "$(last_line "$out")" "$n"
  out=$(brg item bogus --as "$A" 2>&1)
  assert_contains "$(last_line "$out")" "$n"
  out=$(brg send --as "$A" --to nobody <<<"x" 2>&1)
  assert_contains "$(last_line "$out")" "$n"
  out=$(brg wait --as "$A" --bogus)
  assert_contains "$out" "── ОШИБКА: неизвестный параметр: --bogus"
  assert_contains "$(last_line "$out")" "$n"
  assert_eq "$(mk "$A" Note)" "финальная валидация" "an error does not touch the mark"
  out=$(brg wait --as "$A" --timeout x)
  assert_contains "$(last_line "$out")" "$n"
  out=$(brg lead give "${Bn%%.*}" --as "$A" 2>&1)
  assert_contains "$(last_line "$out")" "$n"
  # a read command with the bare name (a subagent): no --busy in the hint
  out=$(brg status --as "${A%%.*}")
  assert_not_contains "$(last_line "$out")" "--busy"
  # an unknown agent / unknown name: plain
  out=$(brg wait --as nobody-1.abcdef)
  assert_not_contains "$out" "--busy"
}

test_claim_and_review_start_set_the_mark_and_item_commands_clear_it() {
  local out
  busy_setup
  item_add_as "$A" "Первая"
  item_add_as "$A" "Вторая"
  out=$(brg item claim I001 --as "$Bn" --paths src/a)
  assert_eq I001 "$(mk "$Bn" Note)"
  assert_eq I001 "$(mk "$Bn" Item)"
  assert_eq claim "$(mk "$Bn" Via)"
  assert_eq "── NEXT: поручи I001 подагенту, затем bash $BRG wait --as $Bn --busy \"I001\"" "$(last_line "$out")"
  # somebody else's item command does not touch it
  brg item claim I002 --as "$C" --paths src/b >/dev/null
  assert_eq I001 "$(mk "$Bn" Item)"
  assert_eq I002 "$(mk "$C" Item)"
  # done by the assignee: gone; NEXT is plain
  out=$(brg item done I001 --as "$Bn" --note ok)
  assert_file_not_exists "$(mfile "$Bn")"
  assert_eq "── NEXT: возьми следующую подзадачу (bash $BRG item list --status todo) или bash $BRG wait --as $Bn" "$(last_line "$out")"
  assert_eq I002 "$(mk "$C" Item)"
  # review --start: a mark of its own; the verdict ends it
  out=$(brg item review I001 --as "$C" --start)
  assert_eq "проверка I001" "$(mk "$C" Note)"
  assert_eq I001 "$(mk "$C" Item)"
  assert_eq review "$(mk "$C" Via)"
  assert_eq "── NEXT: поручи проверку I001 подагенту, затем bash $BRG wait --as $C --busy \"проверка I001\"" "$(last_line "$out")"
  # C still has I002 claimed, so its verdict (not its item) ends the review mark only
  out=$(brg item review I001 --as "$C" --verdict ok --comment ok)
  assert_file_not_exists "$(mfile "$C")" "the verdict ends the review mark"
  assert_eq "── NEXT: продолжай; закончив шаг — bash $BRG wait --as $C" "$(last_line "$out")"
}

test_release_cancel_reassign_clear_the_owners_mark_not_the_leads() {
  local out
  busy_setup
  item_add_as "$A" "Первая"
  item_add_as "$A" "Вторая"
  item_add_as "$A" "Третья"
  brg item claim I001 --as "$Bn" --paths src/a >/dev/null
  brg item claim I002 --as "$Bn" --paths src/b >/dev/null # the mark is now I002
  brg wait --as "$A" --busy "финальная валидация" --timeout 0 >/dev/null
  # the lead cancels an item the assignee does not mark: nothing happens to either mark
  brg item cancel I001 --as "$A" >/dev/null
  assert_eq I002 "$(mk "$Bn" Item)"
  assert_eq "финальная валидация" "$(mk "$A" Note)"
  # the lead releases I002 for the (asleep) assignee: the assignee's mark goes, the lead's stays
  dropped "$Bn"
  assert_file_exists "$(mfile "$Bn")"
  out=$(brg item release I002 --as "$A")
  assert_contains "$out" "снова todo"
  assert_file_not_exists "$(mfile "$Bn")" "release by the lead drops the assignee's mark"
  assert_eq "финальная валидация" "$(mk "$A" Note)" "the lead's own mark stays"
  assert_not_contains "$out" "Ты отмечен" "the lead letting go of another's item is not told about its own mark"
  assert_contains "$(last_line "$out")" "--busy \"финальная валидация\""
  # cancel of a claimed item by the lead clears the assignee's mark
  brg item claim I003 --as "$C" --paths src/c >/dev/null
  assert_eq I003 "$(mk "$C" Item)"
  brg item cancel I003 --as "$A" >/dev/null
  assert_file_not_exists "$(mfile "$C")"
  assert_eq "финальная валидация" "$(mk "$A" Note)"
}

test_reassign_drops_the_old_mark_and_hints_the_new_assignee() {
  local out
  busy_setup
  item_add_as "$A" "Первая"
  brg item claim I001 --as "$Bn" --paths src/a >/dev/null
  dropped "$Bn"
  out=$(brg item reassign I001 --to "${C%%.*}" --as "$A")
  assert_file_not_exists "$(mfile "$Bn")"
  assert_file_not_exists "$(mfile "$C")" "the new assignee gets no mark by itself"
  assert_contains "$(cat "$(tmsg T001 "$(cat "$D/seq")")")" "поручи её подагенту и wait --busy \"I001\""
}

# «Б3»: a mark with an empty Item is never dropped by item commands
test_mark_without_item_survives_item_commands() {
  local out
  busy_setup
  item_add_as "$A" "Первая"
  item_add_as "$A" "Вторая"
  brg item claim I001 --as "$Bn" --paths src/a >/dev/null
  brg busy --as "$Bn" "возня" >/dev/null # replaces the claim mark: Item is empty
  assert_eq "" "$(mk "$Bn" Item)"
  out=$(brg item done I001 --as "$Bn" --note ok)
  assert_eq "возня" "$(mk "$Bn" Note)" "done keeps a mark without Item"
  assert_contains "$out" "Ты отмечен «работает: возня» — если подагент закончил, следующий wait без --busy."
  assert_contains "$(last_line "$out")" "--busy \"возня\""
  # --verdict skip is a decision, not the end of a subagent's work
  brg wait --as "$C" --busy "финальная валидация" --timeout 0 >/dev/null
  out=$(brg item review I001 --as "$C" --verdict skip --comment "не нужна")
  assert_eq "финальная валидация" "$(mk "$C" Note)"
  assert_contains "$out" "Ты отмечен «работает: финальная валидация»"
  # a plain wait is what drops it
  brg wait --as "$C" --timeout 0 >/dev/null
  assert_file_not_exists "$(mfile "$C")"
}

test_leave_and_join_drop_the_mark() {
  local out a2
  busy_setup
  brg wait --as "$Bn" --busy "работа" --timeout 0 >/dev/null
  brg busy --as "$C" "работа" >/dev/null
  brg leave --as "$Bn" >/dev/null
  assert_file_not_exists "$(mfile "$Bn")"
  dropped "$C"
  a2=$(rejoin_as "$C" opencode)
  [ -n "$a2" ] || fail "rejoin"
  assert_file_not_exists "$(mfile "$C")" "join --as: a new session, no subagent"
}

# «Б2»: a mark is valid for the active task alone
test_mark_valid_only_for_the_active_task() {
  local out
  busy_setup
  brg wait --as "$A" --busy "работа" --timeout 0 >/dev/null
  brg busy --as "$Bn" "работа" >/dev/null
  printf 'итог\n' >"$D/summary.md"
  brg task close --as "$A" >/dev/null 2>&1 || brg task close --as "$A" >/dev/null || fail close
  assert_file_not_exists "$(mfile "$A")" "close tidies up"
  # the next wait --busy makes no mark and NEXT has no --busy
  out=$(brg wait --as "$A" --busy "работа" --timeout 0)
  assert_contains "$out" "Задачи нет — пометка «работает» не ставится."
  assert_file_not_exists "$(mfile "$A")"
  assert_eq "── нет новых (0 с) · ход не завершай · NEXT: bash $BRG wait --as $A --timeout 0" "$(last_line "$out")"
  out=$(brg busy --as "$A" "работа")
  assert_contains "$out" "Задачи нет — пометка «работает» не ставится."
  assert_file_not_exists "$(mfile "$A")"
  # a stale file (as after a race with close) does not exist for anybody
  printf 'Task: T001\nSince: %s\nNote: старая\nItem: \nVia: wait\n' "$(date -u +%s)" >"$(mfile "$A")"
  out=$(brg status --as "$A")
  assert_eq "── NEXT: bash $BRG wait --as $A" "$(last_line "$out")"
  assert_not_contains "$out" "Моя пометка"
  assert_not_contains "$(brg who)" "старая"
  # a new task: the old mark (T001) is still not valid
  task_new_as "$A" "Вторая"
  out=$(brg status --as "$A")
  assert_eq "── NEXT: bash $BRG wait --as $A" "$(last_line "$out")"
  assert_not_contains "$(brg who)" "старая"
}

test_cancel_current_and_task_cancel_tidy_up() {
  local out
  busy_setup
  brg busy --as "$Bn" "работа" >/dev/null
  assert_file_exists "$(mfile "$Bn")"
  brg task cancel --as human >/dev/null || fail cancel
  assert_file_not_exists "$(mfile "$Bn")"
}

test_busy_command() {
  local out
  busy_setup
  out=$(brg busy --as "$Bn" "два слова")
  assert_contains "$out" "── отмечено: работает: два слова."
  assert_contains "$out" "или busy --off. Подагент блокирует тебя — вызывай wait, когда он вернётся"
  assert_eq busy "$(mk "$Bn" Via)"
  assert_eq "два слова" "$(mk "$Bn" Note)"
  assert_contains "$(last_line "$out")" "── NEXT: поручи работу подагенту; он блокирует тебя — вернувшись, bash $BRG wait --as $Bn (подагент закончил: ты свободен)"
  assert_contains "$(last_line "$out")" "сразу bash $BRG wait --as $Bn --busy \"два слова\""
  out=$(brg busy --as "$Bn" --off)
  assert_contains "$out" "пометка «работает» снята"
  assert_file_not_exists "$(mfile "$Bn")"
  assert_eq "── NEXT: продолжай; закончив шаг — bash $BRG wait --as $Bn" "$(last_line "$out")"
  # a mutating command: the key is required; a bare name and a missing name fail
  out=$(brg busy --as "${Bn%%.*}" "x" 2>&1)
  assert_contains "$out" "имя ${Bn%%.*} занято другой сессией"
  out=$(brg busy "x" 2>&1)
  assert_contains "$out" "нужно имя агента"
  out=$(brg busy --as "$Bn" --off "x" 2>&1)
  assert_contains "$out" "── ОШИБКА: --off снимает пометку"
  # without a caption, and with a long one (cut)
  out=$(brg busy --as "$Bn")
  assert_contains "$out" "── отмечено: работает. "
  assert_eq "" "$(mk "$Bn" Note)"
  out=$(brg busy --as "$Bn" это очень длинная подпись)
  assert_contains "$out" "Внимание: подпись сокращена до «это очень»"
  assert_eq "это очень" "$(mk "$Bn" Note)"
  # --help, brg help
  assert_contains "$(brg busy --help)" "busy --as <имя>"
  assert_contains "$(brg help)" "busy --as <имя>"
  assert_contains "$(brg wait --help)" "--busy"
}

# busy is allowed while stopped (it starts no work): the STOP line first, NEXT is "end the turn"
test_busy_while_stopped() {
  local out
  busy_setup
  brg stop >/dev/null
  out=$(brg busy --as "$Bn" "работа")
  assert_eq "── STOP: человек остановил бригаду. Новую работу не начинай: сдай сделанное, если нужно (send, item done), и заверши ход." "$(printf '%s\n' "$out" | head -n 1)"
  assert_contains "$(last_line "$out")" "── NEXT: заверши ход"
  assert_eq "работа" "$(mk "$Bn" Note)"
  # wait while stopped: STOP, the mark stays
  out=$(brg wait --as "$Bn")
  assert_contains "$out" "── STOP:"
  assert_eq "работа" "$(mk "$Bn" Note)" "STOP does not touch the mark"
}

test_who_status_formats_and_free_digest() {
  local out pb pc
  busy_setup
  item_add_as "$A" "Первая"
  start_wait "$Bn" "$P/wb" --timeout 20
  pb=$WP
  start_wait "$C" "$P/wc" --busy "финальная валидация" --timeout 20
  pc=$WP
  wait_for 3 test -f "$(mfile "$C")" || fail "no mark"
  out=$(brg who)
  assert_contains "$(line_of "$out" "$Bn")" "${Bn%%.*} · codex · gpt · ждёт · активен"
  assert_contains "$(line_of "$out" "$C")" "${C%%.*} · opencode · gpt · работает: финальная валидация, "
  assert_contains "$(line_of "$out" "$C")" " · активен "
  assert_contains "$(line_of "$out" "$A")" "${A%%.*} · claude · opus · работает · активен"
  # status of A lists the others the same way
  out=$(brg status --as "$A")
  assert_contains "$out" "Онлайн: ${Bn%%.*} (codex, gpt, ждёт), ${C%%.*} (opencode, gpt, работает: финальная валидация, "
  # the digest of A's timed-out wait names the free ones (not C, who works; not itself)
  out=$(brg wait --as "$A" --timeout 1)
  assert_contains "$out" "T001: todo 1 · свободны: ${Bn%%.*}"
  assert_not_contains "$out" "свободны: ${Bn%%.*}, "
  assert_not_contains "$out" "${C%%.*}, "
  # a stopped agent is not free
  : >"$B/run/stopped.${Bn%%.*}"
  out=$(brg wait --as "$A" --timeout 1)
  assert_not_contains "$out" "свободны"
  rm -f "$B/run/stopped.${Bn%%.*}"
  # the mark of a waiting agent: status of its own
  kill "$pb" "$pc" 2>/dev/null
  out=$(brg status --as "$C")
  assert_contains "$out" "Моя пометка: «работает: финальная валидация» — уже "
}

# §5.2: «возможно выпал» is hidden only for a mark from `busy` (a blocking subagent)
test_dropout_note_and_the_busy_mark() {
  local out
  busy_setup
  printf 'dropout_after: 70\n' >>"$B/config"
  brg busy --as "$Bn" "блокирует" >/dev/null
  brg wait --as "$C" --busy "фон" --timeout 0 >/dev/null
  dropped "$Bn"
  dropped "$C"
  out=$(brg who)
  assert_contains "$(line_of "$out" "$Bn")" "asleep"
  assert_contains "$(line_of "$out" "$Bn")" "не на связи"
  assert_not_contains "$(line_of "$out" "$Bn")" "выпал"
  assert_contains "$(line_of "$out" "$C")" "не на связи"
  assert_contains "$(line_of "$out" "$C")" "возможно выпал"
  out=$(brg status --as "$A")
  assert_contains "$out" "${C%%.*} (opencode, gpt, asleep, не на связи"
  assert_contains "$out" "возможно выпал)"
}

test_plain_wait_hints_at_items_in_work() {
  local out
  busy_setup
  item_add_as "$A" "Первая"
  item_add_as "$A" "Вторая"
  brg item claim I001 --as "$Bn" --paths src/a >/dev/null
  brg item done I001 --as "$Bn" --note ok >/dev/null
  brg item claim I002 --as "$Bn" --paths src/b >/dev/null
  # a plain wait drops the mark and says what is in work
  out=$(brg wait --as "$Bn" --timeout 0)
  assert_file_not_exists "$(mfile "$Bn")"
  assert_contains "$out" "У тебя I002 в работе: если подагент работает — wait с --busy \"I002\"."
  assert_eq "── нет новых (0 с) · ход не завершай · NEXT: bash $BRG wait --as $Bn --timeout 0" "$(last_line "$out")"
  # the reviewer
  brg item review I001 --as "$C" --start >/dev/null
  out=$(brg wait --as "$C" --timeout 0)
  assert_contains "$out" "Ты проверяешь I001: если подагент работает — wait с --busy \"проверка I001\"."
  # with --busy: no hint, the "you are marked" line instead
  out=$(brg wait --as "$Bn" --busy "I002" --timeout 0)
  assert_not_contains "$out" "У тебя I002 в работе"
  assert_contains "$out" "Ты отмечен «работает: I002»."
  # the same in a delivered batch
  send_as "$A" "привет" --to "${Bn%%.*}"
  out=$(brg wait --as "$Bn" --busy "I002")
  assert_contains "$out" "привет"
  assert_contains "$out" "Ты отмечен «работает: I002»."
  assert_eq "── NEXT: обработай, затем: bash $BRG wait --as $Bn --busy \"I002\"" "$(last_line "$out")"
  assert_contains "$(printf '%s\n' "$out" | tail -n 2 | head -n 1)" "Ты отмечен"
}

# the mark dropped under a running wait (done by the owner) is not repeated in its NEXT
test_next_of_a_running_wait_is_computed_at_the_end() {
  local out
  busy_setup
  item_add_as "$A" "Первая"
  brg item claim I001 --as "$Bn" --paths src/a >/dev/null
  start_wait "$Bn" "$P/wb" --busy "I001" --timeout 20
  assert_eq I001 "$(mk "$Bn" Item)"
  brg item done I001 --as "$Bn" --note ok >/dev/null # drops the mark under the running wait
  assert_file_not_exists "$(mfile "$Bn")"
  send_as "$A" "привет" --to "${Bn%%.*}"
  wait_pid "$WP" 5 || fail "wait did not end"
  assert_contains "$(cat "$P/wb")" "привет"
  assert_eq "── NEXT: обработай, затем: bash $BRG wait --as $Bn --timeout 20" "$(last_line "$(cat "$P/wb")")"
}

test_board_snapshot_has_the_mark() {
  local s
  busy_setup
  brg wait --as "$A" --busy "финальная валидация" --timeout 0 >/dev/null
  brg board --once >/dev/null || fail board
  s=$(cat "$B/run/board/data.js")
  assert_contains "$s" '"mark":{"note":"финальная валидация","since":'
  assert_contains "$s" '"via":"wait","item":""}'
  assert_contains "$s" '"mark":null'
  # the text goes through the same escaping as everything else
  printf 'Task: T001\nSince: 5\nNote: a"b\\c\nItem: I001\nVia: claim\n' >"$(mfile "$Bn")"
  brg board --once >/dev/null || fail board
  s=$(cat "$B/run/board/data.js")
  assert_contains "$s" '"mark":{"note":"a\"b\\c","since":5,"via":"claim","item":"I001"}'
}

# reviewers' marks go when the item leaves them: cancel (which also wakes them), release,
# the executor taking it back to work, reassign
test_reviewers_marks_go_with_the_round_of_review() {
  local out i
  busy_setup
  for i in Первая Вторая Третья Четвёртая; do item_add_as "$A" "$i"; done
  for i in 1 2 3 4; do
    brg item claim "I00$i" --as "$Bn" --paths "src/$i" >/dev/null || fail "claim $i"
    brg item done "I00$i" --as "$Bn" --note ok >/dev/null || fail "done $i"
  done
  # claim from done (back to work) clears Reviewing: the reviewer's mark goes
  brg item review I001 --as "$C" --start >/dev/null
  assert_eq I001 "$(mk "$C" Item)"
  brg item claim I001 --as "$Bn" --paths src/1 >/dev/null || fail claim
  assert_file_not_exists "$(mfile "$C")" "claim from done drops the reviewers' marks"
  # cancel: the mark goes and the reviewer is woken
  brg item review I002 --as "$C" --start >/dev/null
  brg item cancel I002 --as "$Bn" >/dev/null || fail cancel
  assert_file_not_exists "$(mfile "$C")" "cancel drops the reviewers' marks"
  out=$(hdr "$(tmsg T001 "$(cat "$D/seq")")" Wake)
  assert_contains "$out" "${C%%.*}" "the reviewer is woken by cancel"
  assert_contains "$out" "${A%%.*}" "and the lead"
  # release of a claimed item
  brg item release I001 --as "$Bn" >/dev/null || fail release
  brg item claim I001 --as "$Bn" --paths src/1 >/dev/null
  brg item review I001 --as "$C" --start >/dev/null
  assert_eq I001 "$(mk "$C" Item)"
  brg item release I001 --as "$Bn" >/dev/null || fail release
  assert_file_not_exists "$(mfile "$C")" "release drops the reviewers' marks"
  # reassign to a reviewer: its review mark goes (it works on the item now)
  brg item claim I001 --as "$Bn" --paths src/1 >/dev/null
  brg item review I001 --as "$C" --start >/dev/null
  dropped "$Bn"
  brg item reassign I001 --to "${C%%.*}" --as "$A" >/dev/null || fail reassign
  assert_file_not_exists "$(mfile "$C")" "the new assignee no longer reviews"
}

# a stale NEXT (before the task changed) must not mark the new task
test_stale_caption_of_an_item_is_not_marked() {
  local out
  busy_setup
  item_add_as "$A" "Первая"
  brg item claim I001 --as "$Bn" --paths src/a >/dev/null
  out=$(brg wait --as "$C" --busy "I001" --timeout 0)
  assert_contains "$out" "«I001» — не твоя подзадача"
  assert_file_not_exists "$(mfile "$C")"
  assert_eq "── нет новых (0 с) · ход не завершай · NEXT: bash $BRG wait --as $C --timeout 0" "$(last_line "$out")"
  out=$(brg wait --as "$C" --busy "проверка I001" --timeout 0)
  assert_contains "$out" "не твоя подзадача"
  out=$(brg busy --as "$C" "I001")
  assert_contains "$out" "не твоя подзадача"
  assert_file_not_exists "$(mfile "$C")"
  # my own item and a free caption are fine
  brg wait --as "$Bn" --busy "I001" --timeout 0 >/dev/null
  assert_eq I001 "$(mk "$Bn" Note)"
  brg wait --as "$A" --busy "финальная проверка" --timeout 0 >/dev/null
  assert_eq "финальная проверка" "$(mk "$A" Note)"
  # T001 closed, T002 new, the old NEXT executed late
  brg item cancel I001 --as "$A" >/dev/null
  printf 'итог\n' >"$D/summary.md"
  brg task close --as "$A" >/dev/null 2>&1 || brg task close --as "$A" >/dev/null || fail close
  task_new_as "$A" "Вторая"
  out=$(brg wait --as "$Bn" --busy "I001" --timeout 0)
  assert_contains "$out" "не твоя подзадача"
  assert_file_not_exists "$(mfile "$Bn")"
  assert_not_contains "$(last_line "$out")" "--busy"
}

test_stopped_agent_is_shown_as_stopped() {
  local out
  busy_setup
  brg wait --as "$C" --busy "работа" --timeout 0 >/dev/null
  brg stop "${Bn%%.*}" >/dev/null
  out=$(brg who)
  assert_contains "$(line_of "$out" "$Bn")" "${Bn%%.*} · codex · gpt · остановлен · активен"
  assert_not_contains "$(line_of "$out" "$Bn")" "(stop)"
  assert_contains "$(line_of "$out" "$C")" "работает: работа"
  assert_contains "$(brg status --as "$A")" "${Bn%%.*} (codex, gpt, остановлен)"
  brg stop >/dev/null
  out=$(brg who)
  assert_contains "$(line_of "$out" "$C")" "остановлен"
  assert_contains "$(line_of "$out" "$A")" "остановлен"
}

# «ты отмечен» only for the one who works on the item (not for a lead letting go of another's)
test_empty_item_mark_note_only_for_the_acting_assignee() {
  local out
  busy_setup
  item_add_as "$A" "Первая"
  brg item claim I001 --as "$Bn" --paths src/a >/dev/null
  brg wait --as "$A" --busy "финальная проверка" --timeout 0 >/dev/null
  dropped "$Bn"
  out=$(brg item release I001 --as "$A")
  assert_not_contains "$out" "Ты отмечен"
  assert_contains "$(last_line "$out")" "--busy \"финальная проверка\""
  brg item claim I001 --as "$C" --paths src/a >/dev/null
  brg busy --as "$C" "возня" >/dev/null
  out=$(brg item release I001 --as "$C")
  assert_contains "$out" "Ты отмечен «работает: возня»"
}

# a verdict on a handed-in item closes the round (DESIGN §7.1.1): the other reviewers are
# out of Reviewing, get a message that wakes them alone, keep their marks, and their next
# wait --busy keeps the mark; a verdict on an item in work takes out only its author
test_verdict_closes_the_round_for_other_reviewers() {
  local out E i=0 v last
  busy_setup
  E=$(join_as claude sonnet)
  ack_all "$E"
  ack_all "$E" "$D"
  for v in ok changes skip; do
    i=$((i + 1))
    item_add_as "$A" "Сданная $v"
    brg item claim "I00$i" --as "$Bn" --paths "src/$i" >/dev/null || fail "claim $i"
    brg item done "I00$i" --as "$Bn" --note ok >/dev/null || fail "done $i"
    brg item review "I00$i" --as "$C" --start >/dev/null || fail "start C $i"
    brg item review "I00$i" --as "$E" --start >/dev/null || fail "start E $i"
    out=$(brg item review "I00$i" --as "$C" --verdict "$v" --comment "по делу")
    assert_contains "$out" "Круг проверки закрыт: ${E%%.*} больше не среди проверяющих"
    assert_eq "" "$(hdr "$D/items/I00$i" Reviewing)" "$v: the round is over"
    assert_eq "I00$i" "$(mk "$E" Item)" "$v: the other reviewer's mark stays"
    last=$(tmsg T001 "$(cat "$D/seq")")
    assert_eq "${E%%.*}" "$(hdr "$last" To)"
    assert_eq "${E%%.*}" "$(hdr "$last" Wake)" "$v: wakes the other reviewer alone"
    assert_contains "$(cat "$last")" "${E%%.*}: круг проверки I00$i «Сданная $v» закрыт вердиктом $v от ${C%%.*} — вас больше нет среди проверяющих. Продолжаете проверку — повторите bash $BRG item review I00$i --as <имя> --start"
    out=$(brg wait --as "$E" --busy "проверка I00$i" --timeout 0)
    assert_contains "$out" "закрыт вердиктом $v"
    assert_not_contains "$out" "не твоя подзадача"
    assert_eq "I00$i" "$(mk "$E" Item)" "$v: wait --busy keeps the mark"
    assert_eq "── NEXT: обработай, затем: bash $BRG wait --as $E --busy \"проверка I00$i\" --timeout 0" "$(last_line "$out")"
    brg wait --as "$E" --timeout 0 >/dev/null # the subagent is done: free
  done
  # an item in work: the verdict takes out only its author, nobody else is told
  item_add_as "$A" "В работе"
  brg item claim I004 --as "$Bn" --paths src/4 >/dev/null || fail "claim 4"
  brg item review I004 --as "$C" --start >/dev/null
  brg item review I004 --as "$E" --start >/dev/null
  out=$(brg item review I004 --as "$C" --verdict changes --comment "поправь")
  assert_not_contains "$out" "Круг проверки закрыт"
  assert_eq "${E%%.*}" "$(hdr "$D/items/I004" Reviewing)"
  assert_not_contains "$(cat "$(tmsg T001 "$(cat "$D/seq")")")" "круг проверки"
}
