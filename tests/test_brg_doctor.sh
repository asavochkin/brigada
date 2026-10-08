# brg doctor — checks the environment and the state, changes nothing.

. "$TESTS_DIR/brg_lib.sh"

# runners live in their own process groups: kill them after the test
doc_cleanup() {
  local f r g
  [ -n "${B:-}" ] || return 0
  for f in "$B"/tasks/*/shared/runs/R[0-9]*; do
    [ -f "$f" ] || continue
    case ${f##*/} in *.*) continue ;; esac
    r=$(hdr "$f" Runner)
    g=$(hdr "$f" Pgid)
    [ -n "$g" ] && kill -KILL -- -"$g" 2>/dev/null
    [ -n "$r" ] && kill -KILL "$r" 2>/dev/null
  done
  return 0
}

st_is() { [ "$(hdr "$1" Status)" = "$2" ]; } # RUNFILE STATUS

# fails / warnings of a doctor output
fails() { printf '%s\n' "$1" | awk '/^✗ /'; }
warns() { printf '%s\n' "$1" | awk '/^⚠ /'; }

# A normal project (under git, agents, a task, a finished run): no ✗, exit 0, and
# doctor touches nothing.
test_doctor_green_on_normal_project() {
  local out rc a c before after
  trap doc_cleanup EXIT
  new_proj
  mkdir -p "$P/.git/info"
  bash "$BRG_SRC" init "$P" >/dev/null || fail init # the excludes
  printf 'wait_timeout.claude: 100\nwait_timeout.opencode: 100\nwait_timeout.codex: 25\nwait_timeout.default: 100\n' >>"$B/config"
  a=$(join_as claude opus)
  c=$(join_as codex gpt)
  task_new_as "$a" "Задача"
  brg run --as "$a" --sync -- true >/dev/null || fail run
  ack_all "$c"
  ack_all "$c" "$(tdir T001)"
  start_wait "$c" "$P/wc" --timeout 30
  before=$(cd "$B" && ls -R lobby tasks agents run/locks run/wait run/execq 2>/dev/null | cksum)
  out=$(brg doctor)
  rc=$?
  after=$(cd "$B" && ls -R lobby tasks agents run/locks run/wait run/execq 2>/dev/null | cksum)
  assert_eq 0 "$rc" "doctor exit code; output:
$out"
  assert_eq "" "$(fails "$out")" "✗ in a normal project"
  assert_eq "" "$(warns "$out")" "⚠ in a normal project"
  assert_contains "$out" "── brg doctor "
  assert_contains "$out" "✓ bash "
  assert_contains "$out" "✓ установка: .brigada версии "
  assert_contains "$out" "✓ подключённые агенты (2) — той же платформы"
  assert_contains "$out" "✓ bin/brg: окончания строк LF"
  assert_contains "$out" "✓ bin/brg.cmd: окончания строк CRLF"
  assert_contains "$out" "✓ утилиты: head -c, date +%s, дробный sleep, kill -0, set -m и kill группе процессов"
  assert_contains "$out" "✓ mkdir атомарен"
  assert_contains "$out" "✓ mv поверх файла, открытого другим процессом на чтение, — успешно"
  assert_contains "$out" "✓ .git/info/exclude: переписка и рантайм brigada не коммитятся"
  assert_contains "$out" "✓ блокировки: протухших и зависших нет"
  assert_contains "$out" "✓ brg run: мёртвых и зависших раннеров нет"
  assert_contains "$out" "✓ wait: живых 1"
  assert_contains "$out" "✓ wait_timeout ("
  assert_contains "$out" "claude 100 · opencode 100 · codex 25"
  assert_contains "$out" "── итого: ✓ "
  assert_contains "$out" "Всё в порядке."
  assert_eq "$before" "$after" "doctor changed the state"
  assert_eq "" "$(ls -A "$B/run" | awk '/^\.doctor/')" "scratch dir left behind"
  assert_contains "$(metrics_of - doctor)" "fail=0"
  # from the brigada repo for the project; and --help
  out=$(bash "$BRG_SRC" doctor "$P")
  assert_eq 0 "$?" "doctor from the repo"
  assert_contains "$out" "── brg doctor $(cat "$B/VERSION") · $B"
  out=$(brg doctor --help)
  assert_eq 0 "$?"
  assert_contains "$out" "Использование:"
  kill -TERM $WP
}

