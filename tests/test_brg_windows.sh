# Windows artifacts that can be checked without Windows — bin/brg.cmd
# (static checks), .gitattributes, the CRLF guard of brg, init copying brg.cmd.
# The real check on Windows is WINDOWS.md.

. "$TESTS_DIR/brg_lib.sh"

CMDF=$ROOT/bin/brg.cmd

# lines of FILE: "<lines> <lines ending with CR> <lines with non-ASCII bytes>"
line_stats() {
  LC_ALL=C awk -v cr="$(printf '\r')" '{ t++; if (substr($0, length($0), 1) == cr) c++; if ($0 ~ /[\200-\377]/) u++ }
    END { print t + 0, c + 0, u + 0 }' "$1"
}

test_brg_cmd_is_ascii_with_crlf() {
  local s
  assert_file_exists "$CMDF"
  s=$(line_stats "$CMDF")
  set -- $s
  [ "$1" -gt 20 ] || fail "brg.cmd too short: $1 lines"
  assert_eq "$1" "$2" "every line of brg.cmd must end with CRLF ($s)"
  assert_eq 0 "$3" "brg.cmd must be ASCII"
  # the last byte: a line feed (a final line without CRLF confuses cmd)
  assert_eq 0a "$(tail -c 1 "$CMDF" | od -An -tx1 | tr -d ' \n')"
}

# The bash of Git for Windows is looked up in the documented order; bash from
# PATH (may be WSL's System32\bash.exe) is never run.
test_brg_cmd_finds_git_bash_not_wsl() {
  local t n prev=0 x
  t=$(tr -d '\r' <"$CMDF")
  # search order: BRG_BASH, ProgramFiles, ProgramFiles(x86), LOCALAPPDATA, where git
  for x in 'if exist "%BRG_BASH%"' \
    'if exist "%ProgramFiles%\Git\bin\bash.exe"' \
    'if exist "%ProgramFiles(x86)%\Git\bin\bash.exe"' \
    'if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe"' \
    "('where git 2^>nul')"; do
    n=$(printf '%s\n' "$t" | S=$x awk 'index($0, ENVIRON["S"]) { print NR; exit }')
    [ -n "$n" ] || fail "brg.cmd: no [$x]"
    [ "$n" -gt "$prev" ] || fail "brg.cmd: [$x] out of order (line $n after $prev)"
    prev=$n
  done
  assert_contains "$t" 'if exist "%BRG_G%..\bin\bash.exe"' "git root from <root>\\cmd\\git.exe"
  assert_contains "$t" 'if exist "%BRG_G%..\..\bin\bash.exe"' "git root from <root>\\mingw64\\bin\\git.exe"
  # never a bare bash (PATH): every run of bash goes through the found path
  n=$(printf '%s\n' "$t" | awk 'tolower($0) ~ /^[ \t]*(call[ \t]+)?bash(\.exe)?([ \t]|$)/' | wc -l | tr -d ' ')
  assert_eq 0 "$n" "brg.cmd runs bash from PATH"
  assert_contains "$t" '"%BRG_SH%" "%BRG_SCRIPT%" %*'
  assert_contains "$t" 'goto brg_wsl' "WSL bash refused"
  assert_contains "$t" '%BRG_SH:\System32\=%'
  assert_contains "$t" "Install Git for Windows"
  assert_contains "$t" "set BRG_BASH"
  # brg next to it, with forward slashes; the exit code of brg is kept
  assert_contains "$t" 'set "BRG_SCRIPT=%~dp0brg"'
  assert_contains "$t" 'set "BRG_SCRIPT=%BRG_SCRIPT:\=/%"'
  assert_contains "$t" 'set "BRG_RC=%ERRORLEVEL%"'
  assert_contains "$t" 'exit /b %BRG_RC%'
  assert_contains "$t" 'set "BRG_VIA_CMD=%~f0"'
  # code page: UTF-8 for the call, the old one restored, an opt-out
  assert_contains "$t" 'chcp 65001 >nul 2>&1'
  assert_contains "$t" 'chcp %BRG_CP% >nul 2>&1'
  assert_contains "$t" 'if defined BRG_NO_CHCP goto brg_exec'
  # no parenthesized blocks: %ProgramFiles(x86)% would close them early
  n=$(printf '%s\n' "$t" | awk '!/^rem/ && /\($/' | wc -l | tr -d ' ')
  assert_eq 0 "$n" "brg.cmd has a ( block"
  assert_contains "$t" 'setlocal EnableExtensions DisableDelayedExpansion'
}

