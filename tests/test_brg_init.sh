# brg init: layout, re-init without state loss, config keys, .git/info/exclude.

. "$TESTS_DIR/brg_lib.sh"

test_init_creates_layout() {
  local p out d
  p=$(mk_tmpdir)
  out=$(bash "$BRG_SRC" init "$p")
  assert_eq 0 "$?" "exit code"
  assert_contains "$out" "── brigada "
  assert_contains "$out" ": создано $p/.brigada"
  assert_contains "$out" "нет .git — пропущено"
  for d in bin agents lobby/messages lobby/cursors common tasks run/locks run/wait run/seen; do
    [ -d "$p/.brigada/$d" ] || fail "нет каталога $d"
  done
  for d in bin/brg README.md PROTOCOL.md config config.default VERSION lobby/seq common/project.md run/metrics.log; do
    assert_file_exists "$p/.brigada/$d"
  done
  assert_eq "$(cat "$ROOT/bin/brg")" "$(cat "$p/.brigada/bin/brg")" "bin/brg copied"
  assert_eq "$(cat "$ROOT/template/README.md")" "$(cat "$p/.brigada/README.md")" "README copied"
  assert_eq "$(cat "$ROOT/template/config")" "$(cat "$p/.brigada/config")" "config copied"
  assert_eq 0 "$(cat "$p/.brigada/lobby/seq")" "seq"
  assert_eq "$(bash "$BRG_SRC" version)" "brg $(cat "$p/.brigada/VERSION")" "VERSION"
  assert_contains "$(cat "$p/.brigada/run/metrics.log")" " - init version="
  # the installed copy works from the project
  out=$(cd "$p" && bash .brigada/bin/brg who)
  assert_contains "$out" "агентов нет"
  assert_contains "$out" "bash .brigada/bin/brg join"
}

test_init_defaults_to_cwd_and_template_matches_builtin_defaults() {
  local p cfg
  p=$(mk_tmpdir)
  (cd "$p" && bash "$BRG_SRC" init >/dev/null) || fail "init in cwd"
  assert_file_exists "$p/.brigada/VERSION"
  # built-in defaults (used when config is missing) must equal template/config
  cfg=$(BRG_SOURCE_ONLY=1 bash -c '. "$1"; cfg_defaults; set | awk -F= "/^CFG_/ { print }" | sort' _ "$BRG_SRC")
  tpl=$(awk -F: '/^[a-z]/ { k = $1; v = $2; gsub(/[ \t.]/, "_", k); gsub(/[ \t]/, "", v); print "CFG_" k "=" v }' \
    "$ROOT/template/config" | sort)
  assert_eq "$tpl" "$cfg" "template/config vs cfg_defaults"
}

test_reinit_updates_code_and_docs_but_keeps_state() {
  local a out
  new_proj
  a=$(join_as claude)
  send_as "$a" "сообщение до reinit"
  printf 'wait_timeout.claude: 7\n# свой комментарий\n' >"$B/config"
  printf 'испорчено\n' >"$B/README.md"
  printf 'echo old\n' >"$B/bin/brg"
  printf 'факты\n' >"$B/common/project.md"
  out=$(bash "$BRG_SRC" init "$P")
  assert_contains "$out" "обновлено $B"
  assert_contains "$out" "состояние и config не тронуты"
  assert_contains "$out" "В config нет ключей: wait_timeout.default wait_timeout.opencode"
  assert_eq "$(cat "$ROOT/bin/brg")" "$(cat "$B/bin/brg")" "bin/brg updated"
  assert_eq "$(cat "$ROOT/template/README.md")" "$(cat "$B/README.md")" "README updated"
  assert_eq "$(cat "$ROOT/template/config")" "$(cat "$B/config.default")" "config.default updated"
  assert_eq "wait_timeout.claude: 7
# свой комментарий" "$(cat "$B/config")" "config untouched"
  assert_eq "факты" "$(cat "$B/common/project.md")" "common untouched"
  assert_file_exists "$B/agents/${a%%.*}"
  assert_eq 2 "$(cat "$B/lobby/seq")" "seq kept"
  assert_contains "$(cat "$(msg_file 2)")" "сообщение до reinit"
  assert_file_exists "$B/lobby/cursors/${a%%.*}"
  # keys missing in config come from config.default; config overrides the rest
  out=$(brg status --as "$a")
  assert_contains "$out" "Таймаут wait: 7 с"
  assert_contains "$(brg wait --as "$a" --timeout 0)" "── нет новых (0 с)"
}

