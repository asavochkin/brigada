# brg init: layout, re-init without state loss, config keys, .git/info/exclude,
# the brigada block in AGENTS.md / CLAUDE.md.

. "$TESTS_DIR/brg_lib.sh"

test_init_creates_layout() {
  local p out d
  p=$(mk_tmpdir)
  out=$(bash "$BRG_SRC" init "$p")
  assert_eq 0 "$?" "exit code"
  assert_contains "$out" "── brigada "
  assert_contains "$out" ": создано $p/.brigada"
  assert_contains "$out" "нет .git — пропущено"
  # no git: AGENTS.md is created all the same, CLAUDE.md is not
  assert_contains "$out" "создан AGENTS.md (git: нет .git — пропущено)"
  assert_eq "$(am_block)" "$(cat "$p/AGENTS.md")" "AGENTS.md is the block"
  assert_file_not_exists "$p/CLAUDE.md"
  assert_contains "$out" "Дальше скажи агенту в новой сессии: «подключись к бригаде»"
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
  assert_eq 1 "$(awk '$0 == "/AGENTS.md"' "$p/.git/info/exclude" | wc -l | tr -d ' ')" "/AGENTS.md once"
  assert_eq 5 "$(wc -l <"$p/.git/info/exclude" | tr -d ' ')" "line count after two inits"
}

# brg ≤ 0.2.0 excluded only tasks/lobby/run/agents: init replaces those lines
# (and their comment) with .brigada/, keeping the rest with its line endings.
test_git_exclude_migrates_old_lines_and_worktree() {
  local p w out
  p=$(mk_tmpdir)
  mkdir -p "$p/.git/info"
  printf '*.log\n# brigada: переписка и рантайм не коммитятся\n.brigada/tasks/\n.brigada/lobby/\n.brigada/run/\n.brigada/agents/\nbuild/\r\n' >"$p/.git/info/exclude"
  out=$(bash "$BRG_SRC" init --no-agents-md "$p")
  assert_contains "$out" "заменены на .brigada/ — весь каталог"
  assert_contains "$out" "git rm -r --cached .brigada"
  assert_eq "$(printf '*.log\nbuild/\r\n# brigada: служебный каталог агентов (brg init) не коммитится\n.brigada/\n')" "$(cat "$p/.git/info/exclude")"
  out=$(bash "$BRG_SRC" init "$p" --no-agents-md)
  assert_contains "$out" ".git/info/exclude уже настроен"
  # old lines next to .brigada/ (added by hand): only the old lines go
  printf '.brigada/run/\n.brigada/\n' >"$p/.git/info/exclude"
  bash "$BRG_SRC" init --no-agents-md "$p" >/dev/null || fail init
  assert_eq ".brigada/" "$(cat "$p/.git/info/exclude")"
  # worktree: .git is a file "gitdir: …", info/exclude lives in the common dir
  # (/AGENTS.md of a created AGENTS.md too)
  w=$(mk_tmpdir)
  mkdir -p "$p/.git/worktrees/wt"
  printf '../..\n' >"$p/.git/worktrees/wt/commondir"
  printf 'gitdir: %s/.git/worktrees/wt\n' "$p" >"$w/.git"
  out=$(bash "$BRG_SRC" init "$w")
  assert_contains "$out" "уже настроен"
  assert_contains "$out" "создан AGENTS.md (только у тебя: исключён из git"
  assert_file_exists "$w/AGENTS.md"
  assert_file_not_exists "$p/AGENTS.md"
  assert_eq ".brigada/
# brigada: AGENTS.md создан brg init — чтобы коммитить его, удали строку ниже
/AGENTS.md" "$(cat "$p/.git/info/exclude")"
  assert_file_not_exists "$p/.git/worktrees/wt/info/exclude"
}

