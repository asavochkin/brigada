# brigada on Windows — test checklist

Criterion: `doctor` is green; `brg.cmd` works from PowerShell and cmd, including `send --file` with Cyrillic; an agent keeps its loop for 30 min. None of this has been run on Windows — write every difference from "Expected" into the template at the end. Time: ≈15 min by hand + 30 min of the agent's loop.

The paths below are examples: brigada in `C:\work\brigada`, a toy project in `C:\work\toy`.

## 0. Installation (3 min)

1. Git for Windows (https://git-scm.com/download/win), the installer with default settings.
2. A brigada clone — deliberately with `core.autocrlf=true` (this checks `.gitattributes`). In PowerShell:
   ```
   git clone -c core.autocrlf=true <url-or-path-to-the-brigada-repository> C:\work\brigada
   cd C:\work\brigada
   git ls-files --eol bin/brg bin/brg.cmd template/config
   ```
   Expected: `bin/brg` and `template/config` have `w/lf`, `bin/brg.cmd` has `w/crlf`.
3. The project: `mkdir C:\work\toy; cd C:\work\toy; git init`.

## 1. init and doctor (3 min)

In **Git Bash**:
```
cd /c/work/toy
bash /c/work/brigada/bin/brg init .
bash .brigada/bin/brg doctor; echo "code $?"
```
Expected: init — «создан AGENTS.md (только у тебя: исключён из git …)», `.git/info/exclude` has the lines `.brigada/` and `/AGENTS.md`; doctor — `── итого: … ✗ 0`, «платформа MSYS (Git Bash)», «mkdir атомарен», «mv поверх файла, открытого другим процессом на чтение, — успешно», «AGENTS.md: блок brigada есть», `wait_timeout (msys): … codex 100 …`, code 0. Every ⚠ and ✗ line goes into the template.

In **PowerShell** (Windows PowerShell 5.1; if you have it — PowerShell 7 as well):
```
cd C:\work\toy
chcp
.\.brigada\bin\brg.cmd doctor; "code $LASTEXITCODE"
chcp
```
Expected: the same, plus «запуск через brg.cmd»; Cyrillic and the ✓ marks are readable; code 0; `chcp` afterwards shows the same value as before. If the text is mojibake or `?`: repeat with `$env:BRG_NO_CHCP=1` and record both variants.

`brg.cmd` sets `chcp 65001` for the duration of the call; if the call is interrupted midway (Ctrl-C), the console code page may stay at 65001 — restore it by hand: `chcp <previous>` (the value from the first `chcp` above).

In **cmd.exe**:
```
cd /d C:\work\toy
.brigada\bin\brg.cmd doctor
echo code %ERRORLEVEL%
```

## 2. brg.cmd from PowerShell (6 min)

```
cd C:\work\toy
.\.brigada\bin\brg.cmd join --harness test --model human
```
Expected: the full name `test-1.<key>` (for example, `test-1.k7f3q9`); the line «Ты вызываешь brg из PowerShell/cmd …»; the last line `── NEXT: .\.brigada\bin\brg.cmd wait --as test-1.<key>`. Save the full name — below it is in `$me`:
```
$me = "test-1.<key from the join output>"
```

Cyrillic in arguments and in files:
```
Set-Content -Encoding utf8 brief.txt "Постановка: проверить кириллицу, ёЁ, «кавычки»"
.\.brigada\bin\brg.cmd task new --as $me --title "Проверка кириллицы" --file brief.txt
Set-Content -Encoding utf8 msg.txt "Привет, бригада! ёЁ — «кавычки» — 100%"
.\.brigada\bin\brg.cmd send --as $me --file msg.txt
.\.brigada\bin\brg.cmd item add --as $me --title "Подзадача" --desc "Описание по-русски"
.\.brigada\bin\brg.cmd tail -n 5
.\.brigada\bin\brg.cmd task show
```
Expected: in `tail` and `task show` the text reads without distortion (the task title, the brief, the message, the item). The same in Git Bash: `bash .brigada/bin/brg tail -n 5`.

Errors and exit codes:
```
"x" | Out-File u16.txt
.\.brigada\bin\brg.cmd send --as $me --file u16.txt; "code $LASTEXITCODE"
.\.brigada\bin\brg.cmd send --as nobody --file msg.txt; "code $LASTEXITCODE"
.\.brigada\bin\brg.cmd send --as test-1 --file msg.txt; "code $LASTEXITCODE"
.\.brigada\bin\brg.cmd wait --as $me --timeout 5
```
Expected: «текст в кодировке UTF-16 — нужен UTF-8», code 1; «неизвестный агент: nobody», code 1; without the key — «имя test-1 занято другой сессией», code 1; wait after 5 s — the task summary line `T001: todo 1`, then `── нет новых (5 с) · ход не завершай · NEXT: .\.brigada\bin\brg.cmd wait --as test-1.<key> --timeout 5`.

The busy mark (the quotes in `NEXT:` go through `brg.cmd`):
```
.\.brigada\bin\brg.cmd wait --as $me --busy "финальная валидация" --timeout 3
.\.brigada\bin\brg.cmd who
.\.brigada\bin\brg.cmd wait --as $me --timeout 3
```
Expected: the output of the first `wait` has `Ты отмечен «работает: финальная валидация»` and `NEXT: … wait --as test-1.<key> --busy "финальная валидация" --timeout 3` (the quotes are in place, the command from `NEXT:` can be run as is); `who` while the mark is on — «работает: финальная валидация», after a plain `wait` — «ждёт» (while a wait runs) or «работает» (between calls).

Pause (the agent's turn does not end, `wait` wakes on the human's words and on the lifted pause):
```
.\.brigada\bin\brg.cmd pause
.\.brigada\bin\brg.cmd wait --as $me --timeout 3
.\.brigada\bin\brg.cmd resume
```
Expected: `pause` — «── ПАУЗА для всех …»; `wait` after 3 s — «── пауза · нет новых от человека (3 с) · ход не завершай · NEXT: … wait --as test-1.<key> --timeout 3»; `resume` — «── пауза снята.».

Not from the project root:
```
cd C:\work
.\toy\.brigada\bin\brg.cmd status --as $me
cd C:\work\toy
```
Expected: the first line «brg вызван не из корня проекта … cd "C:\work\toy" …», NEXT in the form `.\.brigada\bin\brg.cmd …`.

Runs:
```
.\.brigada\bin\brg.cmd run --as $me --sync -- "echo привет; exit 3"; "code $LASTEXITCODE"
.\.brigada\bin\brg.cmd run --as $me --timeout 5s -- "sleep 60"
.\.brigada\bin\brg.cmd run --as $me --timeout 5s -- "ping -n 60 127.0.0.1"
```
Wait 15 s, then:
```
.\.brigada\bin\brg.cmd run list
Get-Process sleep, PING -ErrorAction SilentlyContinue
```
Expected: the first — `failed (код 3)`, «привет» in the log tail, code 3; the second and the third — `timeout`; no `sleep` or `PING` processes are left (if some are left, record it: a known risk with Windows processes inside a process group).

The board (view only):
```
.\.brigada\bin\brg.cmd board --once
```
Expected: the first line is the address `file:///C:/work/toy/.brigada/board.html`, then «снимок записан». Open the address (or the file `C:\work\toy\.brigada\board.html`) in Chrome and in Edge: you see the task T001, the agent test-1, the item, the runs with the log tail on click, the conversation; Cyrillic without distortion; no «Снимка ещё нет» banner. Then `.\.brigada\bin\brg.cmd board --static` (without `--once` and without the server; with the server — below) and in Git Bash `bash .brigada/bin/brg say "проверка доски"`: the message appears on the board within ~2 s; Ctrl+C — exit (when cmd asks whether to terminate the batch job — Y), no `.tmp` is left in `.brigada\run\board`.

The board with the server — control from the browser (needs Python 3.8+: `py -3 --version` or `python --version`; no Python — skip this step: `board` prints «Python 3.8+ не найден» and shows `file://`, `doctor` — «Python 3.8+ не найден»). The agent `test-1` is on the line, there is no task (`task cancel --as human`):
```
.\.brigada\bin\brg.cmd doctor
.\.brigada\bin\brg.cmd board
```
Expected: `doctor` — «✓ Python 3.x.y (…\python.exe) — brg board поднимет сервер с управлением; bin/brg-serve.py на месте» (not from `WindowsApps` — the search skips the Store stub); `board` — the first line `http://127.0.0.1:PORT/?t=TOKEN`, then «── доска обновляется … (сервер остановится)». Open the address in Chrome and in Edge: the address bar keeps `http://127.0.0.1:PORT/` (the token moved into a cookie), the header has the buttons «Новая задача», «Пауза», «Стоп всех», and under the conversation there is a message field. Check with Cyrillic: «Новая задача» — the title `Задача с доски: ёЁ`, a brief with «кавычки» and `100%`; in the message field — `"кавычки" и C:\temp\x`; in `.\.brigada\bin\brg.cmd tail -n 5` and `task show` the text is exactly the same; the `board` terminal shows the lines «── с доски: …» readably. The server rejects a title with `%` or `&` with a clear text; a title `README*` (and `fix?`) must reach the task as is (`MSYS=noglob`: Git Bash must not replace the mask with the names of files in the root). «Пауза» → `.\.brigada\bin\brg.cmd who` has the line «ПАУЗА», «Продолжить» lifts it. Start `board` twice in two windows: the second gets another port. Then Ctrl+C in the `board` window (when cmd asks whether to terminate the batch job — Y) and separately — closing the terminal window: Task Manager shows no extra `python.exe` (when the window is closed, it goes away by itself within ≤ 15 s). `.\.brigada\bin\brg.cmd board --static` — a `file:///…` address, no buttons.

A task from the human and the lead (Cyrillic in the title; the agent `test-1` is on the line):
```
.\.brigada\bin\brg.cmd task cancel --as human
Set-Content -Encoding utf8 human.txt "Задача от человека: ёЁ — «кавычки»"
.\.brigada\bin\brg.cmd task new --as human --title "Задача с доски" --file human.txt
.\.brigada\bin\brg.cmd lead give test-1 --as human
.\.brigada\bin\brg.cmd task show
```
Expected: `task new --as human` — `── создана задача T002 «Задача с доски» от человека · lead: test-1.` (no `NEXT:`); `lead give` — «test-1 уже lead задачи T002»; in `task show` the title and the brief read without distortion, `lead test-1`.

Remove the test task and the agent (otherwise the agent in section 3 sees someone else's active task):
```
.\.brigada\bin\brg.cmd task cancel --as human
.\.brigada\bin\brg.cmd leave --as $me
```

## 3. An agent keeps its loop for 30 min

Harness: **Codex CLI on Windows** (PowerShell) — the main candidate; no Codex — Claude Code (on Windows it runs commands in Git Bash) or OpenCode. If there is time — both.

1. Watch the conversation in Git Bash: `cd /c/work/toy && bash .brigada/bin/brg tail -f`.
2. A new agent session in `C:\work\toy`, the phrase: **«подключись к бригаде»** (the block in `AGENTS.md` from init). It did not join — record it in the template and say the full one: **«подключись к .brigada, прочитай инструкцию в .brigada/README.md»**. When asked for permission — "always allow" for brg.
3. Check in `tail`: `join` with the right `--harness`; the agent is in the `wait` loop (Codex on Windows — `wait` of 100 s).
4. Three times in 30 min (at the start, in the middle, at the end) write from Git Bash:
   ```
   bash .brigada/bin/brg say "ответь всем одним словом: pong-1"
   ```
   Expected: the answer `pong-1` in `tail` within one `wait`; in PowerShell the agent sends through `--file` without distorting Cyrillic.
5. Once write to the agent directly in the harness chat: «какое у тебя имя в бригаде? ответь и продолжай цикл».
6. At the end: `bash .brigada/bin/brg stop` → the agent answers «стоп» and ends its turn. Then `bash .brigada/bin/brg resume`.
7. A summary of the loop (put in the agent's name):
   ```
   awk -v a=codex-1 '$2 == a && $3 == "wait.start" { if (e) { g = $1 - e; if (g > m) m = g; if (g > 60) k++ } }
     $2 == a && $3 == "wait" { e = $1; n++; split($5, r, "="); c[r[2]]++ }
     END { printf "wait: %d, max gap %d s, gaps > 60 s: %d\n", n, m, k; for (x in c) printf "  %s: %d\n", x, c[x] }' .brigada/run/metrics.log
   ```
   Expected: no gaps > 60 s (except long model answers), outcomes — `timeout`/`msg`, no avalanches of `superseded`; the loop did not drop out before STOP.

## 4. What to collect

- The `doctor` output from Git Bash, PowerShell and cmd.
- `C:\work\toy\.brigada\run\metrics.log` and `runner.log`; the output of `bash .brigada/bin/brg tail -n 100`.
- The harness and its version, the model, tokens for 30 min (from the UI/`/status`) — compute "tokens per wait".
- Codex: whether the command was "parked" (`write_stdin` in the session transcript) and how many times.

Send the filled-in template as text (or open an issue in the brigada repository).

## 5. Results template

```
# brigada on Windows — results
Date: · Windows (version/build): · Git for Windows (version): · PowerShell (5.1/7.x):
Harness/model for the loop:

| # | Check | Expected | Got | Note |
|---|---|---|---|---|
| 0.2 | .gitattributes with autocrlf=true | brg w/lf, brg.cmd w/crlf | | |
| 1.1 | doctor in Git Bash | ✗ 0, code 0 | | ⚠: |
| 1.2 | doctor through brg.cmd (PowerShell) | ✗ 0, code 0, Cyrillic readable | | chcp before/after: |
| 1.3 | doctor through brg.cmd (cmd) | ✗ 0, code 0 | | |
| 2.1 | join from PowerShell | NEXT with .\.brigada\bin\brg.cmd | | |
| 2.2 | task new / send --file / item add --desc with Cyrillic | no distortion in tail and task show | | |
| 2.3 | UTF-16 file | error «UTF-16», code 1 | | |
| 2.4 | brg.cmd exit codes | 1 on an error, 3 for run --sync exit 3 | | |
| 2.5 | wait --timeout 5 | «нет новых (5 с)» + NEXT | | |
| 2.5a | brg.cmd not from the root | the «не из корня» line with cd, relative NEXT | | |
| 2.5b | pause / wait under a pause / resume | «ПАУЗА», «── пауза · нет новых от человека (3 с)», «пауза снята» | | |
| 2.5c | task new --as human, lead give --as human | no NEXT, Cyrillic without distortion | | |
| 2.6 | run timeout: sleep / ping | timeout, no processes left | | |
| 2.7 | board: address file:///C:/…, the page in Chrome and Edge | all sections, Cyrillic, refresh within ~2 s; send `say` with the text `"кавычки" и C:\temp\x` — on the board it is exactly the same (Git Bash means gawk: this checks escaping) | | |
| 2.8 | board with the server (Python): address http://127.0.0.1…, buttons, Cyrillic, a second board — another port, Ctrl+C and closing the window | a cookie instead of `?t=`, the text from the browser is exactly the same in tail, no `python.exe` left | | python.exe after Ctrl+C / closing the window: |
| 3.1 | the agent joined by itself on the phrase | join with the right harness | | |
| 3.2 | a 30 min loop | no dropouts, pong ×3 | | wait: , max gap: |
| 3.3 | an answer to a message in the chat | answered and went on with the loop | | |
| 3.4 | STOP | «стоп», the turn ended | | |
| 3.5 | tokens | — | | per wait: |

What broke or surprised you:
```
