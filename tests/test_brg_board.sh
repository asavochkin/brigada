# brg board (DESIGN §9.1): the snapshot for the browser page — content, escaping,
# read-only, the cache of finished tasks, the loop, the file:// address, init.

. "$TESTS_DIR/brg_lib.sh"

NL=$'\n'
BOARD_PREFIX='window.BRG_BOARD = '

bdata() { cat "$B/run/board/data.js"; }
has_node() { command -v node >/dev/null 2>&1; }

# close_task NAME TEXT — write summary.md of the active task and close it
close_task() {
  local d
  d=$(cat "$B/tasks/active") || fail "no active task"
  printf '%s\n' "$2" >"$B/tasks/$d/summary.md"
  brg task close --as "$1" >/dev/null 2>&1 || brg task close --as "$1" >/dev/null || fail "close"
}

# data_has TEXT — data.js contains TEXT (for wait_for)
data_has() {
  local s
  s=$(cat "$B/run/board/data.js" 2>/dev/null) || return 1
  case $s in *"$1"*) return 0 ;; esac
  return 1
}

# board_snap — the state of .brigada without run/board: ls -laiR (catches a file
# replaced via mv: a new inode) and cksum of every file
board_snap() {
  (cd "$B" && ls -laiR . | awk '/^\.\/run\/board(\/.*)?:$/ { skip = 1; next } /^$/ { skip = 0 } !skip && $NF != "board"')
  (cd "$B" && find . -type f ! -path './run/board/*' -exec cksum {} + | sort -k3)
}

test_board_snapshot_content() {
  local a c out d
  new_proj
  a=$(join_as claude opus)
  c=$(join_as codex gpt)
  task_new_as "$a" "Доска: проверка" "постановка доски"
  d=$(tdir T001)
  brg item add --as "$a" --title "Первая подзадача" --desc "описание первой" --paths src/a >/dev/null || fail "item add 1"
  brg item add --as "$a" --title "Вторая подзадача" --desc "описание второй" --paths src/b >/dev/null || fail "item add 2"
  brg item claim I001 --as "$c" >/dev/null || fail claim
  brg item done I001 --as "$c" --note "сделано" >/dev/null || fail done
  brg item review I001 --as "$a" --verdict changes --comment "поправь отступы" >/dev/null || fail review
  brg run --as "$a" --sync -- echo board-run-output >/dev/null || fail run
  send_as "$c" "сообщение для доски"
  printf '%s\n' "план работ" >"$d/shared/plan.md"
  out=$(brg board --once) || fail "board --once"
  assert_eq "file://$B/board.html" "$(printf '%s\n' "$out" | head -n 1)" "first line: the page address"
  assert_contains "$out" "снимок записан"
  out=$(bdata)
  case $out in "$BOARD_PREFIX{"*) ;; *) fail "data.js does not start with $BOARD_PREFIX" ;; esac
  for x in '"name":"claude-1"' '"name":"codex-1"' '"Model":"opus"' '"current":{"id":"T001"' '"Id":"I001"' '"Id":"I002"' \
    '"Verdict":"changes"' '"b":"поправь отступы"' '"Command":"echo board-run-output"' '"tail":"  board-run-output"' \
    '"b":"сообщение для доски"' '"brief":"постановка доски"' '"plan":"план работ"' '"summary":null' \
    '"Title":"Доска: проверка"' '"version":"0.3.0"' '"stop":false' '"rh":"ok"'; do
    assert_contains "$out" "$x"
  done
  assert_not_contains "$out" '"Key"' "the session key leaks onto the board"
  assert_not_contains "$out" "$(hdr "$B/agents/claude-1" Key)" "the session key leaks onto the board"
  if has_node; then
    node -e '
      const fs = require("fs"), vm = require("vm"), w = {};
      vm.runInNewContext(fs.readFileSync(process.argv[1], "utf8"), { window: w });
      const d = w.BRG_BOARD;
      if (d.agents.length !== 2 || d.current.items.length !== 2 || d.current.runs.length !== 1) throw new Error("counts");
      if (d.current.items[0].reviews[0].h.Reviewer !== "claude-1") throw new Error("review");
      if (!d.lobby.length || !d.current.messages.length || d.tasks[0].dir.indexOf("T001") !== 0) throw new Error("lists");
    ' "$B/run/board/data.js" || fail "node: data.js does not run or lacks data"
  fi
}

