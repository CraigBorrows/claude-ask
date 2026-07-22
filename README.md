# claude-ask

Lightweight shell helpers for asking [Claude Code](https://claude.com/claude-code)
straight from the terminal — `cd` into a folder and just ask, no persistent REPL.

## Commands

| Command | Behavior |
|---------|----------|
| `ask <q>` | Ask **and** act in the current folder — answers questions, and can edit files, run git, run tests (curated allowlist). Conversational and scoped to the folder: first `ask` starts a session, later `ask`s resume it, so follow-ups remember. `cd` back into a folder resumes its thread. New terminal starts fresh. |
| `askdo <q>` | Same as `ask` (kept as an alias for old muscle memory). |
| `ask1 <q>` | Quick one-off — no memory, no actions. |
| `askdir <q>` | One-off, seeded with the current folder's `ls -la` as context. |
| `askp [q]` | Paste text safely (Ctrl-D), then ask about it — nothing is executed. |
| `runp` | Paste command(s) (Ctrl-D), review, confirm, then run. |
| `ask-new` | Forget this folder's thread; the next `ask` here starts clean. |
| `ask-id` | Print this folder's session id, size, and how close it is to rotating. |
| `ask-sessions` | List all ask-created sessions (they're tagged `ask: <folder>`). |
| `ask-timer on\|off` | Show elapsed time after each ask (on by default). |
| `ask-help` (or `askhelp`) | Print the command cheatsheet. |

```bash
cd ~/projects/thing
ask what does this project do
ask which files changed most recently
ask commit these changes with a good message
ask whats failing in the tests and fix it
```

## Terminal context

`ask` injects a system prompt telling Claude it's answering from a shell prompt
on your actual OS (detected from `/etc/os-release`). That means:

- **Terminal reading by default** — "the navigation add-on I installed" resolves
  to a shell tool like `zoxide`/`fzf`, not a browser extension.
- **Investigates instead of interrogating** — it checks `~/.bashrc`, `$PATH`,
  installed packages and the current folder to answer for itself, rather than
  firing clarifying questions back at you.
- **Terminal-shaped answers** — short, concrete, runnable commands over prose.

Note the trade-off: investigating costs real tool round-trips, so a question that
makes it go look at things can take ~15s versus the ~3.3s floor. Use `ask1` when
you just want a quick fact with no investigation.

While waiting, `ask` prints progress dots so a slow answer doesn't look like a
hang; they're erased once the answer arrives, and the elapsed time is shown:

```
$ ask installed an add on for navigation how do i use
........................
You have zoxide (smart cd) and fzf (fuzzy finder) installed...
  ⏱ 14.50s
```

Dots only animate when stderr is a terminal, so pipes and scripts stay clean.
Set `_CLAUDE_ASK_DOTS=` to turn them off. Ctrl-C during a request kills the
underlying `claude` process and cleans up its temp files.

## Auto-ask

Once you've used any `ask` command in a terminal, an unknown command falls
through to `ask` instead of `command not found`:

```bash
ask when i run htop i see 30gb used        # activates auto-ask
what is the 17gb disk cache                # no 'ask' — still answered
```

The fallback uses the same allowlist as `ask`, so only curated (safe) commands
ever run — a typo can at worst trigger something like `git status`, never
`rm`/`dd`. Toggle with `ask-auto on|off` (off until your first ask each terminal).

### Pasting

Pasting multi-line text into a terminal runs **every line as a command**, so
auto-ask has two guards:

- **Shape check** — only natural-language-looking input is sent to Claude. Lines
  of 1–2 words, or starting with `` ``` ``/`#`/`-`/`/`/`~`/`$`, or containing
  shell plumbing (`>>`, `&&`, `|`, `$(`, `;`) are treated as commands, not
  questions, and fall through to the normal not-found handler.
- **Rate limit** — at most 6 auto-asks per 60 seconds, so a big paste can't
  spray LLM calls.

### Pasting safely — `askp` and `runp`

The hazard isn't pasting, it's pasting **at the bash prompt**, where every line
becomes a command (and a heredoc like `<< 'EOF'` will swallow prose, code fences
and all, straight into whatever file it's writing). These read the paste as
**data** instead, so nothing executes:

| Command | Does |
|---------|------|
| `askp [question]` | Paste text, press **Ctrl-D**, and it's sent to `ask` as context. Nothing is executed. |
| `runp` | Paste command(s), press **Ctrl-D**, see exactly what will run, then confirm `y`. Markdown ```` ``` ```` fences are stripped, so pasting a ```` ```bash ```` block works. Fails safe (runs nothing) if it can't get a terminal to confirm on. |

```bash
askp what does this error mean       # then paste the traceback, Ctrl-D
runp                                 # then paste a ```bash block, Ctrl-D, y
```

## Acting safely — the allowlist

`ask` can run commands unattended (headless mode can't pause for approval), so
it's restricted to an allowlist: file edits, common safe commands (`git`, `ls`,
`cat`, `grep`, `find`, `mkdir`, `npm`, `python`, `pytest`, `make`, ...), and
read-only system info (`top`, `ps`, `free`, `df`, `lscpu`, `nvidia-smi`, ...).
Anything **not** listed — `rm`, `dd`, `mkfs`, `mv`, `chmod`, `curl`, `sudo`,
etc. — is auto-denied, not run.

When a command **is** blocked, `ask` tells you exactly how to enable it — e.g.
`run 'ask-allow lsof'` — instead of getting stuck asking for permission it can't
receive. Add it and re-run.

This blocks casual footguns like a stray `rm`, but it is a **guardrail, not a
sandbox**: allowed tools that execute code (`python`, `node`, `make`, `npm`) can
still do anything a script tells them to. Only ask it to act in folders you'd
trust it to act in.

### Editing the allowlist on the fly

The live allowlist lives in `~/.config/claude-ask/allowlist` (seeded from the
`_CLAUDE_DO_TOOLS_DEFAULT` defaults in `claude-ask.sh` on first use). Manage it
without editing any file — changes apply now **and** persist for new terminals:

| Command | Does |
|---------|------|
| `ask-tools` | Print the current allowlist. |
| `ask-allow <cmd>...` | Allow command(s). `ask-allow docker` adds `Bash(docker:*)`. Bare names become `Bash(name:*)`; full rules like `Bash(git log:*)` or tool names like `Write` pass through. |
| `ask-deny <cmd>...` | Remove command(s) from the allowlist. |
| `ask-tools-edit` | Open the allowlist in `$EDITOR`, then reload it. |
| `ask-tools-reset` | Restore the built-in defaults. |

```bash
ask-allow docker terraform    # let ask run docker/terraform from now on
ask-deny cp                   # take cp back off the list
ask-tools                     # see what's currently allowed
```

Note: changes reach *other already-open terminals* only after they re-source
(`source ~/.bashrc.d/claude-ask.sh`) — they loaded their copy at startup.

## Speed

Measured on this setup: process startup is **0.09s** — spawning is not the
bottleneck. The API round trip is a **~3.2s floor**, and the one thing that
degrades over time is conversation history, because every ask re-sends the
folder's whole thread:

| Session size | Resume time |
|---|---|
| 12 KB | 3.3s |
| 552 KB | 5.6s |
| 1.6 MB | 12.1s |

So a thread auto-rotates once it passes `_CLAUDE_ASK_MAX_KB` (default **250KB**),
keeping asks near the floor. It announces itself:

```
  ↻ thread was 312KB — started a fresh one to stay fast (ask-id for details)
```

The trade-off is that rotating drops that folder's accumulated context. Raise
`_CLAUDE_ASK_MAX_KB` to keep more history, lower it to stay faster, or set it
huge to disable rotation. `ask-id` shows where the current thread sits, and
`ask1` skips history entirely for standalone questions (constant ~3.3s).

**Only ask's own threads rotate.** Rotation is gated on the `ask:` session tag,
so an ordinary interactive claude session can never be abandoned — and rotating
never deletes anything anyway, it just stops resuming that id and starts a new
one. (Threads created before session tagging existed are untagged, so they won't
auto-rotate; use `ask-new` if one of those feels slow.)

## Telling ask sessions apart

Ask threads are created with `--name "ask: <folder>"`, so they're distinguishable
from ordinary interactive sessions — the name shows up in `claude -r` / `/resume`,
and `ask-sessions` lists just them:

```
SIZE     NAME                        SESSION ID
16KB     ask: claude-ask             1249f940-ed4e-43d4-8a15-ffb6a3a1bf7b
12KB     ask: RC-6-hw                d4f61a6e-17e6-4950-8da4-32682c1a2bf2
```

## Model

Set by one variable at the top of `claude-ask.sh`:

```bash
_CLAUDE_ASK_MODEL="haiku"   # fastest, good for quick shell Q&A
```

Switch to `opus` for deeper answers or `sonnet` for a middle ground. Note: Haiku
is fast but weakest at multi-step code fixes — bump to `opus` for gnarly work.

## Install

```bash
./install.sh
```

Symlinks `claude-ask.sh` into `~/.bashrc.d/`, which `.bashrc` auto-sources. Open a
new terminal (or `source ~/.bashrc.d/claude-ask.sh`) and the commands are
available. Requires the `claude` CLI on `PATH` and `uuidgen`.

## How it works

Claude Code scopes conversations **per working directory**
(`~/.claude/projects/<cwd-with-slashes-as-dashes>/<uuid>.jsonl`), so `--resume`
only finds a session created in the same directory. The helpers keep a bash
associative array keyed by `$PWD`, holding one `uuidgen` id per folder visited in
the terminal. The first `ask` in a folder uses `--session-id` to mint it; later
ones use `--resume`. The array lives in the interactive shell, so it's naturally
per-terminal and dies when the terminal closes. Auto-ask is a
`command_not_found_handle` that routes unknown commands to `ask` once activated,
preserving any pre-existing handler (e.g. Fedora's package suggester).

Note: bash runs `command_not_found_handle` in a **separate execution
environment** (a subshell), so nothing it assigns survives the call. That's why
the rate limiter keeps its counter in a file (`$XDG_RUNTIME_DIR/claude-ask-burst-$$`)
rather than a variable, and why auto-ask can't switch itself off — over the limit
it just declines until the window rolls. It also means a bare question asked in a
folder that has no session yet can't record the new session id, so consecutive
bare questions there won't chain; run an explicit `ask` first to establish the
folder's thread.

Editing `~/.bashrc` (and similar shell rc files) is blocked by Claude Code itself
as a sensitive file — no allowlist entry overrides it. Edit those by hand.
