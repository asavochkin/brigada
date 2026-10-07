# Deadlines (send --reply-by, DESIGN §8).

. "$TESTS_DIR/brg_lib.sh"

# four agents with empty inboxes: A, Bn, C, D
four_agents() {
  new_proj
  A=$(join_as claude)
  Bn=$(join_as codex)
  C=$(join_as opencode)
  D=$(join_as claude)
  for x in "$A" "$Bn" "$C" "$D"; do ack_all "$x"; done
}

# The deadline fires exactly once.
test_deadline_fires_exactly_once() {
  local out t0 t1 f
  four_agents
  brg leave --as "$D" >/dev/null # gone agents are not expected to answer
  out=$(printf 'Решаем: делаем X?\n' | brg send --as "$A" --reply-by 2s)
  assert_contains "$out" "── отправлено #6 → all (lobby)"
  assert_contains "$out" "Дедлайн: ответ до "
  assert_contains "$out" "ждём: $Bn, $C."
  f=$(msg_file 6)
  assert_eq "$Bn,$C" "$(hdr "$f" Expect)"
  by=$(hdr "$f" Reply-By)
  assert_eq $(($(hdr "$f" Epoch) + 2)) "$by" "Reply-By = Epoch + 2"
  assert_file_exists "$B/run/deadlines/$A/$by-lobby-6"
  send_as "$Bn" "да" --re 6
  t0=$(date -u +%s)
  out=$(brg wait --as "$A" --timeout 6)
  assert_contains "$out" "  да"
  assert_not_contains "$out" "дедлайн" # C has not answered yet: no early summary
  out=$(brg wait --as "$A" --timeout 6)
  t1=$(date -u +%s)
  assert_eq "── дедлайн по #6 (lobby) истёк: ответили: $Bn; не ответили: $C
── NEXT: обработай, затем: bash $BRG wait --as $A --timeout 6" "$out"
  [ $((t1 - t0)) -le 3 ] || fail "summary late: $((t1 - t0)) s"
  assert_file_exists "$B/run/deadlines/lobby-6.done"
  assert_file_not_exists "$B/run/deadlines/$A/$by-lobby-6"
  # never again
  out=$(brg wait --as "$A" --timeout 1)
  assert_contains "$out" "── нет новых"
  assert_eq 1 "$(awk '$3 == "deadline"' "$B/run/metrics.log" | wc -l | tr -d ' ')" "one deadline metric"
  assert_contains "$(metrics_of "$A" deadline)" "channel=lobby id=6 result=expired replied=$Bn missing=$C"
  assert_contains "$(metrics_of "$A" wait)" "result=deadline delivered=0"
  # others are not woken by A's deadline
  assert_contains "$(brg wait --as "$C" --timeout 0)" "Решаем"
  assert_contains "$(brg wait --as "$C" --timeout 1)" "── нет новых"
}

# Two waits of the same agent racing (takeover) report the deadline once.
test_deadline_once_under_racing_waits() {
  local i n p1 p2
  four_agents
  i=1
  while [ $i -le 5 ]; do
    printf 'вопрос %s\n' "$i" | brg send --as "$A" --to "$Bn" --reply-by 1s >/dev/null || fail send
    i=$((i + 1))
  done
  sleep 1.2
  bash "$BRG" wait --as "$A" --timeout 2 >"$P/w1" 2>&1 &
  p1=$!
  bash "$BRG" wait --as "$A" --timeout 2 >"$P/w2" 2>&1 &
  p2=$!
  track_pid $p1
  track_pid $p2
  wait_pid $p1 5 || fail "w1 hung"
  wait_pid $p2 5 || fail "w2 hung"
  i=5
  while [ $i -le 9 ]; do
    n=$(cat "$P/w1" "$P/w2" | awk -v s="── дедлайн по #$i (lobby) истёк" 'index($0, s) == 1' | wc -l | tr -d ' ')
    assert_eq 1 "$n" "deadline #$i reported once"
    i=$((i + 1))
  done
}

