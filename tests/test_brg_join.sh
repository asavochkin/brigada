# join / leave / who / status / --as resolution.

. "$TESTS_DIR/brg_lib.sh"

test_join_output_roster_and_system_message() {
  local out a k
  new_proj
  out=$(brg join --harness Claude-Code --model "opus 4")
  assert_eq 0 "$?" "exit code"
  k=$(hdr "$B/agents/claude-1" Key)
  case $k in [a-z2-9][a-z2-9][a-z2-9][a-z2-9][a-z2-9][a-z2-9]) ;; *) fail "bad key: [$k]" ;; esac
  assert_contains "$out" "── подключён: claude-1.$k (claude · opus 4 · "
  assert_contains "$out" "Онлайн: никого"
  assert_contains "$out" "через 3 с"
  assert_contains "$out" "timeout: 63000 (мс)"
  assert_eq "── NEXT: bash $BRG wait --as claude-1.$k" "$(printf '%s\n' "$out" | tail -n 1)"
  assert_eq claude "$(hdr "$B/agents/claude-1" Harness)"
  assert_eq "opus 4" "$(hdr "$B/agents/claude-1" Model)"
  [ -n "$(hdr "$B/agents/claude-1" Platform)" ] || fail "no platform"
  is_uint() { case $1 in '' | *[!0-9]*) return 1 ;; esac; }
  is_uint "$(cat "$B/run/seen/claude-1")" || fail "no Last-Seen"
  # the cursor starts at the current end of the lobby; join announces itself
  assert_eq "0/0" "$(cursor claude-1)"
  assert_eq system "$(hdr "$(msg_file 1)" Kind)"
  assert_eq claude-1 "$(hdr "$(msg_file 1)" From)"
  assert_contains "$(cat "$(msg_file 1)")" "claude-1 подключился (claude, opus 4, "
  out=$(brg join --harness OpenCode --model x)
  assert_contains "$out" "── подключён: opencode-1.$(hdr "$B/agents/opencode-1" Key) "
  assert_contains "$out" "Онлайн: claude-1 (claude, opus 4, working)"
  assert_contains "$out" "OpenCode: в инструменте shell/bash передавай timeout: 63000"
  assert_eq "1/1" "$(cursor opencode-1)"
  assert_contains "$(brg join --harness codex-cli --model y)" "── подключён: codex-1."
  assert_contains "$(brg join --harness 'Gemini CLI' --model z)" "── подключён: geminicli-1."
  a=$(join_as claude)
  assert_eq claude-2 "$(base_of "$a")"
  # the newcomer does not get its own announcement or the history
  a=$(brg wait --as "$a" --timeout 0)
  assert_contains "$a" "── нет новых (0 с)"
}

