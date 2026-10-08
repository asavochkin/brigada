# brigada на Windows — чек-лист проверки

Критерий: `doctor` зелёный; `brg.cmd` работает из PowerShell и cmd, включая `send --file` с кириллицей; агент держит цикл 30 мин. Ничего из этого на Windows ещё не запускалось — каждое расхождение с «ожидается» записывай в шаблон в конце. Время: ≈15 мин руками + 30 мин цикла агента.

Пути ниже — для примера: brigada в `C:\work\brigada`, игрушечный проект в `C:\work\toy`.

## 0. Установка (3 мин)

1. Git for Windows (https://git-scm.com/download/win), установщик с настройками по умолчанию.
2. Клон brigada — нарочно с `core.autocrlf=true` (проверяем `.gitattributes`). В PowerShell:
   ```
   git clone -c core.autocrlf=true <url-или-путь-к-репозиторию-brigada> C:\work\brigada
   cd C:\work\brigada
   git ls-files --eol bin/brg bin/brg.cmd template/config
   ```
   Ожидается: у `bin/brg` и `template/config` — `w/lf`, у `bin/brg.cmd` — `w/crlf`.
3. Проект: `mkdir C:\work\toy; cd C:\work\toy; git init`.

## 1. init и doctor (3 мин)

В **Git Bash**:
```
cd /c/work/toy
bash /c/work/brigada/bin/brg init .
bash .brigada/bin/brg doctor; echo "код $?"
```
Ожидается: init — «создан AGENTS.md (только у тебя: исключён из git …)», в `.git/info/exclude` строки `.brigada/` и `/AGENTS.md`; doctor — `── итого: … ✗ 0`, «платформа MSYS (Git Bash)», «mkdir атомарен», «mv поверх файла, открытого другим процессом на чтение, — успешно», «AGENTS.md: блок brigada есть», `wait_timeout (msys): … codex 100 …`, код 0. Все строки ⚠ и ✗ — в шаблон.

В **PowerShell** (Windows PowerShell 5.1; если есть — ещё и PowerShell 7):
```
cd C:\work\toy
chcp
.\.brigada\bin\brg.cmd doctor; "код $LASTEXITCODE"
chcp
```
Ожидается: то же, плюс «запуск через brg.cmd»; кириллица и значки ✓ читаются; код 0; `chcp` после — то же значение, что до. Если текст — «кракозябры» или `?`: повтори с `$env:BRG_NO_CHCP=1` и запиши оба варианта.

`brg.cmd` на время вызова ставит `chcp 65001`; при прерывании посреди вызова (Ctrl-C) кодовая страница консоли может остаться 65001 — верни прежнюю вручную: `chcp <прежняя>` (значение — из первого `chcp` выше).

В **cmd.exe**:
```
cd /d C:\work\toy
.brigada\bin\brg.cmd doctor
echo код %ERRORLEVEL%
```

## 2. brg.cmd из PowerShell (6 мин)

```
cd C:\work\toy
.\.brigada\bin\brg.cmd join --harness test --model human
```
Ожидается: полное имя `test-1.<ключ>` (например, `test-1.k7f3q9`); строка «Ты вызываешь brg из PowerShell/cmd …»; последняя строка `── NEXT: .\.brigada\bin\brg.cmd wait --as test-1.<ключ>`. Сохрани полное имя — ниже оно в `$me`:
```
$me = "test-1.<ключ из вывода join>"
```

Кириллица в аргументах и в файлах:
```
Set-Content -Encoding utf8 brief.txt "Постановка: проверить кириллицу, ёЁ, «кавычки»"
.\.brigada\bin\brg.cmd task new --as $me --title "Проверка кириллицы" --file brief.txt
Set-Content -Encoding utf8 msg.txt "Привет, бригада! ёЁ — «кавычки» — 100%"
.\.brigada\bin\brg.cmd send --as $me --file msg.txt
.\.brigada\bin\brg.cmd item add --as $me --title "Подзадача" --desc "Описание по-русски"
.\.brigada\bin\brg.cmd tail -n 5
.\.brigada\bin\brg.cmd task show
```
Ожидается: в `tail` и `task show` текст читается без искажений (заголовок задачи, постановка, сообщение, подзадача). То же в Git Bash: `bash .brigada/bin/brg tail -n 5`.

Ошибки и коды выхода:
```
"x" | Out-File u16.txt
.\.brigada\bin\brg.cmd send --as $me --file u16.txt; "код $LASTEXITCODE"
.\.brigada\bin\brg.cmd send --as nobody --file msg.txt; "код $LASTEXITCODE"
.\.brigada\bin\brg.cmd send --as test-1 --file msg.txt; "код $LASTEXITCODE"
.\.brigada\bin\brg.cmd wait --as $me --timeout 5
```
Ожидается: «текст в кодировке UTF-16 — нужен UTF-8», код 1; «неизвестный агент: nobody», код 1; без ключа — «имя test-1 занято другой сессией», код 1; wait через 5 с — строка-сводка задачи `T001: todo 1`, затем `── нет новых (5 с) · NEXT: .\.brigada\bin\brg.cmd wait --as test-1.<ключ> --timeout 5`.

Не из корня проекта:
```
cd C:\work
.\toy\.brigada\bin\brg.cmd status --as $me
cd C:\work\toy
```
Ожидается: первая строка «brg вызван не из корня проекта … cd "C:\work\toy" …», NEXT — в форме `.\.brigada\bin\brg.cmd …`.

Прогоны:
```
.\.brigada\bin\brg.cmd run --as $me --sync -- "echo привет; exit 3"; "код $LASTEXITCODE"
.\.brigada\bin\brg.cmd run --as $me --timeout 5s -- "sleep 60"
.\.brigada\bin\brg.cmd run --as $me --timeout 5s -- "ping -n 60 127.0.0.1"
```
Подожди 15 с, затем:
```
.\.brigada\bin\brg.cmd run list
Get-Process sleep, PING -ErrorAction SilentlyContinue
```
Ожидается: первый — `failed (код 3)`, в хвосте лога «привет», код 3; второй и третий — `timeout`; процессов `sleep` и `PING` не осталось (если остались — запиши: известный риск с Windows-процессами внутри группы).

Доска (только просмотр):
```
.\.brigada\bin\brg.cmd board --once
```
Ожидается: первая строка — адрес `file:///C:/work/toy/.brigada/board.html`, затем «снимок записан». Открой адрес (или файл `C:\work\toy\.brigada\board.html`) в Chrome и в Edge: видны задача T001, агент test-1, подзадача, прогоны с хвостом лога по клику, переписка; кириллица без искажений; нет баннера «Снимка ещё нет». Затем `.\.brigada\bin\brg.cmd board` без `--once` и в Git Bash `bash .brigada/bin/brg say "проверка доски"`: сообщение появится на доске за ~2 с; Ctrl+C — выход (на вопрос cmd о завершении пакетного файла — Y), в `.brigada\run\board` не остаётся `.tmp`.

Убрать тестовую задачу и агента (иначе агент в разделе 3 увидит чужую активную задачу):
```
.\.brigada\bin\brg.cmd task cancel --as human
.\.brigada\bin\brg.cmd leave --as $me
```

## 3. Агент держит цикл 30 мин

Харнесс: **Codex CLI на Windows** (PowerShell) — главный кандидат; нет Codex — Claude Code (на Windows он выполняет команды в Git Bash) или OpenCode. Если есть время — оба.

1. В Git Bash смотри переписку: `cd /c/work/toy && bash .brigada/bin/brg tail -f`.
2. Новая сессия агента в `C:\work\toy`, фраза: **«подключись к бригаде»** (блок в `AGENTS.md` от init). Не подключился — запиши в шаблон и скажи полную: **«подключись к .brigada, прочитай инструкцию в .brigada/README.md»**. На запрос разрешения — «always allow» для brg.
3. Проверь в `tail`: `join` с верным `--harness`; агент в цикле `wait` (Codex на Windows — `wait` по 100 с).
4. За 30 мин 3 раза (в начале, середине, конце) напиши из Git Bash:
   ```
   bash .brigada/bin/brg say "ответь всем одним словом: pong-1"
   ```
   Ожидается: ответ `pong-1` в `tail` в пределах одного `wait`; в PowerShell агент отправляет через `--file` без искажения кириллицы.
5. Один раз напиши агенту прямо в чат харнесса: «какое у тебя имя в бригаде? ответь и продолжай цикл».
6. В конце: `bash .brigada/bin/brg stop` → агент отвечает «стоп» и завершает ход. Потом `bash .brigada/bin/brg resume`.
7. Сводка по циклу (подставь имя агента):
   ```
   awk -v a=codex-1 '$2 == a && $3 == "wait.start" { if (e) { g = $1 - e; if (g > m) m = g; if (g > 60) k++ } }
     $2 == a && $3 == "wait" { e = $1; n++; split($5, r, "="); c[r[2]]++ }
     END { printf "wait: %d, макс. пауза %d с, пауз > 60 с: %d\n", n, m, k; for (x in c) printf "  %s: %d\n", x, c[x] }' .brigada/run/metrics.log
   ```
   Ожидается: нет пауз > 60 с (кроме долгих ответов модели), исходы — `timeout`/`msg`, без `superseded`-лавин; цикл не выпал до STOP.

## 4. Что собрать

- Вывод `doctor` из Git Bash, PowerShell и cmd.
- `C:\work\toy\.brigada\run\metrics.log` и `runner.log`; вывод `bash .brigada/bin/brg tail -n 100`.
- Харнесс и версия, модель, токены за 30 мин (из UI/`/status`) — посчитай «токенов на wait».
- Codex: были ли «парковки» команды (`write_stdin` в транскрипте сессии) и сколько.

Заполненный шаблон пришли текстом (или открой issue в репозитории brigada).

## 5. Шаблон результатов

```
# brigada на Windows — результаты
Дата: · Windows (версия/сборка): · Git for Windows (версия): · PowerShell (5.1/7.x):
Харнесс/модель для цикла:

| # | Проверка | Ожидается | Получено | Примечание |
|---|---|---|---|---|
| 0.2 | .gitattributes при autocrlf=true | brg w/lf, brg.cmd w/crlf | | |
| 1.1 | doctor в Git Bash | ✗ 0, код 0 | | ⚠: |
| 1.2 | doctor через brg.cmd (PowerShell) | ✗ 0, код 0, кириллица читается | | chcp до/после: |
| 1.3 | doctor через brg.cmd (cmd) | ✗ 0, код 0 | | |
| 2.1 | join из PowerShell | NEXT с .\.brigada\bin\brg.cmd | | |
| 2.2 | task new / send --file / item add --desc с кириллицей | без искажений в tail и task show | | |
| 2.3 | UTF-16 файл | ошибка «UTF-16», код 1 | | |
| 2.4 | коды выхода brg.cmd | 1 на ошибке, 3 у run --sync exit 3 | | |
| 2.5 | wait --timeout 5 | «нет новых (5 с)» + NEXT | | |
| 2.5a | brg.cmd не из корня | строка «не из корня» с cd, NEXT относительный | | |
| 2.6 | run timeout: sleep / ping | timeout, процессов не осталось | | |
| 2.7 | board: адрес file:///C:/…, страница в Chrome и Edge | все разделы, кириллица, обновление за ~2 с; отправь `say` с текстом `"кавычки" и C:\temp\x` — на доске он точно такой же (Git Bash — это gawk: проверка экранирования) | | |
| 3.1 | агент подключился сам по фразе | join с верным харнессом | | |
| 3.2 | цикл 30 мин | без выпадений, pong ×3 | | wait: , макс. пауза: |
| 3.3 | ответ на сообщение в чате | ответил и продолжил цикл | | |
| 3.4 | STOP | «стоп», ход завершён | | |
| 3.5 | токены | — | | на wait: |

Что сломалось или удивило:
```
