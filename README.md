# brigada

An experiment: a brigade of AI agents from different harnesses — Claude Code, Codex, OpenCode and any other that can run shell commands — works on your task in one project. You give the task to one agent and simply connect the others; from there they agree among themselves who leads, split the work into items, review each other and report to you.

The agents do not talk by having a model parse files; they use a deterministic bash script, `brg`: messages, waiting, tasks and roles, items with path reservations (so that nobody edits the same files), a queue of test runs. No harness setup is needed — no hooks, no plugins: it is enough to tell each agent «подключись к бригаде» ("join the brigade"). All the state lives in the project's `.brigada/` directory.

The protocol is free-form: only the frame is mandatory — safety, questions about the substance of the task go to you, no commits to `main`/`master` without your permission, nobody destroys others' work, a participant only coordinates (the work is done by its subagents), item stages match reality, the result goes to `summary.md`. How to organise the work the agents decide themselves; a proven order is given to them as a recommendation.

## Installation

You need bash 3.2+ (macOS, Linux; Windows — Git for Windows, see [WINDOWS.md](WINDOWS.md)) and git in the project (recommended). Optional: Python 3.8+ — only for the board server (the board gets buttons and a message field); without it everything works, the board only shows. Python not in `PATH` — `BRG_PYTHON=/path/to/python3 brg board`.

With one command (needs git):

```
curl -fsSL https://raw.githubusercontent.com/asavochkin/brigada/master/install.sh | bash
```

It clones the repository into `~/.local/share/brigada` and installs the `brg` command into `~/.local/bin`; if that directory is not in `PATH`, it says what to add. Another directory for the command — `… | bash -s -- /usr/local/bin`; another directory for the clone — the `BRIGADA_DIR` variable (`curl … | BRIGADA_DIR=~/tools/brigada bash`). If you would rather not run a script blind, look at it first: `curl -fsSLO https://raw.githubusercontent.com/asavochkin/brigada/master/install.sh`, `less install.sh`, `bash install.sh` (this clones too: there is no repository next to the file).

By hand: `git clone https://github.com/asavochkin/brigada.git` and `bash <clone>/install.sh [directory for the command]`.

Updating — the same command again (the clone runs `git pull --ff-only`; if the clone has your own edits and the update fails, it says how to update by hand). After updating, run `brg init` in your projects (step 6 below). Removal: `rm ~/.local/bin/brg` and `rm -rf ~/.local/share/brigada`; the `.brigada/` directories in projects are removed separately. From a clone, rerun `install.sh` after moving the repository or after `bin/brg-global` changes (simplest: after every `git pull`). Windows — [WINDOWS.md](WINDOWS.md).

## Quick start

1. In the project root: `brg init` — creates `.brigada/` (instructions for the agents, `config`, `bin/brg`) and hides the whole `.brigada/` from git (`.git/info/exclude`).
   `init` also adds a short brigada block to the project's `AGENTS.md` (if there is none, creates it and hides it from git): "when asked to join the brigade, read `.brigada/README.md`"; to `CLAUDE.md` as well, if it exists and does not import `AGENTS.md` with a `@AGENTS.md` line. Not wanted — delete the block and run `brg init --no-agents-md` (then `AGENTS.md` and `CLAUDE.md` are left alone). After `brg init --no-agents-md`, `brg doctor` warns that `AGENTS.md` has no brigada block — that is expected: say the full phrase to the agent, «подключись к .brigada, прочитай инструкцию в .brigada/README.md». The block is in English (with the phrase «подключиться к бригаде» in quotes); every `brg init` rewrites the block of an earlier version — if `AGENTS.md`/`CLAUDE.md` is in git, that is a change in your repository.
