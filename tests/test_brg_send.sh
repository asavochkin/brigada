# send / say / read / tail, the write path (seq, recovery) and locks.

. "$TESTS_DIR/brg_lib.sh"

test_send_message_format() {
  local a b f out
  new_proj
  a=$(join_as claude)
  b=$(join_as codex)
  out=$(brg send --as "$a" --to " $b , human,$b" <<'BRG_EOF'
строка 1 с $HOME и `x`

строка 3
BRG_EOF
)
  assert_eq 0 "$?" "exit code"
  assert_contains "$out" "── отправлено #3 → $b,human (lobby)"
  assert_contains "$out" "── NEXT: продолжай; закончив шаг — bash $BRG wait --as $a"
  f=$(msg_file 3)
  assert_eq 3 "$(hdr "$f" Id)"
  assert_eq lobby "$(hdr "$f" Channel)"
  assert_eq "$a" "$(hdr "$f" From)"
  assert_eq "$b,human" "$(hdr "$f" To)"
  assert_eq msg "$(hdr "$f" Kind)"
  case $(hdr "$f" Time) in 20[0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z) ;; *) fail "Time: $(hdr "$f" Time)" ;; esac
  case $(hdr "$f" Epoch) in '' | *[!0-9]*) fail "Epoch" ;; esac
  assert_eq 'строка 1 с $HOME и `x`

строка 3' "$(awk 'b { print } /^$/ && !b { b = 1 }' "$f")" "body"
  assert_eq 3 "$(cat "$B/lobby/seq")"
  out=$(printf 'ответ\n' | brg send --as "$b" --re 3 --to "$a")
  assert_contains "$out" "── отправлено #4 → $a (lobby) · re #3"
  assert_eq 3 "$(hdr "$(msg_file 4)" Re)"
  assert_contains "$(metrics_of "$a" send)" "send id=3 channel=lobby to=$b,human bytes="
}

