# The server of the human's board (DESIGN §9.1): bin/brg-serve.py started by `brg board` —
# address and token, the guards (Host, cookie, token, Origin, content), the actions as brg
# calls, the end of the server with its parent, the fallbacks (no Python, --static), the
# search of Python. Needs Python 3.8+ (the tests skip otherwise); the client of the tests is
# Python too (brg itself never calls it outside board/doctor).

. "$TESTS_DIR/brg_lib.sh"
. "$TESTS_DIR/spawn_lib.sh"

NL=$'\n'

# the client: python3 -I -c "$PYCLIENT" PORT METHOD PATH [-H "Name: value"]... [-j key=string]...
# [-ji key=int] [-jb key=bool] [-jf key=FILE] [-jl key=a,b] [-d FILE (raw body)] [--raw FILE]
# prints the status, "H name: value" per header, a blank line, the body
PYCLIENT=$(
  cat <<'PYEOF'
import sys, json, socket, http.client
port = int(sys.argv[1]); method = sys.argv[2]; path = sys.argv[3]
hdr = {}; body = None; js = None; a = sys.argv[4:]; i = 0
while i < len(a):
    k = a[i]
    if k == '-H':
        n, v = a[i + 1].split(': ', 1); hdr[n] = v
    elif k == '-d':
        body = open(a[i + 1], 'rb').read()
    elif k == '--raw':
        s = socket.create_connection(('127.0.0.1', port), timeout=20)
        s.sendall(open(a[i + 1], 'rb').read().replace(b'PORT', str(port).encode()))
        r = b''
        while True:
            try:
                d = s.recv(4096)
            except socket.timeout:
                break
            if not d:
                break
            r += d
        print(r.split(b'\r\n', 1)[0].decode().split(' ')[1]); sys.exit(0)
    else:
        js = js or {}
        key, val = a[i + 1].split('=', 1)
        if k == '-j': js[key] = val
        elif k == '-ji': js[key] = int(val)
        elif k == '-jb': js[key] = (val == 'true')
        elif k == '-jf': js[key] = open(val, 'rb').read().decode('utf-8')
        elif k == '-jl': js[key] = val.split(',')
    i += 2
if js is not None:
    body = json.dumps(js).encode()
elif body is None and method == 'POST':
    body = b'{}'
c = http.client.HTTPConnection('127.0.0.1', port, timeout=60)
c.request(method, path, body=body, headers=hdr)
r = c.getresponse(); data = r.read()
print(r.status)
for n, v in r.getheaders(): print('H %s: %s' % (n, v))
print(); sys.stdout.flush(); sys.stdout.buffer.write(data)
PYEOF
)

# serve_need — PYX = a Python 3.8+ as brg finds it; 1 (the test is skipped) if none
serve_need() {
  PYX=$(BRG_SOURCE_ONLY=1 bash -c '. "$1"; detect_platform; py_find_v p; printf "%s" "$p"' _ "$BRG_SRC")
  [ -n "$PYX" ] || {
    echo "SKIP: нет Python 3.8+"
    return 1
  }
}

