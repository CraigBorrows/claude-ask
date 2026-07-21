# claude-ask

Lightweight shell helpers for asking [Claude Code](https://claude.com/claude-code)
questions straight from the terminal — `cd` into a folder and just ask, no
persistent REPL.

## Commands

| Command | Behavior |
|---------|----------|
| `ask <question>` | Conversational, scoped to the **current folder**. First `ask` in a folder starts a session; later `ask`s in that same folder resume it, so follow-ups remember context. `cd` back into a folder later and it resumes that folder's thread. A new terminal starts fresh. |
| `ask-new` | Forget the current folder's thread; the next `ask` here starts clean. |
| `ask-id` | Print the current folder's session id. |
| `ask1 <question>` | A true one-off — no memory, ignores folder sessions. |
| `askdir <question>` | One-off, seeded with the current folder's `ls -la` as context. |

```bash
cd ~/projects/thing
ask what does this project do
ask which files changed most recently
ask ok summarize that in one line
```

## Model

The model is set by one variable at the top of `claude-ask.sh`:

```bash
_CLAUDE_ASK_MODEL="haiku"   # fastest, good for quick shell Q&A
```

Switch to `opus` for deeper answers or `sonnet` for a middle ground. You can also
override per-call, e.g. `ask1 --model opus "..."`.

## Install

```bash
./install.sh
```

This symlinks `claude-ask.sh` into `~/.bashrc.d/`, which Craig's `.bashrc`
auto-sources. Open a new terminal (or `source ~/.bashrc.d/claude-ask.sh`) and the
`ask` commands are available. Requires the `claude` CLI on `PATH` and `uuidgen`.

## How it works

Claude Code scopes conversations **per working directory**
(`~/.claude/projects/<cwd-with-slashes-as-dashes>/<uuid>.jsonl`), so `--resume`
only finds a session created in the same directory. The helpers keep a bash
associative array keyed by `$PWD`, holding one `uuidgen` id per folder visited in
the terminal. The first `ask` in a folder uses `--session-id` to mint it; later
ones use `--resume`. The array lives in the interactive shell, so it's naturally
per-terminal and dies when the terminal closes.
