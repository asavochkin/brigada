# The session key in the name (DESIGN §3): join gives "<base>.<key>"; commands that
# change state need the key, read commands take the bare name too (without touching
# Last-Seen); a wrong key is refused everywhere; NEXT on a refusal is join; the key
# never leaves the profile; join --as issues a new key only once the agent dropped out.

. "$TESTS_DIR/brg_lib.sh"

# Runners of `brg run` live in their own process groups: kill them ourselves.
key_cleanup() {
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

# A (claude-1) hosts and leads T001 with item I001 and run R001; Bn (codex-1).
# a / bn — the bare names.
key_setup() {
  trap key_cleanup EXIT
  new_proj
  A=$(join_as claude opus)
  Bn=$(join_as codex gpt)
  a=${A%%.*}
  bn=${Bn%%.*}
  task_new_as "$A" "Ключи"
  D=$(tdir T001)
  printf 'описание\n' | brg item add --as "$A" --title "Первая" >/dev/null || fail "item add"
  brg run --as "$A" --sync -- true >/dev/null || fail "run --sync"
}

# no_bare_as OUT BASE — every "--as BASE" in OUT is followed by ".<key>"
no_bare_as() {
  local bad
  bad=$(printf '%s\n' "$1" | awk -v n="--as $2" '{
    s = $0
    while ((i = index(s, n)) > 0) {
      s = substr(s, i + length(n))
      if (substr(s, 1, 1) != ".") { print; next }
    }
  }')
  [ -z "$bad" ] || fail "голое имя в подсказке --as: $bad"
}

# files_with TEXT DIR — files under DIR whose content contains TEXT
files_with() {
  local f
  for f in "$2"/* "$2"/.[!.]*; do
    if [ -d "$f" ]; then
      files_with "$1" "$f"
    elif [ -f "$f" ]; then
      case $(cat "$f") in *"$1"*) printf '%s\n' "$f" ;; esac
    fi
  done
}

# refused_bare OUT RC NAME [EXPECTED_RC] — a refusal of the bare name with NEXT: join
refused_bare() {
  assert_eq "${4:-1}" "$2" "exit code: $1"
  assert_contains "$1" "── ОШИБКА: имя $3 занято другой сессией"
  assert_contains "$1" "Твоё имя — только из вывода твоего join в этом чате"
  assert_eq "── NEXT: bash $BRG join --harness <харнесс> --model <модель>" "$(printf '%s\n' "$1" | tail -n 1)"
  assert_not_contains "$1" "join --as"
}

test_key_bare_name_refused_by_every_write_command() {
  local out
  key_setup
  out=$(printf 'x\n' | brg send --as "$a" 2>&1)
  refused_bare "$out" $? "$a"
  out=$(printf 'x\n' | BRG_AS=$a bash "$BRG" send 2>&1)
  refused_bare "$out" $? "$a"
  out=$(brg wait --as "$a" --timeout 0 2>&1)
  refused_bare "$out" $? "$a" 0
  out=$(brg leave --as "$a" 2>&1)
  refused_bare "$out" $? "$a"
  out=$(printf 'x\n' | brg task new --as "$a" --title "Двойник" --cancel-current 2>&1)
  refused_bare "$out" $? "$a"
  out=$(brg task close --as "$a" --force 2>&1)
  refused_bare "$out" $? "$a"
  out=$(brg task cancel --as "$a" 2>&1)
  refused_bare "$out" $? "$a"
  for x in lead host; do
    out=$(brg $x give "$bn" --as "$a" 2>&1)
    refused_bare "$out" $? "$a"
    out=$(brg $x take --as "$bn" 2>&1)
    refused_bare "$out" $? "$bn"
  done
  out=$(brg item add --as "$a" --title "t" --desc "d" 2>&1)
  refused_bare "$out" $? "$a"
  out=$(brg item claim I001 --as "$a" --paths none 2>&1)
  refused_bare "$out" $? "$a"
  brg item claim I001 --as "$A" --paths none >/dev/null || fail "claim with the key"
  out=$(brg item done I001 --as "$a" 2>&1)
  refused_bare "$out" $? "$a"
  out=$(brg item release I001 --as "$a" 2>&1)
  refused_bare "$out" $? "$a"
  out=$(brg item reassign I001 --to "$bn" --as "$a" 2>&1)
  refused_bare "$out" $? "$a"
  out=$(brg item review I001 --as "$bn" --verdict ok --comment "c" 2>&1)
  refused_bare "$out" $? "$bn"
  out=$(brg run --as "$a" -- true 2>&1)
  refused_bare "$out" $? "$a"
  out=$(brg run cancel R001 --as "$a" 2>&1)
  refused_bare "$out" $? "$a"
  # nothing changed
  assert_eq active "$(hdr "$D/task" Status)"
  assert_eq "$a" "$(hdr "$D/task" Lead)"
  assert_eq "$a" "$(hdr "$D/task" Host)"
  assert_eq claimed "$(hdr "$D/items/I001" Status)"
  assert_file_not_exists "$D/items/I002"
  assert_file_not_exists "$D/shared/runs/R002"
  assert_eq "" "$(hdr "$B/agents/$a" Left)"
  assert_eq "" "$(ls "$D/items/I001.reviews" 2>/dev/null)"
}

test_key_read_commands_take_bare_name_without_last_seen() {
  local out old x
  key_setup
  brg item claim I001 --as "$A" --paths none >/dev/null || fail claim
  old=$(($(date -u +%s) - 30))
  printf '%s\n' "$old" >"$B/run/seen/$a"
  for x in "status" "read" "who" "task show" "task list" "item list" "item show I001" "run list" "run show R001"; do
    out=$(brg $x --as "$a" 2>&1)
    assert_eq 0 "$?" "$x: $out"
    assert_not_contains "$out" "ОШИБКА" "$x"
    no_bare_as "$out" "$a"
  done
  out=$(brg item list --mine --as "$a")
  assert_contains "$out" "I001 · claimed · "
  assert_eq "$old" "$(cat "$B/run/seen/$a")" "Last-Seen untouched by read commands without the key"
  assert_contains "$(metrics_of "$a" status)" "nokey=1"
  # with the key — touched, and no nokey mark
  brg read --as "$A" >/dev/null
  [ "$(cat "$B/run/seen/$a")" != "$old" ] || fail "Last-Seen not touched with the key"
  assert_not_contains "$(metrics_of "$a" read | tail -n 1)" "nokey"
}

test_key_status_without_key_does_not_confirm_identity() {
  local out pw
  key_setup
  export BRG_TICK=0.2
  start_wait "$A" "$P/wa" --timeout 20
  pw=$WP
  out=$(brg status --as "$a")
  assert_eq 0 "$?"
  assert_contains "$out" "wait агента $a работает (pid $pw). Если ты не делал join в этом чате — ты не $a: сделай join."
  assert_not_contains "$out" "Мой wait"
  assert_contains "$out" "Имя без ключа — только просмотр"
  assert_contains "$out" "роль $a: host и lead"
  assert_not_contains "$out" "твоя роль"
  assert_not_contains "$out" "Мои подзадачи"
  assert_not_contains "$(brg task show --as "$a")" "Твоя роль"
  assert_eq "── NEXT: если ты не делал join в этом чате — bash $BRG join --harness <харнесс> --model <модель>; иначе продолжай под полным именем из своего join" "$(printf '%s\n' "$out" | tail -n 1)"
  no_bare_as "$out" "$a"
  # with the key — as before
  out=$(brg status --as "$A")
  assert_contains "$out" "Мой wait: работает (pid $pw)"
  assert_eq "── NEXT: bash $BRG wait --as $A" "$(printf '%s\n' "$out" | tail -n 1)"
  kill -TERM $pw
  wait_pid $pw 3 || fail "wait hung"
}

test_key_wrong_key_refused_everywhere() {
  local out x k
  key_setup
  k=$(hdr "$B/agents/$a" Key)
  for x in "$a.zzzzzz" "$a.ABCDEF" "$a." "$a.$k$k" "$bn.$k"; do
    [ "$x" = "$a.$k" ] && continue
    out=$(brg status --as "$x" 2>&1)
    assert_eq 1 "$?" "status --as $x"
    assert_contains "$out" "ключ устарел или с ошибкой"
    assert_contains "$out" "── NEXT: bash $BRG join --harness <харнесс> --model <модель>"
    out=$(printf 'x\n' | brg send --as "$x" 2>&1)
    assert_eq 1 "$?" "send --as $x"
    assert_contains "$out" "ключ устарел или с ошибкой"
    out=$(brg wait --as "$x" --timeout 0 2>&1)
    assert_eq 0 "$?" "wait --as $x"
    assert_contains "$out" "ключ устарел или с ошибкой"
    assert_eq "── NEXT: bash $BRG join --harness <харнесс> --model <модель>" "$(printf '%s\n' "$out" | tail -n 1)"
  done
}

# Successful commands print the full name in every --as hint and NEXT.
test_key_next_lines_carry_full_name() {
  local out
  key_setup
  out=$(printf 'x\n' | brg send --as "$A")
  assert_eq "── NEXT: продолжай; закончив шаг — bash $BRG wait --as $A" "$(printf '%s\n' "$out" | tail -n 1)"
  no_bare_as "$out" "$a"
  out=$(brg wait --as "$Bn" --timeout 1)
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "NEXT: обработай, затем: bash $BRG wait --as $Bn"
  out=$(brg wait --as "$Bn" --timeout 0)
  assert_eq "── нет новых (0 с) · NEXT: bash $BRG wait --as $Bn --timeout 0" "$(printf '%s\n' "$out" | tail -n 1)"
  for out in "$(brg status --as "$A")" "$(brg read --as "$A")" "$(brg task show --as "$A")" \
    "$(brg item claim I001 --as "$Bn" --paths src/a)" "$(brg item show I001 --as "$Bn")" \
    "$(brg item done I001 --as "$Bn" --note готово)" "$(brg run list --as "$A")" \
    "$(brg item review I001 --as "$A" --verdict ok --comment ok)" "$(brg lead give "$bn" --as "$A")" \
    "$(brg item add --as "$Bn" --title "Вторая" --desc d)" "$(brg run --as "$Bn" --sync -- true)"; do
    no_bare_as "$out" "$a"
    no_bare_as "$out" "$bn"
    case $(printf '%s\n' "$out" | tail -n 1) in
      *"--as"*) case $(printf '%s\n' "$out" | tail -n 1) in *"--as $A"* | *"--as $Bn"*) ;; *) fail "NEXT без полного имени: $out" ;; esac ;;
    esac
  done
  # errors after the name was resolved: NEXT with the full name too
  out=$(printf 'x\n' | brg send --as "$A" --to ghost-9 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "── NEXT: исправь команду и повтори: bash $BRG send --as $A"
  no_bare_as "$out" "$a"
}

# The key lives only in the profile: never in messages, From:, who, tail, metrics,
# cursors, task/item/run files.
test_key_never_leaves_the_profile() {
  local ka kb out
  key_setup
  ka=$(hdr "$B/agents/$a" Key)
  kb=$(hdr "$B/agents/$bn" Key)
  send_as "$A" "привет" --to "$Bn"
  brg wait --as "$Bn" --timeout 0 >/dev/null
  brg item claim I001 --as "$Bn" --paths src/a >/dev/null || fail claim
  brg item done I001 --as "$Bn" --note "готово" >/dev/null || fail done
  brg lead give "$Bn" --as "$A" >/dev/null || fail "lead give"
  out=$(brg who; brg tail; brg item list; brg run list; brg task show)
  assert_not_contains "$out" "$ka"
  assert_not_contains "$out" "$kb"
  assert_eq "$B/agents/$a" "$(files_with "$ka" "$B")"
  assert_eq "$B/agents/$bn" "$(files_with "$kb" "$B")"
  assert_eq "$bn" "$(hdr "$D/task" Lead)"
  assert_eq "$bn" "$(hdr "$D/items/I001" Assignee)"
}

# Target names (send --to, lead|host give, item reassign --to, stop/resume) may come
# with the key: it is dropped.
test_key_target_names_accept_full_name() {
  local out f c
  key_setup
  out=$(printf 'лично\n' | brg send --as "$A" --to "$Bn,human")
  assert_contains "$out" "── отправлено #"
  assert_contains "$out" "→ $bn,human"
  f=$(tmsg T001 "$(cat "$D/seq")")
  assert_eq "$bn,human" "$(hdr "$f" To)"
  c=$(join_as opencode)
  brg item claim I001 --as "$c" --paths none >/dev/null || fail claim
  dropped "$c" # asleep: the lead may reassign
  brg item reassign I001 --to "$Bn" --as "$A" >/dev/null || fail reassign
  assert_eq "$bn" "$(hdr "$D/items/I001" Assignee)"
  brg host give "$Bn" --as "$A" >/dev/null || fail "host give"
  assert_eq "$bn" "$(hdr "$D/task" Host)"
  brg stop "$Bn" >/dev/null || fail stop
  assert_file_exists "$B/run/stopped.$bn"
  brg resume "$Bn" >/dev/null || fail resume
  assert_file_not_exists "$B/run/stopped.$bn"
}

# The impostor from the demo: a session that skipped join and took the name of an
# agent of its harness from who.
test_key_impostor_without_join_is_refused() {
  local o out pw old
  new_proj
  o=$(join_as opencode)
  export BRG_TICK=0.2
  start_wait "$o" "$P/wo" --timeout 20
  pw=$WP
  old=$(cat "$B/run/seen/opencode-1")
  sleep 1
  out=$(brg status --as opencode-1)
  assert_contains "$out" "Если ты не делал join в этом чате — ты не opencode-1: сделай join."
  out=$(printf 'постановка\n' | brg task new --as opencode-1 --title "Задача двойника" 2>&1)
  refused_bare "$out" $? opencode-1
  assert_file_not_exists "$B/tasks/active"
  out=$(printf 'перекличка\n' | brg send --as opencode-1 2>&1)
  refused_bare "$out" $? opencode-1
  assert_eq 1 "$(cat "$B/lobby/seq")" "nothing sent"
  # join --as is refused too: the real agent is waiting
  out=$(brg join --as opencode-1 --harness opencode 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "имя opencode-1 занято: его wait сейчас работает"
  kill -TERM $pw
  wait_pid $pw 3 || fail "wait hung"
  # ... and while it works without a wait
  out=$(brg join --as opencode-1 --harness opencode 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "opencode-1 активен (последний вызов "
  # the real agent keeps its name and key
  assert_contains "$(printf 'я тут\n' | brg send --as "$o")" "── отправлено #"
}

# join --as: refused while the agent is active; allowed once it dropped out (silence
# longer than max(wait timeout + 60 s, dropout_after)), when asleep/gone, at once
# after leave. The stop flag does not matter.
test_key_rejoin_needs_dropout() {
  local a out now k
  new_proj
  printf 'asleep_after: 900\ngone_after: 3600\ndropout_after: 100\n' >>"$B/config"
  a=$(join_as claude) # wait 3 s → threshold max(63, 100) = 100 s
  now=$(date -u +%s)
  # silent for 80 s: still active
  printf '%s\n' $((now - 80)) >"$B/run/seen/${a%%.*}"
  printf '%s\n' $((now - 80)) >"$B/run/wait/${a%%.*}.last"
  out=$(brg join --as "${a%%.*}" --harness claude 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "── ОШИБКА: ${a%%.*} активен (последний вызов 8"
  assert_contains "$out" "Если это ты и ключ потерян — он в последней строке NEXT:"
  assert_contains "$out" "иначе подожди 2"
  assert_contains "$out" "подключись под новым именем: bash $BRG join --harness claude --model <модель>"
  # a recent brg call alone (the wait long ago) is activity too
  printf '%s\n' $((now - 300)) >"$B/run/wait/${a%%.*}.last"
  printf '%s\n' $((now - 10)) >"$B/run/seen/${a%%.*}"
  out=$(brg join --as "${a%%.*}" --harness claude 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "активен (последний вызов 1"
  # ... and so is a killed wait's recent heartbeat
  printf '%s\n' $((now - 300)) >"$B/run/seen/${a%%.*}"
  printf '99999 %s\n' $((now - 20)) >"$B/run/wait/${a%%.*}.hb"
  out=$(brg join --as "${a%%.*}" --harness claude 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "активен (последний вызов 2"
  rm -f "$B/run/wait/${a%%.*}.hb"
  # silent for longer than the threshold (and stopped — does not matter): a new key
  : >"$B/run/stopped.${a%%.*}"
  out=$(brg join --as "$a" --harness claude)
  assert_eq 0 "$?"
  k=$(hdr "$B/agents/${a%%.*}" Key)
  assert_contains "$out" "── переподключён: ${a%%.*}.$k "
  [ "${a%%.*}.$k" != "$a" ] || fail "the key did not change"
  assert_eq 1 "$(awk '/^Key: /' "$B/agents/${a%%.*}" | wc -l | tr -d ' ')" "one Key"
  out=$(printf 'x\n' | brg send --as "$a" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "ключ устарел или с ошибкой"
  a=${a%%.*}.$k
  rm -f "$B/run/stopped.${a%%.*}"
  # asleep: allowed
  printf 'asleep_after: 60\n' >>"$B/config"
  dropped "$a" 70
  a=$(rejoin_as "$a" claude)
  [ -n "$a" ] || fail "rejoin when asleep"
  # after leave: at once
  brg leave --as "$a" >/dev/null || fail leave
  a=$(rejoin_as "$a" claude)
  [ -n "$a" ] || fail "rejoin after leave"
  assert_contains "$(printf 'x\n' | brg send --as "$a")" "── отправлено #"
}

# A profile without Key: (joined before 0.2.0) takes the bare name everywhere; a
# name with a dot is refused; join --as gives it a key.
test_key_legacy_profile_without_key() {
  local a out f old
  new_proj
  a=$(join_as claude)
  f=$B/agents/${a%%.*}
  awk '!/^Key: /' "$f" >"$f.new" && mv "$f.new" "$f"
  a=${a%%.*}
  out=$(printf 'старый\n' | brg send --as "$a")
  assert_eq 0 "$?"
  assert_eq "── NEXT: продолжай; закончив шаг — bash $BRG wait --as $a" "$(printf '%s\n' "$out" | tail -n 1)"
  out=$(brg wait --as "$a" --timeout 0)
  assert_eq "── нет новых (0 с) · NEXT: bash $BRG wait --as $a --timeout 0" "$(printf '%s\n' "$out" | tail -n 1)"
  old=$(cat "$B/run/seen/$a")
  sleep 1
  brg status --as "$a" >/dev/null
  [ "$(cat "$B/run/seen/$a")" != "$old" ] || fail "Last-Seen not touched for a keyless profile"
  out=$(printf 'x\n' | brg send --as "$a.abcdef" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "ключ устарел или с ошибкой"
  dropped "$a"
  a=$(rejoin_as "$a" claude)
  case $a in claude-1.??????) ;; *) fail "no key after join --as: [$a]" ;; esac
  out=$(printf 'x\n' | brg send --as "${a%%.*}" 2>&1)
  refused_bare "$out" $? "${a%%.*}"
}
