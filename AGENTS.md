# AGENTS.md — for agents developing brigada

This file is for those who work **on this repository**. Do not confuse it with the instructions for brigade participants in other projects: those are `template/README.md` and `template/PROTOCOL.md`, which `brg init` copies into `<project>/.brigada/`.

**Language.** Talk to the human in Russian. Technical documentation is in English: this file, `DESIGN.md`, `README.md`, `WINDOWS.md`, `bin/README.md`, `/plans`, code comments, test names and test diagnostics, commit messages, and the text `brg init` writes into projects' files. The user interface is in Russian: everything brg prints (including `--help`), the board UI, `template/README.md` and `template/PROTOCOL.md`, the comments in `template/config`. Russian literals quoted in English texts (UI strings, the phrases the human says to an agent) stay verbatim. Comments are short.

## What this is

An experiment: any number of agents from different harnesses (Claude Code, Codex, OpenCode, …) join a project with the phrase «подключись к бригаде» (`brg init` puts a pointer block to `.brigada/README.md` into the project's `AGENTS.md`/`CLAUDE.md`, DESIGN §3; without the block the phrase is «подключись к .brigada, прочитай инструкцию в .brigada/README.md») and organise the work on the human's task themselves. They interact through the deterministic bash CLI `brg` (messages, waiting, tasks, roles, items with path reservations, a run queue), not through a model parsing files.

- [README.md](README.md) — what it is and how to start it (for the human).
- [DESIGN.md](DESIGN.md) — the specification: what is implemented and why. It describes only what is implemented; something new is a plan in `/plans` first and enters DESIGN together with the code. Known limitations — §12.

## Hard rules: docs = code

1. **Documentation is:**
   - `README.md`, `DESIGN.md`, `WINDOWS.md`, `bin/README.md`;
   - `template/README.md`, `template/PROTOCOL.md`, the comments in `template/config`;
   - `brg … --help` and `brg help`;
   - the map and the constraints in this file.
2. **Statements about the tool's behaviour describe only what is implemented** in the same revision and can be checked against the code or a test: commands, flags, output, exit codes, formats, config, invariants, protection.
3. **Normative texts are allowed as norms** when they are clearly marked as such and not presented as code behaviour: the frames and recommendations of PROTOCOL for participants, the human's decisions, the development rules in this file.
4. **Not allowed in documentation:**
   - plans and promises;
   - discussions and options to choose from;
   - history: what the tool did before, versions in headings or tags, struck-out text, retold field cases;
   - run reports and work status.
5. **Allowed:**
   - a short "why" for a current decision;
   - **known limitations** of the implementation and of testing ("not tested on Windows / in Safari", "tested live with …");
   - procedures the human runs (`WINDOWS.md`).
6. **No revision of `master` has docs and code out of step.**
   - Work branches may hold intermediate revisions, but every behaviour commit includes the minimal edits to every place that describes that behaviour (the agent and human READMEs, DESIGN, `--help`).
   - Text quoted in two places that change in separate parallel branches is fixed in a contract in `/plans` first and checked on the merged tree.
   - General editing goes in separate commits, never mixed into behaviour commits.
7. **Plans, discussions, reviews, reports, status and backlog live in `/plans`,** never in git. New behaviour is a plan first; it enters DESIGN in the implementing commit. Version history lives in commit messages.
8. **A mismatch you find is fixed in the same change.** If the fix needs the human's decision, record it in `/plans` and document today's behaviour.
9. **Checking.** Every validation node checks docs = code on its diff; `tests/test_brg_docs.sh` checks what can be checked mechanically.

## Repository map

| Path | What |
|---|---|
| `bin/brg` | the whole tool, one bash file |
| `bin/brg-serve.py` | the optional server of the human's board (Python ≥ 3.8, stdlib; DESIGN §9.1; `--bind ADDR` — over the network, only when the human asks); `brg board` starts it, `init` installs it into `.brigada/bin/` |
| `bin/brg.cmd` | the Windows shim (PowerShell/cmd → Git Bash), ASCII + CRLF |
| `bin/brg-global`, `install.sh` | the human's global `brg` command (`~/.local/bin/brg`); `install.sh` has two modes: from a clone and from a pipe (`curl … \| bash`: `git clone`/`pull --ff-only` into `~/.local/share/brigada`, then install from that clone; git is allowed only here, only in this mode) |
| `template/` | what `brg init` puts into `.brigada/`: README and PROTOCOL for participant agents, config, `board.html` (the human's board) |
| `tests/` | tests in pure bash: `run.sh`, `lib.sh`, `brg_lib.sh`, `spawn_lib.sh` (helpers of the launched-agent tests), `test_*.sh`, `pingpong.sh`; `test_install.sh` — `install.sh` (no network: the source is a temporary `file://` repository, HOME is replaced; skipped without git); `test_brg_serve.sh` — the board server (the client is Python; skipped without Python); `test_brg_spawn.sh` + `fake_opencode` — agents launched by brg (a fake OpenCode, no LLM) |
| `WINDOWS.md` | the human's checklist for Windows |
| `/plans` | plans, reviews, reports, status, backlog; never committed (`.gitignore`). For the human it is a symlink to `../brigada-archive`; elsewhere create the directory locally |

## Technical constraints of `bin/brg` (hard)

- **bash 3.2** (macOS). Not allowed: associative arrays, `mapfile`/`readarray`, `${x,,}`/`${x^^}`, `|&`, `&>>`, `declare -n`, `$EPOCHSECONDS`, `wait -n`, `sed -i`, `setsid`.
- Utilities: only `mkdir mv rm cat sed awk date sleep kill ls head tail wc sort tr printf cp uname nohup`. No jq/node. `date` only formats (`+%s`, ISO); no date parsing.
- **Harness CLIs** (`opencode run`, `opencode session export`) are called only by the `brg __spawn` supervisor and the `brg __turn` turn wrapper of launched agents (DESIGN §5.5); `spawn`/`doctor`/`board` only look the binary up (`type -P`). The real `opencode` is never called in tests — only `tests/fake_opencode`, through `spawn.opencode.bin` in the test project's `config`.
- **Python only for the human's server** `bin/brg-serve.py` (optional, stdlib, ≥ 3.8; DESIGN §1 item 4, §9.1). `bin/brg` calls Python only in `board` and `doctor`, always through `py_find_v` (it does not call the macOS shim or the Windows Store stubs); the agents' tool is bash 3.2. Without Python `brg board` works in `file://` mode, view only. The server writes no state itself — only through `brg` calls.
- Compatibility with Git Bash on Windows: no GNU/BSD-specific flags; `mv` with retries.
- Record format: `Key: value` headers + an empty line + the body.
- Numbers from options, `config` and the environment are parsed with `dec_v` (decimal, leading zeros allowed: `08` is 8, not a bash octal error). Fractional sleep steps (`BRG_TICK`, `BRG_SPAWN_STEP`) are checked as `^[0-9]+(\.[0-9]+)?$` (`frac_ok`) and never go into bash arithmetic.
- Invariants that are easy to break (details: DESIGN §4–§7):
  - a write is tmp + `mv` under a `mkdir` lock; a stale lock is removed atomically (`mv lock lock.stale.$$`), only by its owner;
  - **no signals by a pid from a file** (the pid may have been reused): the `wait` takeover goes through the pid file, stopping goes through flags;
  - one `wait` per agent; delivery at least once (`Acked`/`Pending`, the next `wait` acknowledges);
  - `wait` always exits with code 0 and prints `NEXT:` as its last line (except STOP/SUPERSEDED/LEFT and the orphan exit: `wait` exits silently when the process that started it died), argument errors included;
  - the `brg run` exec lock is never broken by age, only by the owner's death or a stale runner heartbeat; the same holds for the supervisor lock `spawn.S00N` (DESIGN §5.5); the lock order is `spawn.S → roster → task → runs → chan`;
  - no line of brg output tells an agent launched by brg «не завершать ход» (all waiting phrases go through `next_wait`); the supervisor and the turn wrapper signal only their own children.

## Pitfalls we have already hit

They are not visible from the code — do not repeat them.

- **bash 3.2: `read -t` does not work on a pipe, and traps do not interrupt a blocking `read`.** So the stdin of message bodies is read by a background `head -c` into a temp file, polled up to `BRG_STDIN_WAIT` — watchdogs on signals lost a body already read.
- **An own process group only via `set -m`** (in a subshell before the start); macOS has no `setsid`. The `brg run` runner is `nohup` + `set -m` with every fd redirected, otherwise the harness waits for the pipe to close and the call "hangs".
- **`kill -0` gives EPERM for a process you have no rights to** (from the Codex sandbox to a process outside it; on macOS without a sandbox — `kill -0 1`): that means "alive", not "dead". The liveness of a pid from a file goes only through `pid_alive` (the only place that parses the text of a `kill` error; `kill -0` directly — only to own children and `$$`), and a runner's death is also confirmed by a silent heartbeat (`runner_dead_grace`). What remains is ESRCH: a pid namespace may hide a live process, and then ordinary locks and the `wait` orphan check are wrong (DESIGN §12, item 3). In tests the sandbox is imitated by `BRG_TEST_EPERM_PIDS`.
- **A signal by a pid from a file may kill an unrelated program** (the pid is reused after KILL) — hence the takeover through the pid file and flags instead of signals.
- **Claude Code**: a Bash command that hits the tool limit is not killed but goes to the background — a second `wait` on top of the first (hence SUPERSEDED and the `wait` timeout below the limit); the Bash tool defaults to 2 min, the model must pass `timeout`.
- **Codex**: a long command is "parked" after 10–30 s and the model polls it itself; the default sandbox has `.git` read-only, no network, limited signals and limited access to processes/services outside it.
- **OpenCode v2**: the shell tool is called `shell`; headless is `opencode run --standalone`. The model's commands run in their own process groups and outlive the turn (a trailing `wait` — hence the supervisor's cursor rollback); on SIGINT `run` stops them itself and exits with 130 (it does not handle SIGTERM); the message argument is re-encoded — the prompt goes only through stdin; `session export` without `--standalone` starts a long-lived background service for the human, and a big export through a pipe is cut — read only the start of the file.
- **`curl | bash` and `install.sh`**: in bash 3.2, when the script is read from stdin, `BASH_SOURCE` is unset (under `set -u` `${BASH_SOURCE[0]}` fails, `$0` is just `bash`, which would mean "the current directory"); in bash ≥ 4 inside a function it is `main`. So the mode test is `src=${BASH_SOURCE:-}` at the top level plus `[ -f "$src" ]`; the whole body is in functions and `main "$@"` is the last line (any command reading stdin would eat the rest of the script: `git` and `exec` get `</dev/null`).
- **Network and `Sec-Fetch-Site`**: a browser sends `Sec-Fetch-*` only to a potentially trustworthy URL (loopback, https). On a network address the header is absent, and a "no header — let it in" check silently admits foreign pages from a neighbouring port; so off loopback the snapshot is protected by the token `k` in the script address. macOS: `0.0.0.0` with `SO_REUSEADDR` binds on top of a foreign `127.0.0.1:P` — for `0.0.0.0` the socket goes without it. `EACCES` on `bind` is about the port, not the address (code 5 only for `EADDRNOTAVAIL`, and before a retry on another port). `HTTPServer.server_bind` calls `getfqdn` — the server overrides it (reverse DNS could eat 5 s of the handshake).
- **Windows/NTFS**: `mv` over a file opened by another process (an antivirus, a reader) fails — retries are needed; `bash` in PATH may turn out to be WSL — `brg.cmd` finds Git Bash itself.
- **macOS `sed -i`/`date -d` are incompatible with GNU** — do not use them; do not parse dates at all (only `date +%s`).

## Tests

```bash
bash tests/run.sh                       # everything (pingpong included)
BRG_SKIP_PINGPONG=1 bash tests/run.sh   # faster
bash tests/run.sh item                  # filter by a substring of "file:function"
```

Tests must leave no processes and no temporary directories. `test_brg_docs.sh` checks the commands and flags mentioned in the docs (`README.md`, `DESIGN.md`, `AGENTS.md`, `bin/README.md`, `template/*.md`, `WINDOWS.md`) against `brg <cmd> --help` — when you change the CLI, check the docs; it also checks the language (Cyrillic only inside quotes in the English docs of the `DOCS_EN` list and in code comments), links and anchors, `§N item M` references, and the markers of history and unfinished work. The development machine has only `/bin/bash` 3.2; bash ≥ 4 (Git Bash) has never been tested.

Names in tests: `join_as` returns the full name (`claude-1.<key>`), which goes into `--as`; `From:`, `who`, `tail`, the paths `agents/`, `cursors/`, `run/wait/` and `metrics.log` use the base name (`${x%%.*}`, `base_of`). The helpers `cursor`, `tcursor`, `pid_is`, `ack_all`, `metrics_of` accept either; `rejoin_as` is `join --as` with a new key, `dropped` is an agent's "silence" for `join --as`.

## How we work (the human's preferences)

- **In stages.** Once a plan is agreed, the implementation of a stage goes to an executor subagent with a self-contained assignment (pointers to DESIGN, constraints, criteria, tests). Every node is checked by a separate high-effort agent that took no part in the implementation; the final check is by a fresh agent. The validator runs the tests and the mechanical checks itself, reads the diff, runs its own reproductions, checks docs = code, and gives the verdict "accepted / blocking fixes". Fixes after the remarks → the stage commit (with a Co-Authored-By trailer if the environment requires one).
- **Do not stop on questions.** If a question for the human comes up, continue with whatever is not blocked; collect the questions and ask them along the way.
- **Plan first.** A plan goes to `/plans`; decisions enter DESIGN.md in the implementing commit.
- **LLM runs are short and only with consent.** Do not start long or expensive runs without the human. OpenCode headless: `opencode run --standalone --model <provider>/<model>`. The provider may throttle (requests hang and are retried) — the brigade must survive that; leave a time margin.
- **The protocol's philosophy (the human's decision).** `template/PROTOCOL.md` sets only the goal and minimal frames (safety; questions about business substance go to the human; the human sees the questions and the result; no commits to main/master without permission and no destroying other people's work; communication through brg; a participant is only a coordinator, any work is done by its subagent, one at a time, more with the human's permission; the board shows the truth — item stages and "busy/waiting" as they really are; closing with `summary.md`). The whole process is recommendations: agents may agree on something else and build their own tools. Expectations (PROTOCOL, section 3; DESIGN §1 item 8): decisions are collegial, the lead is a facilitator and the link to the human (there is one role, lead, always present — brg assigns it), the work belongs to the participants (done by their subagents), an item is checked by another participant; subagents never join the brigade. `brg` does not impose a process (for example, it does not require review) — it gives flexible tools for every case (DESIGN §7.1.1: check, do not check, change your mind, your own order), tied to the board, and keeps the state consistent.
- **The global `brg` command** of the human is the wrapper from `install.sh`. If you changed `bin/brg-global` or the repository path, run `bash install.sh` and tell the human. Changes to `bin/brg` need no reinstall, but projects pick them up through `brg init`.

## Public repository

The repository is public and "bare": only the tool, the tests and the documents. Reports and logs of live runs, data of other projects, internal names of providers and models are never committed. Plans and the human's local notes live outside git: `/plans` (above) and `AGENTS.local.md` if it exists (in .gitignore; e.g. the provider for runs, where the reports are) — read it.

## State

The version is `BRG_VERSION` in `bin/brg`. Work status, the next steps and what the human checks themselves are in `plans/STATUS.md`; known limitations are in DESIGN §12.