# ── the brigada block in AGENTS.md / CLAUDE.md (DESIGN §3) ──
# am_block → the current block (as brg writes it, LF, no final newline)
am_block() { BRG_SOURCE_ONLY=1 bash -c '. "$1"; printf "%s" "$AM_BLOCK"' _ "$BRG_SRC"; }
# am_count FILE → number of begin markers
am_count() { awk 'index($0, "<!-- brigada:begin") == 1' "$1" | wc -l | tr -d ' '; }
# same_bytes A B — byte-for-byte (cat would drop trailing newlines)
same_bytes() { [ "$(od -c <"$1")" = "$(od -c <"$2")" ] || fail "${3:-files differ}: $1 vs $2"; }

test_agents_md_block_text() {
  local b
  b=$(am_block)
  assert_contains "$b" "<!-- brigada:begin"
  assert_contains "$b" "«подключиться к бригаде»"
  assert_contains "$b" ".brigada/README.md"
  assert_contains "$b" "--no-agents-md"
  assert_eq 4 "$(printf '%s\n' "$b" | wc -l | tr -d ' ')" "block lines"
  assert_eq "<!-- brigada:end -->" "$(printf '%s\n' "$b" | tail -n 1)"
}

# No AGENTS.md: created with the block and kept out of git; re-init changes nothing.
test_agents_md_created_and_excluded() {
  local p out
  p=$(mk_tmpdir)
  mkdir -p "$p/.git/info"
  out=$(bash "$BRG_SRC" init "$p")
  assert_eq 0 "$?"
  assert_contains "$out" "создан AGENTS.md (только у тебя: исключён из git — чтобы коммитить, удали /AGENTS.md из .git/info/exclude)"
  assert_contains "$out" "Дальше скажи агенту в новой сессии: «подключись к бригаде»"
  assert_eq "$(am_block)" "$(cat "$p/AGENTS.md")"
  assert_eq "/AGENTS.md" "$(tail -n 1 "$p/.git/info/exclude")"
  assert_file_not_exists "$p/CLAUDE.md"
  cp "$p/AGENTS.md" "$p/a.before"
  cp "$p/.git/info/exclude" "$p/x.before"
  out=$(bash "$BRG_SRC" init "$p")
  assert_contains "$out" "AGENTS.md: блок brigada уже есть"
  same_bytes "$p/a.before" "$p/AGENTS.md" "re-init changed AGENTS.md"
  same_bytes "$p/x.before" "$p/.git/info/exclude" "re-init changed exclude"
  # /AGENTS.md already excluded by hand (CRLF): not added again
  rm "$p/AGENTS.md"
  printf 'AGENTS.md\r\n' >"$p/.git/info/exclude"
  bash "$BRG_SRC" init --no-agents-md "$p" >/dev/null || fail init
  cp "$p/.git/info/exclude" "$p/x.before"
  bash "$BRG_SRC" init "$p" >/dev/null || fail init
  same_bytes "$p/x.before" "$p/.git/info/exclude" "/AGENTS.md added twice"
}

# AGENTS.md of the project: content kept, the block appended after an empty line
# (a missing final newline added); re-init — one block, the file unchanged.
test_agents_md_appended_once() {
  local p out
  p=$(mk_tmpdir)
  mkdir -p "$p/.git/info"
  printf '# Правила\n\nтекст' >"$p/AGENTS.md"
  chmod 640 "$p/AGENTS.md"
  out=$(bash "$BRG_SRC" init "$p")
  assert_contains "$out" "блок brigada добавлен в AGENTS.md (файл, вероятно, в git — коммитить блок или нет, решай сам)"
  assert_contains "$out" "«подключись к бригаде»"
  { printf '# Правила\n\nтекст\n\n%s\n' "$(am_block)"; } >"$p/expected"
  same_bytes "$p/expected" "$p/AGENTS.md"
  assert_not_contains "$(cat "$p/.git/info/exclude")" "AGENTS.md"
  assert_contains "$(ls -l "$p/AGENTS.md")" "-rw-r-----" "mode kept"
  out=$(bash "$BRG_SRC" init "$p")
  assert_contains "$out" "AGENTS.md: блок brigada уже есть"
  same_bytes "$p/expected" "$p/AGENTS.md" "re-init"
  assert_eq 1 "$(am_count "$p/AGENTS.md")"
  # the file ends with an empty line already: no second one
  printf 'a\n\n' >"$p/AGENTS.md"
  bash "$BRG_SRC" init "$p" >/dev/null || fail init
  { printf 'a\n\n%s\n' "$(am_block)"; } >"$p/expected"
  same_bytes "$p/expected" "$p/AGENTS.md" "after an empty line"
}

