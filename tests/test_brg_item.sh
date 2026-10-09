# Items (subtasks) and path reservations.

. "$TESTS_DIR/brg_lib.sh"

# A task T001 led by A (claude-1, model opus); Bn (codex-1, gpt), C (opencode-1, gpt);
# everybody's inbox empty.
item_setup() {
  new_proj
  A=$(join_as claude opus)
  Bn=$(join_as codex gpt)
  C=$(join_as opencode gpt)
  task_new_as "$A" "Подзадачи"
  D=$(tdir T001)
  for x in "$A" "$Bn" "$C"; do
    ack_all "$x"
    ack_all "$x" "$D"
  done
}
# item_add_as NAME TITLE [BODY] — add an item, fail on error
item_add_as() {
  printf '%s\n' "${3:-описание}" | brg item add --as "$1" --title "$2" >/dev/null || fail "item add as $1: $2"
}
claim_ok() { # NAME ITEM PATHS
  brg item claim "$2" --as "$1" --paths "$3" >/dev/null || fail "claim $2 by $1 ($3): $(brg item claim "$2" --as "$1" --paths "$3" 2>&1)"
}
# body FILE — the body of a record (after the first blank line)
body() { awk 'b { print } /^$/ && !b { b = 1 }' "$1"; }

test_item_add_layout_and_notice() {
  local out f pa pc
  item_setup
  export BRG_TICK=0.2
  start_wait "$A" "$P/wa" --timeout 20
  pa=$WP
  start_wait "$C" "$P/wc" --timeout 3
  pc=$WP
  out=$(brg item add --as "$Bn" --title "  Починить логин  " <<'BRG_EOF'
Пустой пароль должен отвергаться: $HOME и `x` — дословно.

Готово, когда тест зелёный.
BRG_EOF
)
  assert_eq 0 "$?" "exit code"
  assert_contains "$out" "── добавлена подзадача I001 «Починить логин» (T001, todo)."
  assert_contains "$out" "Lead ${A%%.*} получил уведомление"
  assert_eq "── NEXT: продолжай; закончив шаг — bash $BRG wait --as $Bn" "$(printf '%s\n' "$out" | tail -n 1)"
  f=$D/items/I001
  assert_eq I001 "$(hdr "$f" Id)"
  assert_eq "Починить логин" "$(hdr "$f" Title)"
  assert_eq todo "$(hdr "$f" Status)"
  assert_eq "${Bn%%.*}" "$(hdr "$f" Creator)"
  assert_eq "" "$(hdr "$f" Assignee)"
  [ -n "$(hdr "$f" Created)" ] || fail "no Created"
  assert_eq 'Пустой пароль должен отвергаться: $HOME и `x` — дословно.

Готово, когда тест зелёный.' "$(body "$f")" "description verbatim"
  # system message in the task channel: wakes only the lead
  f=$(tmsg T001 1)
  assert_eq system "$(hdr "$f" Kind)"
  assert_eq "${Bn%%.*}" "$(hdr "$f" From)"
  assert_eq all "$(hdr "$f" To)"
  assert_eq "${A%%.*}" "$(hdr "$f" Wake)"
  wait_pid $pa 3 || fail "the lead was not woken"
  assert_contains "$(cat "$P/wa")" "${Bn%%.*} добавил подзадачу I001 «Починить логин»: Пустой пароль должен отвергаться"
  wait_pid $pc 6 || fail "C's wait hung"
  assert_contains "$(cat "$P/wc")" "── нет новых" "quiet for the others"
  # ... and comes with C's next waking batch
  send_as "$A" "раздаю"
  out=$(brg wait --as "$C" --timeout 1)
  assert_contains "$out" "${Bn%%.*} добавил подзадачу I001"
  assert_contains "$out" "  раздаю"
  # the lead's own add is quiet for everybody; numbering continues
  item_add_as "$A" "Вторая"
  assert_eq no "$(hdr "$(tmsg T001 3)" Wake)"
  assert_file_exists "$D/items/I002"
  assert_contains "$(metrics_of "$Bn" item.add)" "task=T001 id=I001"
  # errors
  out=$(printf 'x\n' | brg item add --as "$A" --title " " 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нужен --title"
  out=$(brg item add --as "$A" --title "t" </dev/null 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "пустое сообщение"
  out=$(printf 'x\n' | brg item add --as "$A" --title "t" --verdict ok 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "неизвестный параметр для item add: --verdict"
  assert_contains "$out" "── NEXT:"
  out=$(brg item frob --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "неизвестная подкоманда: item frob"
}

test_item_needs_active_task() {
  local out
  new_proj
  A=$(join_as claude)
  out=$(printf 'x\n' | brg item add --as "$A" --title "t" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет активной задачи — подзадачи бывают только у неё"
  out=$(brg item list 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет активной задачи"
}

# Path normalization (relative to the project root) and its refusals.
test_path_normalization() {
  local out
  new_proj
  out=$(BRG_SOURCE_ONLY=1 bash -c '
    . "$1"; cfg_load
    for p in "./src/auth/" "src//a/./b" "." "./" "src\\win\\x" " tests/a " "a b/c" "./.brigada/x"; do
      if path_norm_v r "$p"; then printf "%s => %s\n" "$p" "$r"; else printf "%s => ERR\n" "$p"; fi
    done
    for p in "../x" "a/../b" "src/.." "/abs/x" "C:/x" "c:\\x" "~/x" "src/*.js" "a?b" "x[1]"; do
      if path_norm_v r "$p"; then printf "%s => %s\n" "$p" "$r"; else printf "%s => ERR %s\n" "$p" "$PN_ERR"; fi
    done
    paths_parse " ./src/a/ , src/a,tests ,,src/b"; echo "list: $PP_LIST"
    paths_parse "src,.,tests"; echo "list: $PP_LIST"
    paths_parse "none"; echo "list: $PP_LIST"' _ "$BRG")
  assert_contains "$out" "./src/auth/ => src/auth"
  assert_contains "$out" "src//a/./b => src/a/b"
  assert_contains "$out" ". => ."
  assert_contains "$out" "./ => ."
  assert_contains "$out" 'src\win\x => src/win/x'
  assert_contains "$out" " tests/a  => tests/a"
  assert_contains "$out" "a b/c => a b/c"
  assert_contains "$out" "./.brigada/x => .brigada/x"
  assert_contains "$out" "../x => ERR .. — выход за корень проекта запрещён"
  assert_contains "$out" "a/../b => ERR .."
  assert_contains "$out" "src/.. => ERR .."
  assert_contains "$out" "/abs/x => ERR абсолютный путь"
  assert_contains "$out" "C:/x => ERR абсолютный путь"
  assert_contains "$out" 'c:\x => ERR абсолютный путь'
  assert_contains "$out" "~/x => ERR ~"
  assert_contains "$out" "src/*.js => ERR маски"
  assert_contains "$out" "a?b => ERR маски"
  assert_contains "$out" "x[1] => ERR маски"
  assert_contains "$out" "list: src/a,tests,src/b"
  assert_contains "$out" "list: ."
  assert_contains "$out" "list: none"
}

# Two claims of overlapping paths → the second is refused with the
# list of conflicts. Overlap = prefix at a component boundary, case-insensitive.
test_claim_overlap_rules_and_conflict_list() {
  local out
  item_setup
  item_add_as "$A" "Auth"
  item_add_as "$A" "Соседний каталог"
  item_add_as "$A" "Весь src"
  item_add_as "$A" "Своё"
  out=$(brg item claim I1 --as "$Bn" --paths "./src/auth/,tests//auth")
  assert_eq 0 "$?"
  assert_contains "$out" "── I001 «Auth» — твоя. Резервирование: src/auth, tests/auth."
  assert_eq claimed "$(hdr "$D/items/I001" Status)"
  assert_eq "${Bn%%.*}" "$(hdr "$D/items/I001" Assignee)"
  assert_eq "src/auth,tests/auth" "$(hdr "$D/items/I001" Paths)"
  assert_eq "${Bn%%.*}" "$(hdr "$D/reservations/I001" Agent)"
  assert_eq "src/auth
tests/auth" "$(body "$D/reservations/I001")"
  # src/authx does not overlap src/auth (component boundary)
  claim_ok "$C" I2 "src/authx"
  # src overlaps src/auth (Bn) and src/authx (C): refused, both listed
  out=$(brg item claim I3 --as "$A" --paths "docs,SRC" 2>&1)
  assert_eq 1 "$?" "overlap refused"
  assert_contains "$out" "── ОШИБКА: пути пересекаются с чужими резервированиями — I003 не взята"
  assert_contains "$out" "  SRC ↔ src/auth — I001 «Auth», ${Bn%%.*} (working)"
  assert_contains "$out" "  SRC ↔ src/authx — I002 «Соседний каталог», ${C%%.*} (working)"
  assert_not_contains "$out" "docs ↔"
  assert_contains "$out" "── NEXT:"
  assert_eq todo "$(hdr "$D/items/I003" Status)" "not claimed"
  assert_file_not_exists "$D/reservations/I003"
  # the whole project overlaps everything
  out=$(brg item claim I3 --as "$A" --paths . 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" ". ↔ src/auth — I001"
  # a deeper path inside someone's reservation
  out=$(brg item claim I3 --as "$A" --paths "tests/auth/login_test.js" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "tests/auth/login_test.js ↔ tests/auth — I001 «Auth», ${Bn%%.*}"
  # own reservation of another item is not a conflict
  claim_ok "$Bn" I4 "src/auth/util"
  assert_eq claimed "$(hdr "$D/items/I004" Status)"
  # --paths none: no reservation, never a conflict
  brg item release I4 --as "$Bn" >/dev/null || fail release
  out=$(brg item claim I4 --as "$A" --paths none)
  assert_contains "$out" "Резервирование: — (без правок файлов)."
  assert_eq none "$(hdr "$D/items/I004" Paths)"
  assert_file_not_exists "$D/reservations/I004"
  # argument errors
  out=$(brg item claim I3 --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нужен --paths"
  out=$(brg item claim I3 --as "$A" --paths "../etc" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "недопустимый путь в --paths: «../etc» — .. — выход за корень проекта запрещён"
  out=$(brg item claim I3 --as "$A" --paths "/etc/passwd" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "абсолютный путь"
  out=$(brg item claim I3 --as "$A" --paths "none,src" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "none нельзя смешивать"
  out=$(brg item claim I1 --as "$A" --paths docs 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I001 уже в работе у ${Bn%%.*}"
  out=$(brg item claim I9 --as "$A" --paths docs 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет подзадачи I009 в задаче T001"
  # the claim notice is quiet, to all
  f=$(tmsg T001 5)
  assert_eq no "$(hdr "$f" Wake)"
  assert_contains "$(cat "$f")" "${Bn%%.*} взял I001 «Auth» · пути: src/auth, tests/auth"
}

# A second claim by the assignee changes its paths (conflicts re-checked).
test_claim_again_changes_paths() {
  local out
  item_setup
  item_add_as "$A" "Один"
  item_add_as "$A" "Два"
  claim_ok "$Bn" I1 "src/a"
  claim_ok "$C" I2 "src/b"
  out=$(brg item claim I1 --as "$Bn" --paths "src/a,docs")
  assert_contains "$out" "── пути I001 обновлены: src/a, docs (были: src/a)."
  assert_eq "src/a,docs" "$(hdr "$D/items/I001" Paths)"
  out=$(brg item claim I1 --as "$Bn" --paths "src" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I001 оставлена с прежними путями"
  assert_eq "src/a,docs" "$(hdr "$D/items/I001" Paths)"
  assert_eq "src/a
docs" "$(body "$D/reservations/I001")"
}

# Overlap with my own other items (DESIGN §7.1): the claim succeeds with a
# warning — a second session under my name shows up there. No overlap, none,
# and a renew over the item's own paths are silent; "." overlaps all of mine.
test_claim_own_overlap_warns() {
  local out
  item_setup
  for x in 1 2 3 4 5 6 7; do item_add_as "$A" "Пункт $x"; done
  claim_ok "$Bn" I1 "src/auth"
  out=$(brg item claim I2 --as "$Bn" --paths "docs")
  assert_eq 0 "$?"
  assert_not_contains "$out" "⚠" "no overlap"
  out=$(brg item claim I1 --as "$Bn" --paths "src/auth,tests")
  assert_contains "$out" "── пути I001 обновлены"
  assert_not_contains "$out" "⚠" "renew over its own paths"
  out=$(brg item claim I3 --as "$Bn" --paths "SRC/auth/login.js")
  assert_eq 0 "$?" "own overlap is not a refusal"
  assert_contains "$out" "── I003 «Пункт 3» — твоя. Резервирование: SRC/auth/login.js."
  assert_contains "$out" "⚠ эти пути уже твои по I001 (твой путь ↔ твоё резервирование):
  SRC/auth/login.js ↔ src/auth — I001 «Пункт 1»
Если I001 брал не ты — под твоим именем работает другая сессия: сообщи lead'у (bash $BRG send --as $Bn --to ${A%%.*}) и человеку (в своём чате)."
  assert_contains "$(printf '%s\n' "$out" | tail -n 1)" "── NEXT: поручи I003 подагенту, затем bash $BRG wait --as $Bn"
  assert_eq claimed "$(hdr "$D/items/I003" Status)"
  assert_file_exists "$D/reservations/I003"
  assert_contains "$(metrics_of "$Bn" item.claim | tail -n 1)" "own=I001"
  out=$(brg item claim I4 --as "$Bn" --paths none)
  assert_not_contains "$out" "⚠" "--paths none"
  # the whole project overlaps every reservation of mine
  out=$(brg item claim I5 --as "$Bn" --paths .)
  assert_eq 0 "$?"
  assert_contains "$out" "⚠ эти пути уже твои по I001, I002, I003 "
  assert_contains "$out" "  . ↔ tests — I001 «Пункт 1»"
  assert_contains "$out" "  . ↔ docs — I002 «Пункт 2»"
  # someone else's own items are not mine (and C's claim is refused by Bn's ".")
  out=$(brg item claim I6 --as "$C" --paths "lib" 2>&1)
  assert_eq 1 "$?"
  assert_not_contains "$out" "⚠"
  # the lead overlapping itself is told to tell the human
  brg item release I5 --as "$Bn" >/dev/null || fail release
  claim_ok "$A" I6 "lib"
  out=$(brg item claim I7 --as "$A" --paths "lib/x")
  assert_contains "$out" "⚠ эти пути уже твои по I006"
  assert_contains "$out" "под твоим именем работает другая сессия: сообщи человеку (в своём чате)."
}

# A race of two (here: eight) claims of one item → exactly one wins.
test_claim_race_exactly_one_winner() {
  local i n
  item_setup
  item_add_as "$A" "Гонка"
  i=1
  while [ $i -le 8 ]; do
    join_as claude >"$P/name.$((i + 1))"
    i=$((i + 1))
  done
  i=2
  while [ $i -le 9 ]; do
    (
      if bash "$BRG" item claim I1 --as "$(cat "$P/name.$i")" --paths "src/race" >"$P/out.$i" 2>&1; then
        echo "claude-$i" >>"$P/won"
      fi
    ) &
    i=$((i + 1))
  done
  wait
  n=$(wc -l <"$P/won" | tr -d ' ')
  assert_eq 1 "$n" "winners: $(cat "$P/won")"
  assert_eq "$(cat "$P/won")" "$(hdr "$D/items/I001" Assignee)"
  assert_eq "$(cat "$P/won")" "$(hdr "$D/reservations/I001" Agent)"
  assert_eq 7 "$(cat "$P"/out.* | awk '/уже в работе у/' | wc -l | tr -d ' ')" "losers told who has it"
  assert_eq "" "$(ls -A "$B/run/locks")" "locks left"
}

# Two different items with overlapping paths claimed in parallel: never both.
test_claim_race_overlapping_paths() {
  local n
  item_setup
  item_add_as "$A" "Первый"
  item_add_as "$A" "Второй"
  (bash "$BRG" item claim I1 --as "$Bn" --paths "src" >/dev/null 2>&1 && echo 1 >>"$P/won") &
  (bash "$BRG" item claim I2 --as "$C" --paths "src/x" >/dev/null 2>&1 && echo 2 >>"$P/won") &
  wait
  n=$(wc -l <"$P/won" | tr -d ' ')
  assert_eq 1 "$n" "exactly one of two overlapping claims"
}

test_done_and_release_free_reservations() {
  local out pa
  item_setup
  item_add_as "$A" "Сделать"
  item_add_as "$A" "Вернуть"
  claim_ok "$Bn" I1 "src/a"
  claim_ok "$Bn" I2 "src/b"
  out=$(brg item done I1 --as "$C" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "завершить I001 может только исполнитель (${Bn%%.*})"
  out=$(brg item done I1 --as "$Bn" --result shared/nope.md 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "--result: нет файла shared/nope.md (путь от корня проекта)"
  mkdir -p "$D/shared"
  printf 'отчёт\n' >"$D/shared/report.md"
  export BRG_TICK=0.2
  start_wait "$A" "$P/wa" --timeout 20
  pa=$WP
  out=$(brg item done I1 --as "$Bn" --note "логин чинится, тест зелёный" --result "./.brigada/tasks/T001/shared/report.md")
  assert_eq 0 "$?"
  assert_contains "$out" "── I001 «Сделать» — done. Резервирование снято (src/a)."
  assert_eq done "$(hdr "$D/items/I001" Status)"
  assert_eq "логин чинится, тест зелёный" "$(hdr "$D/items/I001" Note)"
  assert_eq ".brigada/tasks/T001/shared/report.md" "$(hdr "$D/items/I001" Result)"
  [ -n "$(hdr "$D/items/I001" Done)" ] || fail "no Done"
  assert_file_not_exists "$D/reservations/I001"
  wait_pid $pa 3 || fail "the lead was not woken by done"
  assert_contains "$(cat "$P/wa")" "${Bn%%.*} завершил I001 «Сделать»: логин чинится, тест зелёный"
  assert_contains "$(cat "$P/wa")" "Результат: .brigada/tasks/T001/shared/report.md"
  out=$(brg item done I1 --as "$Bn" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I001 — done, а не в работе"
  # the freed path can be taken by someone else
  item_add_as "$A" "Третий"
  claim_ok "$C" I3 "src/a/deep"
  # release: back to todo, reservation gone
  out=$(brg item release I2 --as "$C" 2>&1)
  assert_eq 1 "$?" "release by a stranger"
  assert_contains "$out" "вернуть I002 в todo может исполнитель (${Bn%%.*}) или lead (${A%%.*})"
  out=$(brg item release I2 --as "$A" 2>&1)
  assert_eq 1 "$?" "the lead, while the assignee is active"
  assert_contains "$out" "исполнитель ${Bn%%.*} активен (working)"
  out=$(brg item release I2 --as "$Bn")
  assert_contains "$out" "── I002 «Вернуть» снова todo, резервирование снято."
  assert_eq todo "$(hdr "$D/items/I002" Status)"
  assert_eq "" "$(hdr "$D/items/I002" Assignee)"
  assert_eq "" "$(hdr "$D/items/I002" Paths)"
  assert_file_not_exists "$D/reservations/I002"
  claim_ok "$C" I2 "src/b"
  # the lead may release the item of an asleep assignee
  printf '%s\n' $(($(date -u +%s) - 90)) >"$B/run/seen/${C%%.*}"
  out=$(brg item release I2 --as "$A")
  assert_contains "$out" "снова todo"
  assert_contains "$(cat "$(tmsg T001 $(cat "$D/seq"))")" "${A%%.*} вернул I002 «Вернуть» в todo (lead; ${C%%.*} — asleep)"
}

# reassign: only the lead, only if the assignee is asleep/gone; the reservation
# moves to the new assignee (conflicts re-checked), who is woken.
test_reassign_rules() {
  local out pc
  item_setup
  item_add_as "$A" "Переназначаемая"
  item_add_as "$A" "Шире"
  claim_ok "$Bn" I1 "src/a"
  out=$(brg item reassign I1 --to "${C%%.*}" --as "$Bn" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "переназначать подзадачи может только lead (${A%%.*})"
  out=$(brg item reassign I1 --to "${C%%.*}" --as "$A" 2>&1)
  assert_eq 1 "$?" "assignee active"
  assert_contains "$out" "исполнитель ${Bn%%.*} активен (working) — переназначить можно, только если он asleep или gone"
  out=$(brg item reassign I2 --to "${C%%.*}" --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I002 — todo, а не в работе"
  out=$(brg item reassign I1 --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "кому: item reassign"
  # Bn (asleep) also holds a wider reservation of another item: moving I001 to C
  # would overlap it → refused
  claim_ok "$Bn" I2 "src"
  printf '%s\n' $(($(date -u +%s) - 90)) >"$B/run/seen/${Bn%%.*}"
  out=$(brg item reassign I1 --to "${C%%.*}" --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "пути I001 пересекаются с чужими резервированиями — не переназначена"
  assert_contains "$out" "src/a ↔ src — I002 «Шире», ${Bn%%.*} (asleep)"
  # once the wider one is released by the lead, the move passes
  brg item release I2 --as "$A" >/dev/null || fail "lead release"
  export BRG_TICK=0.2
  start_wait "$C" "$P/wc" --timeout 20
  pc=$WP
  out=$(brg item reassign I1 --to "${C%%.*}" --as "$A")
  assert_eq 0 "$?"
  assert_contains "$out" "── I001 «Переназначаемая»: ${Bn%%.*} → ${C%%.*}; резервирование (src/a) перешло к ${C%%.*}."
  assert_eq "${C%%.*}" "$(hdr "$D/items/I001" Assignee)"
  assert_eq "${C%%.*}" "$(hdr "$D/reservations/I001" Agent)"
  wait_pid $pc 3 || fail "the new assignee was not woken"
  assert_contains "$(cat "$P/wc")" "lead ${A%%.*} переназначил I001 «Переназначаемая»: ${Bn%%.*} (asleep) → ${C%%.*}."
  # the old assignee's reservation no longer blocks C; it blocks others for C
  out=$(brg item claim I2 --as "$Bn" --paths "src/a/x" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "src/a/x ↔ src/a — I001 «Переназначаемая», ${C%%.*}"
  # to a gone agent: refused
  brg leave --as "$Bn" >/dev/null
  printf '%s\n' $(($(date -u +%s) - 90)) >"$B/run/seen/${C%%.*}"
  out=$(brg item reassign I1 --to "${Bn%%.*}" --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "${Bn%%.*} — gone"
}

# review: the assignee may not review its own work; same model as
# the assignee while another model is online → a warning; verdict wakes the assignee.
test_review_rules() {
  local out pb n
  item_setup
  item_add_as "$A" "Ревьюируемая"
  claim_ok "$Bn" I1 "src/a"
  out=$(printf 'сам себя\n' | brg item review I1 --as "$Bn" --verdict ok 2>&1)
  assert_eq 1 "$?" "review by the assignee"
  assert_contains "$out" "I001 делал ты — своё ревью не засчитывается"
  assert_eq "" "$(ls "$D/items/I001.reviews" 2>/dev/null)" "nothing recorded"
  out=$(printf 'x\n' | brg item review I1 --as "$C" --verdict maybe 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "--verdict — ok или changes"
  out=$(printf 'x\n' | brg item review I1 --as "$C" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нужен --verdict ok|changes"
  # C has the same model (gpt) as Bn, and A (opus) is online: warning, recorded anyway
  export BRG_TICK=0.2
  start_wait "$Bn" "$P/wb" --timeout 20
  pb=$WP
  out=$(printf 'Нет теста на пустой пароль.\nДобавь.\n' | brg item review I1 --as "$C" --verdict changes)
  assert_eq 0 "$?"
  assert_contains "$out" "── ревью #1 по I001 записано (changes); сообщение отправлено: ${Bn%%.*}, ${A%%.*}."
  assert_contains "$out" "Внимание: ты на той же модели (gpt), что и исполнитель ${Bn%%.*}, а онлайн есть агент другой модели: ${A%%.*} (opus)."
  f=$D/items/I001.reviews/1
  assert_eq "${C%%.*}" "$(hdr "$f" Reviewer)"
  assert_eq changes "$(hdr "$f" Verdict)"
  assert_eq gpt "$(hdr "$f" Model)"
  assert_eq "${Bn%%.*}" "$(hdr "$f" Assignee)"
  assert_eq "Нет теста на пустой пароль.
Добавь." "$(body "$f")"
  wait_pid $pb 3 || fail "the assignee was not woken by the review"
  assert_contains "$(cat "$P/wb")" "ревью I001 «Ревьюируемая» от ${C%%.*} (gpt): changes — нужны правки"
  assert_contains "$(cat "$P/wb")" "  Нет теста на пустой пароль."
  n=$(cat "$D/seq")
  assert_eq "${Bn%%.*},${A%%.*}" "$(hdr "$(tmsg T001 "$n")" To)"
  assert_eq "" "$(hdr "$(tmsg T001 "$n")" Wake)" "wakes both"
  # a different model: no warning; the lead reviewing → only the assignee is addressed
  out=$(printf 'теперь ок\n' | brg item review I1 --as "$A" --verdict ok)
  assert_contains "$out" "── ревью #2 по I001 записано (ok); сообщение отправлено: ${Bn%%.*}."
  assert_not_contains "$out" "Внимание"
  # same model, but nobody of another model online: no warning
  brg leave --as "$A" >/dev/null
  out=$(printf 'ещё раз\n' | brg item review I1 --as "$C" --verdict ok)
  assert_not_contains "$out" "Внимание"
  out=$(brg item list)
  assert_contains "$out" "I001 · claimed · ${Bn%%.*} · «Ревьюируемая» · пути: src/a"
  assert_contains "$out" "ревью: ok от ${C%%.*} (всего 3)"
  out=$(brg item show I1)
  assert_contains "$out" "── ревью #1: changes от ${C%%.*} (gpt) · "
  assert_contains "$out" "  Нет теста на пустой пароль."
  assert_contains "$out" "── ревью #2: ok от ${A%%.*} (opus)"
  # a todo item has nothing to review
  item_add_as "$C" "Пустая"
  out=$(printf 'x\n' | brg item review I2 --as "$C" --verdict ok 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I002 — todo: ревьюить нечего"
}

# task close without --force is refused while items are claimed; --force and cancel
# turn them into cancelled and release the reservations (DESIGN §6).
test_close_and_cancel_with_claimed_items() {
  local out
  item_setup
  item_add_as "$A" "В работе"
  item_add_as "$A" "Готовая"
  claim_ok "$Bn" I1 "src/a"
  claim_ok "$C" I2 "src/b"
  brg item done I2 --as "$C" >/dev/null || fail done
  brg wait --as "$A" --timeout 0 >/dev/null # the lead takes the "done" notice first
  printf 'итог\n' >"$D/summary.md"
  out=$(brg task close --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "подзадачи ещё в работе (claimed): I001"
  assert_eq active "$(hdr "$D/task" Status)"
  out=$(brg task close --as "$A" --force)
  assert_contains "$out" "закрыта с --force; подзадачи I001 отменены"
  assert_eq cancelled "$(hdr "$D/items/I001" Status)"
  assert_eq "${A%%.*}" "$(hdr "$D/items/I001" Cancelled-By)" "the headers of item cancel"
  [ -n "$(hdr "$D/items/I001" Cancelled)" ] || fail "no Cancelled"
  assert_eq done "$(hdr "$D/items/I002" Status)"
  assert_eq "" "$(ls -A "$D/reservations")" "reservations released"
  out=$(brg wait --as "$Bn" --timeout 1)
  assert_contains "$out" "Закрыта с --force: подзадачи в работе отменены — I001 (${Bn%%.*}); прекрати правки по ним."
  # cancel (and --cancel-current) do the same
  task_new_as "$A" "Вторая"
  D=$(tdir T002)
  item_add_as "$A" "Третья"
  claim_ok "$C" I1 "src/c"
  out=$(printf 'x\n' | brg task new --as "$Bn" --title "Третья задача" --cancel-current)
  assert_contains "$out" "задача T002 отменена"
  assert_eq cancelled "$(hdr "$D/items/I001" Status)"
  assert_eq "" "$(ls -A "$D/reservations")"
  assert_contains "$(cat "$B/lobby/messages/"*.msg | awk '/отменена/')" "Подзадачи в работе отменены, резервирования сняты: I001 (${C%%.*})."
  # items of a finished task are out of reach
  out=$(brg item claim I1 --as "$C" --paths x 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет подзадачи I001 в задаче T003"
}

test_item_list_show_status_who() {
  local out
  item_setup
  item_add_as "$A" "Первая" "строка описания 1
строка 2"
  item_add_as "$Bn" "Вторая"
  item_add_as "$A" "Третья"
  claim_ok "$Bn" I1 "src/a,tests/a"
  claim_ok "$Bn" I3 none
  brg item done I3 --as "$Bn" --note "готово" >/dev/null || fail done
  out=$(brg item list --as "$C")
  assert_contains "$out" "I001 · claimed · ${Bn%%.*} · «Первая» · пути: src/a, tests/a · "
  assert_contains "$out" "I002 · todo · «Вторая» · создал ${Bn%%.*}"
  assert_contains "$out" "I003 · done · на проверке (ждёт проверяющего) · ${Bn%%.*} · «Третья» · итог: готово"
  assert_contains "$out" "── T001: todo 1 · в работе 1 · правки 0 · на проверке 1 · готово 0 · отменено 0"
  assert_contains "$out" "── NEXT:"
  out=$(brg item list --status todo,done)
  assert_not_contains "$out" "I001"
  assert_contains "$out" "I002"
  assert_contains "$out" "I003"
  out=$(brg item list --as "$Bn" --mine)
  assert_contains "$out" "I001"
  assert_contains "$out" "I003"
  assert_not_contains "$out" "I002 ·"
  out=$(brg item list --mine 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нужно имя агента"
  out=$(brg item list --status bogus 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "--status — todo, claimed, done, cancelled"
  out=$(brg item show I1 --as "$C")
  assert_contains "$out" "── I001 «Первая» · claimed · задача T001"
  assert_contains "$out" "Создал: ${A%%.*} · "
  assert_contains "$out" "Исполнитель: ${Bn%%.*} (working) · взята "
  assert_contains "$out" "Пути: src/a, tests/a"
  assert_contains "$out" "── описание ──
строка описания 1
строка 2"
  out=$(brg item show I7 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет подзадачи I007"
  out=$(brg status --as "$Bn")
  assert_contains "$out" "Подзадачи T001: todo 1 · в работе 1 · правки 0 · на проверке 1 · готово 0"
  assert_contains "$out" "Мои подзадачи и резервирования:
  I001 «Первая» · пути: src/a, tests/a · в работе "
  out=$(brg status --as "$C")
  assert_contains "$out" "Мои подзадачи: нет — свободные: bash $BRG item list --status todo"
  out=$(brg who)
  assert_contains "$out" "${Bn%%.*} · codex · gpt · working · активен "
  assert_contains "$out" " с назад · подзадач в работе: 1" # seconds: 0 or 1, by timing
  assert_not_contains "$(printf '%s\n' "$out" | awk -v c="${C%%.*}" 'index($0, c " ") == 1')" "подзадач"
}

# --desc / --comment instead of stdin (one-liners; PowerShell has no
# heredoc). With them stdin is not read at all — not even a pipe that never closes.
test_item_desc_and_comment_options() {
  local out t0 t1 f
  item_setup
  t0=$(date -u +%s)
  out=$(brg item add --as "$A" --title "Кратко" --desc 'Описание строкой: $HOME и `x` — дословно' < <(sleep 30))
  assert_eq 0 "$?"
  t1=$(date -u +%s)
  [ $((t1 - t0)) -le 2 ] || fail "--desc still read stdin ($((t1 - t0)) s)"
  assert_contains "$out" "── добавлена подзадача I001 «Кратко»"
  assert_eq 'Описание строкой: $HOME и `x` — дословно' "$(body "$D/items/I001")"
  assert_contains "$(cat "$(tmsg T001 1)")" "добавил подзадачу I001 «Кратко»: Описание строкой"
  out=$(brg item add --as "$A" --title "Две строки" --desc "первая
вторая")
  assert_eq "первая
вторая" "$(body "$D/items/I002")"
  printf 'из файла\n' >"$P/d.txt"
  out=$(brg item add --as "$A" --title "x" --desc "y" --file "$P/d.txt" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "--desc и --file вместе нельзя"
  out=$(brg item add --as "$A" --title "x" --desc "   " 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "пустое"
  out=$(brg item add --as "$A" --title "x" --comment "y" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "неизвестный параметр для item add: --comment"
  # review --comment
  claim_ok "$Bn" I001 "src/a"
  out=$(brg item review I001 --as "$C" --verdict changes --comment "нет теста на пустой пароль" < <(sleep 30))
  assert_eq 0 "$?"
  assert_contains "$out" "── ревью #1 по I001 записано (changes)"
  f=$D/items/I001.reviews/1
  assert_eq "нет теста на пустой пароль" "$(body "$f")"
  out=$(brg item review I001 --as "$C" --verdict ok --comment "x" --file "$P/d.txt" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "--comment и --file вместе нельзя"
  out=$(brg item review I001 --as "$C" --verdict ok --desc "x" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "неизвестный параметр для item review: --desc"
  assert_contains "$(brg item --help)" '--desc "описание"'
  assert_contains "$(brg item --help)" '--comment "…"'
}

# Rehearsal fixes: item add --paths — the proposed paths (Paths-Hint, normalized and
# checked like claim's); claim without --paths takes them (conflicts checked as
# usual), an explicit --paths always wins; without a hint --paths stays required.
test_item_add_paths_hint() {
  local out f
  item_setup
  out=$(brg item add --as "$A" --title "С путями" --desc "d" --paths "./src/a/, tests//a")
  assert_eq 0 "$?"
  assert_contains "$out" "Предлагаемые пути: src/a, tests/a. Взять в работу: bash $BRG item claim I001 --as <имя> — возьмёт их"
  f=$D/items/I001
  assert_eq "src/a,tests/a" "$(hdr "$f" Paths-Hint)"
  assert_eq "" "$(hdr "$f" Paths)"
  assert_contains "$(cat "$(tmsg T001 1)")" "Предлагаемые пути: src/a, tests/a"
  assert_contains "$(cat "$(tmsg T001 1)")" "взять: bash $BRG item claim I001 --as <имя> (возьмёт предлагаемые пути"
  assert_contains "$(metrics_of "$A" item.add)" "hint=src/a,tests/a"
  out=$(brg item add --as "$A" --title "x" --desc "d" --paths "../etc" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "недопустимый путь в --paths: «../etc»"
  assert_file_not_exists "$D/items/I002" "nothing added"
  assert_contains "$(brg item list)" "I001 · todo · «С путями» · создал ${A%%.*} · предлагаемые пути: src/a, tests/a"
  assert_contains "$(brg item show I1)" "Предлагаемые пути: src/a, tests/a (claim без --paths возьмёт их)"
  # claim without --paths: the hint
  out=$(brg item claim I1 --as "$Bn")
  assert_eq 0 "$?"
  assert_contains "$out" "── I001 «С путями» — твоя. Взяты предлагаемые пути: src/a, tests/a (нужны другие — повтори claim с --paths)."
  assert_eq "src/a,tests/a" "$(hdr "$f" Paths)"
  assert_eq "src/a,tests/a" "$(hdr "$f" Paths-Hint)" "the hint is kept"
  assert_eq "${Bn%%.*}" "$(hdr "$D/reservations/I001" Agent)"
  assert_contains "$(metrics_of "$Bn" item.claim)" "paths=src/a,tests/a renew=0 hint=1"
  assert_not_contains "$(brg item show I1)" "Предлагаемые пути" "same as the reserved ones"
  # a second claim of one's own item changes paths: --paths required
  out=$(brg item claim I1 --as "$Bn" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "повторный claim меняет пути I001, укажи полный список (сейчас: src/a,tests/a)"
  # a hint overlapping someone's reservation: refused as usual; explicit --paths wins
  item_add_as "$A" "Шире" >/dev/null
  brg item add --as "$A" --title "Весь src" --desc "d" --paths src >/dev/null || fail "add I003"
  out=$(brg item claim I3 --as "$C" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I003 не взята (предлагаемые пути заняты — укажи свои: --paths …)"
  assert_contains "$out" "src ↔ src/a — I001 «С путями», ${Bn%%.*}"
  out=$(brg item claim I3 --as "$C" --paths docs)
  assert_contains "$out" "Резервирование: docs."
  assert_eq docs "$(hdr "$D/items/I003" Paths)"
  assert_contains "$(brg item show I3)" "Предлагаемые пути: src"
  assert_not_contains "$(brg item show I3)" "claim без --paths"
  # no hint: --paths is required, as before
  out=$(brg item claim I2 --as "$C" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нужен --paths"
  assert_contains "$out" "у I002 нет предлагаемых путей"
  assert_eq todo "$(hdr "$D/items/I002" Status)"
  # a "none" hint: an item without file changes
  brg item add --as "$A" --title "Исследование" --desc "d" --paths NONE >/dev/null || fail "add I004"
  assert_eq none "$(hdr "$D/items/I004" Paths-Hint)"
  out=$(brg item claim I4 --as "$C")
  assert_contains "$out" "Взяты предлагаемые пути: — (без правок файлов)"
  # release: the hint stays for the next claimer
  brg item release I1 --as "$Bn" >/dev/null || fail release
  assert_contains "$(brg item list --status todo)" "I001 · todo · «С путями» · создал ${A%%.*} · предлагаемые пути: src/a, tests/a"
  out=$(brg item claim I1 --as "$A")
  assert_contains "$out" "Взяты предлагаемые пути: src/a, tests/a"
  assert_contains "$(brg item --help)" '[--paths "предлагаемые пути"]'
}

# Rehearsal fixes: one-line limits are lenient — a longer --note/--title/--desc/
# --comment is cut at a UTF-8 boundary with the mark " …(обрезано)" and a warning;
# stdin/--file bodies keep the hard limit (msg_max_bytes), like send.
test_lenient_one_line_limits() {
  local out f long note
  item_setup
  # unit: the cut never splits a character
  out=$(BRG_SOURCE_ONLY=1 bash -c '
    . "$1"
    for c in "жжж 3" "жжж 4" "aж 2" "€€ 4" "€€ 5" "€€ 6" "€€ 7" "😀x 3" "😀x 4" "abc 0"; do
      utf8_cut_v r "${c% *}" "${c##* }"; printf "%s => [%s]\n" "$c" "$r"
    done' _ "$BRG")
  assert_contains "$out" "жжж 3 => [ж]"
  assert_contains "$out" "жжж 4 => [жж]"
  assert_contains "$out" "aж 2 => [a]"
  assert_contains "$out" "€€ 4 => [€]"
  assert_contains "$out" "€€ 5 => [€]"
  assert_contains "$out" "€€ 6 => [€€]"
  assert_contains "$out" "€€ 7 => [€€]"
  assert_contains "$out" "😀x 3 => []"
  assert_contains "$out" "😀x 4 => [😀]"
  assert_contains "$out" "abc 0 => []"
  # --note > 500 bytes: done passes, the note is cut (478 bytes + the 22-byte mark)
  item_add_as "$A" "Длинный итог"
  claim_ok "$Bn" I1 "src/a"
  long="a$(awk 'BEGIN { for (i = 0; i < 300; i++) printf "ж" }')"
  out=$(brg item done I1 --as "$Bn" --note "$long")
  assert_eq 0 "$?" "done with a long note"
  assert_contains "$out" "── I001 «Длинный итог» — done."
  assert_contains "$out" "Внимание: --note длиннее 500 байт (601) — сохранено обрезанным, с пометкой «…(обрезано)». --note — одна-две фразы; подробности — файлом (например, в shared/ задачи) и --result <путь>."
  note="a$(awk 'BEGIN { for (i = 0; i < 238; i++) printf "ж" }') …(обрезано)"
  assert_eq "$note" "$(hdr "$D/items/I001" Note)"
  assert_eq done "$(hdr "$D/items/I001" Status)"
  # --title > 200 bytes
  out=$(brg item add --as "$A" --title "$(awk 'BEGIN { for (i = 0; i < 250; i++) printf "t" }')" --desc d)
  assert_eq 0 "$?"
  assert_contains "$out" "Внимание: --title длиннее 200 байт (250)"
  assert_eq "$(awk 'BEGIN { for (i = 0; i < 178; i++) printf "t" }') …(обрезано)" "$(hdr "$D/items/I002" Title)"
  # --desc over msg_max_bytes (8192): cut; the same text from stdin: refused
  long=$(awk 'BEGIN { for (i = 0; i < 9000; i++) printf "d" }')
  out=$(brg item add --as "$A" --title "Длинное описание" --desc "$long")
  assert_eq 0 "$?"
  assert_contains "$out" "Внимание: --desc длиннее 8191 байт (9000)"
  assert_contains "$out" "Полный текст положи файлом в shared/ задачи"
  f=$D/items/I003
  assert_eq 8191 "$(body "$f" | LC_ALL=C awk '{ n += length($0) } END { print n }')" "the cut body fits the limit"
  assert_contains "$(body "$f")" "ddd …(обрезано)"
  out=$(printf '%s\n' "$long" | brg item add --as "$A" --title "Из stdin" 2>&1)
  assert_eq 1 "$?" "stdin keeps the hard limit"
  assert_contains "$out" "больше лимита 8192 (msg_max_bytes)"
  # --comment over the limit: the review is recorded, cut
  out=$(brg item review I1 --as "$C" --verdict ok --comment "$long")
  assert_eq 0 "$?"
  assert_contains "$out" "Внимание: --comment длиннее 8191 байт (9000)"
  assert_contains "$(body "$D/items/I001.reviews/1")" "…(обрезано)"
  # send keeps refusing
  out=$(printf '%s\n' "$long" | brg send --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "больше лимита"
}

# ── review of items (DESIGN §7.1.1) ──
# last_msg — the newest message of the task channel
last_msg() { tmsg T001 "$(cat "$D/seq")"; }

# item add --no-review: "Review: no"; done → at once "готово без проверки".
test_item_no_review() {
  local out f
  item_setup
  out=$(brg item add --as "$A" --title "Без проверки" --desc d --paths src/a --no-review)
  assert_eq 0 "$?"
  assert_contains "$out" "Проверка не нужна (--no-review): после item done подзадача сразу «готово · без проверки»."
  item_add_as "$A" "С проверкой"
  f=$D/items/I001
  assert_eq no "$(hdr "$f" Review)"
  assert_eq "" "$(hdr "$D/items/I002" Review)" "reviewed by default"
  assert_contains "$(cat "$(tmsg T001 1)")" "Стадия: todo; проверка не нужна (решение бригады, --no-review)"
  assert_contains "$(metrics_of "$A" item.add | head -n 1)" "review=no"
  assert_contains "$(brg item list)" "I001 · todo · «Без проверки» · создал ${A%%.*} · предлагаемые пути: src/a · без проверки"
  out=$(brg item claim I1 --as "$Bn" --no-review 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "item claim не принимает --no-review"
  brg item claim I1 --as "$Bn" >/dev/null || fail claim
  claim_ok "$Bn" I2 src/b
  out=$(brg item done I1 --as "$Bn" --note "сделано")
  assert_contains "$out" "Стадия: готово · без проверки (item add --no-review)."
  assert_eq 0 "$(hdr "$f" Done-Reviews)"
  assert_not_contains "$(cat "$(last_msg)")" "Взяться за проверку"
  out=$(brg item done I2 --as "$Bn")
  assert_contains "$out" "Стадия: на проверке (ждёт проверяющего)"
  assert_contains "$(cat "$(last_msg)")" "Стадия: на проверке (ждёт проверяющего). Взяться за проверку: bash $BRG item review I002 --as <имя> --start"
  out=$(brg item list)
  assert_contains "$out" "I001 · done · готово · без проверки · ${Bn%%.*} · «Без проверки» · итог: сделано"
  assert_contains "$out" "I002 · done · на проверке (ждёт проверяющего) · ${Bn%%.*}"
  assert_contains "$out" "── T001: todo 0 · в работе 0 · правки 0 · на проверке 1 · готово 1 · отменено 0"
  out=$(brg item show I1)
  assert_contains "$out" "Стадия: готово · без проверки (решение при планировании: item add --no-review)"
  assert_contains "$out" "Проверка не нужна (item add --no-review)"
  out=$(brg item show I2)
  assert_contains "$out" "Стадия: на проверке
Проверяющего пока нет — взяться: bash $BRG item review I002 --as <имя> --start"
  # a review of a --no-review item still counts
  brg item review I1 --as "$C" --verdict changes --comment "всё же поправь" >/dev/null || fail review
  assert_contains "$(brg item list)" "I001 · done · правки по ревью от ${C%%.*}"
  assert_contains "$(brg item --help)" "[--no-review]"
}

# item review --start: the name into Reviewing (no duplicates), a quiet notice; no
# text, stdin not read; refused for the assignee, a todo item, with a verdict or a
# text, and while stopped; the verdict takes the reviewer out of Reviewing.
test_review_start() {
  local out t0 t1 f n
  item_setup
  item_add_as "$A" "Проверяемая"
  item_add_as "$A" "Свободная"
  claim_ok "$Bn" I1 "src/a"
  f=$D/items/I001
  t0=$(date -u +%s)
  out=$(brg item review I1 --as "$C" --start < <(sleep 30))
  assert_eq 0 "$?"
  t1=$(date -u +%s)
  [ $((t1 - t0)) -le 2 ] || fail "--start read stdin ($((t1 - t0)) s)"
  assert_contains "$out" "── ты проверяешь I001 «Проверяемая» (исполнитель ${Bn%%.*}, claimed)"
  assert_contains "$out" "Проверку делает твой подагент — поручи ему: смотреть сам diff, а не отчёт исполнителя — git diff -- <пути>"
  assert_contains "$out" "пути I001: src/a"
  assert_contains "$out" "Внимание: ты на той же модели (gpt), что и исполнитель ${Bn%%.*}" "warned before the work, not after"
  assert_contains "$out" "Вердикт пишешь ты: bash $BRG item review I001 --as $C --verdict ok|changes"
  assert_eq "── NEXT: поручи проверку I001 подагенту, затем bash $BRG wait --as $C" "$(printf '%s\n' "$out" | tail -n 1)"
  assert_eq "${C%%.*}" "$(hdr "$f" Reviewing)"
  n=$(cat "$D/seq")
  assert_eq system "$(hdr "$(last_msg)" Kind)"
  assert_eq all "$(hdr "$(last_msg)" To)"
  assert_eq no "$(hdr "$(last_msg)" Wake)" "quiet, like claim"
  assert_contains "$(cat "$(last_msg)")" "${C%%.*} взялся проверять I001 «Проверяемая» (исполнитель ${Bn%%.*})"
  assert_contains "$(metrics_of "$C" item.review.start)" "id=I001 again=0"
  # again: no duplicate, no new message
  out=$(brg item review I1 --as "$C" --start)
  assert_eq 0 "$?"
  assert_contains "$out" "── ты уже проверяешь I001 «Проверяемая» — отметка есть (проверяют: ${C%%.*})."
  assert_eq "${C%%.*}" "$(hdr "$f" Reviewing)"
  assert_eq "$n" "$(cat "$D/seq")" "no second notice"
  # a second reviewer
  out=$(brg item review I1 --as "$A" --start)
  assert_eq "${C%%.*},${A%%.*}" "$(hdr "$f" Reviewing)"
  assert_contains "$(brg item show I1)" "Проверяют: ${C%%.*}, ${A%%.*}"
  # refusals
  out=$(brg item review I1 --as "$Bn" --start 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I001 делал ты — своё ревью не засчитывается"
  out=$(brg item review I2 --as "$C" --start 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I002 — todo: ревьюить нечего"
  for x in "--verdict ok" "--comment x" "--file $P/nofile"; do
    out=$(brg item review I1 --as "$C" --start $x 2>&1)
    assert_eq 1 "$?" "--start with $x"
    assert_contains "$out" "--start — только отметка «взялся проверять»: без --verdict, --comment и --file"
    assert_contains "$out" "── NEXT:"
  done
  out=$(brg item review I1 --as "$C" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нужен --verdict ok|changes|skip (или --start — взялся проверять)"
  # the stop: --start starts work — refused; a verdict is handing in — allowed
  brg stop "${C%%.*}" >/dev/null || fail stop
  out=$(brg item review I1 --as "$C" --start 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "item review --start не выполнено: при стопе новую работу не начинают"
  assert_eq "── NEXT: заверши ход (стоп снимет человек и напишет тебе «продолжай»)" "$(printf '%s\n' "$out" | tail -n 1)"
  out=$(brg item review I1 --as "$C" --verdict changes --comment "нет теста")
  assert_eq 0 "$?" "a verdict while stopped"
  assert_contains "$(printf '%s\n' "$out" | head -n 1)" "── STOP:"
  brg resume "${C%%.*}" >/dev/null || fail resume
  # the verdict took C out of Reviewing; A is still reviewing
  assert_eq "${A%%.*}" "$(hdr "$f" Reviewing)"
  assert_contains "$(cat "$(last_msg)")" "${Bn%%.*}: подзадача ещё в работе — внеси правки (силами подагента) и сдай: bash $BRG item done I001 --as <имя>."
  assert_contains "$(brg item list)" "I001 · claimed · ${Bn%%.*} · «Проверяемая» · пути: src/a · "
  assert_contains "$(brg item list)" " · правки по ревью от ${C%%.*} · проверяет ${A%%.*} · ревью: changes от ${C%%.*}"
  brg item review I1 --as "$A" --verdict ok --comment ок >/dev/null || fail "review A"
  assert_eq "" "$(hdr "$f" Reviewing)" "the last reviewer out"
  # release clears Reviewing: the work starts over
  brg item review I1 --as "$C" --start >/dev/null || fail start
  brg item release I1 --as "$Bn" >/dev/null || fail release
  assert_eq "" "$(hdr "$f" Reviewing)"
  assert_contains "$(brg item --help)" "--start"
}

# The stages (DESIGN §7.1.1) and rework after changes: the assignee claims the
# handed-in item back (previous paths, conflicts checked), fixes, hands it in again.
test_review_stages_and_rework() {
  local out f e0
  item_setup
  item_add_as "$A" "Ок до сдачи"
  item_add_as "$A" "С правками"
  item_add_as "$A" "Соседняя"
  # ok before handing in → on review (handed in after the review), then ok → готово
  claim_ok "$Bn" I1 src/one
  brg item review I1 --as "$C" --verdict ok --comment "ок" >/dev/null || fail review1
  out=$(brg item done I1 --as "$Bn")
  assert_contains "$out" "Стадия: на проверке (сдана после ревью, ждёт проверяющего) — ревью #1 (ok от ${C%%.*}) было до сдачи: нужна новая проверка"
  assert_eq 1 "$(hdr "$D/items/I001" Done-Reviews)"
  assert_contains "$(brg item list)" "I001 · done · на проверке (сдана после ревью, ждёт проверяющего) · ${Bn%%.*}"
  assert_contains "$(brg item show I1)" "Стадия: на проверке — сдана после ревью #1 (ok от ${C%%.*}): нужна новая проверка"
  brg item review I1 --as "$A" --verdict ok --comment "и после сдачи ок" >/dev/null || fail review1b
  assert_contains "$(brg item list)" "I001 · done · готово · ${Bn%%.*}"
  out=$(brg item claim I1 --as "$C" --paths x 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I001 — сдана (${Bn%%.*}), стадия: готово; последний вердикт: #2 ok от ${A%%.*}. Вернуть её в работу может только исполнитель ${Bn%%.*}"
  # handed in → на проверке; changes → правки
  claim_ok "$Bn" I2 "src/two,docs"
  brg item done I2 --as "$Bn" --note "первая сдача" >/dev/null || fail done2
  f=$D/items/I002
  assert_eq 0 "$(hdr "$f" Done-Reviews)"
  e0=$(hdr "$f" Claimed-Epoch)
  out=$(brg item review I2 --as "$C" --verdict changes --comment "нет теста")
  assert_contains "$out" "Стадия I002: правки по ревью от ${C%%.*} — исполнитель вернёт её в работу (item claim) и пересдаст."
  assert_contains "$(cat "$(last_msg)")" "${Bn%%.*}, как пересдать: bash $BRG item claim I002 --as <имя> (вернёт в работу с прежними путями) → правки (силами подагента) → bash $BRG item done I002 --as <имя>"
  assert_contains "$(brg item list)" "I002 · done · правки по ревью от ${C%%.*} · ${Bn%%.*} · «С правками» · итог: первая сдача · ревью: changes от ${C%%.*}"
  assert_contains "$(brg item show I2)" "Стадия: правки по ревью #1 от ${C%%.*} — исполнитель возвращает её в работу: bash $BRG item claim I002 --as <имя>"
  assert_contains "$(brg status --as "$Bn")" "  I002 «С правками» · правки по ревью от ${C%%.*} — верни в работу: bash $BRG item claim I002 --as $Bn (прежние пути)"
  # done again without claiming back: refused with the way out
  out=$(brg item done I2 --as "$Bn" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I002 ждёт правок по ревью #1 от ${C%%.*} — сначала верни её в работу: bash $BRG item claim I002 --as $Bn (прежние пути), затем правки и item done"
  # someone else may not claim it
  out=$(brg item claim I2 --as "$C" --paths x 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I002 — сдана (${Bn%%.*}), стадия: правки по ревью от ${C%%.*}; последний вердикт: #1 changes от ${C%%.*}. Вернуть её в работу может только исполнитель ${Bn%%.*}"
  assert_eq done "$(hdr "$f" Status)"
  # the previous paths are taken meanwhile: refused, still done
  claim_ok "$C" I3 "src/two/x"
  out=$(brg item claim I2 --as "$Bn" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I002 не возвращена в работу (прежние пути заняты — укажи свои: --paths …)"
  assert_contains "$out" "src/two ↔ src/two/x — I003 «Соседняя», ${C%%.*}"
  assert_eq done "$(hdr "$f" Status)"
  brg item release I3 --as "$C" >/dev/null || fail release3
  # back to work: the previous paths, claimed anew, quiet notice
  sleep 1
  out=$(brg item claim I2 --as "$Bn")
  assert_eq 0 "$?"
  assert_contains "$out" "── I002 «С правками» снова в работе — правки по ревью #1 от ${C%%.*} (замечания: bash $BRG item show I002). Резервирование — прежние пути: src/two, docs"
  assert_contains "$out" "Работу выполняет твой подагент — поручи ему"
  assert_eq claimed "$(hdr "$f" Status)"
  assert_eq "src/two,docs" "$(hdr "$f" Paths)"
  assert_eq "${Bn%%.*}" "$(hdr "$D/reservations/I002" Agent)"
  [ "$(hdr "$f" Claimed-Epoch)" -gt "$e0" ] || fail "Claimed-Epoch not renewed"
  assert_eq "" "$(hdr "$f" Done)"
  assert_eq "" "$(hdr "$f" Done-Reviews)"
  assert_eq "${A%%.*}" "$(hdr "$(last_msg)" Wake)" "handed-in work back: wakes the lead"
  assert_contains "$(cat "$(last_msg)")" "${Bn%%.*} вернул I002 «С правками» в работу — правки по ревью #1 · пути: src/two, docs"
  assert_contains "$(metrics_of "$Bn" item.claim | tail -n 1)" "fix=1"
  assert_contains "$(brg item show I2)" "Стадия: в работе — правки по ревью #1 от ${C%%.*}"
  # the reservation is real: others are refused
  out=$(brg item claim I3 --as "$C" --paths src/two 2>&1)
  assert_eq 1 "$?"
  # hand in again → на проверке (handed in again), then ok → готово
  out=$(brg item done I2 --as "$Bn" --note "тест добавлен")
  assert_contains "$out" "Стадия: на проверке (пересдана, ждёт проверяющего)"
  assert_eq 1 "$(hdr "$f" Done-Reviews)"
  assert_contains "$(cat "$(last_msg)")" "${Bn%%.*} пересдал I002 «С правками» после правок по ревью #1: тест добавлен"
  assert_contains "$(brg item list)" "I002 · done · на проверке (пересдана, ждёт проверяющего) · ${Bn%%.*}"
  assert_contains "$(brg item show I2)" "Стадия: на проверке — пересдана после ревью #1 (changes от ${C%%.*})"
  out=$(brg item review I2 --as "$C" --verdict ok --comment "теперь да")
  assert_contains "$out" "Стадия I002: готово."
  assert_contains "$(brg item list)" "I002 · done · готово · ${Bn%%.*}"
  # explicit --paths wins over the previous ones
  claim_ok "$Bn" I3 src/three
  brg item done I3 --as "$Bn" >/dev/null || fail done3
  brg item review I3 --as "$A" --verdict changes --comment "ещё" >/dev/null || fail review3
  out=$(brg item claim I3 --as "$Bn" --paths "src/three,tests/three")
  assert_contains "$out" "снова в работе — правки по ревью #1 от ${A%%.*}"
  assert_contains "$out" "Резервирование: src/three, tests/three."
  assert_eq "src/three,tests/three" "$(hdr "$D/items/I003" Paths)"
  assert_contains "$(brg item list)" "── T001: todo 0 · в работе 1 · правки 0 · на проверке 0 · готово 2 · отменено 0"
}

# Item files of brg < 0.5.0 (no Review, Done-Reviews, Reviewing) read as before:
# done without Done-Reviews = handed in before any review.
test_review_stage_of_old_items() {
  local out
  item_setup
  printf 'Id: I001\nTitle: Старая\nStatus: done\nCreator: %s\nAssignee: %s\nPaths: src/a\nCreated: x\nDone: x\n\nописание\n' \
    "${A%%.*}" "${Bn%%.*}" >"$D/items/I001"
  printf 'Id: I002\nTitle: Старая с ревью\nStatus: done\nCreator: %s\nAssignee: %s\nPaths: src/b\nCreated: x\nDone: x\n\nописание\n' \
    "${A%%.*}" "${Bn%%.*}" >"$D/items/I002"
  mkdir -p "$D/items/I002.reviews"
  printf 'Item: I002\nReviewer: %s\nVerdict: changes\n\nпоправь\n' "${C%%.*}" >"$D/items/I002.reviews/1"
  out=$(brg item list)
  assert_contains "$out" "I001 · done · на проверке (ждёт проверяющего) · ${Bn%%.*} · «Старая»"
  assert_contains "$out" "I002 · done · правки по ревью от ${C%%.*} · ${Bn%%.*} · «Старая с ревью»"
  out=$(brg item claim I2 --as "$Bn")
  assert_contains "$out" "снова в работе — правки по ревью #1 от ${C%%.*}"
  assert_eq "src/b" "$(hdr "$D/items/I002" Paths)"
}

# The lead hands the changes of an asleep assignee over (a reviewed item is claimed
# back only by its assignee — without this it would be stuck).
test_reassign_rework() {
  local out f
  item_setup
  item_add_as "$A" "Правки"
  claim_ok "$Bn" I1 src/a
  brg item done I1 --as "$Bn" >/dev/null || fail done
  brg item review I1 --as "$A" --verdict changes --comment "поправь" >/dev/null || fail review
  f=$D/items/I001
  out=$(brg item reassign I1 --to "${C%%.*}" --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "исполнитель ${Bn%%.*} активен"
  printf '%s\n' $(($(date -u +%s) - 90)) >"$B/run/seen/${Bn%%.*}"
  out=$(brg item reassign I1 --to "${C%%.*}" --as "$A")
  assert_eq 0 "$?"
  assert_contains "$out" "── I001 «Правки» (правки по ревью #1): ${Bn%%.*} → ${C%%.*}"
  assert_eq claimed "$(hdr "$f" Status)"
  assert_eq "${C%%.*}" "$(hdr "$f" Assignee)"
  assert_eq "${C%%.*}" "$(hdr "$D/reservations/I001" Agent)"
  assert_eq "" "$(hdr "$f" Done)"
  brg item done I1 --as "$C" >/dev/null || fail "done by C"
  assert_contains "$(brg item list)" "I001 · done · на проверке (пересдана, ждёт проверяющего) · ${C%%.*}"
  # an item handed in and waiting for a review is not reassigned
  out=$(brg item reassign I1 --to "${Bn%%.*}" --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I001 — done, а не в работе"
}

# task close does not require reviews, but names what was not accepted.
test_close_warns_unreviewed() {
  local out
  item_setup
  item_add_as "$A" "На проверке"
  item_add_as "$A" "С правками"
  item_add_as "$A" "Принята"
  brg item add --as "$A" --title "Без проверки" --desc d --no-review >/dev/null || fail add4
  claim_ok "$Bn" I1 src/a
  claim_ok "$Bn" I2 src/b
  claim_ok "$Bn" I3 src/c
  claim_ok "$Bn" I4 src/d
  for x in I1 I2 I3 I4; do brg item done $x --as "$Bn" >/dev/null || fail "done $x"; done
  brg item review I2 --as "$C" --verdict changes --comment "нет" >/dev/null || fail review2
  brg item review I3 --as "$C" --verdict ok --comment "да" >/dev/null || fail review3
  printf 'итог\n' >"$D/summary.md"
  brg wait --as "$A" --timeout 0 >/dev/null
  out=$(brg task close --as "$A")
  assert_eq 0 "$?" "not a refusal"
  assert_contains "$out" "── задача T001 «Подзадачи» закрыта."
  assert_contains "$out" "Внимание: не приняты: I001 (на проверке), I002 (правки) — brg закрытию не мешает, но скажи о них человеку в отчёте."
  assert_eq done "$(hdr "$D/task" Status)"
  # all accepted: no warning
  task_new_as "$A" "Вторая"
  D=$(tdir T002)
  ack_all "$A" "$D"
  item_add_as "$A" "Одна"
  claim_ok "$Bn" I1 src/a
  brg item done I1 --as "$Bn" >/dev/null || fail done
  brg item review I1 --as "$C" --verdict ok --comment ок >/dev/null || fail review
  printf 'итог\n' >"$D/summary.md"
  brg wait --as "$A" --timeout 0 >/dev/null
  out=$(brg task close --as "$A")
  assert_eq 0 "$?"
  assert_not_contains "$out" "не приняты"
}

# item done --no-review: handed in + the verdict skip by the assignee at once (Done-Reviews
# counted before it), Reviewing cleared, one system message.
test_done_no_review() {
  local out f n
  item_setup
  item_add_as "$A" "Сдать без проверки"
  claim_ok "$Bn" I1 src/a
  brg item review I1 --as "$C" --start >/dev/null || fail start
  f=$D/items/I001
  n=$(cat "$D/seq")
  out=$(brg item done I1 --as "$Bn" --note "мелочь" --no-review)
  assert_eq 0 "$?"
  assert_contains "$out" "Стадия: готово · без проверки — записан вердикт skip #1 (проверка не нужна)."
  assert_eq done "$(hdr "$f" Status)"
  assert_eq 0 "$(hdr "$f" Done-Reviews)" "counted before the skip"
  assert_eq "" "$(hdr "$f" Reviewing)" "a verdict on a done item ends the review"
  assert_eq skip "$(hdr "$f.reviews/1" Verdict)"
  assert_eq "${Bn%%.*}" "$(hdr "$f.reviews/1" Reviewer)"
  assert_eq "при сдаче (item done --no-review)" "$(body "$f.reviews/1")"
  assert_eq $((n + 1)) "$(cat "$D/seq")" "one system message"
  assert_eq "${A%%.*}" "$(hdr "$(last_msg)" Wake)"
  assert_contains "$(cat "$(last_msg)")" "${Bn%%.*} завершил I001 «Сдать без проверки»: мелочь
Проверка не нужна (item done --no-review).
Стадия: готово · без проверки."
  assert_contains "$(brg item list)" "I001 · done · готово · без проверки · ${Bn%%.*}"
  assert_contains "$(brg item show I1)" "Стадия: готово · без проверки (решил ${Bn%%.*}: вердикт skip #1)"
  assert_contains "$(brg item --help)" "[--result <путь>] [--no-review]"
}

# --verdict skip: anybody (the assignee too), no comment needed and stdin not waited
# for, no model warning; ok/changes after it take over again.
test_verdict_skip() {
  local out t0 t1 f
  item_setup
  item_add_as "$A" "Первая"
  item_add_as "$A" "Вторая"
  item_add_as "$A" "Третья"
  claim_ok "$Bn" I1 src/a
  claim_ok "$Bn" I2 src/b
  claim_ok "$Bn" I3 src/c
  brg item done I1 --as "$Bn" >/dev/null || fail done1
  brg item done I2 --as "$Bn" >/dev/null || fail done2
  # by the assignee, no comment, an open pipe on stdin
  t0=$(date -u +%s)
  out=$(brg item review I1 --as "$Bn" --verdict skip < <(sleep 30))
  assert_eq 0 "$?"
  t1=$(date -u +%s)
  [ $((t1 - t0)) -le 2 ] || fail "skip read stdin ($((t1 - t0)) s)"
  assert_contains "$out" "── решение #1 по I001 записано (skip — проверка не нужна); сообщение отправлено: ${A%%.*}."
  assert_contains "$out" "Стадия I001: готово · без проверки."
  assert_not_contains "$out" "Внимание"
  assert_eq "" "$(body "$D/items/I001.reviews/1")"
  assert_eq "${A%%.*}" "$(hdr "$(last_msg)" To)"
  assert_contains "$(cat "$(last_msg)")" "${Bn%%.*}: I001 «Первая» — skip — проверка не нужна"
  assert_contains "$(brg item list)" "I001 · done · готово · без проверки · ${Bn%%.*}"
  # after changes: skip by someone else → "no changes needed" to the assignee
  brg item review I2 --as "$C" --verdict changes --comment "переделай" >/dev/null || fail changes2
  out=$(brg item review I2 --as "$A" --verdict skip --comment "не стоит того")
  assert_contains "$out" "Стадия I002: готово · без проверки."
  assert_contains "$(cat "$(last_msg)")" "${Bn%%.*}: правки не нужны — I002 готова, без проверки."
  assert_eq "не стоит того" "$(body "$D/items/I002.reviews/2")"
  # ok and changes after it take over again
  brg item review I2 --as "$C" --verdict ok --comment "ок" >/dev/null || fail ok2
  assert_contains "$(brg item list)" "I002 · done · готово · ${Bn%%.*}"
  brg item review I2 --as "$C" --verdict changes --comment "нет, всё же" >/dev/null || fail changes2b
  assert_contains "$(brg item list)" "I002 · done · правки по ревью от ${C%%.*}"
  # skip on an item in work: handed in → at once "готово · без проверки"
  brg item review I3 --as "$C" --verdict skip >/dev/null || fail skip3
  assert_contains "$(cat "$(last_msg)")" "После item done — сразу «готово · без проверки»."
  out=$(brg item done I3 --as "$Bn")
  assert_contains "$out" "Стадия: готово · без проверки — проверку отменили раньше (вердикт skip #1 от ${C%%.*})."
  # nothing to skip in todo
  item_add_as "$A" "Четвёртая"
  out=$(brg item review I4 --as "$A" --verdict skip 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I004 — todo: ревьюить нечего"
  assert_contains "$(brg item --help)" "--verdict skip [--comment \"почему\" | --file F]"
}

# Reviewing and the verdicts: a verdict on a done item clears it all; "готово" while
# somebody reviews → "на проверке" (--start on an accepted / no-review item).
test_reviewing_and_accepted_stage() {
  local out f
  item_setup
  item_add_as "$A" "Принятая"
  brg item add --as "$A" --title "Без проверки" --desc d --no-review >/dev/null || fail add2
  claim_ok "$Bn" I1 src/a
  claim_ok "$Bn" I2 src/b
  brg item done I1 --as "$Bn" >/dev/null || fail done1
  brg item done I2 --as "$Bn" >/dev/null || fail done2
  f=$D/items/I001
  brg item review I1 --as "$A" --start >/dev/null || fail startA
  brg item review I1 --as "$C" --start >/dev/null || fail startC
  brg item review I1 --as "$A" --verdict ok --comment ок >/dev/null || fail ok1
  assert_eq "" "$(hdr "$f" Reviewing)" "a verdict on done clears all of Reviewing"
  assert_contains "$(brg item list)" "I001 · done · готово · ${Bn%%.*}"
  # changed our minds: a review is needed after all
  out=$(brg item review I1 --as "$C" --start)
  assert_contains "$out" "Стадия: на проверке (проверяет ${C%%.*})."
  assert_contains "$(brg item list)" "I001 · done · на проверке (проверяет ${C%%.*}) · ${Bn%%.*}"
  brg item review I2 --as "$C" --start >/dev/null || fail start2
  assert_contains "$(brg item list)" "I002 · done · на проверке (проверяет ${C%%.*}) · ${Bn%%.*} · «Без проверки»"
  ack_all "$A"
  ack_all "$A" "$D"
  assert_contains "$(brg wait --as "$A" --timeout 0)" "на проверке I001 (${C%%.*}), I002 (${C%%.*})"
  brg item review I2 --as "$C" --verdict ok --comment ок >/dev/null || fail ok2
  assert_contains "$(brg item list)" "I002 · done · готово · ${Bn%%.*}"
  assert_contains "$(brg item list)" "── T001: todo 0 · в работе 0 · правки 0 · на проверке 1 · готово 1 · отменено 0"
}

# Back to work from any stage of done (the assignee only): an accepted item is redone;
# someone else is told the stage and the newest verdict. ok after someone's changes —
# "правки не нужны".
test_reopen_done_item() {
  local out f
  item_setup
  item_add_as "$A" "Переделать"
  claim_ok "$Bn" I1 "src/a"
  brg item done I1 --as "$Bn" --note "первая" --result .brigada/VERSION >/dev/null || fail done
  brg item review I1 --as "$C" --verdict changes --comment "мало" >/dev/null || fail changes
  out=$(brg item review I1 --as "$A" --verdict ok --comment "достаточно")
  assert_contains "$out" "Стадия I001: готово."
  assert_contains "$(cat "$(last_msg)")" "${Bn%%.*}: правки не нужны — I001 готова."
  f=$D/items/I001
  out=$(brg item claim I1 --as "$C" --paths x 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I001 — сдана (${Bn%%.*}), стадия: готово; последний вердикт: #2 ok от ${A%%.*}. Вернуть её в работу может только исполнитель ${Bn%%.*}"
  brg item review I1 --as "$C" --start >/dev/null || fail start
  out=$(brg item claim I1 --as "$Bn")
  assert_eq 0 "$?"
  assert_contains "$out" "── I001 «Переделать» снова в работе (была: на проверке (проверяет ${C%%.*})). Резервирование — прежние пути: src/a"
  assert_not_contains "$out" "Последний вердикт" "handed in again it will be reviewed again"
  assert_eq claimed "$(hdr "$f" Status)"
  for x in Done Done-Reviews Note Result Reviewing; do
    assert_eq "" "$(hdr "$f" $x)" "$x cleared"
  done
  assert_eq "${A%%.*}" "$(hdr "$(last_msg)" Wake)" "wakes the lead"
  assert_contains "$(cat "$(last_msg)")" "${Bn%%.*} вернул I001 «Переделать» в работу (была: на проверке (проверяет ${C%%.*})) · пути: src/a
Стадия: в работе."
  assert_contains "$(metrics_of "$Bn" item.claim | tail -n 1)" "back=1 fix=0"
  # the redo is handed in: on review again (the ok was for the work before), then ok
  out=$(brg item done I1 --as "$Bn" --note "переделал")
  assert_contains "$out" "Стадия: на проверке (сдана после ревью, ждёт проверяющего) — ревью #2 (ok от ${A%%.*}) было до сдачи: нужна новая проверка"
  assert_contains "$(cat "$(last_msg)")" "Стадия: на проверке (сдана после ревью, ждёт проверяющего)."
  assert_contains "$(brg item list)" "I001 · done · на проверке (сдана после ревью, ждёт проверяющего) · ${Bn%%.*}"
  brg item review I1 --as "$C" --verdict ok --comment "переделка ок" >/dev/null || fail "ok of the redo"
  assert_contains "$(brg item list)" "I001 · done · готово · ${Bn%%.*}"
  # taken off review: handed in without a verdict → on review again
  item_add_as "$A" "Отозвать"
  claim_ok "$Bn" I2 src/b
  brg item done I2 --as "$Bn" >/dev/null || fail done2
  out=$(brg item claim I2 --as "$Bn")
  assert_contains "$out" "снова в работе (была: на проверке (ждёт проверяющего))"
  assert_not_contains "$out" "Последний вердикт"
  # handed in without a review (skip), redone: stays without a review — and says how to change that
  item_add_as "$A" "Без проверки"
  claim_ok "$Bn" I3 src/c
  brg item done I3 --as "$Bn" --no-review >/dev/null || fail done3
  out=$(brg item claim I3 --as "$Bn")
  assert_contains "$out" "Последний вердикт — skip (#1 от ${Bn%%.*}): после item done подзадача сразу станет «готово · без проверки»; нужна проверка — пусть проверяющий отметится: item review I003 --as <имя> --start."
  out=$(brg item done I3 --as "$Bn")
  assert_contains "$out" "Стадия: готово · без проверки"
}

# reassign takes the new assignee out of Reviewing (it does not review its own work).
test_reassign_clears_new_assignee_from_reviewing() {
  local f
  item_setup
  item_add_as "$A" "Передаваемая"
  claim_ok "$Bn" I1 src/a
  brg item review I1 --as "$C" --start >/dev/null || fail startC
  brg item review I1 --as "$A" --start >/dev/null || fail startA
  f=$D/items/I001
  printf '%s\n' $(($(date -u +%s) - 90)) >"$B/run/seen/${Bn%%.*}"
  out=$(brg item reassign I1 --to "${C%%.*}" --as "$A")
  assert_eq 0 "$?"
  assert_contains "$out" "Стадия: в работе."
  assert_eq "${A%%.*}" "$(hdr "$f" Reviewing)"
}

# item cancel: todo — anybody; claimed/done — the assignee or the lead; reservation and
# Reviewing go; wakes the lead and the assignee (not the author); allowed while
# stopped; no way back from cancelled.
test_item_cancel() {
  local out t0 t1 f
  item_setup
  item_add_as "$A" "Лишняя"
  item_add_as "$A" "В работе"
  item_add_as "$A" "Сданная"
  claim_ok "$Bn" I2 src/b
  claim_ok "$Bn" I3 src/c
  brg item done I3 --as "$Bn" >/dev/null || fail done3
  # todo: anybody; no comment, stdin not waited for
  t0=$(date -u +%s)
  out=$(brg item cancel I1 --as "$C" < <(sleep 30))
  assert_eq 0 "$?"
  t1=$(date -u +%s)
  [ $((t1 - t0)) -le 2 ] || fail "cancel read stdin ($((t1 - t0)) s)"
  assert_contains "$out" "── I001 «Лишняя» отменена (была: todo). Стадия: отменено."
  f=$D/items/I001
  assert_eq cancelled "$(hdr "$f" Status)"
  assert_eq "${C%%.*}" "$(hdr "$f" Cancelled-By)"
  [ -n "$(hdr "$f" Cancelled)" ] || fail "no Cancelled"
  assert_eq "${A%%.*}" "$(hdr "$(last_msg)" Wake)" "the lead"
  assert_contains "$(cat "$(last_msg)")" "${C%%.*} отменил I001 «Лишняя» (была: todo)"
  # claimed: not by a stranger; the lead may, with a comment
  brg item review I2 --as "$C" --start >/dev/null || fail start2
  out=$(brg item cancel I2 --as "$C" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "отменить I002 (claimed) может исполнитель (${Bn%%.*}) или lead (${A%%.*})"
  out=$(brg item cancel I2 --as "$A" --comment "задача решена иначе")
  assert_eq 0 "$?"
  assert_contains "$out" "Резервирование снято (src/b)."
  assert_eq cancelled "$(hdr "$D/items/I002" Status)"
  assert_eq "" "$(hdr "$D/items/I002" Reviewing)"
  assert_file_not_exists "$D/reservations/I002"
  assert_eq "${Bn%%.*}" "$(hdr "$(last_msg)" Wake)" "the assignee (the lead wrote it)"
  assert_contains "$(cat "$(last_msg)")" "${A%%.*} отменил I002 «В работе» (была: claimed): задача решена иначе"
  assert_contains "$(cat "$(last_msg)")" "${Bn%%.*}: прекрати правки по I002"
  # done: the assignee, while stopped
  brg stop "${Bn%%.*}" >/dev/null || fail stop
  out=$(brg item cancel I3 --as "$Bn" --comment "не понадобилась")
  assert_eq 0 "$?" "allowed while stopped"
  assert_contains "$(printf '%s\n' "$out" | head -n 1)" "── STOP:"
  assert_contains "$out" "отменена (была: done)"
  brg resume "${Bn%%.*}" >/dev/null || fail resume
  # no way back
  out=$(brg item cancel I3 --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I003 уже отменена (${Bn%%.*}"
  out=$(brg item claim I3 --as "$Bn" --paths src/c 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "I003 отменена (${Bn%%.*}): из cancelled пути назад нет"
  out=$(brg item review I3 --as "$A" --verdict skip 2>&1)
  assert_eq 1 "$?"
  out=$(brg item list)
  assert_contains "$out" "I001 · cancelled · — · «Лишняя»"
  assert_contains "$out" "── T001: todo 0 · в работе 0 · правки 0 · на проверке 0 · готово 0 · отменено 3"
  assert_contains "$(brg item show I1)" "Стадия: отменено (${C%%.*}, "
  assert_contains "$(brg item list --status cancelled)" "I002 · cancelled"
  assert_contains "$(brg item --help)" "item cancel I00N --as <имя> [--comment"
}

# Only numeric review files (from 1) are verdict records; 2.bak, 3~, 0 in .reviews and
# I001~ / I002.bak in items are no phantom items, no records, and not the newest one.
test_no_phantoms_from_stray_files() {
  local out f r
  item_setup
  item_add_as "$A" "Настоящая"
  item_add_as "$A" "Только ноль"
  claim_ok "$Bn" I1 src/a
  claim_ok "$Bn" I2 src/b
  brg item done I1 --as "$Bn" >/dev/null || fail done1
  brg item done I2 --as "$Bn" >/dev/null || fail done2
  f=$D/items/I001
  mkdir -p "$f.reviews" "$D/items/I002.reviews"
  for r in 1:changes:"${C%%.*}" 2:ok:"${A%%.*}" 2.bak:changes:x 3~:changes:x 0:skip:x; do
    printf 'Item: I001\nReviewer: %s\nVerdict: %s\n\nтело %s\n' "${r##*:}" "$(printf '%s' "$r" | cut -d: -f2)" "${r%%:*}" >"$f.reviews/${r%%:*}"
  done
  printf 'Item: I002\nReviewer: x\nVerdict: ok\n\nноль\n' >"$D/items/I002.reviews/0"
  cp "$f" "$D/items/I001~"
  sed 's/^Status: done/Status: todo/' "$f" >"$D/items/I002.bak"
  out=$(brg item list)
  assert_contains "$out" "I001 · done · готово · ${Bn%%.*} · «Настоящая» · ревью: ok от ${A%%.*} (всего 2)"
  assert_contains "$out" "I002 · done · на проверке (ждёт проверяющего) · ${Bn%%.*} · «Только ноль»"
  assert_not_contains "$out" "I002 · done · на проверке (ждёт проверяющего) · ${Bn%%.*} · «Только ноль» · ревью"
  assert_eq "" "$(printf '%s\n' "$out" | awk '$1 != "I001" && $1 != "I002" && $1 != "──"')" "only the real items"
  for r in "2.bak" "3~" "I001~" "I002.bak"; do
    assert_not_contains "$out" "$r" "a phantom: $r"
  done
  assert_contains "$out" "── T001: todo 0 · в работе 0 · правки 0 · на проверке 1 · готово 1 · отменено 0"
  ack_all "$A"
  ack_all "$A" "$D"
  assert_contains "$(brg wait --as "$A" --timeout 0)" "T001: на проверке I002 · готово I001
"
  assert_contains "$(brg status --as "$A")" "Подзадачи T001: todo 0 · в работе 0 · правки 0 · на проверке 1 · готово 1"
  out=$(brg item show I1)
  assert_contains "$out" "── ревью #1: changes от ${C%%.*}"
  assert_contains "$out" "── ревью #2: ok от ${A%%.*}"
  for r in "#2.bak" "#3~" "#0:"; do
    assert_not_contains "$out" "$r" "item show: $r"
  done
  # the next record is #3 (3~ is not one), and it is the newest
  brg item review I1 --as "$C" --verdict changes --comment "ещё" >/dev/null || fail review
  assert_eq changes "$(hdr "$f.reviews/3" Verdict)"
  assert_contains "$(brg item list)" "I001 · done · правки по ревью от ${C%%.*}"
  # the board: records only
  brg board --once >/dev/null || fail board
  out=$(cat "$B/run/board/data.js")
  assert_not_contains "$out" "тело 2.bak"
  assert_not_contains "$out" "тело 0"
  assert_not_contains "$out" '"Id":"I001~"'
}

# The comment of --verdict skip and item cancel: from a heredoc (stdin a regular file
# in bash 3.2) it is kept; a pipe that never closes is not waited for.
test_optional_comment_from_heredoc() {
  local out t0 t1
  item_setup
  item_add_as "$A" "Пропустить"
  item_add_as "$A" "Отменить"
  item_add_as "$A" "Без комментария"
  claim_ok "$Bn" I1 src/a
  brg item done I1 --as "$Bn" >/dev/null || fail done
  out=$(brg item review I1 --as "$C" --verdict skip <<'BRG_EOF'
мелкая правка
опечатка в README
BRG_EOF
)
  assert_eq 0 "$?"
  assert_eq "мелкая правка
опечатка в README" "$(body "$D/items/I001.reviews/1")"
  assert_contains "$(cat "$(last_msg)")" "skip — проверка не нужна
мелкая правка"
  out=$(brg item cancel I2 --as "$A" <<'BRG_EOF'
дублирует I001
BRG_EOF
)
  assert_eq 0 "$?"
  assert_contains "$(cat "$(last_msg)")" "отменил I002 «Отменить» (была: todo): дублирует I001"
  # an empty heredoc is no comment, not an error
  out=$(brg item cancel I3 --as "$A" </dev/null)
  assert_eq 0 "$?"
  printf '' >"$P/empty"
  item_add_as "$A" "Пустой файл"
  out=$(brg item cancel I4 --as "$A" <"$P/empty")
  assert_eq 0 "$?" "an empty stdin file"
  # a pipe that never closes: not read, no wait
  item_add_as "$A" "Пайп"
  t0=$(date -u +%s)
  out=$(brg item cancel I5 --as "$A" < <(sleep 30))
  assert_eq 0 "$?"
  t1=$(date -u +%s)
  [ $((t1 - t0)) -le 2 ] || fail "cancel waited for the pipe ($((t1 - t0)) s)"
}
