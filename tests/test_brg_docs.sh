# The docs (DOCS_CLI: README, DESIGN, AGENTS, bin/README, template/*.md, WINDOWS)
# mention only commands, subcommands and flags that brg really has: every
# `brg <cmd> [<sub>] …` (in code spans and code blocks; in PROTOCOL also the bare
# form `item claim …`) answers `<cmd> [<sub>] --help` with code 0 and lists each
# of its --flags in that help; a lone `--flag` must exist in some command's help.
# Language (D11): in the English docs (DOCS_EN) and in code comments Cyrillic stands only
# inside quotes. Links: markdown links, `§N` (and its items), and the PROTOCOL / README
# section references lead to an existing heading, section or item. Markers: no history
# or unfinished-work markers in the docs (marker_check).

. "$TESTS_DIR/brg_lib.sh"

DOC_CMDS="join leave busy send wait read who tail say status stop pause resume task lead item run doctor init board spawn help"
NL=$'\n'
US=$'\037' # field separator of doc_invocations (tabs would collapse in read)

# Flags of other programs, written alone in a code span: FLAG=WORDS — the flag counts as that
# program's (and is not checked against brg) only when its line names the program (a word
# of the |-list, case-sensitive). In `brg <cmd> …` spans every flag is brg's: a wrong
# `brg wait --format` fails.
EXT_FLAGS="--sandbox=Codex --auto=OpenCode|opencode --format=OpenCode|opencode --continue=OpenCode|opencode|supervisor|__spawn --session=OpenCode|opencode --standalone=OpenCode|opencode --root=server|brg-serve --ready=server|brg-serve --alive=server|brg-serve --retry-any=server|brg-serve --eol=git"

# doc_invocations FILE — one line per invocation: "cmd US sub US  --flag --flag"
# or "FLAG US US  --flag" for a code span that is just flags (`--reply-by 10m`);
# spans of other programs (git, Set-Content, …) are skipped, and so are lone flags of
# other programs in their program's context (EXT_FLAGS) and `--help` (every command has it)
doc_invocations() {
  awk -v cmds="$DOC_CMDS" -v US="$US" -v ext="$EXT_FLAGS" '
    BEGIN {
      n = split(cmds, a, " "); for (i = 1; i <= n; i++) known[a[i]] = 1
      n = split(ext, a, " "); for (i = 1; i <= n; i++) { k = index(a[i], "="); ctx[substr(a[i], 1, k - 1)] = substr(a[i], k + 1) }
    }
    function foreign(w,   n, b, i) {
      if (!(w in ctx)) return 0
      n = split(ctx[w], b, "|")
      for (i = 1; i <= n; i++) if (index($0, b[i])) return 1
      return 0
    }
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
      for (i = 1; i <= n; i++) { w = clean(t[i]); if (w ~ /^--[a-z][a-z-]*$/ && w != "--help" && !foreign(w)) fl = fl " " w }
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

# The docs whose brg commands and flags are checked (C10; not board.html)
DOCS_CLI="README.md DESIGN.md AGENTS.md bin/README.md template/README.md template/PROTOCOL.md WINDOWS.md"

test_docs_mention_only_real_commands_and_flags() {
  local f cmd sb flags x help all= n=0 rc subs errs=
  new_proj
  for cmd in $DOC_CMDS; do
    all="$all$(brg "$cmd" --help 2>&1)$NL"
  done
  all="$all$(brg help)"
  for f in $DOCS_CLI; do
    f=$ROOT/$f
    assert_file_exists "$f"
    while IFS=$US read -r cmd sb flags; do
      n=$((n + 1))
      if [ "$cmd" = FLAG ]; then
        for x in $flags; do
          has_flag "$all" "$x" || errs="$errs${NL}${f##*/}: no brg help has the flag $x"
        done
        continue
      fi
      case " $DOC_CMDS " in
        *" $cmd "*) ;;
        *)
          errs="$errs${NL}${f##*/}: no command brg $cmd"
          continue
          ;;
      esac
      help=$(brg "$cmd" --help 2>&1)
      rc=$?
      [ "$rc" -eq 0 ] || errs="$errs${NL}${f##*/}: brg $cmd --help → exit code $rc"
      subs=
      case $cmd in
        task) subs="new close cancel show list" ;;
        lead) subs="give take" ;;
        item) subs="add claim done release reassign review cancel list show" ;;
        run) subs="list show cancel" ;;
        spawn) subs="list show wake rm detach rights opencode" ;; # opencode: the harness argument
        *) sb= ;; # a lowercase argument (doctor <dir>, tail lobby), not a subcommand
      esac
      if [ -n "$sb" ]; then
        case " $subs " in
          *" $sb "*)
            brg "$cmd" "$sb" --help >/dev/null 2>&1 || errs="$errs${NL}${f##*/}: brg $cmd $sb --help → an error"
            ;;
          *) errs="$errs${NL}${f##*/}: no subcommand brg $cmd $sb" ;;
        esac
      fi
      for x in $flags; do
        [ "$x" = --help ] && continue
        has_flag "$help" "$x" || errs="$errs${NL}${f##*/}: brg $cmd${sb:+ $sb} has no flag $x"
      done
    done <<EOF