# Replies: Re: N, or any later non-system message from an addressee to the
# sender or to all. All answered early → the summary comes with that batch.
test_deadline_reply_rules_and_early_summary() {
  local out
  four_agents
  printf 'Кто за?\n' | brg send --as "$A" --reply-by 1h >/dev/null || fail send # #5
  assert_eq "$D,$Bn,$C" "$(hdr "$(msg_file 5)" Expect)" # roster order
  send_as "$Bn" "за (всем, без re)"          # #6 counts: to all
  send_as "$C" "частное D" --to "$D"         # #7 no: to D, no Re
  join_as codex >/dev/null                   # #8 system: never a reply
  send_as "$D" "лично A" --to "$A"           # #9 counts: to the sender
  out=$(brg status --as "$A")
  assert_contains "$out" "Мой дедлайн по #5 (lobby): до "
  assert_contains "$out" "ответили: $D, $Bn · ждём: $C"
  out=$(brg wait --as "$A" --timeout 1)
  assert_contains "$out" "  за (всем, без re)"
  assert_not_contains "$out" "ответили все"
  send_as "$C" "ответ D по теме" --to "$D" --re 5 # #10 counts: Re: 5 (not delivered to A)
  send_as "$Bn" "ещё мысль"                       # wakes A
  out=$(brg wait --as "$A" --timeout 1)
  assert_contains "$out" "  ещё мысль"
  assert_not_contains "$out" "ответ D по теме"
  assert_contains "$out" "── по #5 (lobby) до срока ответили все адресаты: $D, $Bn, $C"
  assert_eq "── NEXT: обработай, затем: bash $BRG wait --as $A --timeout 1" "$(printf '%s\n' "$out" | tail -n 1)"
  assert_file_exists "$B/run/deadlines/lobby-5.done"
  assert_eq "" "$(ls "$B/run/deadlines/$A")" "index removed"
  assert_contains "$(metrics_of "$A" deadline)" "result=answered"
}

test_deadline_options() {
  local out
  four_agents
  out=$(printf 'x\n' | brg send --as "$A" --to "$Bn" --reply-by 90)
  assert_contains "$out" "(через 90 с), ждём: $Bn."
  assert_eq "$Bn" "$(hdr "$(msg_file 5)" Expect)"
  out=$(printf 'x\n' | brg send --as "$A" --to "$Bn,$A,human" --reply-by 5m)
  assert_contains "$out" "(через 5 мин), ждём: $Bn, human."
  out=$(printf 'x\n' | brg send --as "$A" --to "$A" --reply-by 5m)
  assert_contains "$out" "Внимание: дедлайн не установлен"
  assert_eq "" "$(hdr "$(msg_file 7)" Reply-By)"
  for bad in 5x 0 0s 25h abc; do
    out=$(printf 'x\n' | brg send --as "$A" --reply-by "$bad" 2>&1)
    assert_eq 1 "$?" "--reply-by $bad"
    assert_contains "$out" "--reply-by — срок вида 90s, 5m, 1h"
  done
  assert_eq 7 "$(cat "$B/lobby/seq")" "rejected sends wrote nothing"
}

# A deadline in the task channel; the human's reply via say counts too.
test_deadline_in_task_channel_with_human() {
  local out
  four_agents
  task_new_as "$A" "Сроки"
  printf 'Человек, подтверди\n' | brg send --as "$A" --to human --reply-by 1h >/dev/null || fail send
  assert_eq human "$(hdr "$(tmsg T001 1)" Expect)"
  brg say "подтверждаю" >/dev/null
  out=$(brg wait --as "$A" --timeout 2)
  assert_contains "$out" "  подтверждаю"
  assert_contains "$out" "── по #1 (T001) до срока ответили все адресаты: human"
}

# The reporter claimed the marker and died before printing: a minute after the
# deadline the summary is given again instead of being lost (dup allowed).
test_deadline_claimed_but_not_printed_is_reported_again() {
  local out by by2
  four_agents
  printf 'вопрос\n' | brg send --as "$A" --to "$Bn" --reply-by 1h >/dev/null || fail send
  by=$(hdr "$(msg_file 5)" Reply-By)
  # simulate: deadline long expired, marker claimed by a reporter that was killed
  by2=$(($(date -u +%s) - 61))
  mv "$B/run/deadlines/$A/$by-lobby-5" "$B/run/deadlines/$A/$by2-lobby-5"
  : >"$B/run/deadlines/lobby-5.done"
  out=$(brg wait --as "$A" --timeout 1)
  assert_contains "$out" "── дедлайн по #5 (lobby) истёк: ответили: никто; не ответили: $Bn"
  assert_eq "" "$(ls "$B/run/deadlines/$A")" "index removed after printing"
  assert_contains "$(brg wait --as "$A" --timeout 0)" "── нет новых"
  # a fresh claim (a racing wait about to print) is respected
  printf 'вопрос 2\n' | brg send --as "$A" --to "$Bn" --reply-by 1s >/dev/null || fail send
  : >"$B/run/deadlines/lobby-6.done"
  sleep 1.1
  assert_contains "$(brg wait --as "$A" --timeout 1)" "── нет новых"
}