test_gitattributes_fix_line_endings() {
  local f=$ROOT/.gitattributes t x
  assert_file_exists "$f"
  t=$(cat "$f")
  for x in 'bin/brg text eol=lf' '*.sh text eol=lf' 'template/* text eol=lf' '*.cmd text eol=crlf'; do
    printf '%s\n' "$t" | awk -v l="$x" '$0 == l { f = 1 } END { exit !f }' || fail ".gitattributes: no line [$x]"
  done
  if command -v git >/dev/null 2>&1 && [ -d "$ROOT/.git" ]; then
    assert_contains "$(cd "$ROOT" && git check-attr eol -- bin/brg)" "eol: lf"
    assert_contains "$(cd "$ROOT" && git check-attr eol -- bin/brg.cmd)" "eol: crlf"
    assert_contains "$(cd "$ROOT" && git check-attr eol -- template/README.md)" "eol: lf"
    assert_contains "$(cd "$ROOT" && git check-attr eol -- tests/run.sh)" "eol: lf"
  fi
  # the files themselves are as the attributes say
  set -- $(line_stats "$ROOT/bin/brg")
  assert_eq 0 "$2" "bin/brg has CRLF lines"
  for x in "$ROOT"/template/*; do
    set -- $(line_stats "$x")
    assert_eq 0 "$2" "$x has CRLF lines"
  done
}

# init copies brg.cmd byte for byte (CRLF kept); re-init updates it.
test_init_installs_brg_cmd() {
  new_proj
  assert_file_exists "$B/bin/brg.cmd"
  cmp -s "$CMDF" "$B/bin/brg.cmd" 2>/dev/null || [ "$(od -c <"$CMDF")" = "$(od -c <"$B/bin/brg.cmd")" ] ||
    fail "brg.cmd changed by init"
  printf 'old\r\n' >"$B/bin/brg.cmd"
  bash "$BRG_SRC" init "$P" >/dev/null || fail reinit
  [ "$(od -c <"$CMDF")" = "$(od -c <"$B/bin/brg.cmd")" ] || fail "re-init did not update brg.cmd"
}

# brg read with CRLF line endings (autocrlf=true) explains itself instead of
# failing with a syntax error, and exits with code 2.
test_crlf_brg_explains_itself() {
  local d out rc
  d=$(mk_tmpdir)
  awk '{ printf "%s\r\n", $0 }' "$BRG_SRC" >"$d/brg"
  out=$(bash "$d/brg" help 2>&1)
  rc=$?
  assert_eq 2 "$rc"
  assert_contains "$out" "окончания строк CRLF (Windows) — bash его не выполнит"
  assert_contains "$out" "git checkout -- bin/brg"
  assert_contains "$out" "doctor"
  assert_not_contains "$out" "syntax error"
  assert_not_contains "$out" "command not found"
}

# bin/brg.cmd passes the script as C:/…/brg; brg also splits a path with
# backslashes (C:\…\brg) on "\" to find its .brigada. (On macOS/Linux a backslash
# is an ordinary file-name character, so only the expression is checked here.)
test_backslash_script_path() {
  local out
  assert_contains "$(sed -n '1,40p' "$BRG_SRC")" '_brg_src=${_brg_src//\\//}'
  out=$(bash -c '_brg_src=$1; _brg_src=${_brg_src//\\//}; echo "${_brg_src%/*}"' _ 'C:\toy\.brigada\bin\brg')
  assert_eq "C:/toy/.brigada/bin" "$out"
}