$(doc_invocations "$f")
EOF
  done
  [ -z "$errs" ] || fail "docs and brg disagree:$errs"
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
Одиночный флаг `--reply-by 10m` и `--no-such`; `--help`.
Codex: `--sandbox danger-full-access`; OpenCode `--auto`.
Без контекста: `--sandbox x`; `brg wait --format json`.
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
  assert_not_contains "$out" "--help"
  assert_not_contains "$out" "--auto"
  assert_contains "$out" "wait|| --format"
  # --sandbox counts only once: on the line without its program
  assert_eq 1 "$(printf '%s\n' "$out" | grep -c -- '--sandbox')" "--sandbox outside Codex: $out"
}

# ── Language (D11) ─────────────────────────────────────────────────────────
# Language lint (D11): Cyrillic outside quotes in English docs and in code comments.
# lang_check MODE FILE — MODE: sh (bash: lines that start with #), py (# lines outside
# triple-quoted strings), js (// lines inside <script>), md (all prose outside fenced code).
# Prints "FILE:LINE: text" for each offending line and "FILE: lost track …" when the
# parser ends inside a quote or a heredoc (then its skipping cannot be trusted).
# Quotes are `…`, "…", «…»; a quote may continue on the next comment line (paragraph in md);
# in md, fenced code and link targets (the part in parentheses of [text](target)) are skipped too.
# Known limit: a trailing comment after code (`cmd # …`) is not checked — `#` after code
# cannot be told from ${x#…} without a real parser.
lang_check() {
  LC_ALL=C awk -v mode="$1" -v c1="$(printf '\320')" -v c2="$(printf '\321')" \
    -v c3="$(printf '\322')" -v c4="$(printf '\323')" -v lq="«" -v rq="»" '
    function cyr(s) { return index(s, c1) || index(s, c2) || index(s, c3) || index(s, c4) }
    # unquote(s): s without quoted parts; CQ — the quote left open at the end (carried over)
    function unquote(s,   out, i, c, cl, k) {
      out = ""
      while (s != "") {
        if (CQ != "") {
          i = index(s, CQ)
          if (i == 0) return out
          s = substr(s, i + length(CQ)); CQ = ""
          continue
        }
        # the earliest opener
        i = 0; c = ""
        if ((k = index(s, "`")) && (i == 0 || k < i)) { i = k; c = "`"; cl = "`" }
        if ((k = index(s, "\"")) && (i == 0 || k < i)) { i = k; c = "\""; cl = "\"" }
        if ((k = index(s, lq)) && (i == 0 || k < i)) { i = k; c = lq; cl = rq }
        if (i == 0) return out s
        out = out substr(s, 1, i - 1)
        s = substr(s, i + length(c)); CQ = cl
      }
      return out
    }
    function check(text) { if (cyr(unquote(text))) printf "%s:%d: %s\n", FILENAME, FNR, $0 }
    # sh_code(line): walk the code of a bash line, keep Q (open quote) and queue heredocs
    function sh_code(l,   n, i, c, p, j, w, dash) {
      n = length(l); p = " "
      for (i = 1; i <= n; i++) {
        c = substr(l, i, 1)
        if (Q == "\047") { if (c == "\047") Q = ""; p = c; continue }
        if (Q == "$\047") { if (c == "\\") i++; else if (c == "\047") Q = ""; p = c; continue }
        if (Q == "\"") { if (c == "\\") i++; else if (c == "\"") Q = ""; p = c; continue }
        if (c == "\\") { i++; p = "x"; continue }
        if (c == "\047") { Q = (p == "$") ? "$\047" : "\047"; p = c; continue }
        if (c == "\"") { Q = "\""; p = c; continue }
        if (c == "#" && p ~ /[ \t;|&(]/) return
        if (c == "<" && substr(l, i, 2) == "<<" && substr(l, i, 3) != "<<<" && p != "<") {
          j = i + 2; dash = 0
          if (substr(l, j, 1) == "-") { dash = 1; j++ }
          while (substr(l, j, 1) ~ /[ \t]/) j++
          if (substr(l, j, 1) ~ /[\047"]/) j++
          w = ""
          while (substr(l, j, 1) ~ /[A-Za-z0-9_]/) { w = w substr(l, j, 1); j++ }
          if (substr(l, j, 1) ~ /[\047"]/) j++
          if (w != "") { HN++; HW[HN] = w; HD[HN] = dash }
          i = j - 1; p = "x"; continue
        }
        p = c
      }
    }
    FNR == 1 { Q = ""; CQ = ""; HN = 0; HI = 1; TQ = ""; SCRIPT = 0; FENCE = 0 }
    mode == "sh" {
      if (HI <= HN) { # a heredoc body
        w = $0; if (HD[HI]) sub(/^\t+/, "", w)
        if (w == HW[HI]) HI++
        if (HI > HN) { HN = 0; HI = 1 }
        next
      }
      if (Q == "" && $0 ~ /^[ \t]*#/) {
        if (FNR == 1 && $0 ~ /^#!/) next
        t = $0; sub(/^[ \t]*#+/, "", t); check(t); next
      }
      CQ = ""
      sh_code($0)
      next
    }
    mode == "py" {
      if (TQ == "" && $0 ~ /^[ \t]*#/) { t = $0; sub(/^[ \t]*#+/, "", t); check(t); next }
      CQ = ""
      s = $0
      while (s != "") {
        if (TQ != "") { i = index(s, TQ); if (!i) break; s = substr(s, i + 3); TQ = ""; continue }
        a = index(s, "\"\"\""); b = index(s, "\047\047\047")
        if (!a && !b) break
        if (a && (!b || a < b)) { TQ = "\"\"\""; s = substr(s, a + 3) } else { TQ = "\047\047\047"; s = substr(s, b + 3) }
      }
      next
    }
    mode == "js" {
      if ($0 ~ /<script[ >]/) { SCRIPT = 1; next }
      if ($0 ~ /<\/script>/) { SCRIPT = 0; next }
      if (!SCRIPT) next
      if ($0 ~ /^[ \t]*\/\//) { t = $0; sub(/^[ \t]*\/\/+/, "", t); check(t); next }
      CQ = ""
      next
    }
    mode == "md" {
      if ($0 ~ /^[ \t]*```/) { FENCE = !FENCE; CQ = ""; next }
      if (FENCE) next
      if ($0 ~ /^[ \t]*$/) { CQ = ""; next }
      # link targets are paths and anchors, not prose: [text](target) → [text]
      t = ""; s = $0
      while ((i = index(s, "](")) > 0 && (j = index(substr(s, i + 2), ")")) > 0) { t = t substr(s, 1, i); s = substr(s, i + 2 + j) }
      check(t s)
      next
    }
    END {
      if (mode == "sh" && (Q != "" || HI <= HN)) printf "%s: lost track: the file ends inside %s\n", FILENAME, (Q != "" ? "a quote " Q : "a heredoc " HW[HI])
      if (mode == "py" && TQ != "") printf "%s: lost track: the file ends inside %s\n", FILENAME, TQ
      if (mode == "md" && FENCE) printf "%s: lost track: an unclosed code fence\n", FILENAME
    }' "$2"
}

# ── Links ──────────────────────────────────────────────────────────────────
# Russian upper/lower case pairs for the GitHub slug (two-byte literals, as in bin/brg)
RU_UP="АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ"
RU_LO="абвгдеёжзийклмнопрстуфхцчшщъыьэюя"

# md_headings FILE — the GitHub anchors of FILE, one per line (outside fenced code):
# lowercase (ASCII and Russian Cyrillic), punctuation dropped, spaces → "-", repeats get -1, -2…
md_headings() {
  LC_ALL=C awk -v up="$RU_UP" -v lo="$RU_LO" '
    BEGIN { for (i = 1; i < length(up); i += 2) L[substr(up, i, 2)] = substr(lo, i, 2) }
    function slug(s,   o, i, n, c, k, len) {
      o = ""; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c ~ /[A-Z]/) { o = o tolower(c); continue }
        if (c ~ /[a-z0-9_-]/) { o = o c; continue }
        if (c == " ") { o = o "-"; continue }
        if (c < "\200") continue # ASCII punctuation
        len = (c >= "\360") ? 4 : (c >= "\340") ? 3 : 2
        k = substr(s, i, len); i += len - 1
        if (c == "\320" || c == "\321") { o = o ((k in L) ? L[k] : k); continue }
        if (c == "\302" || c == "\342" || c == "\343" || c >= "\360") continue # punctuation, symbols, emoji
        o = o k # other letters as they are
      }
      return o
    }
    /^[ \t]*```/ { f = !f; next }
    f { next }
    /^#+ / { h = $0; sub(/^#+ +/, "", h); sub(/[ #]+$/, "", h); s = slug(h); if (s in seen) print s "-" seen[s]++; else { print s; seen[s] = 1 } }
  ' "$1"
}

# design_index DESIGN — "S N" for each numbered section, "I N M" for item M of section N
# (a top-level "M. " line between the heading of N and the next numbered heading)
sec_index() {
  LC_ALL=C awk '
    /^[ \t]*```/ { f = !f; next }
    f { next }
    /^#+ [0-9]+(\.[0-9]+)*\.? / { s = $2; sub(/\.$/, "", s); print "S " s; next }
    /^#+ / { next }
    s != "" && /^[0-9]+\. / { m = $1; sub(/\.$/, "", m); print "I " s " " m }
  ' "$1"
}

# link_check ROOT FILE… — references that lead nowhere, one "FILE:LINE: what" per line:
#   markdown links (path, path#anchor, #anchor) in .md files (relative to the file);
#   `§N`, `§N п. M` / `§N item M` → DESIGN.md (ROOT/DESIGN.md);
#   «PROTOCOL…, раздел N[, п. M]» / «PROTOCOL…, section N[, item M]» → template/PROTOCOL.md,
#   «README…, раздел N[, п. M]» → template/README.md; a bare «раздел N» inside those two
#   files means the file itself.
link_check() {
  local root=$1 f d idx g m w
  shift
  idx=$(mk_tmpdir)/idx
  { sec_index "$root/DESIGN.md" | sed 's/^/D /'
    sec_index "$root/template/PROTOCOL.md" | sed 's/^/P /'
    sec_index "$root/template/README.md" | sed 's/^/R /'
    for g in "$root"/*.md "$root"/template/*.md "$root"/bin/*.md; do
      [ -f "$g" ] || continue
      md_headings "$g" | sed "s|^|H $g#|"
    done; } >"$idx"
  for f in "$@"; do
    d=${f%/*} m= w=
    case $f in *.md) m=1 ;; esac
    case $f in */template/PROTOCOL.md) w=P ;; */template/README.md) w=R ;; esac
    LC_ALL=C awk -v idx="$idx" -v dir="$d" -v md="$m" -v self="$w" \
      -v sect="§" -v razd="раздел" -v pt="п." '
      BEGIN { while ((getline l < idx) > 0) have[l] = 1 }
      function bad(what) { printf "%s:%d: %s\n", FILENAME, FNR, what }
      # norm(p): drop "/./" and "dir/.." from a path
      function norm(p,   o) {
        while (sub(/\/\.\//, "/", p)) ;
        while (match(p, /\/[^\/]+\/\.\.\//)) p = substr(p, 1, RSTART) substr(p, RSTART + RLENGTH)
        return p
      }
      # num(s): the leading N or N.M… of s ("" if none)
      function num(s) { if (match(s, /^[0-9]+(\.[0-9]+)*/)) return substr(s, 1, RLENGTH); return "" }
      # item(s): M of a following ", п. M" / " п. M" / " item M" / ", item M" ("" if none)
      function item(s,   t) {
        t = s; sub(/^,? +/, "", t)
        if (substr(t, 1, length(pt)) == pt) { t = substr(t, length(pt) + 1); sub(/^ +/, "", t); return num(t) }
        if (substr(t, 1, 5) == "item ") { t = substr(t, 6); sub(/^ +/, "", t); return num(t) }
        return ""
      }
      function ref(doc, name, s,   n, m) {
        n = num(s); if (n == "") return
        if (!(("D" == doc ? "D" : doc) " S " n in have)) { bad(name " " n ": no such section"); return }
        m = item(substr(s, length(n) + 1))
        if (m != "" && !((doc " I " n " " m) in have)) bad(name " " n ", item " m ": no such item")
      }
      /^[ \t]*```/ { fence = !fence }
      {
        line = $0
        # §N [п. M | item M] → DESIGN
        s = line
        while ((i = index(s, sect)) > 0) { s = substr(s, i + length(sect)); ref("D", "§", s) }
        # раздел N / section N after PROTOCOL or README (or bare «раздел» inside those files)
        s = line; pre = ""
        while (1) {
          i = index(s, razd); j = index(s, "section ")
          if (!i && !j) break
          if (i && (!j || i < j)) { k = i; w = razd } else { k = j; w = "section " }
          pre = pre substr(s, 1, k - 1); s = substr(s, k + length(w))
          t = s; sub(/^[^ 0-9]*/, "", t); sub(/^ +/, "", t) # «разделе 3», «раздела 4»
          back = substr(pre, length(pre) > 40 ? length(pre) - 40 : 1)
          p = 0; r = 0
          for (q = 1; (z = index(substr(back, q), "PROTOCOL")) > 0; q += z) p = q + z
          for (q = 1; (z = index(substr(back, q), "README")) > 0; q += z) r = q + z
          if (p > r) doc = "P"; else if (r > p) doc = "R"; else doc = self
          if (doc == "" || (w != razd && doc != "P")) continue
          ref(doc, (doc == "P" ? "PROTOCOL" : "README") " " (w == razd ? "раздел" : "section"), t)
        }
        # markdown links
        if (!md || fence) next
        s = line
        while ((i = index(s, "](")) > 0) {
          s = substr(s, i + 2); j = index(s, ")"); if (!j) break
          u = substr(s, 1, j - 1); s = substr(s, j + 1)
          sub(/ .*/, "", u)
          if (u ~ /^[a-z]+:/ || u == "") continue
          file = u; anc = ""
          if ((k = index(u, "#")) > 0) { file = substr(u, 1, k - 1); anc = substr(u, k + 1) }
          path = norm((file == "") ? FILENAME : dir "/" file)
          if (file != "" && system("[ -e \"" path "\" ]") != 0) { bad("link " u ": no file"); continue }
          if (anc == "" || path !~ /\.md$/) continue
          if (!(("H " path "#" anc) in have)) bad("link " u ": no such heading")
        }
      }' "$f"
  done
}

# The English docs (D11)
DOCS_EN="AGENTS.md README.md WINDOWS.md DESIGN.md bin/README.md"

# lang_tree ROOT — lang_check over the English docs and the code comments of ROOT
lang_tree() {
  local f
  for f in $DOCS_EN; do lang_check md "$1/$f"; done
  for f in "$1"/bin/brg "$1"/bin/brg-global "$1"/install.sh "$1"/tests/*.sh "$1"/tests/fake_opencode; do
    [ -f "$f" ] && lang_check sh "$f"
  done
  lang_check py "$1/bin/brg-serve.py"
  lang_check js "$1/template/board.html"
  # brg.cmd (REM/:: comments) must be plain ASCII anyway: cmd.exe reads it in the OEM code page
  LC_ALL=C awk '/[\200-\377]/ { printf "%s:%d: not ASCII\n", FILENAME, FNR }' "$1/bin/brg.cmd"
}

test_docs_language() {
  local out
  out=$(lang_tree "$ROOT")
  [ -z "$out" ] || fail "Cyrillic outside quotes in an English doc or a code comment:$NL$out"
}

# The language checker on fixtures: what it flags and what it skips.
test_docs_language_checker() {
  local d out
  d=$(mk_tmpdir)
  cat >"$d/a.sh" <<'EOF'
#!/usr/bin/env bash
# good: the output «пауза снята», "нет новых" and `brg say` are quoted
# good: a quote may go on «на следующую
# строку» of the comment
# bad: здесь проза
x=${y#*a} # trailing: не проверяется (known limit)
cat <<'BRG_EOF'
# inside a heredoc: проза
BRG_EOF
cat <<-END
	# inside a dash heredoc: проза
	END
awk '
  # inside a quoted multi-line string: проза
' /dev/null
s="a multi-line
# string: проза
"
  # bad, indented: снова проза
EOF
  out=$(lang_check sh "$d/a.sh")
  assert_contains "$out" "a.sh:5: # bad: здесь проза"
  assert_contains "$out" "a.sh:19:   # bad, indented: снова проза"
  assert_eq 2 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "only the two bad lines: $out"
  printf '%s\n' 's="never closed' '# проза' >"$d/b.sh"
  assert_contains "$(lang_check sh "$d/b.sh")" "lost track"
  cat >"$d/a.py" <<'EOF'
# good: «ответ» is quoted
# bad: проза
x = """
# not a comment: проза
"""
EOF
  out=$(lang_check py "$d/a.py")
  assert_contains "$out" "a.py:2:"
  assert_not_contains "$out" "a.py:4:"
  cat >"$d/a.html" <<'EOF'
<p>// outside the script: проза</p>
<script>
  // good: "назад"
  // bad: проза
  let x = 'проза в коде';
</script>
EOF
  out=$(lang_check js "$d/a.html")
  assert_eq "$d/a.html:4:   // bad: проза" "$out"
  cat >"$d/a.md" <<'EOF'
Say «подключись к бригаде»; see [the section](DESIGN.md#5-ожидание-и-рабочий-цикл).
A quote «across
lines» is fine.
```
expected: ── нет новых
```
Bad: проза.
EOF
  out=$(lang_check md "$d/a.md")
  assert_eq "$d/a.md:7: Bad: проза." "$out"
}

# Links and references of the tree lead to existing headings, sections and items.
test_docs_links() {
  local out r=$ROOT
  local f tests=
  for f in "$r"/tests/*.sh; do
    case $f in */test_brg_docs.sh) ;; *) tests="$tests $f" ;; esac # its fixtures are bad on purpose
  done
  out=$(link_check "$r" "$r"/*.md "$r"/template/*.md "$r"/bin/README.md "$r"/bin/brg "$r"/bin/brg-serve.py \
    "$r"/bin/brg-global "$r"/install.sh $tests "$r"/tests/fake_opencode "$r"/template/board.html)
  [ -z "$out" ] || fail "references that lead nowhere:$NL$out"
  # the index is not empty: the DESIGN sections and items were found
  out=$(sec_index "$r/DESIGN.md")
  assert_contains "$out" "S 5.5"
  assert_contains "$out" "I 12 3"
}

# The link checker on fixtures.
test_docs_links_checker() {
  local r out
  r=$(mk_tmpdir)
  mkdir "$r/template"
  cat >"$r/DESIGN.md" <<'EOF'
# brigada — дизайн
## 1. Цели
1. first
2. second
## 5. Ожидание и рабочий цикл
1. one
### 5.1 Таймауты: по харнессам
```
## 9. not a heading (fenced)
```
## Без номера
## Без номера
EOF
  cat >"$r/template/PROTOCOL.md" <<'EOF'
# Протокол
## 2. Рамки
1. a
2. b
## 4. Рекомендации
EOF
  cat >"$r/template/README.md" <<'EOF'
# Инструкция
## 2. Рабочий цикл
1. x
Bare: раздел 2, п. 1 is ok; раздел 7 is not.
EOF
  cat >"$r/good.md" <<'EOF'
[a](DESIGN.md#1-цели) [b](DESIGN.md#51-таймауты-по-харнессам) [c](DESIGN.md#brigada--дизайн)
[d](DESIGN.md#без-номера-1) [e](template/PROTOCOL.md) [f](https://example.com/x#y) [g](#local)
§1, §5.1, §1 п. 2, §1 item 1, §5, п. 1, DESIGN §1, item 2; PROTOCOL.md, раздел 2, п. 2;
`PROTOCOL.md`, раздел 4; README, раздел 2; PROTOCOL, section 2, item 1
## Local
EOF
  cat >"$r/bad.sh" <<'EOF'
# DESIGN §9 (only fenced in DESIGN), §5.2, §1 п. 3, §5 item 2
echo "начни с PROTOCOL.md, раздел 3" # PROTOCOL.md, раздел 2, п. 5; README, раздел 5
EOF
  cat >"$r/bad.md" <<'EOF'
[a](DESIGN.md#9-not-a-heading-fenced) [b](DESIGN.md#без-номера-2) [c](nofile.md) [d](#nowhere)
PROTOCOL, section 7
EOF
  out=$(link_check "$r" "$r/good.md" "$r/template/README.md")
  assert_eq "$r/template/README.md:4: README раздел 7: no such section" "$out"
  out=$(link_check "$r" "$r/bad.sh" "$r/bad.md")
  assert_contains "$out" "bad.sh:1: § 9: no such section"
  assert_contains "$out" "bad.sh:1: § 5.2: no such section"
  assert_contains "$out" "bad.sh:1: § 1, item 3: no such item"
  assert_contains "$out" "bad.sh:1: § 5, item 2: no such item"
  assert_contains "$out" "bad.sh:2: PROTOCOL раздел 3: no such section"
  assert_contains "$out" "bad.sh:2: PROTOCOL раздел 2, item 5: no such item"
  assert_contains "$out" "bad.sh:2: README раздел 5: no such section"
  assert_contains "$out" "bad.md:1: link DESIGN.md#9-not-a-heading-fenced: no such heading"
  assert_contains "$out" "bad.md:1: link DESIGN.md#без-номера-2: no such heading"
  assert_contains "$out" "bad.md:1: link nofile.md: no file"
  assert_contains "$out" "bad.md:1: link #nowhere: no such heading"
  assert_contains "$out" "bad.md:2: PROTOCOL section 7: no such section"
  assert_eq 12 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "nothing else: $out"
}

# ── Markers ────────────────────────────────────────────────────────────────
# marker_check LANG FILE — lines with history or unfinished-work markers (docs = code),
# one "FILE:LINE: text" per line; fenced code is skipped. Case-sensitive, under LC_ALL=C
# (Cyrillic as literals, no ranges). All docs: ~~ (struck-out text), TODO, FIXME ("todo" in
# lowercase is an item status). LANG en: "Stage A"/"stage B" (a lettered phase), a version
# in parentheses "(0.9.2)"/"(v0.9.2)", "in 0.9"/"In 0.9.2" (but not a duration: "in 0.5 s"),
# "since 0.9", "used to be|have|work|wake|show", "previously". LANG ru: «этап A», «(в 0.9».
# In AGENTS.md the sections "How we work" and "Pitfalls" are exempt (they are about our
# process and about past mistakes on purpose).
marker_check() {
  LC_ALL=C awk -v lang="$1" -v ru_e1="Э" -v ru_e2="э" -v ru_tap="тап " -v ru_v1="В" -v ru_v2="в" '
    function wb(s, i) { return i < 1 || i > length(s) || substr(s, i, 1) !~ /[A-Za-z0-9_]/ } # a word boundary at s[i]
    function hit(s,   t, r, k, c, rest) {
      if (index(s, "~~") || index(s, "TODO") || index(s, "FIXME")) return 1
      if (lang == "ru") {
        t = s
        while ((k = index(t, ru_tap)) > 0) {
          r = substr(t, 1, k - 1); c = substr(r, length(r) - 1)
          rest = substr(t, k + length(ru_tap))
          if ((c == ru_e1 || c == ru_e2) && rest ~ /^[A-Z]([^A-Za-z0-9_]|$)/) return 1
          t = rest
        }
        return match(s, "\\((" ru_v1 "|" ru_v2 ") 0\\.[0-9]") > 0
      }
      t = s
      while (match(t, /[Ss]tage [A-Z]/)) {
        if (wb(t, RSTART - 1) && wb(t, RSTART + RLENGTH)) return 1
        t = substr(t, RSTART + RLENGTH)
      }
      if (match(s, /\(v?0\.[0-9]+\.[0-9]+\)/)) return 1
      t = s
      while (match(t, /([Ii]n|since) 0\.[0-9]+/)) {
        rest = substr(t, RSTART + RLENGTH)
        if (wb(t, RSTART - 1) && rest !~ /^[0-9]*[ ]*(s|ms|min|h|MB|KB)([^A-Za-z]|$)/) return 1
        t = rest
      }
      t = s
      while (match(t, /used to (be|have|work|wake|show)|previously/)) {
        if (wb(t, RSTART - 1) && wb(t, RSTART + RLENGTH)) return 1
        t = substr(t, RSTART + RLENGTH)
      }
      return 0
    }
    FNR == 1 { fence = 0; skip = 0 }
    /^[ \t]*```/ { fence = !fence; next }
    fence { next }
    /^## / { skip = (FILENAME ~ /(^|\/)AGENTS\.md$/ && ($0 ~ /^## How we work/ || $0 ~ /^## Pitfalls/)) }
    skip { next }
    hit($0) { printf "%s:%d: %s\n", FILENAME, FNR, $0 }
  ' "$2"
}

# marker_tree ROOT — marker_check over every doc of ROOT
marker_tree() {
  local f
  for f in $DOCS_EN; do marker_check en "$1/$f"; done
  for f in template/README.md template/PROTOCOL.md; do marker_check ru "$1/$f"; done
}

test_docs_markers() {
  local out
  out=$(marker_tree "$ROOT")
  [ -z "$out" ] || fail "history or unfinished-work markers in the docs:$NL$out"
}

# The marker checker on fixtures: what it flags and the false positives it must not flag.
test_docs_markers_checker() {
  local d out
  d=$(mk_tmpdir)
  cat >"$d/en.md" <<'EOF'
bad: Stage B adds harnesses.
bad: the board (0.9.2) does this.
bad: (v0.8.0) too.
bad: In 0.9.2 it changed.
bad: since 0.7 the lead is one.
bad: it used to wake everyone.
bad: as previously described.
bad: ~~struck~~ out.
bad: TODO later.
bad: FIXME now.
good: status todo, stages of an item, the backstage A-list.
good: a pause of 0.5 s, wait in 0.5 s, done in 0.3 s; version 0.10.0; Python ≥ 3.8 (3.8.0–3.8.11).
good: «Stage» alone, stage 3, Stages A-Z; get used to it; he used to.
```
~~ TODO in fenced code: Stage A (0.9.2)
```
EOF
  out=$(marker_check en "$d/en.md")
  assert_eq 10 "$(printf '%s\n' "$out" | grep -c ': bad: ')" "every bad line: $out"
  assert_not_contains "$out" "good:"
  assert_not_contains "$out" "fenced"
  cat >"$d/ru.md" <<'EOF'
плохо: этап B — другие харнессы.
плохо: Этап A — только OpenCode.
плохо: так было (в 0.9.2).
хорошо: этапы работы, этап 6, поэтапно; в 0.5 с; (версия 0.10.0).
EOF
  out=$(marker_check ru "$d/ru.md")
  assert_eq 3 "$(printf '%s\n' "$out" | grep -c ': плохо: ')" "every bad line: $out"
  assert_not_contains "$out" "хорошо"
  mkdir "$d/x"
  cat >"$d/x/AGENTS.md" <<'EOF'
# AGENTS
## How we work
- Stage A of the plan (0.9.2) is exempt here.
## Pitfalls we have already hit
- it used to hang (exempt).
## State
- TODO: flagged again.
EOF
  out=$(marker_check en "$d/x/AGENTS.md")
  assert_eq "$d/x/AGENTS.md:7: - TODO: flagged again." "$out"
}