# A body with ", \, a newline, a tab, \001, DEL, U+2028 and Cyrillic: exact JSON escapes
# in data.js, no raw control bytes; node parses it back to the very same text.
BODY_RAW=$'q "кавычки" \\ обр\tтаб\001ctl\177del\342\200\250ls\nвторая строка'
BODY_JSON='q \"кавычки\" \\ обр\tтаб\u0001ctl\u007fdel\u2028ls\nвторая строка'
board_check_escapes() { # [LABEL]
  local s n
  s=$(bdata)
  assert_contains "$s" "\"b\":\"$BODY_JSON\"" "escapes${1:+ ($1)}"
  assert_contains "$s" '"Title":"T \"x\" \\ y"' "escapes in a header${1:+ ($1)}"
  n=$(LC_ALL=C tr -d '\040-\176\200-\377\n' <"$B/run/board/data.js" | wc -c | tr -d ' ')
  assert_eq 0 "$n" "raw control bytes in data.js${1:+ ($1)}"
}
test_board_escaping() {
  local a f
  new_proj
  a=$(join_as claude)
  task_new_as "$a" 'T "x" \ y'
  printf '%s\n' "$BODY_RAW" | brg send --as "$a" >/dev/null || fail send
  f=$(tmsg T001 1)
  brg board --once >/dev/null || fail board
  board_check_escapes
  if has_node; then
    node -e '
      const fs = require("fs"), path = require("path");
      let s = fs.readFileSync(process.argv[1], "utf8");
      const p = "window.BRG_BOARD = ";
      if (!s.startsWith(p) || !s.endsWith(";\n")) throw new Error("wrapper");
      const d = JSON.parse(s.slice(p.length, -2));
      const raw = fs.readFileSync(process.argv[2], "utf8");
      const body = raw.slice(raw.indexOf("\n\n") + 2).replace(/\n$/, "");
      const m = d.current.messages.find(x => x.f === path.basename(process.argv[2]));
      if (!m) throw new Error("no message");
      if (m.b !== body) throw new Error("body: " + JSON.stringify(m.b) + " != " + JSON.stringify(body));
      if (d.current.task.h.Title !== "T \"x\" \\ y") throw new Error("title");
    ' "$B/run/board/data.js" "$f" || fail "node: JSON.parse / round trip"
  fi
}

# The same with gawk / mawk as awk (PATH shim), when the system has them.
test_board_escaping_other_awks() {
  local a x p sh ran=
  new_proj
  a=$(join_as claude)
  task_new_as "$a" 'T "x" \ y'
  printf '%s\n' "$BODY_RAW" | brg send --as "$a" >/dev/null || fail send
  for x in gawk mawk; do
    p=$(command -v "$x" 2>/dev/null) || continue
    sh=$(mk_tmpdir)
    ln -s "$p" "$sh/awk"
    PATH="$sh:$PATH" bash "$BRG" board --once >/dev/null || fail "board with $x"
    board_check_escapes "$x"
    ran="$ran $x"
  done
  [ -n "$ran" ] || echo "SKIP: gawk/mawk not installed"
}

# board changes nothing outside run/board: no touch_seen, no run_check/execq_scan on
# a run whose runner is dead, no body_gc of need_root, no metrics; the dead runner
# is shown (rh: dead).
test_board_is_read_only() {
  local a c d dp old before after s n
  new_proj
  a=$(join_as claude)
  c=$(join_as codex)
  task_new_as "$a" "Только чтение"
  send_as "$a" "сообщение"
  d=$(tdir T001)
  old=$(($(date -u +%s) - 50))
  for n in claude-1 codex-1; do
    printf '%s\n' "$old" >"$B/run/seen/$n"
    printf '%s\n' "$old" >"$B/run/wait/$n.last"
  done
  dp=$(dead_pid)
  mkdir -p "$d/shared/runs" "$B/run/execq"
  printf 'Id: R001\nTask: T001\nAgent: claude-1\nCommand: make test\nMode: bg\nTimeout: 100\nStatus: running\nRequested: x\nRequested-Epoch: %s\nStarted: x\nStarted-Epoch: %s\nRunner: %s\n' \
    "$old" "$old" "$dp" >"$d/shared/runs/R001"
  printf 'строка лога\n' >"$d/shared/runs/R001.log"
  printf 'Id: R002\nTask: T001\nAgent: codex-1\nCommand: make lint\nMode: bg\nTimeout: 100\nStatus: queued\nRequested: x\nRequested-Epoch: %s\nRunner: %s\n' \
    "$old" "$dp" >"$d/shared/runs/R002"
  printf '2\n' >"$B/run/runs.seq"
  mkdir "$B/run/locks/exec.lock"
  printf '%s %s\n' "$dp" "$old" >"$B/run/locks/exec.lock/owner"
  printf 'R001 %s\n' "${d##*/}" >"$B/run/locks/exec.lock/run"
  printf '%s R002 %s %s\n' "$dp" "${d##*/}" "$old" >"$B/run/execq/000002"
  : >"$B/run/.body.$dp.x"
  mkdir "$B/run/board" # board creates it; its own files are not compared
  before=$(board_snap)
  brg board --once >/dev/null || fail board
  after=$(board_snap)
  assert_eq "$before" "$after" ".brigada changed outside run/board"
  s=$(bdata)
  assert_contains "$s" '"Status":"running"'
  assert_contains "$s" '"rh":"dead"'
  assert_contains "$s" '"tail":"  строка лога"'
  assert_contains "$s" '"Id":"R002"'
  assert_contains "$s" '"seen":'"$old"
  assert_contains "$s" '"state":"working"'
  # the dead runner is still for brg to settle
  assert_eq running "$(hdr "$d/shared/runs/R001" Status)"
  assert_file_exists "$B/run/execq/000002"
  assert_file_exists "$B/run/.body.$dp.x"
}