# start_board [args…] — brg board --interval 1 --port 0 in the background; sets BP BOUT URL PORT TOK SPID
start_board() {
  BOUT=$(mk_tmpdir)/out
  bash "$BRG" board --interval 1 --port 0 "$@" >"$BOUT" 2>&1 &
  BP=$!
  track_pid $BP
  wait_for 10 first_is_url || fail "board did not print an http address:
$(cat "$BOUT")"
  URL=$(head -n 1 "$BOUT")
  PORT=${URL#http://127.0.0.1:}
  PORT=${PORT%%/*}
  TOK=${URL##*\?t=}
  SPID=$(sed -n 2p "$B/run/board/ready")
  track_pid "$SPID"
  COOKIE="brg_$PORT=$TOK"
}
first_is_url() { case $(head -n 1 "$BOUT" 2>/dev/null) in http://127.0.0.1:*/\?t=*) return 0 ;; esac; return 1; }

# stop_board — TERM, wait for the end of both
stop_board() {
  kill -TERM "$BP" 2>/dev/null
  wait_pid "$BP" 8 || fail "board did not exit on TERM"
  wait_for 5 is_dead "$SPID" || fail "the server outlived brg board (TERM)"
}

# http METHOD PATH [client args…] — HTTP_OUT, HTTP_ST, HTTP_BODY
http() {
  HTTP_OUT=$("$PYX" -I -c "$PYCLIENT" "$PORT" "$@") || fail "client: $*"
  HTTP_ST=${HTTP_OUT%%"$NL"*}
  HTTP_BODY=${HTTP_OUT#*"$NL$NL"}
}
# post ACTION [json args…] — POST /api/ACTION with the cookie and the token
post() {
  local a=$1
  shift
  http POST "/api/$a" -H "Cookie: $COOKIE" -H "X-Brg-Token: $TOK" -H "Content-Type: application/json" "$@"
}
hdr_of() { printf '%s\n' "$HTTP_OUT" | awk -v k="H $1:" 'index($0, k) == 1 { print substr($0, length(k) + 2); exit }'; }

# the body of a message file (after the blank line)
body_of() { sed '1,/^$/d' "$1"; }

no_srv_tmp() { [ -z "$(cd "$B/run/board" && ls -A | awk '/^\.srv\.tmp\.|^\.tmp\./')" ]; }

test_serve_address_auth_and_headers() {
  local n
  serve_need || return 0
  new_proj
  start_board
  assert_contains "$(sed -n 2p "$BOUT")" "каждые 1 с"
  assert_contains "$(sed -n 2p "$BOUT")" "сервер остановится"
  assert_eq "$PORT" "$(sed -n 1p "$B/run/board/ready")" "ready: the port"
  assert_eq "$PORT" "$(cat "$B/run/board/port")" "port file"
  assert_eq "$TOK" "$(cat "$B/run/board/token")" "token file"
  assert_contains "$(ls -l "$B/run/board/token")" "-rw-------" "token: mode 600"
  # no cookie / a wrong token / the token in the address
  http GET /
  assert_eq 403 "$HTTP_ST" "GET / without a cookie"
  assert_contains "$HTTP_BODY" "brg board"
  http GET "/?t=0123456789abcdef0123456789abcdef"
  assert_eq 403 "$HTTP_ST" "a wrong token"
  http GET "/?t=$TOK"
  assert_eq 303 "$HTTP_ST" "GET /?t= redirects"
  assert_eq "/" "$(hdr_of Location)" "redirect to /"
  assert_eq "$COOKIE; HttpOnly; SameSite=Strict; Path=/" "$(hdr_of Set-Cookie)" "the cookie"
  http GET /data.js -H "Cookie: $COOKIE"
  assert_eq 404 "$HTTP_ST"
  # the page with the token in a meta, only with the cookie; headers
  http GET / -H "Cookie: $COOKIE"
  assert_eq 200 "$HTTP_ST"
  assert_contains "$HTTP_BODY" "<meta name=\"brg-token\" content=\"$TOK\">"
  assert_not_contains "$HTTP_BODY" "<!--BRG_META-->" "the placeholder is replaced"
  assert_eq "DENY" "$(hdr_of X-Frame-Options)"
  assert_eq "frame-ancestors 'none'" "$(hdr_of Content-Security-Policy)"
  assert_eq "no-referrer" "$(hdr_of Referrer-Policy)"
  assert_eq "nosniff" "$(hdr_of X-Content-Type-Options)"
  assert_eq "no-store" "$(hdr_of Cache-Control)"
  http GET / -H "Cookie: brg=$TOK"
  assert_eq 403 "$HTTP_ST" "a cookie of another name"
  http GET / -H "Cookie: brg_$PORT=0123456789abcdef0123456789abcdef"
  assert_eq 403 "$HTTP_ST" "a wrong value of the cookie"
  http GET / -H "Cookie: other=1; $COOKIE"
  assert_eq 200 "$HTTP_ST" "the cookie among others"
  # Host on every request
  http GET / -H "Cookie: $COOKIE" -H "Host: evil.example:$PORT"
  assert_eq 403 "$HTTP_ST" "GET with a foreign Host"
  http GET "/?t=$TOK" -H "Host: evil.example"
  assert_eq 403 "$HTTP_ST" "GET /?t= with a foreign Host"
  http GET / -H "Cookie: $COOKIE" -H "Host: localhost:$PORT"
  assert_eq 200 "$HTTP_ST" "Host localhost"
  # the snapshot and the white list of paths
  http GET /run/board/data.js -H "Cookie: $COOKIE"
  assert_eq 200 "$HTTP_ST"
  assert_contains "$HTTP_BODY" "window.BRG_BOARD = "
  assert_contains "$(hdr_of Content-Type)" "javascript"
  http GET "/run/board/data.js?12345" -H "Cookie: $COOKIE"
  assert_eq 200 "$HTTP_ST" "data.js with a query"
  http GET /run/board/data.js -H "Cookie: $COOKIE" -H "Sec-Fetch-Site: same-origin"
  assert_eq 200 "$HTTP_ST" "data.js loaded by the page itself"
  for n in same-site cross-site none; do
    http GET /run/board/data.js -H "Cookie: $COOKIE" -H "Sec-Fetch-Site: $n"
    assert_eq 403 "$HTTP_ST" "data.js from a script of another origin ($n)"
  done
  http GET /run/board/T001.js -H "Cookie: $COOKIE"
  assert_eq 404 "$HTTP_ST" "no such task cache"
  for n in /run/board/token /run/board/ready /board.html /config /run/board/../../config /run/board/../token /agents /etc/passwd /run/board/T001.js.bak; do
    http GET "$n" -H "Cookie: $COOKIE"
    assert_eq 404 "$HTTP_ST" "path $n"
  done
  # methods
  for n in OPTIONS PUT DELETE; do
    http $n /api/say -H "Cookie: $COOKIE"
    assert_eq 405 "$HTTP_ST" "$n"
    assert_eq "" "$(hdr_of Access-Control-Allow-Origin)" "no CORS"
  done
  # the token is printed once (in the address), the log has no URLs
  assert_eq 1 "$(grep -c "$TOK" "$BOUT")" "the token in the terminal output"
  stop_board
}

test_serve_post_guards() {
  local seq0
  serve_need || return 0
  new_proj
  join_as claude >/dev/null
  start_board
  seq0=$(cat "$B/lobby/seq")
  printf 'x\n' >"$P/t.txt"
  http POST /api/say -H "Content-Type: application/json" -j text=x
  assert_eq 403 "$HTTP_ST" "no cookie and no token"
  http POST /api/say -H "Cookie: $COOKIE" -H "Content-Type: application/json" -j text=x
  assert_eq 403 "$HTTP_ST" "no X-Brg-Token"
  http POST /api/say -H "Cookie: $COOKIE" -H "X-Brg-Token: 0123456789abcdef0123456789abcdef" -H "Content-Type: application/json" -j text=x
  assert_eq 403 "$HTTP_ST" "a wrong X-Brg-Token"
  http POST /api/say -H "X-Brg-Token: $TOK" -H "Content-Type: application/json" -j text=x
  assert_eq 403 "$HTTP_ST" "no cookie"
  http POST /api/say -H "Cookie: $COOKIE" -H "X-Brg-Token: $TOK" -H "Content-Type: application/json" -H "Origin: http://evil.example" -j text=x
  assert_eq 403 "$HTTP_ST" "a foreign Origin"
  http POST /api/say -H "Cookie: $COOKIE" -H "X-Brg-Token: $TOK" -H "Content-Type: application/json" -H "Origin: null" -j text=x
  assert_eq 403 "$HTTP_ST" "Origin: null"
  http POST /api/say -H "Cookie: $COOKIE" -H "X-Brg-Token: $TOK" -H "Content-Type: application/json" -H "Host: evil.example" -j text=x
  assert_eq 403 "$HTTP_ST" "a foreign Host"
  http POST /api/say -H "Cookie: $COOKIE" -H "X-Brg-Token: $TOK" -H "Content-Type: text/plain" -d "$P/t.txt"
  assert_eq 415 "$HTTP_ST" "not a JSON content type"
  http POST /api/say -H "Cookie: $COOKIE" -H "X-Brg-Token: $TOK" -H "Content-Type: application/json" -d "$P/t.txt"
  assert_eq 400 "$HTTP_ST" "not JSON"
  printf '[1, 2]' >"$P/arr.json"
  http POST /api/say -H "Cookie: $COOKIE" -H "X-Brg-Token: $TOK" -H "Content-Type: application/json" -d "$P/arr.json"
  assert_eq 400 "$HTTP_ST" "JSON, but not an object"
  post nope -j text=x
  assert_eq 404 "$HTTP_ST" "an unknown action"
  http GET /api/say -H "Cookie: $COOKIE"
  assert_eq 404 "$HTTP_ST" "GET of an action"
  # no Content-Length / chunked / too long
  printf 'POST /api/say HTTP/1.1\r\nHost: 127.0.0.1:PORT\r\nCookie: %s\r\nX-Brg-Token: %s\r\nContent-Type: application/json\r\n\r\n' "$COOKIE" "$TOK" >"$P/raw1"
  assert_eq 411 "$("$PYX" -I -c "$PYCLIENT" "$PORT" X X --raw "$P/raw1")" "no Content-Length"
  printf 'POST /api/say HTTP/1.1\r\nHost: 127.0.0.1:PORT\r\nCookie: %s\r\nX-Brg-Token: %s\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n' "$COOKIE" "$TOK" >"$P/raw2"
  assert_eq 411 "$("$PYX" -I -c "$PYCLIENT" "$PORT" X X --raw "$P/raw2")" "chunked"
  printf 'POST /api/say HTTP/1.1\r\nHost: 127.0.0.1:PORT\r\nCookie: %s\r\nX-Brg-Token: %s\r\nContent-Type: application/json\r\nContent-Length: 2000000\r\n\r\n' "$COOKIE" "$TOK" >"$P/raw3"
  assert_eq 413 "$("$PYX" -I -c "$PYCLIENT" "$PORT" X X --raw "$P/raw3")" "over 1 MB"
  # a bad argument is refused by the server before brg
  post say -j to=../x -j text=x
  assert_eq 400 "$HTTP_ST" "a bad name"
  post say -j channel=T1 -j text=x
  assert_eq 400 "$HTTP_ST" "a bad channel"
  post say -j re=abc -j text=x
  assert_eq 400 "$HTTP_ST" "a bad re"
  post say -j text="   "
  assert_eq 400 "$HTTP_ST" "an empty text"
  assert_eq "$seq0" "$(cat "$B/lobby/seq")" "a refused request wrote a message"
  assert_file_not_exists "$B/run/stopped"
  stop_board
}

test_serve_say_byte_for_byte_and_reply() {
  local a c ex m f
  serve_need || return 0
  new_proj
  a=$(join_as claude)
  c=$(join_as codex)
  ex=$'Привет, "кавычки" и \'апострофы\'\n$HOME `date` %s %d \\n \\\\ * ? [x] {a,b}\n\nтретья строка: ёЁ — «ёлочки» 100%\n  с отступом'
  printf '%s\n' "$ex" >"$P/text.txt"
  start_board
  # to all (lobby: no task yet)
  post say -j to=all -jf text="$P/text.txt"
  assert_eq 200 "$HTTP_ST"
  assert_contains "$HTTP_BODY" '"ok": true'
  m=$(msg_file "$(cat "$B/lobby/seq")")
  assert_eq human "$(hdr "$m" From)"
  assert_eq all "$(hdr "$m" To)"
  assert_eq "$ex" "$(body_of "$m")" "the text arrived byte for byte"
  # to named agents; channel; the terminal line
  post say -jl to="$(base_of "$a"),$(base_of "$c")" -j text=двоим
  assert_contains "$HTTP_BODY" '"ok": true'
  m=$(msg_file "$(cat "$B/lobby/seq")")
  assert_eq "$(base_of "$a"),$(base_of "$c")" "$(hdr "$m" To)"
  task_new_as "$a" "Задача" "постановка"
  post say -j channel=lobby -j text="в lobby при активной задаче"
  m=$(msg_file "$(cat "$B/lobby/seq")")
  assert_eq "в lobby при активной задаче" "$(body_of "$m")" "channel lobby"
  post say -j channel=T001 -j text="в задачу"
  f=$(tmsg T001 "$(cat "$(tdir T001)/seq")")
  assert_eq "в задачу" "$(body_of "$f")" "channel T001"
  # a question is closed by the human's reply from the page
  printf 'можно?\n' | brg send --as "$a" --to human --ask >/dev/null || fail ask
  f=$(cat "$(tdir T001)/seq")
  assert_contains "$(brg who)" "ждут ответа человека"
  post say -j to="$(base_of "$a")" -ji re="$f" -j text=да
  assert_contains "$HTTP_BODY" '"ok": true'
  assert_not_contains "$(brg who)" "ждут ответа человека" "the question is closed"
  m=$(tmsg T001 "$(cat "$(tdir T001)/seq")")
  assert_eq "$f" "$(hdr "$m" Re)"
  assert_eq human "$(hdr "$m" From)"
  # brg refuses (no such message): ok:false with its words, the code
  post say -ji re=999 -j text=x
  assert_eq 200 "$HTTP_ST"
  assert_contains "$HTTP_BODY" '"ok": false'
  assert_contains "$HTTP_BODY" "нет сообщения"
  # the terminal and no temp files
  assert_contains "$(cat "$BOUT")" "── с доски: say → all (#"
  assert_contains "$(cat "$BOUT")" "── с доски: say → $(base_of "$a")"
  assert_contains "$(cat "$BOUT")" "ОШИБКА (код 1)"
  no_srv_tmp || fail "temp files left in run/board: $(ls -A "$B/run/board")"
  stop_board
}

test_serve_task_lead_pause_stop() {
  local a c d
  serve_need || return 0
  new_proj
  a=$(join_as claude)
  c=$(join_as codex)
  printf 'Постановка: проверить "кириллицу", $x и %%s\nвторая строка\n' >"$P/brief.txt"
  start_board
  post task-new -j title="Задача «с доски» — ёЁ" -jf brief="$P/brief.txt"
  assert_eq 200 "$HTTP_ST"
  assert_contains "$HTTP_BODY" '"ok": true'
  d=$(tdir T001) || fail "no T001"
  assert_eq human "$(hdr "$d/task" Created-By)"
  assert_eq "Задача «с доски» — ёЁ" "$(hdr "$d/task" Title)"
  assert_eq "$(base_of "$a")" "$(hdr "$d/task" Lead)"
  assert_eq "$(cat "$P/brief.txt")" "$(cat "$d/brief.md")" "the brief"
  # a second one: refused until cancel_current
  post task-new -j title="Вторая" -j brief="постановка 2"
  assert_contains "$HTTP_BODY" '"ok": false'
  assert_contains "$HTTP_BODY" "уже есть активная задача"
  assert_eq 1 "$(ls "$B/tasks" | awk '/^T0/' | wc -l | tr -d ' ')" "no second task"
  post task-new -j title="Вторая" -j brief="постановка 2" -jb cancel_current=true
  assert_contains "$HTTP_BODY" '"ok": true'
  assert_eq cancelled "$(hdr "$(tdir T001)/task" Status)" "T001 cancelled by cancel_current"
  assert_eq active "$(hdr "$(tdir T002)/task" Status)"
  # a title is one line, up to 200 bytes
  post task-new -j title="$(printf 'a\tb')" -j brief=x
  assert_eq 400 "$HTTP_ST" "a control character in the title"
  post task-new -j title="$(printf '%0300d' 0)" -j brief=x
  assert_eq 400 "$HTTP_ST" "a long title"
  post task-new -j title=ok -j brief="  "
  assert_eq 400 "$HTTP_ST" "an empty brief"
  # lead
  post lead -j name="$(base_of "$c")"
  assert_contains "$HTTP_BODY" '"ok": true'
  assert_eq "$(base_of "$c")" "$(hdr "$(tdir T002)/task" Lead)"
  post lead -j name=nobody
  assert_contains "$HTTP_BODY" '"ok": false'
  post lead -j name="../x"
  assert_eq 400 "$HTTP_ST"
  # pause / resume / stop
  post pause
  assert_contains "$HTTP_BODY" '"ok": true'
  assert_file_exists "$B/run/paused"
  post resume
  assert_file_not_exists "$B/run/paused"
  post pause -j name="$(base_of "$a")"
  assert_file_exists "$B/run/paused.$(base_of "$a")"
  post resume -j name="$(base_of "$a")"
  assert_file_not_exists "$B/run/paused.$(base_of "$a")"
  post stop -j name="$(base_of "$c")"
  assert_file_exists "$B/run/stopped.$(base_of "$c")"
  post stop
  assert_file_exists "$B/run/stopped"
  post resume
  assert_file_not_exists "$B/run/stopped"
  assert_file_not_exists "$B/run/stopped.$(base_of "$c")"
  post pause -j name="../x"
  assert_eq 400 "$HTTP_ST"
  # cancel the task
  post task-cancel
  assert_contains "$HTTP_BODY" '"ok": true'
  assert_eq cancelled "$(hdr "$(tdir T002)/task" Status)"
  assert_contains "$(cat "$BOUT")" "── с доски: новая задача «Задача «с доски» — ёЁ»"
  assert_contains "$(cat "$BOUT")" "── с доски: lead → $(base_of "$c")"
  assert_contains "$(cat "$BOUT")" "── с доски: pause всех"
  assert_contains "$(cat "$BOUT")" "── с доски: stop $(base_of "$c")"
  assert_contains "$(cat "$BOUT")" "── с доски: отмена задачи"
  no_srv_tmp || fail "temp files left in run/board"
  stop_board
}

test_serve_ends_with_term() {
  serve_need || return 0
  new_proj
  start_board
  assert_eq "$SPID" "$(sed -n 2p "$B/run/board/ready")"
  is_alive "$SPID" || fail "the server is not running"
  post pause
  post resume
  stop_board
  assert_file_not_exists "$B/run/board/ready" "ready is removed by the server"
  assert_file_exists "$B/run/board/port" "the port is kept for the next run"
  assert_file_exists "$B/run/board/token" "the token is kept"
  no_srv_tmp || fail "temp files left: $(ls -A "$B/run/board")"
}

# The parent is killed with -9: the server leaves itself — on Unix at once (the parent
# changed), and by the stale run/board/alive when that check is off.
test_serve_ends_when_parent_is_killed() {
  serve_need || return 0
  new_proj
  start_board
  kill -KILL "$BP"
  wait_for 8 is_dead "$SPID" || fail "the server outlived its parent (kill -9)"
  wait "$BP" 2>/dev/null
  assert_file_not_exists "$B/run/board/ready"
}

test_serve_ends_by_stale_heartbeat() {
  serve_need || return 0
  new_proj
  export BRG_SERVE_NO_PPID=1 BRG_SERVE_ALIVE_MAX=3
  start_board
  # the bash loop keeps run/board/alive fresh: the server lives past its limit
  sleep 5
  is_alive "$SPID" || fail "the server left although its parent is alive"
  kill -KILL "$BP"
  wait "$BP" 2>/dev/null
  sleep 0.5
  is_alive "$SPID" || fail "the server left at once — the heartbeat test is not testing it"
  wait_for 10 is_dead "$SPID" || fail "the server outlived the stale heartbeat (parent killed -9)"
  assert_file_not_exists "$B/run/board/ready"
}

test_serve_port_saved_and_busy() {
  local p1 s lp
  serve_need || return 0
  new_proj
  start_board
  p1=$PORT
  stop_board
  assert_eq "$p1" "$(cat "$B/run/board/port")"
  # the saved port is used again
  BOUT=$(mk_tmpdir)/out
  bash "$BRG" board --interval 1 >"$BOUT" 2>&1 &
  BP=$!
  track_pid $BP
  wait_for 10 first_is_url || fail "no address"
  assert_contains "$(head -n 1 "$BOUT")" "http://127.0.0.1:$p1/"
  SPID=$(sed -n 2p "$B/run/board/ready")
  stop_board
  # the saved port is taken by someone else: a new address, a line about it
  s=$(mk_tmpdir)/bound
  "$PYX" -I -c 'import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5)
open(sys.argv[2], "w").write("ok\n"); time.sleep(120)' "$p1" "$s" &
  lp=$!
  track_pid $lp
  wait_for 5 test -f "$s" || fail "the listener did not start"
  BOUT=$(mk_tmpdir)/out
  bash "$BRG" board --interval 1 >"$BOUT" 2>&1 &
  BP=$!
  track_pid $BP
  wait_for 10 first_is_url || fail "no address when the saved port is busy:
$(cat "$BOUT")"
  assert_contains "$(cat "$BOUT")" "порт $p1 занят — новый адрес"
  case $(head -n 1 "$BOUT") in "http://127.0.0.1:$p1/"*) fail "the busy port was used" ;; esac
  SPID=$(sed -n 2p "$B/run/board/ready")
  stop_board
  # an explicit --port that is busy: no server, the file address and why
  BOUT=$(mk_tmpdir)/out
  bash "$BRG" board --interval 1 --port "$p1" >"$BOUT" 2>&1 &
  BP=$!
  track_pid $BP
  wait_for 10 grep -q "порт занят" "$BOUT" || fail "no word about the busy port:
$(cat "$BOUT")"
  assert_contains "$(cat "$BOUT")" "file://$B/board.html"
  assert_contains "$(cat "$BOUT")" "доска только для просмотра"
  assert_file_not_exists "$B/run/board/ready"
  kill -TERM "$BP"
  wait_pid "$BP" 8 || fail "board did not exit on TERM"
  kill "$lp" 2>/dev/null
}

test_serve_static_once_and_no_python() {
  local o fake
  serve_need || return 0
  new_proj
  # --static: the file address, no server
  BOUT=$(mk_tmpdir)/out
  bash "$BRG" board --static --interval 1 >"$BOUT" 2>&1 &
  BP=$!
  track_pid $BP
  wait_for 10 test -f "$B/run/board/data.js" || fail "no data.js"
  assert_eq "file://$B/board.html" "$(head -n 1 "$BOUT")"
  assert_not_contains "$(cat "$BOUT")" "Python"
  assert_file_not_exists "$B/run/board/ready"
  assert_file_not_exists "$B/run/board/port"
  assert_file_not_exists "$B/run/board/token"
  kill -TERM "$BP"
  wait_pid "$BP" 8 || fail "static board did not exit on TERM"
  # --once: no server either
  o=$(brg board --once) || fail "board --once"
  assert_eq "file://$B/board.html" "$(printf '%s\n' "$o" | head -n 1)"
  assert_file_not_exists "$B/run/board/ready"
  # no Python (BRG_PYTHON that does not exist, and one that is too old)
  fake=$(mk_tmpdir)/oldpython
  printf '#!/bin/sh\nexit 1\n' >"$fake"
  chmod +x "$fake"
  for o in /nonexistent/python3 "$fake"; do
    BOUT=$(mk_tmpdir)/out
    BRG_PYTHON=$o bash "$BRG" board --interval 1 >"$BOUT" 2>&1 &
    BP=$!
    track_pid $BP
    wait_for 10 grep -q "Python 3.8+ не найден" "$BOUT" || fail "no word about Python ($o):
$(cat "$BOUT")"
    assert_eq "file://$B/board.html" "$(head -n 1 "$BOUT")" "the file address without Python"
    assert_file_not_exists "$B/run/board/ready"
    kill -TERM "$BP"
    wait_pid "$BP" 8 || fail "board did not exit on TERM"
  done
  # the server file is missing in .brigada: the same, with the reason
  rm -f "$B/bin/brg-serve.py"
  BOUT=$(mk_tmpdir)/out
  bash "$BRG" board --interval 1 >"$BOUT" 2>&1 &
  BP=$!
  track_pid $BP
  wait_for 10 grep -q "нет .brigada/bin/brg-serve.py" "$BOUT" || fail "no word about the missing file:
$(cat "$BOUT")"
  assert_eq "file://$B/board.html" "$(head -n 1 "$BOUT")"
  kill -TERM "$BP"
  wait_pid "$BP" 8 || fail "board did not exit on TERM"
}

test_serve_dead_server_falls_back_to_file() {
  serve_need || return 0
  new_proj
  start_board
  kill -KILL "$SPID"
  wait_for 8 grep -q "сервер доски остановился" "$BOUT" || fail "no word about the dead server:
$(cat "$BOUT")"
  assert_contains "$(cat "$BOUT")" "file://$B/board.html"
  # the loop goes on
  rm -f "$B/run/board/data.js"
  wait_for 5 test -f "$B/run/board/data.js" || fail "the snapshot is not written after the server died"
  kill -TERM "$BP"
  wait_pid "$BP" 8 || fail "board did not exit on TERM"
}

test_serve_old_temp_files_are_cleaned() {
  serve_need || return 0
  new_proj
  mkdir -p "$B/run/board"
  : >"$B/run/board/.srv.tmp.old.txt"
  touch -t 202001010000 "$B/run/board/.srv.tmp.old.txt"
  : >"$B/run/board/.srv.tmp.fresh.txt"
  start_board
  assert_file_not_exists "$B/run/board/.srv.tmp.old.txt" "an old temp file"
  assert_file_exists "$B/run/board/.srv.tmp.fresh.txt" "a fresh temp file is not touched"
  stop_board
}

test_serve_init_installs_and_doctor_reports() {
  local out
  serve_need || return 0
  new_proj
  assert_eq "$(cat "$ROOT/bin/brg-serve.py")" "$(cat "$B/bin/brg-serve.py")" "init installs brg-serve.py"
  printf '# испорчено\n' >"$B/bin/brg-serve.py"
  out=$(bash "$BRG_SRC" init "$P") || fail reinit
  assert_contains "$out" "brg-serve.py"
  assert_eq "$(cat "$ROOT/bin/brg-serve.py")" "$(cat "$B/bin/brg-serve.py")" "init updates brg-serve.py"
  assert_contains "$out" "Python 3.8+"
  # doctor: found / not found / the file is missing
  out=$(brg doctor)
  assert_contains "$out" "✓ Python "
  assert_contains "$out" "bin/brg-serve.py на месте"
  out=$(BRG_PYTHON=/nonexistent/python3 brg doctor)
  assert_contains "$out" "✓ Python 3.8+ не найден — доска только для просмотра"
  rm -f "$B/bin/brg-serve.py"
  out=$(brg doctor)
  assert_contains "$out" "⚠ Python "
  assert_contains "$out" "нет .brigada/bin/brg-serve.py"
}

# The search of Python: BRG_PYTHON alone when set; a bare name goes through PATH; stubs
# of the Microsoft Store are skipped; the result is sys.executable.
test_serve_python_search() {
  local d r real
  serve_need || return 0
  d=$(mk_tmpdir)
  find_py() { # [env…] — the result of py_find_v in a fresh brg
    env "$@" BRG_SOURCE_ONLY=1 bash -c '. "$1"; detect_platform; py_find_v p; printf "[%s]" "$p"' _ "$BRG_SRC"
  }
  real=$("$PYX" -I -c 'import sys; print(sys.executable)')
  assert_eq "[$real]" "$(find_py BRG_PYTHON="$PYX")" "BRG_PYTHON is sys.executable"
  assert_eq "[]" "$(find_py BRG_PYTHON=/nonexistent/python3)" "a missing BRG_PYTHON: no fallback"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$PYX" >"$d/mypython"
  chmod +x "$d/mypython"
  assert_eq "[$real]" "$(find_py PATH="$d:$PATH" BRG_PYTHON=mypython)" "a bare name goes through PATH"
  assert_eq "[]" "$(find_py BRG_PYTHON=mypython_not_there)" "a bare name that is not in PATH"
  mkdir -p "$d/Microsoft/WindowsApps"
  cp "$d/mypython" "$d/Microsoft/WindowsApps/python3.exe"
  assert_eq "[]" "$(find_py BRG_PYTHON="$d/Microsoft/WindowsApps/python3.exe")" "a Microsoft Store stub is skipped"
  r=$(BRG_PYTHON= BRG_SOURCE_ONLY=1 bash -c '. "$1"; detect_platform; py_find_v a; py_find_v b; [ -n "$a" ] && [ "$a" = "$b" ] && echo same' _ "$BRG_SRC")
  assert_eq same "$r" "the default search finds Python, once per process"
}

# The rules of the server that a Mac cannot run for real: the title on Windows (cmd.exe
# expands % and friends even inside quotes), the call of brg.cmd there, names and channels.
test_serve_validators_and_windows_rules() {
  local out
  serve_need || return 0
  out=$("$PYX" -I -c '
import importlib.util, sys
sp = importlib.util.spec_from_file_location("srv", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
def refused(f, *a):
    try:
        f(*a)
    except m.Refuse:
        return True
    return False
print("title ok", not refused(m.v_title, "Задача «с доски» — ёЁ, 100 причин"))
print("title tab", refused(m.v_title, "a\tb"))
print("title nl", refused(m.v_title, "a\nb"))
print("title 201 bytes", refused(m.v_title, "я" * 101), "200 bytes", not refused(m.v_title, "я" * 100))
print("title special posix", not refused(m.v_title, "a % ^ & | < > ! \" b"))
print("name ok", not refused(m.v_name, "claude-1"), "dot", not refused(m.v_name, "claude-1.k7f3q9"))
print("name bad", refused(m.v_name, "../x"), refused(m.v_name, "-x"), refused(m.v_name, "a b"), refused(m.v_name, "a\n"), refused(m.v_name, ""))
print("chan", not refused(m.v_chan, "lobby"), not refused(m.v_chan, "T001"), refused(m.v_chan, "T1"), refused(m.v_chan, "t001"), refused(m.v_chan, "lobby\n"))
m.CFG["root"] = "C:/p/.brigada"
m.CFG["bash"] = "bash"
print("posix call", m.brg_cmd())
m.WIN = True
print("title win %", refused(m.v_title, "100%"), "&", refused(m.v_title, "a & b"), "!", refused(m.v_title, "hi!"), "plain", not refused(m.v_title, "Задача: ёЁ (1)"))
print("win call", m.brg_cmd())
' "$ROOT/bin/brg-serve.py") || fail "python: $out"
  assert_contains "$out" "title ok True"
  assert_contains "$out" "title tab True"
  assert_contains "$out" "title nl True"
  assert_contains "$out" "title 201 bytes True 200 bytes True"
  assert_contains "$out" "title special posix True"
  assert_contains "$out" "name ok True dot True"
  assert_contains "$out" "name bad True True True True True"
  assert_contains "$out" "chan True True True True True"
  assert_contains "$out" "posix call ['bash', 'C:/p/.brigada/bin/brg']"
  assert_contains "$out" "title win % True & True ! True plain True"
  assert_contains "$out" "win call ['C:/p/.brigada/bin/brg.cmd']"
}

# A second `brg board` in the same project: its own port (the saved one is taken) and its own
# heartbeat — the server of a killed board does not live on the other board's heartbeat.
test_serve_two_boards() {
  local b1 s1 p1 o1 b2 s2 p2 o2
  serve_need || return 0
  new_proj
  export BRG_SERVE_NO_PPID=1 BRG_SERVE_ALIVE_MAX=3
  start_board
  b1=$BP s1=$SPID p1=$PORT o1=$BOUT
  BOUT=$(mk_tmpdir)/out
  bash "$BRG" board --interval 1 >"$BOUT" 2>&1 &
  BP=$!
  track_pid $BP
  wait_for 10 first_is_url || fail "no address of the second board:
$(cat "$BOUT")"
  b2=$BP o2=$BOUT
  s2=$(sed -n 2p "$B/run/board/ready")
  track_pid "$s2"
  p2=$(head -n 1 "$o2")
  p2=${p2#http://127.0.0.1:}
  p2=${p2%%/*}
  [ "$p1" != "$p2" ] || fail "both boards on port $p1"
  assert_contains "$(cat "$o2")" "порт $p1 занят — новый адрес"
  is_alive "$s1" && is_alive "$s2" || fail "a server is not running"
  # the first board dies without a word: its server goes by its own heartbeat although
  # the second board keeps writing its own
  kill -KILL "$b1"
  wait "$b1" 2>/dev/null
  wait_for 12 is_dead "$s1" || fail "the server of the killed board outlived its heartbeat"
  is_alive "$s2" || fail "the other server left"
  kill -TERM "$b2"
  wait_pid "$b2" 8 || fail "the second board did not exit on TERM"
  wait_for 5 is_dead "$s2" || fail "the second server outlived its board"
}

# The environment of the brg calls: no BRG_AS (the human's calls are not an agent's), no chcp,
# MSYS=noglob (Git Bash started from python.exe would expand README* in a title). A stub
# stands in for brg and prints what it got.
test_serve_call_environment() {
  local d out
  serve_need || return 0
  d=$(mk_tmpdir)
  mkdir -p "$d/root/bin"
  printf '%s\n' 'echo "MSYS=$MSYS NOCHCP=$BRG_NO_CHCP AS=[$BRG_AS] PWD=$PWD"' 'echo "ARGS=$*"' >"$d/root/bin/brg"
  out=$(BRG_AS=agent-1 "$PYX" -I -c '
import importlib.util, sys, os
sp = importlib.util.spec_from_file_location("srv", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
m.CFG.update(root=sys.argv[2] + "/root", proj=sys.argv[2], bash="bash")
os.environ["BRG_AS"] = "agent-1"
code, text = m.run_brg(["task", "new", "--title", "README*"])
print(code); print(text)
' "$ROOT/bin/brg-serve.py" "$d") || fail "python: $out"
  assert_contains "$out" "MSYS=noglob"
  assert_contains "$out" "NOCHCP=1"
  assert_contains "$out" "AS=[]"
  assert_contains "$out" "PWD="
  assert_contains "$out" "ARGS=task new --title README*"
}

# Agents launched by brg (DESIGN §5.5, §9.1): /api/spawn and /api/spawn-ctl — the checks
# (400), a call that launches the fake harness (spawn.opencode.bin in config) and answers in
# < 2 s; the human's locale (brg exports LC_ALL=C) reaches the harness through the server
test_serve_spawn_actions_and_locale() {
  local t0 e
  serve_need || return 0
  sp_proj
  script 1 <<'XEOF'
sleep 1.2
XEOF
  export LC_ALL=en_US.UTF-8 LANG=ru_RU.UTF-8
  start_board
  unset LC_ALL
  export LANG=C
  post spawn -j harness=opencode -j model=-x
  assert_eq 400 "$HTTP_ST" "a model starting with -"
  post spawn -j harness=opencode -j model=provider/model -ji count=9
  assert_eq 400 "$HTTP_ST" "count 9"
  post spawn -j harness=opencode -j model=provider/model -j rights=root
  assert_eq 400 "$HTTP_ST" "rights"
  post spawn -j "harness=open code" -j model=provider/model
  assert_eq 400 "$HTTP_ST" "harness"
  post spawn -j harness=opencode -j model=provider/model -j "note=две${NL}строки"
  assert_eq 400 "$HTTP_ST" "a note of two lines"
  post spawn-ctl -j id=../x -j op=wake
  assert_eq 400 "$HTTP_ST" "id"
  post spawn-ctl -j id=S001 -j op=kill
  assert_eq 400 "$HTTP_ST" "op"
  post spawn-ctl -j id=S001 -j op=rights -j rights=root
  assert_eq 400 "$HTTP_ST" "rights of spawn-ctl"
  assert_file_not_exists "$B/run/spawn/S001"
  t0=$(date -u +%s)
  post spawn -j harness=opencode -j model=provider/model -j rights=project -ji count=1 -j "note=с доски"
  # < 2 s on an idle machine (the supervisor is detached); a loaded one gets a margin
  [ $(($(date -u +%s) - t0)) -le 8 ] || fail "spawn from the board took longer than 8 s"
  assert_eq 200 "$HTTP_ST"
  assert_contains "$HTTP_BODY" '"ok": true'
  assert_contains "$HTTP_BODY" "S001 → opencode-1 (provider/model) запущен · права: project"
  assert_contains "$(cat "$BOUT")" "── с доски: spawn opencode × 1 (provider/model, права project)"
  wait_turn S001 1
  e=$(cat "$FK/run.1/env")
  assert_contains "$e" "LC_ALL=en_US.UTF-8" "the human's LC_ALL, not C"
  assert_contains "$e" "LANG=ru_RU.UTF-8"
  assert_contains "$e" "BRG_SPAWN=S001"
  assert_not_contains "$(cat "$FK/run.1/argv")" "--auto"
  assert_contains "$(cat "$FK/run.1/prompt")" "Человек: «с доски»"
  wait_state S001 frozen
  post spawn-ctl -j id=opencode-1 -j op=rights -j rights=full
  assert_eq 200 "$HTTP_ST"
  assert_contains "$HTTP_BODY" '"ok": true'
  assert_contains "$HTTP_BODY" "права S001: full — со следующего хода"
  wait_for 15 rec_is S001 Rights full || fail "the rights were not applied"
  post spawn-ctl -j id=S001 -j op=wake
  assert_contains "$HTTP_BODY" '"ok": true'
  wait_turn S001 2
  assert_contains "$(cat "$FK/run.2/argv")" "--auto"
  wait_state S001 frozen
  wait_state S001 frozen
  post spawn-ctl -j id=S001 -j op=rm
  assert_contains "$HTTP_BODY" '"ok": true'
  wait_state S001 removed
  stop_board
  sp_assert_clean
}