test_git_exclude_added_once_and_keeps_content() {
  local p ex out
  p=$(mk_tmpdir)
  mkdir -p "$p/.git/info"
  printf '*.log' >"$p/.git/info/exclude" # no trailing newline
  out=$(bash "$BRG_SRC" init "$p")
  assert_contains "$out" "добавлено в .git/info/exclude: .brigada/ (весь каталог brigada не коммитится)"
  ex=$(cat "$p/.git/info/exclude")
  assert_eq "*.log" "$(printf '%s\n' "$ex" | head -n 1)" "old content kept on its own line"
  out=$(bash "$BRG_SRC" init "$p")
  assert_contains "$out" ".git/info/exclude уже настроен"
  assert_eq 1 "$(awk '$0 == ".brigada/"' "$p/.git/info/exclude" | wc -l | tr -d ' ')" ".brigada/ once"
  assert_eq 3 "$(wc -l <"$p/.git/info/exclude" | tr -d ' ')" "line count after two inits"
}

# brg ≤ 0.2.0 excluded only tasks/lobby/run/agents: init replaces those lines
# (and their comment) with .brigada/, keeping the rest with its line endings.
test_git_exclude_migrates_old_lines_and_worktree() {
  local p w out
  p=$(mk_tmpdir)
  mkdir -p "$p/.git/info"
  printf '*.log\n# brigada: переписка и рантайм не коммитятся\n.brigada/tasks/\n.brigada/lobby/\n.brigada/run/\n.brigada/agents/\nbuild/\r\n' >"$p/.git/info/exclude"
  out=$(bash "$BRG_SRC" init "$p")
  assert_contains "$out" "заменены на .brigada/ — весь каталог"
  assert_contains "$out" "git rm -r --cached .brigada"
  assert_eq "$(printf '*.log\nbuild/\r\n# brigada: служебный каталог агентов (brg init) не коммитится\n.brigada/\n')" "$(cat "$p/.git/info/exclude")"
  out=$(bash "$BRG_SRC" init "$p")
  assert_contains "$out" ".git/info/exclude уже настроен"
  # old lines next to .brigada/ (added by hand): only the old lines go
  printf '.brigada/run/\n.brigada/\n' >"$p/.git/info/exclude"
  bash "$BRG_SRC" init "$p" >/dev/null || fail init
  assert_eq ".brigada/" "$(cat "$p/.git/info/exclude")"
  # worktree: .git is a file "gitdir: …", info/exclude lives in the common dir
  w=$(mk_tmpdir)
  mkdir -p "$p/.git/worktrees/wt"
  printf '../..\n' >"$p/.git/worktrees/wt/commondir"
  printf 'gitdir: %s/.git/worktrees/wt\n' "$p" >"$w/.git"
  out=$(bash "$BRG_SRC" init "$w")
  assert_contains "$out" "уже настроен"
  assert_file_not_exists "$p/.git/worktrees/wt/info/exclude"
}

test_init_only_from_repo_and_commands_need_state() {
  local p out
  new_proj
  out=$(bash "$BRG" init "$P" 2>&1)
  assert_eq 1 "$?" "init from installed copy must fail"
  assert_contains "$out" "init запускается из репозитория brigada"
  out=$(bash "$BRG_SRC" who 2>&1)
  assert_eq 1 "$?" "commands from the repo copy need .brigada"
  assert_contains "$out" "не найдено состояние brigada"
  out=$(bash "$BRG_SRC" init /nonexistent/dir 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "нет каталога"
  out=$(bash "$BRG" help)
  assert_contains "$out" "join --harness"
  out=$(bash "$BRG" send --help)
  assert_contains "$out" "Использование:"
  out=$(bash "$BRG" frobnicate 2>&1)
  assert_eq 1 "$?"
  assert_contains "$out" "неизвестная команда: frobnicate"
}