# CRLF in the installed brg: it cannot run itself, doctor from the repo finds it.
test_doctor_crlf_in_brg() {
  local out
  new_proj
  awk '{ printf "%s\r\n", $0 }' "$BRG_SRC" >"$B/bin/brg.tmp" && mv "$B/bin/brg.tmp" "$B/bin/brg"
  out=$(bash "$BRG" doctor 2>&1)
  assert_eq 2 "$?" "the CRLF guard"
  assert_contains "$out" "окончания строк CRLF"
  out=$(bash "$BRG_SRC" doctor "$P")
  assert_eq 1 "$?"
  assert_contains "$(fails "$out")" "✗ bin/brg: окончания строк CRLF"
  assert_contains "$out" "→ Причина — git с core.autocrlf=true"
  assert_contains "$out" "bin/brg init $P"
  assert_contains "$out" "Есть ошибки (✗)"
  # templates with CRLF: a warning; brg.cmd without CRLF: a warning off Windows,
  # an error on it
  bash "$BRG_SRC" init "$P" >/dev/null
  awk '{ printf "%s\r\n", $0 }' "$B/README.md" >"$B/README.tmp" && mv "$B/README.tmp" "$B/README.md"
  tr -d '\r' <"$B/bin/brg.cmd" >"$B/bin/c.tmp" && mv "$B/bin/c.tmp" "$B/bin/brg.cmd"
  out=$(brg doctor)
  assert_eq 0 "$?" "only warnings"
  assert_contains "$(warns "$out")" "⚠ окончания строк CRLF: README.md"
  assert_contains "$(warns "$out")" "⚠ bin/brg.cmd: окончания строк LF"
  out=$(BRG_PLATFORM=MSYS brg doctor)
  assert_eq 1 "$?"
  assert_contains "$(fails "$out")" "✗ bin/brg.cmd: окончания строк LF"
}

# Leftovers of crashes: a lock of a dead owner, a dead runner holding the exec
# lock, a queue entry with a live pid but no heartbeat, a hung wait — each a ✗
# with a hint; doctor itself fixes nothing.
test_doctor_stale_locks_dead_runners_hung_waits() {
  local out a dp sp r f
  trap doc_cleanup EXIT
  new_proj
  a=$(join_as claude)
  task_new_as "$a" "Задача"
  dp=$(dead_pid)
  mkdir "$B/run/locks/chan.lobby.lock"
  printf '%s %s\n' "$dp" "$(date -u +%s)" >"$B/run/locks/chan.lobby.lock/owner"
  out=$(brg doctor)
  assert_eq 1 "$?"
  assert_contains "$(fails "$out")" "✗ протухшая блокировка chan.lobby.lock: владелец (pid $dp) мёртв"
  assert_contains "$out" "→ brg снимет её сам при следующем обращении"
  assert_file_exists "$B/run/locks/chan.lobby.lock/owner" "doctor removed the lock"
  rm -rf "$B/run/locks/chan.lobby.lock"
  # a runner killed with -9 while running
  brg run --as "$a" -- 'sleep 30' >/dev/null || fail run
  f=$(tdir T001)/shared/runs/R001
  wait_for 3 st_is "$f" running || fail "R001 did not start"
  r=$(hdr "$f" Runner)
  kill -KILL "$r"
  sleep 0.3
  out=$(brg doctor)
  assert_eq 1 "$?"
  assert_contains "$(fails "$out")" "✗ exec-блокировка у мёртвого раннера (pid $r, прогон R001)"
  assert_contains "$out" "run show R001"
  assert_eq 1 "$(fails "$out" | wc -l | tr -d ' ')" "one line per dead runner:
$out"
  assert_eq running "$(hdr "$f" Status)" "doctor settled the run"
  kill -KILL -- -"$(hdr "$f" Pgid)" 2>/dev/null
  brg run show R1 >/dev/null # settles it (killed)
  rm -rf "$B/run/locks/exec.lock"
  # a queue entry: live pid, no heartbeat
  sleep 60 &
  sp=$!
  track_pid $sp
  mkdir -p "$B/run/execq"
  printf '%s R099 %s\n' $sp "$(basename "$(tdir T001)")" >"$B/run/execq/000099"
  # a hung wait: live pid, no heartbeat
  printf '%s\n' $sp >"$B/run/wait/$a.pid"
  out=$(brg doctor)
  assert_eq 1 "$?"
  assert_contains "$(fails "$out")" "✗ очередь brg run: R099 — раннер (pid $sp) не подаёт признаков жизни"
  assert_contains "$out" "run cancel R099"
  assert_contains "$(fails "$out")" "✗ wait агента $a: pid $sp жив, но heartbeat не обновляется (нет файла heartbeat)"
  assert_contains "$out" "SUPERSEDED"
  assert_file_exists "$B/run/execq/000099" "doctor dropped the entry"
  # a leftover pid file of a finished wait is harmless
  rm -f "$B/run/execq/000099"
  printf '%s\n' "$(dead_pid)" >"$B/run/wait/$a.pid"
  out=$(brg doctor)
  assert_eq 0 "$?" "$out"
  assert_contains "$out" "✓ wait: живых 0, остались pid-файлы завершённых: 1 (безвредно)"
  : >"$B/run/stopped"
  assert_contains "$(warns "$(brg doctor)")" "⚠ бригада остановлена (stop)"
}