2. Open agent sessions **in the project root** (as many as you like, in any harnesses; from another directory an agent finds someone else's `.brigada` or none) and in each one say:
   **«подключись к бригаде»**. A session opened before `init`, or after `--no-agents-md` — the full phrase: **«подключись к .brigada, прочитай инструкцию в .brigada/README.md»**. When asked for permission — "always allow" for brg calls.
   **Codex — brg outside the sandbox** (approve running brg without the sandbox, or start Codex with, for example, `--sandbox danger-full-access`): a command started through `brg run` from the sandbox cannot reach local services (a database), and a sandbox with its own pid namespace can hide live processes from brg. Processes the sandbox cannot reach (EPERM) brg treats as alive, but this is not yet tested on a machine with Codex; `brg doctor` from the sandbox shows ⚠. Details — [DESIGN §12](DESIGN.md#12-открытые-вопросы), item 3.
   **Or launch the agents yourself, without windows** (OpenCode only for now, macOS/Linux): `brg spawn opencode --model <provider/model> [--count N] [--rights full|project] [--note "…"]` or the «Добавить агента» button on the board with the server. brg connects the agent itself and runs its turns: a free agent ends its turn (idling costs nothing), brg waits for it and continues its session when the agent has something to do — passing the messages straight into the prompt. Rights: `full` (default) — the agent can do everything you can, including outside the project directory and reading `.env`; `project` — OpenCode's default rules: inside the project everything is allowed — any commands, edits, network, git push; outside the project and `.env` — refused (the refusal shows on the board, with a «дать полные права» button). On the board such an agent has «⚙ S003», what it did in its last turn, tokens and cost (with subagents — through `opencode session export`; otherwise honestly «без подагентов»); a failed turn shows there too, the lead gets a message, and a new message or the «Разбудить» button wakes it. `brg spawn list` / `show` — the same in the terminal; `brg spawn wake|rm|detach <S|name>` — wake, remove, take into a window (prints the command to open its session); `brg spawn rights <S|name> full|project` — change the rights from the next turn. Both kinds of agents work in one brigade and cannot tell each other apart.
   `brg init` writes `.brigada/VERSION`, and a running `brg spawn` supervisor then continues on the new code. So do not run `brg init` in a project while an agent launched by brg is mid-turn there.
3. Give the task to any agent in its chat. It becomes the lead: it registers the task, gathers the others and reports to you **in that chat** (and on the board: `send --to human`). Or give it yourself, without an agent's chat: `brg task new --as human --title "…" < brief` — brg picks the lead: the previous lead if it is on the line; otherwise an agent on the line (free ones before busy ones, the earlier joined first); if nobody is on the line, the first agent to get in touch becomes the lead.
4. Watching:
   - `brg board` — the board in a browser: open the address from the first line of the output; it shows the task and its status, who is in the brigade and what they do («ждёт» — free, «работает: подпись» — its subagent works; if everyone waits while a task is on, the banner «бригада простаивает»), items with reviews, runs, the conversation, the brief, the plan and the summary, past tasks. It refreshes every 2 s while the command runs (Ctrl+C — exit). **With Python 3.8+, `brg board` starts the server itself** (address `http://127.0.0.1:PORT/?t=TOKEN`, by default only your computer — a VM's board from the host: [below](#the-board-from-another-machine-vm); keep the address to yourself — the token gives control) and the page lets you control the brigade: write to the brigade and answer questions («Ответить»), give a task («Новая задача»), appoint the lead, set and lift a pause, stop an agent or everyone, cancel the task (dangerous actions ask for confirmation); every action is an ordinary `brg` call on your behalf, and the `brg board` terminal shows the line «── с доски: …». No Python, the server did not start, or `brg board --static` — the board opens as a file (`file://…/.brigada/board.html`, view only; control it with `brg` commands);
   - `brg tail -f` — the agents' conversation;
   - `brg who` — who is in the brigade; an agent shows «возможно выпал» — write «продолжай» to it in its chat;
   - `brg item list`, `brg run list` — items and test runs.
5. Stepping in:
   - the same with commands (if the board has no server or you prefer it): `brg say "text"` — a message to everyone, `brg say --to codex-1 "text"` — to one agent; `brg say --to codex-1 --re 20 "yes"` — an answer to the agent's question #20 (open questions are on the board and in `brg who`);
   - `brg stop` — stop everyone (`brg stop <name>` — one agent): the agent sees STOP in `wait` or as the first line of any of its commands, and brg does not let it start new work; stopped agents have ended their turn — after `brg resume` write «продолжай» to them in their chat;
   - `brg pause` — softer than a stop: the brigade (`brg pause <name>` — one agent) starts no new work (subagents finish what they began) and wakes only on your messages; an agent connected by hand does not end its turn but waits in `wait`; `brg resume` lifts the pause — everyone waiting wakes by itself, with what has piled up; `brg say` does not lift the pause, so you can talk to the brigade during a pause;
   - `brg task cancel --as human` — cancel the current task; `brg lead give <name> --as human` — appoint another lead;
   - `brg doctor` — check the environment and the state if something is wrong.
6. A new version of brigada in a project — `brg init` again (the state and `config` are kept).

Without the global command: `bash /path/to/brigada/bin/brg init <project>`, then from the project — `bash .brigada/bin/brg <command>`. Help: `brg help`, `brg <command> --help`.

## The board from another machine (VM)

By default `brg board` listens only on `127.0.0.1` — the host cannot open a VM's board that way. Two ways:

- **SSH tunnel (recommended).** On the VM: `brg board` (the first line is `http://127.0.0.1:PORT/?t=TOKEN`). On the host: `ssh -N -L PORT:127.0.0.1:PORT <vm>`, then open the same address from the first line. **The port number is the same on both sides**: the cookie name and the `Host` check depend on it, and with another local port the board answers 403. To fix the port in advance — `brg board --port 8765`. The traffic goes over SSH, and the board stays reachable only for you.
- **`--bind` (trusted network).** `brg board --bind 192.168.64.5` (the VM's IPv4 address, dotted decimal — find it with `ip -4 addr` on Linux, `ipconfig getifaddr en0` on macOS) — the board listens on that address; `--bind 0.0.0.0` — on all the machine's addresses. Open `http://192.168.64.5:PORT/?t=TOKEN` from the host (with `0.0.0.0` the first line shows `127.0.0.1` — substitute the VM's IP). Open it by IP address, not by name (a name gets 403). The flag lasts for one run: the next `brg board` without it listens only on `127.0.0.1` again. **Careful:** this is HTTP without encryption — the token and the whole conversation travel in clear text, and the board can control the brigade and launch agents with full rights (running commands on the VM). Only a VM and a home network you trust; after the work change the token (`rm .brigada/run/board/token`, restart `brg board`). The macOS/Windows firewall may ask permission for Python. IPv6, host names and HTTPS are not supported.

## What happens inside

- **The wait loop.** An agent connected by hand never ends its turn: the last action of every step is `brg wait`, which blocks until a message or a timeout (100 s; Codex — 25 s) and prints the next command (`NEXT:`); `wait` without `--busy` means "I am free", `wait --busy "label"` — "my subagent is working". Idling costs one model call per timeout. ([DESIGN §5](DESIGN.md#5-ожидание-и-рабочий-цикл))
- **A name with a session key.** `join` gives an agent a name like `claude-1.k7f3q9`: others (and you in `who`, `tail`) see it as `claude-1`, and commands that change the state are not accepted without the key. So a session that skipped `join` cannot pass itself off as an agent of its harness from `who`. You need no key: `say --to`, `stop <name>` take the base name. ([§3](DESIGN.md#3-подключение))
- **Tasks and roles.** One active task per project; one role — lead: the facilitator and your contact (whoever you gave the task to is the lead; if you gave the task yourself through brg, brg appoints the lead; there is always a lead); the participants share the work; every participant is only a coordinator, the work itself is done by its subagents (one at a time by default). The brief is `brief.md`, the plan and artefacts are in `shared/`, the result is `summary.md` and a line in `common/history.md`. ([§6](DESIGN.md#6-задачи))
- **Items and runs.** Items are claimed with path reservations; whether another participant reviews a handed-in item is the brigade's decision, but the item stage (in progress, under review, changes, done, no review, cancelled) always matches reality — you see it on the board; tests and builds go through `brg run` — one command per project at a time, and the result comes to the agent as a message. ([§7](DESIGN.md#7-подзадачи-и-код))
- **Agents launched by brg.** `brg spawn` starts a supervisor process per agent: it holds `wait` for the free agent and, when there is something new, continues the harness session (`opencode run --session …`), passing the batch of messages into the prompt; crashes, stop, pause, rights and tokens are on the board. ([§5.5](DESIGN.md#55-агенты-запущенные-brg-090))
- **Settings** — `.brigada/config`: wait timeouts per harness, the "asleep/gone" thresholds, limits, the harness for `brg spawn`. `.brigada/config.default` holds the defaults; `brg init` rewrites it. A new project's `.brigada/config` is a copy with every setting commented out: uncomment a line to change that setting. `brg init` never changes an existing `config`, so values written there stay fixed even if a later version changes the default.

## Documentation

| File | What |
|---|---|
| [DESIGN.md](DESIGN.md) | the specification: how it works and why; open questions — §12 |
| [AGENTS.md](AGENTS.md) | for agents developing brigada: constraints, tests, how we work |
| [template/README.md](template/README.md), [template/PROTOCOL.md](template/PROTOCOL.md) | instructions for the brigade's agents (`brg init` copies them into `.brigada/`) |
| [bin/README.md](bin/README.md) | what is in `bin/` (`brg`, `brg-serve.py`, `brg.cmd`, `brg-global`) |
| [WINDOWS.md](WINDOWS.md) | the Windows test checklist |

Tests: `bash tests/run.sh` (plain bash; the board server tests are skipped without Python).

## Status

Experimental version 0.9.2. Done and covered by tests on macOS (bash 3.2): transport, waiting, the session key in the agent's name, tasks and roles, items and their review, questions to the human on the board, `brg run`, the Windows shim, `doctor`, the `brg board` board (with an optional Python server — control from the browser), the busy mark (`wait --busy`), one lead role and a task from the human (`task new --as human`), pause (`brg pause`), the brigada block in `AGENTS.md` («подключись к бригаде»), agents launched by brg (`brg spawn`; OpenCode — tested only with a fake harness). Known problems (including the untested work in the Codex sandbox) and what is next — [DESIGN §12](DESIGN.md#12-открытые-вопросы). Not yet tested: Windows (including the one-command installation and `brg board --bind`), the board server in Safari and on Windows, the cost of waiting in Claude Code and Codex — the timeouts are conservative for now.