# Finished tasks other than the current one are cached in T00N.js once; the last
# finished task is the current one (rebuilt every tick); another brg version drops
# the cache.
test_board_cache_of_finished_tasks() {
  local a s d2
  new_proj
  a=$(join_as claude)
  task_new_as "$a" "Первая"
  close_task "$a" "итог первой"
  task_new_as "$a" "Вторая"
  d2=$(tdir T002)
  close_task "$a" "итог второй"
  brg board --once >/dev/null || fail board1
  assert_file_exists "$B/run/board/T001.js"
  assert_file_not_exists "$B/run/board/T002.js" "the current task is cached"
  assert_file_not_exists "$B/run/board/T001.part"
  s=$(cat "$B/run/board/T001.js")
  case $s in '(window.BRG_TASKS = window.BRG_TASKS || {})["T001"] = {"id":"T001"'*) ;; *) fail "T001.js: $s" ;; esac
  assert_contains "$s" '"summary":"итог первой"'
  s=$(bdata)
  assert_contains "$s" '"current":{"id":"T002"'
  assert_contains "$s" '"summary":"итог второй"'
  assert_contains "$s" '"sum":"итог первой"'
  assert_eq "brg 0.3.0" "brg $(cat "$B/run/board/VERSION")"
  # written once: a marker survives the next snapshot
  printf '// marker\n' >>"$B/run/board/T001.js"
  printf '%s\n' "итог второй, уточнён" >"$d2/summary.md"
  brg board --once >/dev/null || fail board2
  assert_contains "$(cat "$B/run/board/T001.js")" "// marker" "T001.js rewritten"
  assert_contains "$(bdata)" '"summary":"итог второй, уточнён"' "the current task is rebuilt"
  # a new active task: T002 goes to the cache
  task_new_as "$a" "Третья"
  brg board --once >/dev/null || fail board3
  assert_file_exists "$B/run/board/T002.js"
  assert_contains "$(bdata)" '"current":{"id":"T003"'
  # another version: the cache is dropped and rebuilt
  printf '0.0.1\n' >"$B/run/board/VERSION"
  brg board --once >/dev/null || fail board4
  assert_not_contains "$(cat "$B/run/board/T001.js")" "// marker" "cache kept after a version change"
  assert_eq "0.3.0" "$(cat "$B/run/board/VERSION")"
}

# The last BOARD_MSGS (500) messages of a channel; over BRG_BOARD_MAX the oldest are
# dropped; meta.trunc says how many are shown.
test_board_limits() {
  local a i s d
  new_proj
  a=$(join_as claude)
  d=$B/lobby/messages
  i=1
  while [ $i -le 510 ]; do
    printf -v s '%s/%06d.msg' "$d" $i
    printf 'Id: %s\nChannel: lobby\nFrom: claude-1\nTo: all\nKind: msg\nTime: x\nEpoch: 1\n\nсообщение номер %s\n' $i $i >"$s"
    i=$((i + 1))
  done
  printf '510\n' >"$B/lobby/seq"
  brg board --once >/dev/null || fail board
  s=$(bdata)
  assert_contains "$s" '"b":"сообщение номер 510"'
  assert_contains "$s" '"b":"сообщение номер 11"'
  assert_not_contains "$s" '"b":"сообщение номер 10"'
  assert_contains "$s" '"trunc":{"lobby":{"shown":500,"total":510}}'
  BRG_BOARD_MAX=20000 bash "$BRG" board --once >/dev/null || fail board-small
  s=$(bdata)
  assert_contains "$s" '"b":"сообщение номер 510"'
  assert_not_contains "$s" '"b":"сообщение номер 11"'
  assert_contains "$s" '"trunc":{"lobby":{"shown":'
  [ "$(wc -c <"$B/run/board/data.js")" -le 20000 ] || fail "data.js over BRG_BOARD_MAX"
  # long texts are cut at 64 KB
  task_new_as "$a" "Длинный план"
  awk 'BEGIN { for (i = 0; i < 2000; i++) print "строка плана номер " i " ........................" }' >"$(tdir T001)/shared/plan.md"
  brg board --once >/dev/null || fail board-plan
  assert_contains "$(bdata)" '…(обрезано)'
}