test_send_crlf_bom_file_and_trailing_newlines() {
  local a f
  new_proj
  a=$(join_as claude)
  printf '\357\273\277первая\r\nвторая\r\n\r\n\r\n' >"$P/body.txt"
  brg send --as "$a" --file "$P/body.txt" >/dev/null || fail "send --file"
  f=$(msg_file 2)
  assert_eq "первая
вторая" "$(awk 'b { print } /^$/ && !b { b = 1 }' "$f")"
  assert_eq 0 "$(tr -cd '\r' <"$f" | wc -c | tr -d ' ')" "no CR left"
  printf 'a\r\nb' | brg send --as "$a" >/dev/null || fail "stdin CRLF without final newline"
  assert_eq "a
b" "$(awk 'b { print } /^$/ && !b { b = 1 }' "$(msg_file 3)")"
  out=$(brg send --as "$a" --file "$P/missing.txt" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет файла"
}

test_send_size_limit() {
  local a out body
  new_proj
  a=$(join_as claude)
  printf 'msg_max_bytes: 100\n' >>"$B/config"
  # 99 bytes of text + newline = 100: accepted (Cyrillic counts in bytes)
  body=$(awk 'BEGIN { for (i = 0; i < 33; i++) printf "ж"; printf "abc" }') # 33*2+3 = 69
  body="$body$(awk 'BEGIN { for (i = 0; i < 30; i++) printf "x" }')"          # 99
  printf '%s\n' "$body" | brg send --as "$a" >/dev/null || fail "99+1 bytes rejected"
  out=$(printf '%sy\n' "$body" | brg send --as "$a" 2>&1)
  assert_eq 1 "$?" "101 bytes must fail"
  assert_contains "$out" "сообщение 101 байт — больше лимита 100"
  assert_contains "$out" "Положи текст в файл"
  assert_contains "$out" "── NEXT: исправь команду и повтори: bash $BRG send --as $a"
  assert_eq 2 "$(cat "$B/lobby/seq")" "rejected message not written"
}

test_send_rejections_keep_next() {
  local a out
  new_proj
  a=$(join_as claude)
  out=$(printf ' \n\t\n' | brg send --as "$a" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "пустое сообщение"
  out=$(brg send --as "$a" </dev/null 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "пустое сообщение"
  out=$(printf 'x\n' | brg send --as "$a" --to nobody-1 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет такого агента: nobody-1"
  out=$(printf 'x\n' | brg send --as "$a" --to "all,$a" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "all нельзя смешивать"
  out=$(printf 'x\n' | brg send --as "$a" --re 99 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет сообщения #99"
  out=$(printf 'x\n' | brg send --as "$a" --channel T001 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет канала: T001"
  out=$(brg send --as "$a" hello </dev/null 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "неизвестный параметр: hello"
  assert_contains "$out" "── NEXT: исправь команду и повтори: bash $BRG send --as $a "
  assert_contains "$out" "wait --as $a"
  out=$(brg send --as "$a" --to 2>&1 </dev/null)
  assert_eq 1 "$?"
  assert_contains "$out" "--to требует значение"
  assert_eq 1 "$(cat "$B/lobby/seq")" "nothing written"
}

# 10 senders × 100 messages in parallel: ids contiguous, every message exactly once,
# per-sender order preserved, no temp files or locks left.
test_concurrent_stress() {
  local i n bad
  new_proj
  i=1
  while [ $i -le 10 ]; do
    join_as claude >/dev/null
    i=$((i + 1))
  done
  i=1
  while [ $i -le 10 ]; do
    (
      k=1
      while [ $k -le 100 ]; do
        printf 's%s-%s\n' "$i" "$k" | bash "$BRG" send --as "claude-$i" >/dev/null || echo "send failed $i $k" >>"$P/errors"
        k=$((k + 1))
      done
    ) &
    i=$((i + 1))
  done
  wait
  assert_file_not_exists "$P/errors"
  assert_eq 1010 "$(cat "$B/lobby/seq")" "seq"
  n=$(ls "$B/lobby/messages" | wc -l | tr -d ' ')
  assert_eq 1010 "$n" "files (no temp leftovers)"
  bad=$(cd "$B/lobby/messages" && ls | awk '
    { id = $0; sub(/\.msg$/, "", id); id += 0; seen[id] = 1
      f = $0; hdr = 1; body = ""
      while ((getline l < f) > 0) {
        if (hdr && l == "") { hdr = 0; continue }
        if (hdr && l ~ /^Id: /) { if (substr(l, 5) + 0 != id) print "id mismatch " f }
        if (!hdr) body = l
      }
      close(f)
      if (body ~ /^s[0-9]+-[0-9]+$/) {
        if (body in got) print "dup " body
        got[body] = id
        split(substr(body, 2), p, "-")
        if (p[2] + 0 <= last[p[1]]) print "order " body
        last[p[1]] = p[2] + 0
        cnt++
      }
    }
    END {
      for (i = 1; i <= 1010; i++) if (!(i in seen)) print "hole " i
      if (cnt != 1000) print "count " cnt
    }')
  assert_eq "" "$bad" "stress check"
  assert_eq "" "$(ls -A "$B/run/locks")" "locks left"
  assert_eq "" "$(ls -A "$B/lobby" | awk '/tmp/')" "seq temp left"
}

# A crash between mv of the message and the seq update leaves a file above seq.
test_seq_recovery_after_crash_between_mv_and_seq() {
  local a b f out
  new_proj
  a=$(join_as claude)
  b=$(join_as codex)
  brg wait --as "$a" --timeout 0 >/dev/null
  send_as "$b" "до сбоя"
  assert_eq 3 "$(cat "$B/lobby/seq")"
  f=$(msg_file 4) # "crash": file written, seq not updated
  sed -e 's/^Id: 3$/Id: 4/' -e 's/до сбоя/потерянное при сбое/' "$(msg_file 3)" >"$f"
  out=$(brg wait --as "$a" --timeout 0)
  assert_contains "$out" "#3 $b → all"
  assert_contains "$out" "#4 $b → all"
  assert_contains "$out" "потерянное при сбое"
  send_as "$b" "после сбоя"
  assert_file_exists "$(msg_file 5)"
  assert_eq 5 "$(cat "$B/lobby/seq")" "seq recomputed from files"
  assert_contains "$(cat "$(msg_file 5)")" "после сбоя"
  assert_contains "$(metrics_of "$b" seq.recover)" "seq=3 max=4"
  # seq missing altogether → recomputed
  rm -f "$B/lobby/seq"
  send_as "$b" "без seq"
  assert_eq 6 "$(cat "$B/lobby/seq")"
  # a hole below seq (lost file) does not stop delivery
  rm -f "$(msg_file 5)"
  send_as "$b" "после дыры"
  out=$(brg wait --as "$a" --timeout 0)
  assert_contains "$out" "#6 $b → all"
  assert_contains "$out" "#7 $b → all"
  assert_not_contains "$out" "#5 "
}

dead_pid() { # a pid that surely does not exist now
  sleep 0 &
  local p=$!
  wait $p
  echo $p
}

test_stale_lock_dead_owner_is_broken() {
  local a t0 t1
  new_proj
  a=$(join_as claude)
  mkdir "$B/run/locks/chan.lobby.lock"
  printf '%s %s\n' "$(dead_pid)" "$(date -u +%s)" >"$B/run/locks/chan.lobby.lock/owner"
  t0=$(date -u +%s)
  send_as "$a" "через протухшую блокировку"
  t1=$(date -u +%s)
  [ $((t1 - t0)) -le 2 ] || fail "dead owner lock broke slowly: $((t1 - t0)) s"
  assert_eq 2 "$(cat "$B/lobby/seq")"
  assert_contains "$(metrics_of "$a" lock.break)" "lock=chan.lobby.lock"
  assert_eq "" "$(ls -A "$B/run/locks")" "leftovers"
}

test_live_lock_respected_until_lock_stale() {
  local a sp p
  new_proj
  a=$(join_as claude)
  sleep 30 &
  sp=$!
  track_pid $sp
  mkdir "$B/run/locks/chan.lobby.lock"
  printf '%s %s\n' $sp "$(date -u +%s)" >"$B/run/locks/chan.lobby.lock/owner"
  printf 'x\n' | bash "$BRG" send --as "$a" >"$P/out" 2>&1 &
  p=$!
  track_pid $p
  sleep 1.5
  is_alive $p || fail "send did not wait for a live lock: $(cat "$P/out")"
  assert_eq 1 "$(cat "$B/lobby/seq")" "written under someone else's lock"
  # older than lock_stale (3 s) with a live owner → broken
  wait_pid $p 6 || fail "live but stale lock never broken"
  assert_eq 2 "$(cat "$B/lobby/seq")"
  is_alive $sp || fail "the lock owner process must not be touched"
}

test_ownerless_lock_gets_grace_period() {
  local a t0 t1
  new_proj
  a=$(join_as claude)
  mkdir "$B/run/locks/chan.lobby.lock" # mkdir done, owner never written
  t0=$(date -u +%s)
  send_as "$a" "после ownerless"
  t1=$(date -u +%s)
  [ $((t1 - t0)) -ge 3 ] || fail "ownerless lock broken too early: $((t1 - t0)) s"
  [ $((t1 - t0)) -le 7 ] || fail "ownerless lock broken too late: $((t1 - t0)) s"
  assert_contains "$(metrics_of "$a" lock.break)" "owner=none"
}

# Several processes find the same stale lock: exactly one breaks it, mutual
# exclusion holds, nobody removes a fresh lock.
test_stale_lock_break_race() {
  local i bad
  new_proj
  mkdir "$B/run/locks/race.lock"
  printf '%s %s\n' "$(dead_pid)" "$(date -u +%s)" >"$B/run/locks/race.lock/owner"
  i=1
  while [ $i -le 8 ]; do
    BRG_SOURCE_ONLY=1 bash -c '
      . "$1"; cfg_load; AGENT=racer-$3
      lock_acquire race
      mkdir "$2/inside" 2>/dev/null || echo "overlap $3" >>"$2/errors"
      sleep 0.1
      rm -rf "$2/inside"
      lock_release race
      echo "$3" >>"$2/done"' _ "$BRG" "$P" "$i" &
    i=$((i + 1))
  done
  wait
  assert_file_not_exists "$P/errors"
  assert_eq 8 "$(wc -l <"$P/done" | tr -d ' ')" "all acquired"
  assert_eq 1 "$(awk '$3 == "lock.break"' "$B/run/metrics.log" | wc -l | tr -d ' ')" "exactly one break"
  assert_eq "" "$(ls -A "$B/run/locks")" "leftovers"
}

test_lock_release_only_own() {
  local sp
  new_proj
  sleep 30 &
  sp=$!
  track_pid $sp
  mkdir "$B/run/locks/x.lock"
  printf '%s %s\n' $sp "$(date -u +%s)" >"$B/run/locks/x.lock/owner"
  BRG_SOURCE_ONLY=1 bash -c '. "$1"; cfg_load; HELD=" x"; lock_release x; release_all' _ "$BRG"
  assert_file_exists "$B/run/locks/x.lock/owner" "foreign lock removed"
  BRG_SOURCE_ONLY=1 bash -c '. "$1"; cfg_load; lock_acquire y; [ -d "$2/y.lock" ] || exit 1; lock_release y; [ ! -e "$2/y.lock" ]' \
    _ "$BRG" "$B/run/locks" || fail "own lock not released"
  # a command killed inside the critical section leaves no lock behind (EXIT/TERM trap)
  BRG_SOURCE_ONLY=1 bash -c '. "$1"; cfg_load; trap release_all EXIT; lock_acquire z; exit 3' _ "$BRG"
  assert_file_not_exists "$B/run/locks/z.lock"
}

test_say_from_human() {
  local a b out
  new_proj
  a=$(join_as claude)
  b=$(join_as codex)
  : >"$B/run/stopped"
  : >"$B/run/stopped.$a"
  : >"$B/run/stopped.$b"
  out=$(brg say привет всем)
  assert_contains "$out" "── отправлено #3 от human → all (lobby). Общий стоп снят."
  assert_file_not_exists "$B/run/stopped"
  assert_file_exists "$B/run/stopped.$a" "say to all keeps per-agent stops"
  assert_eq human "$(hdr "$(msg_file 3)" From)"
  assert_eq all "$(hdr "$(msg_file 3)" To)"
  assert_contains "$(cat "$(msg_file 3)")" "привет всем"
  out=$(printf 'из stdin\r\n' | brg say --to "$a")
  assert_contains "$out" "→ $a (lobby). Стоп $a снят."
  assert_file_not_exists "$B/run/stopped.$a"
  assert_file_exists "$B/run/stopped.$b"
  out=$(brg say --to human x 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "human не может писать сам себе"
  out=$(brg say --to nobody x 2>&1)
  assert_eq 1 "$?"
  out=$(brg say "" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "пустое сообщение"
  assert_contains "$(brg wait --as "$a" --timeout 0)" "#4 human → $a"
}

test_read_reshows_without_moving_cursor() {
  local a b c out
  new_proj
  a=$(join_as claude)
  b=$(join_as codex)
  c=$(join_as opencode)
  send_as "$b" "всем-1"
  send_as "$b" "лично-a" --to "$a"
  send_as "$b" "лично-c" --to "$c"
  send_as "$a" "моё"
  brg wait --as "$a" >/dev/null
  assert_eq "0/7" "$(cursor "$a")"
  out=$(brg read --as "$a")
  assert_contains "$out" "── lobby · после #0: 6"
  assert_contains "$out" "всем-1"
  assert_contains "$out" "лично-a"
  assert_contains "$out" "  моё"
  assert_not_contains "$out" "лично-c"
  assert_contains "$out" "── NEXT: курсор не сдвинут; закончив шаг — bash $BRG wait --as $a"
  assert_eq "0/7" "$(cursor "$a")" "read must not move the cursor"
  out=$(brg read --as "$a" --since 4)
  assert_contains "$out" "── lobby · после #4: 2"
  assert_not_contains "$out" "всем-1"
  out=$(brg read --as "$a" --all --since 4)
  assert_contains "$out" "лично-c"
  out=$(brg read --as "$a" --since 7)
  assert_contains "$out" "── lobby: после #7 сообщений для тебя нет"
  out=$(brg read --as "$a" --since x 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "── NEXT: bash $BRG read --as $a"
  # cap with a hint
  printf 'wait_output_max: 300\n' >>"$B/config"
  out=$(brg read --as "$a" --since 0)
  assert_contains "$out" "не показано (лимит вывода): bash $BRG read --as $a --since "
}

test_tail_shows_everything_and_follows() {
  local a b out p
  new_proj
  a=$(join_as claude)
  b=$(join_as codex)
  send_as "$a" "лично для b" --to "$b"
  send_as "$b" "ответ" --re 3 --to "$a"
  out=$(brg tail)
  assert_contains "$out" "#1 [система] $a → all · "
  assert_contains "$out" "#3 $a → $b · "
  assert_contains "$out" "  лично для b"
  assert_contains "$out" "#4 $b → $a · re #3 · "
  case $out in *"#4 $b → $a · re #3 · "[0-2][0-9]:[0-5][0-9]:[0-5][0-9]*) ;; *) fail "tail time format: $out" ;; esac
  out=$(brg tail -n 1)
  assert_not_contains "$out" "#3 $a → "
  assert_contains "$out" "#4 "
  BRG_TICK=0.2 bash "$BRG" tail -f >"$P/tail" 2>&1 &
  p=$!
  track_pid $p
  wait_for 3 test -s "$P/tail" || fail "tail -f printed nothing"
  send_as "$b" "новое после tail -f"
  wait_for 3 awk '/новое после tail -f/ { f = 1 } END { exit !f }' "$P/tail" || fail "tail -f missed a message"
  kill -TERM $p # (INT is ignored in background jobs of a non-interactive shell)
  wait_pid $p 3 || fail "tail -f did not stop on TERM"
  assert_eq 0 "$WAIT_RC" "tail -f exit code on TERM"
  out=$(brg tail T009 2>&1)
  assert_eq 1 "$?"
}

# Body from a pipe: a background reader copies stdin; a
# source that closes within BRG_STDIN_WAIT is delivered in full, one that does
# not is cut off with a clear error and nothing is sent (never a silent loss).
test_send_stdin_pipe_reader() {
  local a out t0 t1 rc
  new_proj
  a=$(join_as claude)
  # a pipe that never closes: an error after ~10 s (default), nothing written
  t0=$(date -u +%s)
  out=$(bash "$BRG" send --as "$a" < <(sleep 30) 2>&1)
  rc=$?
  t1=$(date -u +%s)
  assert_eq 1 "$rc" "exit code"
  [ $((t1 - t0)) -ge 9 ] && [ $((t1 - t0)) -le 13 ] || fail "took $((t1 - t0)) s (expected ~10)"
  assert_contains "$out" "── ОШИБКА: stdin не закрыт — передай тело через heredoc или --file"
  assert_contains "$out" "Ничего не отправлено."
  assert_contains "$out" "── NEXT: исправь команду и повтори: bash $BRG send --as $a"
  # a slow source that closes in time is delivered in full
  out=$(BRG_STDIN_WAIT=3 bash "$BRG" send --as "$a" < <(printf 'первая\n'; sleep 1.5; printf 'вторая') 2>&1)
  assert_eq 0 "$?" "slow source within the limit: $out"
  assert_eq "первая
вторая" "$(awk 'b { print } /^$/ && !b { b = 1 }' "$(msg_file 2)")"
  # a slower one (closes after the limit): explicit error, nothing written
  t0=$(date -u +%s)
  out=$(BRG_STDIN_WAIT=1 bash "$BRG" send --as "$a" < <(printf 'начало'; sleep 3; printf ' конец\n') 2>&1)
  rc=$?
  t1=$(date -u +%s)
  assert_eq 1 "$rc"
  assert_contains "$out" "stdin не закрыт"
  [ $((t1 - t0)) -le 2 ] || fail "did not stop at the limit: $((t1 - t0)) s"
  assert_eq 2 "$(cat "$B/lobby/seq")" "nothing written"
  assert_eq "" "$(ls -A "$B/run" | awk '/^\.body/')" "temp files left"
  # an ordinary pipe is not delayed
  t0=$(date -u +%s)
  printf 'быстро\n' | brg send --as "$a" >/dev/null || fail "pipe send"
  t1=$(date -u +%s)
  [ $((t1 - t0)) -le 1 ] || fail "pipe send took $((t1 - t0)) s"
  # a runaway stream is bounded and refused as too big
  out=$(awk 'BEGIN { for (i = 0; i < 5000; i++) print "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }' | brg send --as "$a" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "больше лимита 8192"
  assert_eq "" "$(ls -A "$B/run" | awk '/^\.body/')" "temp files left"
}

# A corrupted seq far above the messages on disk: readers do not walk to it,
# the next write resets it to the highest file.
test_seq_far_above_files_is_not_trusted() {
  local a b out t0 t1
  new_proj
  a=$(join_as claude)
  b=$(join_as codex)
  ack_all "$a"
  send_as "$b" "до порчи"
  printf '1000000000\n' >"$B/lobby/seq"
  t0=$(date -u +%s)
  out=$(brg wait --as "$a" --timeout 0)
  assert_contains "$out" "  до порчи"
  out=$(brg wait --as "$a" --timeout 0)
  assert_contains "$out" "── нет новых"
  brg tail >/dev/null || fail tail
  t1=$(date -u +%s)
  [ $((t1 - t0)) -le 2 ] || fail "slow with a corrupted seq: $((t1 - t0)) s"
  send_as "$b" "после порчи"
  assert_eq 4 "$(cat "$B/lobby/seq")" "seq reset to the highest file + 1"
  assert_file_exists "$(msg_file 4)"
  assert_contains "$(metrics_of "$b" seq.reset)" "seq=1000000000 max=3"
  assert_contains "$(brg wait --as "$a" --timeout 1)" "#4 $b → all"
}

# A brg killed with SIGKILL while reading stdin leaves run/.body.<pid>.<rnd>;
# any later command removes the copies whose pid is dead (live ones stay).
test_stale_body_copies_are_removed() {
  local a sp dp
  new_proj
  a=$(join_as claude)
  sleep 30 &
  sp=$!
  track_pid $sp
  dp=$(dead_pid)
  printf 'полутело\n' >"$B/run/.body.$dp.123"
  printf 'живое\n' >"$B/run/.body.$sp.456"
  printf 'мусор\n' >"$B/run/.body.x.1"
  brg who >/dev/null || fail who
  assert_file_not_exists "$B/run/.body.$dp.123" "dead owner's copy"
  assert_file_not_exists "$B/run/.body.x.1"
  assert_file_exists "$B/run/.body.$sp.456" "a live reader's copy must stay"
  # a reader really killed with -9 mid-read
  bash "$BRG" send --as "$a" < <(printf 'начало'; sleep 30) >/dev/null 2>&1 &
  dp=$!
  track_pid $dp
  wait_for 3 has_body $dp || fail "no stdin copy of the reader"
  kill -KILL $dp
  wait $dp 2>/dev/null
  brg who >/dev/null || fail who
  has_body $dp && fail "copy of the killed reader left"
  return 0
}
has_body() { [ -n "$(ls -A "$B/run" | awk -v p="$1" 'index($0, ".body." p ".") == 1')" ]; } # PID

# A UTF-16 file (Windows PowerShell 5.1: > and Out-File) is refused with
# a hint, not sent as garbage.
test_send_utf16_file_is_refused() {
  local a out
  new_proj
  a=$(join_as codex)
  printf '\377\376\037\004@\004\n\000' >"$P/u16.txt"
  out=$(brg send --as "$a" --file "$P/u16.txt" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "текст в кодировке UTF-16 — нужен UTF-8"
  assert_contains "$out" "Set-Content -Encoding utf8"
  assert_contains "$out" "── NEXT:"
  printf '\376\377\004\037\n' >"$P/u16be.txt"
  out=$(brg send --as "$a" --file "$P/u16be.txt" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "UTF-16"
  assert_eq 1 "$(cat "$B/lobby/seq")" "nothing sent"
}