test_join_requires_harness_and_model() {
  local out
  new_proj
  out=$(brg join --model m 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нужен --harness"
  assert_contains "$out" "── NEXT: bash $BRG join --harness"
  out=$(brg join --harness claude 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "--model unknown"
  out=$(brg join --harness '!!!' --model m 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "недопустимый --harness"
  assert_eq "" "$(ls "$B/agents")" "no agent created"
}

test_join_parallel_names_are_unique() {
  local i names
  new_proj
  i=1
  while [ $i -le 10 ]; do
    join_as claude >"$P/name.$i" &
    i=$((i + 1))
  done
  wait
  names=$(cat "$P"/name.* | sed 's/\..*//' | sort)
  assert_eq "$(printf 'claude-%s\n' 1 10 2 3 4 5 6 7 8 9)" "$names" "names"
  assert_eq 10 "$(ls "$B/agents" | wc -l | tr -d ' ')" "roster size"
  assert_eq 10 "$(cat "$B/lobby/seq")" "one announcement each"
  assert_eq "" "$(ls -A "$B/agents" | awk '/^\./')" "temp leftovers"
  assert_eq "" "$(ls -A "$B/run/locks")" "lock leftovers"
}

test_join_refuses_other_platform() {
  local out a
  new_proj
  a=$(BRG_PLATFORM=Darwin join_as claude)
  out=$(BRG_PLATFORM=WSL bash "$BRG" join --harness codex --model m 2>&1)
  assert_eq 1 "$?" "mismatch must fail"
  assert_contains "$out" "платформа WSL не совпадает"
  assert_contains "$out" "${a%%.*} (Darwin, working)"
  assert_contains "$out" "── NEXT:"
  assert_file_not_exists "$B/agents/codex-1"
  # a gone agent does not block
  brg leave --as "$a" >/dev/null || fail "leave"
  out=$(BRG_PLATFORM=WSL bash "$BRG" join --harness codex --model m)
  assert_contains "$out" "── подключён: codex-1.$(hdr "$B/agents/codex-1" Key) (codex · m · WSL)"
}

test_leave_marks_gone_and_blocks_commands() {
  local a b out
  new_proj
  a=$(join_as claude)
  b=$(join_as codex)
  out=$(brg leave --as "$a")
  assert_contains "$out" "── ${a%%.*} отключён"
  [ -n "$(hdr "$B/agents/${a%%.*}" Left)" ] || fail "no Left header"
  assert_eq no "$(hdr "$(msg_file 3)" Wake)" "leave notice is quiet"
  # quiet: does not wake b on its own, comes with the next waking batch
  assert_contains "$(brg wait --as "$b" --timeout 0)" "── нет новых"
  brg say "есть кто?" >/dev/null
  out=$(brg wait --as "$b" --timeout 0)
  assert_contains "$out" "#3 [система] ${a%%.*} → all"
  assert_contains "$out" "#4 human → all"
  assert_contains "$(brg who)" "${a%%.*} · claude · m · gone (leave)"
  out=$(printf 'x\n' | brg send --as "$a" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "агент ${a%%.*} отключён"
  out=$(brg wait --as "$a")
  assert_eq 0 "$?" "wait always exits 0"
  assert_contains "$out" "агент ${a%%.*} отключён"
  assert_contains "$out" "── NEXT: заверши ход"
  out=$(printf 'x\n' | brg send --as "$b" --to "${a%%.*}")
  assert_contains "$out" "Внимание: ${a%%.*} — gone"
}

test_as_resolution() {
  local a out
  new_proj
  a=$(join_as claude)
  out=$(printf 'x\n' | brg send 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нужно имя агента: --as"
  out=$(printf 'x\n' | brg send --as ghost-1 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "неизвестный агент: ghost-1"
  assert_contains "$out" "join --harness"
  out=$(printf 'x\n' | brg send --as ../x 2>&1)
  assert_eq 1 "$?"
  out=$(printf 'через BRG_AS\n' | BRG_AS=$a bash "$BRG" send)
  assert_contains "$out" "── отправлено #2 → all"
  assert_eq "${a%%.*}" "$(hdr "$(msg_file 2)" From)"
}

test_who_states() {
  local a b c d out
  new_proj
  a=$(join_as claude)
  b=$(join_as codex)
  c=$(join_as opencode)
  d=$(join_as claude)
  brg wait --as "$a" --timeout 0 >/dev/null # the others' announcements
  start_wait "$a" "$P/wa" --timeout 20
  printf '%s\n' $(($(date -u +%s) - 90)) >"$B/run/seen/${c%%.*}"  # > asleep_after (60)
  printf '%s\n' $(($(date -u +%s) - 500)) >"$B/run/seen/${d%%.*}" # > gone_after (120)
  : >"$B/run/stopped.${b%%.*}"
  out=$(brg who)
  assert_contains "$out" "${a%%.*} · claude · m · waiting · активен"
  assert_contains "$out" "${b%%.*} · codex · m · working (stop) · активен"
  assert_contains "$out" "${c%%.*} · opencode · m · asleep · активен 9" # 90 s (91 if a second boundary passed)
  assert_contains "$out" "${d%%.*} · claude · m · gone · активен 8 мин назад"
  # a live wait whose heartbeat went stale (pid reuse guard) is not "waiting"
  kill -STOP $WP
  printf '%s %s\n' $WP $(($(date -u +%s) - 100)) >"$B/run/wait/${a%%.*}.hb"
  assert_contains "$(brg who)" "${a%%.*} · claude · m · working"
  kill -CONT $WP
  kill -TERM $WP
  wait_pid $WP 3 || fail "wait hung"
}

test_status_one_screen() {
  local a b out
  new_proj
  a=$(join_as claude)
  b=$(join_as codex)
  send_as "$b" "всем"
  send_as "$b" "лично" --to "${a%%.*}"
  send_as "$a" "своё"
  out=$(brg status --as "$a")
  assert_contains "$out" "── status: ${a%%.*} · claude · m · платформа"
  assert_contains "$out" "Таймаут wait: 3 с. Таймаут инструмента: Claude Code: в Bash tool передавай timeout: 63000 (мс)"
  assert_contains "$out" "Мой wait: не запущен"
  assert_contains "$out" "lobby: новых для тебя 3"
  assert_contains "$out" "Онлайн: ${b%%.*} (codex, m, working)"
  assert_eq "── NEXT: bash $BRG wait --as $a" "$(printf '%s\n' "$out" | tail -n 1)"
  assert_eq "0/0" "$(cursor "$a")" "status does not move the cursor"
  brg wait --as "$a" >/dev/null
  out=$(brg status --as "$a")
  assert_contains "$out" "lobby: новых для тебя 0 · выдано последним wait и ждёт подтверждения: #1…#5"
  start_wait "$a" "$P/w" --timeout 20
  out=$(brg status --as "$a")
  assert_contains "$out" "Мой wait: работает (pid $WP)"
  : >"$B/run/stopped"
  out=$(brg status --as "$a")
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "── STOP"
  wait_pid $WP 3 || fail "wait ignored stop"
}

# wait_timeout.<harness>.<platform> (DESIGN §5.1) — Codex on Windows
# (MSYS) blocks instead of parking: 100 s by default, not 25. The user's config
# wins over any default: config <h>.<plat> → config <h> → config.default <h>.<plat>
# → config.default <h> → built-in.
# wt HARNESS PLATFORM — the wait timeout brg of the project would use
wt() { BRG_SOURCE_ONLY=1 bash -c '. "$1"; cfg_load; wait_timeout_v t "$2" "$3"; echo "$t"' _ "$BRG" "$1" "$2"; }
test_wait_timeout_per_platform() {
  local out a
  new_proj # its config: wait_timeout.codex: 2
  out=$(BRG_PLATFORM=MSYS brg join --harness codex --model gpt)
  a=$(printf '%s\n' "$out" | sed -n 's/^── подключён: \([^ ]*\) .*/\1/p')
  assert_contains "$out" "возвращается при сообщениях или через 2 с" "user's wait_timeout.codex beats default codex.msys"
  assert_contains "$out" "Таймаут инструмента: Codex (Windows): wait блокирует команду до 2 с"
  # without the user's key: config.default codex.msys (100) on MSYS, codex (25) elsewhere
  awk '!/^wait_timeout\.codex:/' "$B/config" >"$B/config.tmp" && mv "$B/config.tmp" "$B/config"
  out=$(brg status --as "$a") # the platform recorded at join: MSYS
  assert_contains "$out" "Таймаут wait: 100 с."
  assert_contains "$out" "Codex (Windows): wait блокирует команду до 100 с — если инструмент принимает лимит времени, ставь ≥ 160000 мс"
  assert_eq 25 "$(wt codex Darwin)"
  assert_eq 25 "$(wt codex Linux)"
  # the user's platform key beats the user's plain key
  printf 'wait_timeout.codex: 9\nwait_timeout.codex.msys: 7\n' >>"$B/config"
  assert_contains "$(brg status --as "$a")" "Таймаут wait: 7 с."
  assert_eq 9 "$(wt codex Darwin)"
  assert_contains "$(brg wait --as "$a" --timeout 0)" "── нет новых (0 с)"
  # a plain key in config beats a platform key in config.default
  printf 'wait_timeout.claude.darwin: 300\n' >>"$B/config.default"
  printf 'wait_timeout.claude: 11\n' >>"$B/config"
  assert_eq 11 "$(wt claude Darwin)"
  # without config.default either: the built-in values
  rm -f "$B/config.default"
  printf 'heartbeat: 1\n' >"$B/config"
  assert_eq 100 "$(wt codex MSYS)"
  assert_eq 25 "$(wt codex Darwin)"
  # wait_timeout.default only for harnesses without a key of their own
  printf 'wait_timeout.default: 50\n' >>"$B/config"
  assert_eq 25 "$(wt codex Darwin)"
  assert_eq 50 "$(wt myharness Darwin)"
}

# Started by bin/brg.cmd (BRG_VIA_CMD) brg names itself the way
# PowerShell/cmd can run it, and tells about --file.
test_commands_shown_for_brg_cmd() {
  local out a up
  new_proj
  out=$(cd "$P" && BRG_VIA_CMD='C:\toy\.brigada\bin\brg.cmd' bash .brigada/bin/brg join --harness codex --model gpt)
  a=$(printf '%s\n' "$out" | sed -n 's/^── подключён: \([^ ]*\) .*/\1/p')
  assert_eq '── NEXT: .\.brigada\bin\brg.cmd wait --as '"$a" "$(printf '%s\n' "$out" | tail -n 1)"
  assert_contains "$out" "Ты вызываешь brg из PowerShell/cmd"
  assert_contains "$out" "--file <путь>"
  out=$(cd "$P" && BRG_VIA_CMD='C:\toy\.brigada\bin\brg.cmd' bash .brigada/bin/brg wait --as "$a" --timeout 0)
  assert_eq '── нет новых (0 с) · ход не завершай · NEXT: .\.brigada\bin\brg.cmd wait --as '"$a"' --timeout 0' "$out"
  assert_not_contains "$out" "не из корня"
  # not from the project root: still the relative form (a quoted full path is no
  # command in PowerShell, & "…" is none in cmd), and first a line: go to the root
  out=$(BRG_VIA_CMD='C:\My Projects\toy\.brigada\bin\brg.cmd' brg status --as "$a")
  assert_eq '── ВНИМАНИЕ: brg вызван не из корня проекта. Команды brg (и из NEXT тоже) выполняй из корня: cd "C:\My Projects\toy" (в cmd, если корень на другом диске: cd /d "C:\My Projects\toy"), затем .\.brigada\bin\brg.cmd …' "$(printf '%s\n' "$out" | head -n 1)"
  assert_eq '── NEXT: .\.brigada\bin\brg.cmd wait --as '"$a" "$(printf '%s\n' "$out" | tail -n 1)"
  out=$(BRG_VIA_CMD='C:\toy\.brigada\bin\brg.cmd' brg wait --as "$a" --timeout 0)
  assert_contains "$out" 'cd "C:\toy"'
  assert_eq '── нет новых (0 с) · ход не завершай · NEXT: .\.brigada\bin\brg.cmd wait --as '"$a"' --timeout 0' "$(printf '%s\n' "$out" | tail -n 1)"
  # the root in another case is still the root (Windows paths ignore case); only
  # where the file system ignores case too
  up=$(printf '%s' "$P" | tr 'a-z' 'A-Z')
  if [ -d "$up" ]; then
    out=$(cd "$up" && BRG_VIA_CMD='C:\toy\.brigada\bin\brg.cmd' bash "$P/.brigada/bin/brg" status --as "$a")
    assert_not_contains "$out" "не из корня"
  fi
  # without brg.cmd: as before
  out=$(brg status --as "$a")
  assert_not_contains "$out" "PowerShell/cmd"
  assert_not_contains "$out" "не из корня"
}

# Rehearsal fixes: "X подключился" (and "вернулся") stays quiet for everyone but the
# host of the active task — it brings the newcomer into the work.
test_join_wakes_the_task_host() {
  local a b c out pa pb f
  new_proj
  a=$(join_as claude)
  b=$(join_as codex)
  printf 'x\n' | brg task new --as "$a" --title "Хост" >/dev/null || fail "task new"
  ack_all "$a"
  ack_all "$b"
  export BRG_TICK=0.2
  start_wait "$a" "$P/wa" --timeout 20
  pa=$WP
  start_wait "$b" "$P/wb" --timeout 20
  pb=$WP
  c=$(join_as opencode)
  f=$(msg_file "$(cat "$B/lobby/seq")")
  assert_eq "${a%%.*}" "$(hdr "$f" Wake)" "wakes only the host"
  wait_pid $pa 3 || fail "the host was not woken by the join"
  assert_contains "$(cat "$P/wa")" "${c%%.*} подключился (opencode, m, "
  assert_contains "$(cat "$P/wa")" "host ${a%%.*}: учти его в задаче T001"
  sleep 0.6
  is_alive $pb || fail "a participant woke up on the join: $(cat "$P/wb")"
  # back after leave (join --as): the same
  brg leave --as "$c" >/dev/null
  start_wait "$a" "$P/wa2" --timeout 20
  pa=$WP
  brg join --as "$c" --harness opencode >/dev/null || fail "rejoin"
  f=$(msg_file "$(cat "$B/lobby/seq")")
  assert_eq "${a%%.*}" "$(hdr "$f" Wake)"
  wait_pid $pa 3 || fail "the host was not woken by the return"
  assert_contains "$(cat "$P/wa2")" "${c%%.*} переподключён новой сессией (opencode, m, "
  is_alive $pb || fail "a participant woke up on the return"
  kill -TERM $pb
  wait_pid $pb 3 || fail "wait hung"
  # the host itself coming back: nobody to wake
  # it has dropped out (asleep: no wait and no brg calls for longer than asleep_after)
  printf '%s\n' $(($(date -u +%s) - 100)) >"$B/run/seen/${a%%.*}"
  printf '%s\n' $(($(date -u +%s) - 100)) >"$B/run/wait/${a%%.*}.last"
  brg join --as "$a" --harness claude >/dev/null || fail "host rejoin"
  f=$(msg_file "$(cat "$B/lobby/seq")")
  assert_eq no "$(hdr "$f" Wake)"
  assert_not_contains "$(cat "$f")" "учти его"
}

# Rehearsal fixes: who/status show an agent without a live wait for longer than its
# wait timeout + 60 s ("без wait N мин") and, with neither a wait nor a brg call for
# longer than max(wait timeout + 60 s, dropout_after), "возможно выпал" (the human
# then says "продолжай" in its chat). The states themselves (asleep/gone) do not
# change; a stopped agent is not "выпал".
test_who_shows_possible_dropouts() {
  local a b c d e out now
  new_proj # claude: wait 3 s → "без wait" after 63 s; asleep_after 60, gone_after 120
  printf 'dropout_after: 90\n' >>"$B/config"
  a=$(join_as claude)
  b=$(join_as claude)
  c=$(join_as claude)
  d=$(join_as claude)
  e=$(join_as claude)
  brg wait --as "$e" --timeout 0 >/dev/null
  now=$(date -u +%s)
  printf '%s\n' $((now - 200)) >"$B/run/wait/${a%%.*}.last"
  printf '%s\n' $((now - 100)) >"$B/run/seen/${a%%.*}" # asleep, no wait, no brg calls
  printf '%s\n' $((now - 200)) >"$B/run/wait/${b%%.*}.last" # no wait, but brg calls
  printf '%s\n' $((now - 200)) >"$B/run/wait/${d%%.*}.last" # stopped by the human
  printf '%s\n' $((now - 100)) >"$B/run/seen/${d%%.*}"
  : >"$B/run/stopped.${d%%.*}"
  printf '%s\n' $((now - 200)) >"$B/run/wait/${e%%.*}.last" # a killed wait: its heartbeat is recent
  printf '99999 %s\n' $((now - 10)) >"$B/run/wait/${e%%.*}.hb"
  out=$(brg who)
  assert_contains "$out" "${a%%.*} · claude · m · asleep · активен 10" # 100 s (101 if a second boundary passed)
  assert_contains "$out" " с назад · без wait 3 мин · возможно выпал"
  assert_contains "$out" "${b%%.*} · claude · m · working · активен "
  assert_contains "$(printf '%s\n' "$out" | awk -v n="${b%%.*}" 'index($0, n " ") == 1')" " · без wait 3 мин"
  assert_not_contains "$(printf '%s\n' "$out" | awk -v n="${b%%.*}" 'index($0, n " ") == 1')" "выпал"
  assert_not_contains "$(printf '%s\n' "$out" | awk -v n="${c%%.*}" 'index($0, n " ") == 1')" "без wait" "just joined"
  assert_contains "$(printf '%s\n' "$out" | awk -v n="${d%%.*}" 'index($0, n " ") == 1')" "${d%%.*} · claude · m · asleep (stop) · активен 10"
  assert_contains "$(printf '%s\n' "$out" | awk -v n="${d%%.*}" 'index($0, n " ") == 1')" " с назад · без wait 3 мин"
  assert_not_contains "$(printf '%s\n' "$out" | awk -v n="${d%%.*}" 'index($0, n " ") == 1')" "выпал"
  assert_not_contains "$(printf '%s\n' "$out" | awk -v n="${e%%.*}" 'index($0, n " ") == 1')" "без wait"
  assert_contains "$out" "── «возможно выпал»: ни wait, ни вызовов brg дольше 90 с (dropout_after; не меньше таймаута wait + 60 с) — модель могла завершить ход. Человеку: напиши этому агенту в его чат «продолжай»."
  out=$(brg status --as "$b")
  assert_contains "$out" "Мой wait: не запущен · без wait 3 мин"
  assert_contains "$out" "${a%%.*} (claude, m, asleep, без wait 3 мин, возможно выпал)"
  # a wait of its own resets it (the finishing wait marks the time)
  brg wait --as "$a" --timeout 0 >/dev/null
  out=$(brg who)
  assert_not_contains "$(printf '%s\n' "$out" | awk -v n="${a%%.*}" 'index($0, n " ") == 1')" "без wait"
  assert_not_contains "$out" "── «возможно выпал»"
  # a left (gone) agent is not annotated
  printf '%s\n' $((now - 200)) >"$B/run/wait/${b%%.*}.last"
  brg leave --as "$b" >/dev/null
  assert_not_contains "$(brg who | awk -v n="${b%%.*}" 'index($0, n " ") == 1')" "без wait"
  # the default dropout_after (300 s, template config): an agent quietly writing code
  # for a few minutes is "без wait", not "возможно выпал"
  awk '!/^dropout_after:/' "$B/config" >"$B/config.tmp" && mv "$B/config.tmp" "$B/config"
  assert_eq 300 "$(BRG_SOURCE_ONLY=1 bash -c '. "$1"; cfg_load; echo "$DROPOUT_AFTER"' _ "$BRG")"
  now=$(date -u +%s)
  printf '%s\n' $((now - 200)) >"$B/run/wait/${c%%.*}.last"
  printf '%s\n' $((now - 110)) >"$B/run/seen/${c%%.*}"
  out=$(brg who | awk -v n="${c%%.*}" 'index($0, n " ") == 1')
  assert_contains "$out" "${c%%.*} · claude · m · asleep · "
  assert_contains "$out" " · без wait 3 мин"
  assert_not_contains "$out" "выпал"
  printf 'dropout_after: 100\n' >>"$B/config"
  assert_contains "$(brg who | awk -v n="${c%%.*}" 'index($0, n " ") == 1')" " · без wait 3 мин · возможно выпал"
}
