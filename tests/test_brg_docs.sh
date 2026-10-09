# The agent docs (template/README.md, template/PROTOCOL.md) and WINDOWS.md
# mention only commands, subcommands and flags that brg really has: every
# `brg <cmd> [<sub>] …` (in code spans and code blocks; in PROTOCOL also the bare
# form `item claim …`) answers `<cmd> [<sub>] --help` with code 0 and lists each
# of its --flags in that help; a lone `--flag` must exist in some command's help.

. "$TESTS_DIR/brg_lib.sh"

DOC_CMDS="join leave send wait read who tail say status stop resume task lead host item run doctor init board help"
NL=$'\n'
US=$'\037' # field separator of doc_invocations (tabs would collapse in read)

# doc_invocations FILE — one line per invocation: "cmd US sub US  --flag --flag"
# or "FLAG US US  --flag" for a code span that is just flags (`--reply-by 10m`);
# spans of other programs (git, Set-Content, …) are skipped
doc_invocations() {
  awk -v cmds="$DOC_CMDS" -v US="$US" '
    BEGIN { n = split(cmds, a, " "); for (i = 1; i <= n; i++) known[a[i]] = 1 }
    function clean(w) { sub(/^[\[("«'"'"']+/, "", w); sub(/[\])"»,.;:'"'"']+$/, "", w); return w }
    function emit(t, s, n,   cmd, sb, fl, j, w) {
      cmd = clean(t[s])
      if (cmd !~ /^[a-z]/) return # a placeholder: <команда>, …
      sb = ""
      if (t[s + 1] ~ /^[a-z]+$/) sb = t[s + 1]
      fl = ""
      for (j = s + 1; j <= n; j++) {
        if (t[j] == "--" || t[j] == "·") break
        w = clean(t[j])
        if (w ~ /^--[a-z][a-z-]*$/) fl = fl " " w
      }
      printf "%s%s%s%s%s\n", cmd, US, sb, US, fl
    }
    function scan(seg,   k, n, t, i, found, w, fl) {
      k = index(seg, " # "); if (k) seg = substr(seg, 1, k - 1)
      sub(/^[ \t]+/, "", seg)
      n = split(seg, t, /[ \t]+/)
      found = 0
      for (i = 1; i <= n; i++)
        if (t[i] ~ /(^|[\/\\])brg(\.cmd)?$/ && (i == 1 || t[i - 1] == "bash")) { found = 1; emit(t, i + 1, n) }
      if (found) return
      if (t[1] in known) { emit(t, 1, n); return }
      if (t[1] !~ /^--/) return
      fl = ""
      for (i = 1; i <= n; i++) { w = clean(t[i]); if (w ~ /^--[a-z][a-z-]*$/) fl = fl " " w }
      if (fl != "") printf "FLAG%s%s%s\n", US, US, fl
    }
    /^[ \t]*```/ { fence = !fence; next }
    fence { scan($0); next }
    {
      s = $0
      while ((i = index(s, "`")) > 0) {
        s = substr(s, i + 1)
        j = index(s, "`")
        if (j == 0) break
        scan(substr(s, 1, j - 1))
        s = substr(s, j + 1)
      }
    }' "$1"
}

# has_flag HELP FLAG — FLAG appears in HELP as a whole flag
has_flag() {
  case "$1 " in
    *"$2 "* | *"$2]"* | *"$2|"* | *"$2="* | *"$2,"* | *"$2)"* | *"$2"$'\n'*) return 0 ;;
  esac
  return 1
}

test_docs_mention_only_real_commands_and_flags() {
  local f cmd sb flags x help all= n=0 rc subs errs=
  new_proj
  for cmd in $DOC_CMDS; do
    all="$all$(brg "$cmd" --help 2>&1)$NL"
  done
  all="$all$(brg help)"
  for f in "$ROOT/template/README.md" "$ROOT/template/PROTOCOL.md" "$ROOT/WINDOWS.md"; do
    assert_file_exists "$f"
    while IFS=$US read -r cmd sb flags; do
      n=$((n + 1))
      if [ "$cmd" = FLAG ]; then
        for x in $flags; do
          has_flag "$all" "$x" || errs="$errs${NL}${f##*/}: флага $x нет ни в одной справке brg"
        done
        continue
      fi
      case " $DOC_CMDS " in
        *" $cmd "*) ;;
        *)
          errs="$errs${NL}${f##*/}: нет команды brg $cmd"
          continue
          ;;
      esac
      help=$(brg "$cmd" --help 2>&1)
      rc=$?
      [ "$rc" -eq 0 ] || errs="$errs${NL}${f##*/}: brg $cmd --help → код $rc"
      subs=
      case $cmd in
        task) subs="new close cancel show list" ;;
        lead | host) subs="give take" ;;
        item) subs="add claim done release reassign review cancel list show" ;;
        run) subs="list show cancel" ;;
        *) sb= ;; # a lowercase argument (doctor <dir>, tail lobby), not a subcommand
      esac
      if [ -n "$sb" ]; then
        case " $subs " in
          *" $sb "*)
            brg "$cmd" "$sb" --help >/dev/null 2>&1 || errs="$errs${NL}${f##*/}: brg $cmd $sb --help → ошибка"
            ;;
          *) errs="$errs${NL}${f##*/}: нет подкоманды brg $cmd $sb" ;;
        esac
      fi
      for x in $flags; do
        has_flag "$help" "$x" || errs="$errs${NL}${f##*/}: у brg $cmd${sb:+ $sb} нет флага $x"
      done
    done <<EOF
$(doc_invocations "$f")
EOF
  done
  [ -z "$errs" ] || fail "расхождения доков и brg:$errs"
  [ "$n" -gt 40 ] || fail "too few command mentions found ($n): the extractor is broken?"
}

# The extractor itself: catches a wrong command, subcommand and flag.
test_docs_checker_catches_mistakes() {
  local d out
  d=$(mk_tmpdir)
  cat >"$d/bad.md" <<'EOF'
Текст `bash .brigada/bin/brg frob --as x` и `item clam I001 --paths a`.
```
bash .brigada/bin/brg send --as x --tooo all
.\.brigada\bin\brg.cmd wait --as x --timeout 5 -- --not-a-flag
git ls-files --eol bin/brg bin/brg.cmd
```
Одиночный флаг `--reply-by 10m` и `--no-such`.
EOF
  out=$(doc_invocations "$d/bad.md" | tr "$US" '|')
  assert_contains "$out" "frob||"
  assert_contains "$out" "item|clam| --paths"
  assert_contains "$out" "send|| --as --tooo"
  assert_contains "$out" "wait|| --as --timeout"
  assert_not_contains "$out" "--not-a-flag"
  assert_not_contains "$out" "eol"
  assert_contains "$out" "FLAG|| --reply-by"
  assert_contains "$out" "FLAG|| --no-such"
}
