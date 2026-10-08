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
  printf 'итог\n' >"$D/summary.md"
  out=$(brg task close --as "$A" 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "подзадачи ещё в работе (claimed): I001"
  assert_eq active "$(hdr "$D/task" Status)"
  out=$(brg task close --as "$A" --force)
  assert_contains "$out" "закрыта с --force; подзадачи I001 отменены"
  assert_eq cancelled "$(hdr "$D/items/I001" Status)"
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
  assert_contains "$out" "I003 · done · ${Bn%%.*} · «Третья» · итог: готово"
  assert_contains "$out" "── T001: todo 1 · в работе 1 · готово 1 · отменено 0"
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
  assert_contains "$out" "Подзадачи T001: todo 1 · в работе 1 · готово 1"
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