# Agents of another platform; wait timeouts above the limits of the harnesses;
# missing git excludes.
test_doctor_platform_config_git() {
  local out
  new_proj
  BRG_PLATFORM=WSL brg join --harness claude --model m >/dev/null || fail join
  out=$(brg doctor)
  assert_eq 1 "$?"
  assert_contains "$(fails "$out")" "✗ подключены агенты другой платформы: claude-1 (WSL, working)"
  out=$(BRG_PLATFORM=WSL brg doctor)
  assert_contains "$(warns "$out")" "⚠ bash из WSL"
  assert_not_contains "$out" "агенты другой платформы"
  new_proj
  printf 'wait_timeout.claude: 700\nwait_timeout.opencode: 300\nwait_timeout.codex: 60\n' >>"$B/config"
  out=$(brg doctor)
  assert_eq 1 "$?"
  assert_contains "$(fails "$out")" "больше 540 с: claude 700"
  assert_contains "$(warns "$out")" "выше рекомендованного: opencode 300, codex 60"
  assert_contains "$(warns "$out")" "⚠ wait_timeout (darwin) меньше 5 с: прочие 3"
  # on Windows codex blocks: 60 is fine there (the user's codex key wins over codex.msys)
  printf 'wait_timeout.claude: 100\nwait_timeout.opencode: 100\nwait_timeout.default: 100\n' >>"$B/config"
  out=$(BRG_PLATFORM=MSYS brg doctor)
  assert_contains "$out" "✓ wait_timeout (msys): claude 100 · opencode 100 · codex 60"
  awk '!/^wait_timeout\.codex:/' "$B/config" >"$B/config.tmp" && mv "$B/config.tmp" "$B/config"
  assert_contains "$(BRG_PLATFORM=MSYS brg doctor)" "✓ wait_timeout (msys): claude 100 · opencode 100 · codex 100"
  # git: excludes missing
  mkdir -p "$P/.git/info"
  out=$(brg doctor)
  assert_eq 1 "$?"
  assert_contains "$(fails "$out")" "✗ .git/info/exclude: нет .brigada/tasks/ .brigada/lobby/ .brigada/run/ .brigada/agents/"
  assert_contains "$out" "init $P"
  # no .brigada at all: a clear error, not a crash
  out=$(cd "$(mk_tmpdir)" && bash "$BRG_SRC" doctor 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "не найден .brigada"
}

# Liveness of processes (via the test hook): a parent out of reach (EPERM) — ⚠
# sandbox; EPERM even for a finished child — ⚠ death not visible. The exec lock of
# a dead runner gets the verdict of brg itself: no ✗ while its heartbeat is fresh
# within runner_dead_grace.
test_doctor_sandbox_eperm_and_dead_runner_grace() {
  local out dp now
  new_proj
  out=$(brg doctor)
  assert_contains "$out" "✓ процессы: kill -0 видит родителя и смерть процесса"
  out=$(bash -c 'BRG_TEST_EPERM_PIDS=$$ bash "$1" doctor; exit $?' _ "$BRG")
  assert_eq 0 "$?" "⚠ only; output:
$out"
  assert_contains "$(warns "$out")" "⚠ песочница: чужие процессы недоступны (EPERM на родителя"
  assert_contains "$out" "запускай вне песочницы"
  assert_not_contains "$out" "смерть процессов не видна"
  out=$(BRG_TEST_EPERM_PIDS='*' brg doctor)
  assert_contains "$(warns "$out")" "⚠ смерть процессов не видна: kill -0 к завершённому процессу"
  assert_contains "$out" "отвечает EPERM"
  assert_contains "$out" "runner_stale"
  # runner_dead_grace: the same verdict as brg
  printf 'runner_dead_grace: 30\n' >>"$B/config"
  dp=$(dead_pid)
  now=$(date -u +%s)
  mkdir "$B/run/locks/exec.lock"
  printf '%s %s\n' "$dp" $((now - 100)) >"$B/run/locks/exec.lock/owner"
  printf 'R001 T001\n' >"$B/run/locks/exec.lock/run"
  printf '%s %s\n' "$dp" "$now" >"$B/run/locks/exec.lock/hb"
  mkdir -p "$B/run/execq"
  printf '%s R002 T001 %s\n' "$dp" "$now" >"$B/run/execq/000002"
  out=$(brg doctor)
  assert_eq 0 "$?" "a dead pid within runner_dead_grace; output:
$out"
  assert_contains "$out" "✓ блокировки: протухших и зависших нет"
  assert_contains "$out" "✓ brg run: мёртвых и зависших раннеров нет"
  printf '%s %s\n' "$dp" $((now - 40)) >"$B/run/locks/exec.lock/hb"
  printf '%s R002 T001 %s\n' "$dp" $((now - 40)) >"$B/run/execq/000002"
  out=$(brg doctor)
  assert_eq 1 "$?"
  assert_contains "$(fails "$out")" "✗ exec-блокировка у мёртвого раннера (pid $dp, прогон R001)"
  assert_contains "$(fails "$out")" "✗ очередь brg run: R002 — раннер (pid $dp) мёртв"
  # runner_dead_grace not below runner_stale
  printf 'runner_dead_grace: 60\n' >>"$B/config"
  assert_contains "$(warns "$(brg doctor)")" "⚠ runner_dead_grace (60) не меньше runner_stale (60) — brg берёт 59"
}