# The loop: a new message reaches data.js within 3 s; TERM — code 0, no .tmp left.
test_board_loop_and_term() {
  local a out bp
  new_proj
  a=$(join_as claude)
  task_new_as "$a" "Цикл"
  out=$(mk_tmpdir)/out
  bash "$BRG" board --interval 1 >"$out" 2>&1 &
  bp=$!
  track_pid $bp
  wait_for 5 test -f "$B/run/board/data.js" || fail "no data.js"
  send_as "$a" "новое сообщение для цикла"
  wait_for 3 data_has "новое сообщение для цикла" || fail "data.js not updated within 3 s"
  kill -TERM $bp
  wait_pid $bp 5 || fail "board did not exit on TERM"
  assert_eq 0 "$WAIT_RC" "exit code on TERM"
  assert_eq "" "$(cd "$B/run/board" && ls -A | awk '/^\.tmp/')" ".tmp left in run/board"
  assert_eq "file://$B/board.html" "$(head -n 1 "$out")"
  assert_contains "$(cat "$out")" "каждые 1 с"
}

test_board_url() {
  local out
  out=$(BRG_SOURCE_ONLY=1 bash -c '
    . "$1"
    board_url_v u "/tmp/a b/#x?y%z/.brigada" Darwin && echo "1 $u"
    board_url_v u /c/Users/x/.brigada MSYS && echo "2 $u"
    board_url_v u /home/x/.brigada MSYS || echo "3 rc=1 [$u]"
    board_url_v u /mnt/c/x/.brigada WSL || echo "4 rc=1 [$u]"
    board_url_v u /cygdrive/d/p/.brigada Cygwin && echo "5 $u"
    BRG_VIA_CMD="C:\\Users\\a b\\proj\\.brigada\\bin\\brg.cmd"
    board_url_v u /c/Users/whatever MSYS && echo "6 $u"
    BRG_VIA_CMD="d:\\p#1\\.brigada\\bin\\brg.cmd"
    board_url_v u /d/p MSYS && echo "7 $u"
  ' _ "$BRG_SRC")
  assert_contains "$out" "1 file:///tmp/a%20b/%23x%3Fy%25z/.brigada/board.html"
  assert_contains "$out" "2 file:///C:/Users/x/.brigada/board.html"
  assert_contains "$out" "3 rc=1 []"
  assert_contains "$out" "4 rc=1 []"
  assert_contains "$out" "5 file:///D:/p/.brigada/board.html"
  assert_contains "$out" "6 file:///C:/Users/a%20b/proj/.brigada/board.html"
  assert_contains "$out" "7 file:///D:/p%231/.brigada/board.html"
}

test_board_cli_errors_and_init() {
  local out rc p
  new_proj
  assert_file_exists "$B/board.html"
  assert_eq "$(cat "$ROOT/template/board.html")" "$(cat "$B/board.html")" "board.html installed"
  printf 'испорчено\n' >"$B/board.html"
  out=$(bash "$BRG_SRC" init "$P") || fail reinit
  assert_contains "$out" "board.html"
  assert_eq "$(cat "$ROOT/template/board.html")" "$(cat "$B/board.html")" "board.html updated"
  out=$(brg board --help) || fail "board --help"
  assert_contains "$out" "--interval"
  assert_contains "$out" "--once"
  assert_contains "$(brg help)" "board [--interval S] [--once]"
  out=$(brg board --interval 0 2>&1)
  rc=$?
  assert_eq 1 "$rc" "--interval 0"
  assert_contains "$out" "--interval"
  out=$(brg board --frob 2>&1)
  assert_eq 1 "$?" "unknown option"
  assert_file_not_exists "$B/run/board" "a refused board wrote its snapshot"
  # no metrics from board
  brg board --once >/dev/null || fail board
  assert_not_contains "$(cat "$B/run/metrics.log")" " board"
  # no .brigada state: an error, nothing created
  p=$(mk_tmpdir)
  mkdir -p "$p/.brigada/bin"
  cp "$BRG_SRC" "$p/.brigada/bin/brg"
  out=$(bash "$p/.brigada/bin/brg" board --once 2>&1)
  assert_eq 1 "$?" "board without .brigada state"
  assert_contains "$out" "не найдено состояние brigada"
  assert_eq "bin" "$(ls -A "$p/.brigada")" "board without state created files"
}