# An old or edited block is replaced by the current one, the rest untouched;
# extra blocks go; begin without end — the file is not touched.
test_agents_md_old_block_replaced() {
  local p out
  p=$(mk_tmpdir)
  printf 'до\n\n<!-- brigada:begin — старый -->\nстарый текст\n<!-- brigada:end -->\n\nпосле\n<!-- brigada:begin -->\nдубль\n<!-- brigada:end -->\nконец\n' >"$p/AGENTS.md"
  out=$(bash "$BRG_SRC" init "$p")
  assert_contains "$out" "блок brigada обновлён в AGENTS.md"
  { printf 'до\n\n%s\n\nпосле\nконец\n' "$(am_block)"; } >"$p/expected"
  same_bytes "$p/expected" "$p/AGENTS.md"
  out=$(bash "$BRG_SRC" init "$p")
  assert_contains "$out" "AGENTS.md: блок brigada уже есть"
  same_bytes "$p/expected" "$p/AGENTS.md" "re-init"
  # the block is the last line, without a final newline: none is added
  printf 'x\n<!-- brigada:begin -->\nстарый\n<!-- brigada:end -->' >"$p/AGENTS.md"
  bash "$BRG_SRC" init "$p" >/dev/null || fail init
  printf 'x\n%s' "$(am_block)" >"$p/expected"
  same_bytes "$p/expected" "$p/AGENTS.md" "block at EOF"
  # begin without end: not touched, the full phrase
  printf 'x\n<!-- brigada:begin -->\nобрыв\n' >"$p/AGENTS.md"
  cp "$p/AGENTS.md" "$p/expected"
  out=$(bash "$BRG_SRC" init "$p")
  assert_eq 0 "$?"
  assert_contains "$out" "AGENTS.md: есть «<!-- brigada:begin», но нет «<!-- brigada:end» — не тронут"
  assert_contains "$out" "Дальше скажи агенту: «подключись к .brigada, прочитай инструкцию в .brigada/README.md»."
  same_bytes "$p/expected" "$p/AGENTS.md" "broken block"
}

# CRLF file: the block is written with CRLF, the rest untouched (also on update).
test_agents_md_crlf() {
  local p
  p=$(mk_tmpdir)
  printf '# P\r\nстрока\r\n' >"$p/AGENTS.md"
  bash "$BRG_SRC" init "$p" >/dev/null || fail init
  { printf '# P\r\nстрока\r\n\r\n'; am_block | awk '{ printf "%s\r\n", $0 }'; } >"$p/expected"
  same_bytes "$p/expected" "$p/AGENTS.md"
  bash "$BRG_SRC" init "$p" >/dev/null || fail init
  same_bytes "$p/expected" "$p/AGENTS.md" "re-init"
  printf '# P\r\n<!-- brigada:begin -->\r\nold\r\n<!-- brigada:end -->\r\nконец\r\n' >"$p/AGENTS.md"
  bash "$BRG_SRC" init "$p" >/dev/null || fail init
  { printf '# P\r\n'; am_block | awk '{ printf "%s\r\n", $0 }'; printf 'конец\r\n'; } >"$p/expected"
  same_bytes "$p/expected" "$p/AGENTS.md" "update"
}

# CLAUDE.md: importing AGENTS.md — untouched; without the import — the block;
# none — not created; a link to AGENTS.md — the same file, one block.
test_claude_md_rules() {
  local p out
  p=$(mk_tmpdir)
  printf '# Claude\n  @AGENTS.md \t\n' >"$p/CLAUDE.md"
  cp "$p/CLAUDE.md" "$p/expected"
  out=$(bash "$BRG_SRC" init "$p")
  assert_contains "$out" "CLAUDE.md импортирует AGENTS.md (@AGENTS.md) — не тронут"
  assert_contains "$out" "«подключись к бригаде»"
  same_bytes "$p/expected" "$p/CLAUDE.md" "@AGENTS.md"
  printf '@./AGENTS.md\n' >"$p/CLAUDE.md"
  cp "$p/CLAUDE.md" "$p/expected"
  bash "$BRG_SRC" init "$p" >/dev/null || fail init
  same_bytes "$p/expected" "$p/CLAUDE.md" "@./AGENTS.md"
  # only a whole-line import counts: an inline mention gets the block (Claude Code
  # may then see it twice — harmless; missing it would not be)
  printf '# Claude\nсм. @AGENTS.md выше\n' >"$p/CLAUDE.md"
  out=$(bash "$BRG_SRC" init "$p")
  assert_contains "$out" "блок brigada добавлен в CLAUDE.md"
  { printf '# Claude\nсм. @AGENTS.md выше\n\n%s\n' "$(am_block)"; } >"$p/expected"
  same_bytes "$p/expected" "$p/CLAUDE.md" "no import"
  out=$(bash "$BRG_SRC" init "$p")
  assert_contains "$out" "CLAUDE.md: блок brigada уже есть"
  same_bytes "$p/expected" "$p/CLAUDE.md" "re-init"
  # CLAUDE.md a link to AGENTS.md: written once, the link stays
  p=$(mk_tmpdir)
  printf 'общее\n' >"$p/AGENTS.md"
  ln -s AGENTS.md "$p/CLAUDE.md"
  out=$(bash "$BRG_SRC" init "$p")
  assert_contains "$out" "CLAUDE.md — тот же файл, что AGENTS.md"
  [ -L "$p/CLAUDE.md" ] || fail "the link replaced by a file"
  assert_eq 1 "$(am_count "$p/AGENTS.md")"
  # AGENTS.md a link to CLAUDE.md: written through the link
  p=$(mk_tmpdir)
  printf 'общее\n' >"$p/CLAUDE.md"
  ln -s CLAUDE.md "$p/AGENTS.md"
  bash "$BRG_SRC" init "$p" >/dev/null || fail init
  [ -L "$p/AGENTS.md" ] || fail "the link replaced by a file"
  assert_eq 1 "$(am_count "$p/CLAUDE.md")"
}

# --no-agents-md: neither file is created or changed (old blocks too), the full phrase.
test_init_no_agents_md() {
  local p out
  p=$(mk_tmpdir)
  mkdir -p "$p/.git/info"
  out=$(bash "$BRG_SRC" init --no-agents-md "$p")
  assert_eq 0 "$?"
  assert_contains "$out" "AGENTS.md и CLAUDE.md не тронуты (--no-agents-md)"
  assert_contains "$out" "Дальше скажи агенту: «подключись к .brigada, прочитай инструкцию в .brigada/README.md»."
  assert_not_contains "$out" "«подключись к бригаде»"
  assert_file_not_exists "$p/AGENTS.md"
  assert_file_not_exists "$p/CLAUDE.md"
  assert_not_contains "$(cat "$p/.git/info/exclude")" "AGENTS.md"
  printf '<!-- brigada:begin -->\nстарый\n<!-- brigada:end -->\n' >"$p/AGENTS.md"
  printf 'claude\n' >"$p/CLAUDE.md"
  cp "$p/AGENTS.md" "$p/a.before"
  cp "$p/CLAUDE.md" "$p/c.before"
  bash "$BRG_SRC" init "$p" --no-agents-md >/dev/null || fail init
  same_bytes "$p/a.before" "$p/AGENTS.md"
  same_bytes "$p/c.before" "$p/CLAUDE.md"
  out=$(bash "$BRG_SRC" init --help)
  assert_contains "$out" "--no-agents-md"
  out=$(bash "$BRG_SRC" init --no-such 2>&1)
  assert_eq 1 "$?"
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
