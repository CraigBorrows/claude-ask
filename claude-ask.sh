# Claude Code terminal helpers

# Model used by the ask helpers. 'haiku' = fastest (good for quick shell Q&A);
# switch to 'opus' for deeper answers, or 'sonnet' for a middle ground.
_CLAUDE_ASK_MODEL="haiku"

# Detected once, in a subshell so /etc/os-release doesn't leak vars into the shell.
_CLAUDE_ASK_OS="$( . /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" )"

# Tells Claude (a) it's answering from a terminal, so default to shell/CLI
# meanings, (b) to investigate with its own read-only commands instead of
# interrogating the user, and (c) how to report a blocked command, since it
# can't request interactive permission in headless mode.
_CLAUDE_ASK_SYSPROMPT="You are answering questions typed at an interactive shell prompt, through a wrapper called 'ask'. The user is at a bash prompt on ${_CLAUDE_ASK_OS:-Linux}, in the working directory you were started in.

Default to the terminal reading of a question: assume it is about the shell, CLI tools, this machine, or files here — not about GUI apps, browsers or websites unless the user clearly says so. For example, 'the navigation add-on I installed' means a shell tool such as zoxide or fzf, not a browser extension.

Investigate before asking — this is the most important rule. You have read-only commands available. NEVER tell the user to check a file, run a command, or look something up in order to answer: if you can run it, run it yourself first. Never reply with a list of possibilities you could have narrowed down by reading ~/.bashrc, checking \$PATH, listing installed packages, or looking at this folder. Ask a clarifying question only if the answer is genuinely undiscoverable from this machine, and then ask at most one.

Keep answers short: the output goes straight to a terminal, so prefer concrete runnable commands over prose, and avoid long markdown.

You cannot request interactive permission. If a Bash command or tool is blocked by the permission allowlist, do NOT ask the user to approve it or offer to proceed. Instead tell them the exact command to enable it: run 'ask-allow <command>' (for example, if 'top' is blocked, say: run 'ask-allow top'), then re-run their request. Prefer non-interactive command forms such as 'top -bn1' or 'ps'."

# Per-(terminal x folder) conversation map. Claude Code scopes sessions by
# directory, so we track one session id per folder visited in this terminal.
declare -A _CLAUDE_SESSIONS 2>/dev/null

# --- allowlist ------------------------------------------------------------
# Commands ask may run unattended. Anything NOT listed (rm, dd, mkfs, mv,
# chmod, chown, curl, wget, sudo, ...) is auto-denied, not run.
# NOTE: this stops casual footguns like a stray `rm`, but tools that run code
# (python, node, make, npm) can still do anything a script tells them to — it's
# a guardrail, not a sandbox. Only 'ask' to act in folders you'd let it act in.
#
# These are the built-in DEFAULTS (the seed). The live list is kept in
# $_CLAUDE_DO_TOOLS_FILE and edited on the fly with ask-allow / ask-deny /
# ask-tools / ask-tools-edit / ask-tools-reset. Persisted there, it survives new
# terminals and git pulls without touching this file.
_CLAUDE_DO_TOOLS_DEFAULT=(
    Read Grep Glob LS Edit Write MultiEdit NotebookEdit
    'Bash(git:*)' 'Bash(ls:*)' 'Bash(cat:*)' 'Bash(head:*)' 'Bash(tail:*)'
    'Bash(grep:*)' 'Bash(rg:*)' 'Bash(find:*)' 'Bash(mkdir:*)' 'Bash(touch:*)'
    'Bash(echo:*)' 'Bash(pwd)' 'Bash(wc:*)' 'Bash(diff:*)' 'Bash(tree:*)'
    'Bash(stat:*)' 'Bash(file:*)' 'Bash(which:*)' 'Bash(date:*)' 'Bash(sort:*)'
    'Bash(uniq:*)' 'Bash(sed:*)' 'Bash(awk:*)' 'Bash(jq:*)' 'Bash(cp:*)'
    'Bash(npm:*)' 'Bash(npx:*)' 'Bash(node:*)' 'Bash(python:*)' 'Bash(python3:*)'
    'Bash(pip:*)' 'Bash(pip3:*)' 'Bash(pytest:*)' 'Bash(cargo:*)' 'Bash(go:*)'
    'Bash(make:*)'
    # read-only system info (so "how much cpu/memory/disk" works out of the box)
    'Bash(ps:*)' 'Bash(top:*)' 'Bash(free:*)' 'Bash(df:*)' 'Bash(du:*)'
    'Bash(uptime:*)' 'Bash(uname:*)' 'Bash(lscpu:*)' 'Bash(nproc:*)' 'Bash(lsblk:*)'
    'Bash(ip:*)' 'Bash(ss:*)' 'Bash(sensors:*)' 'Bash(nvidia-smi:*)' 'Bash(vmstat:*)'
    'Bash(hostname:*)' 'Bash(whoami:*)' 'Bash(id:*)' 'Bash(env:*)' 'Bash(printenv:*)'
)

_CLAUDE_ASK_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-ask"
_CLAUDE_DO_TOOLS_FILE="$_CLAUDE_ASK_CONFIG_DIR/allowlist"

_claude_load_tools() {
    if [ -f "$_CLAUDE_DO_TOOLS_FILE" ]; then
        mapfile -t _CLAUDE_DO_TOOLS < <(grep -vE '^[[:space:]]*(#|$)' "$_CLAUDE_DO_TOOLS_FILE")
    else
        _CLAUDE_DO_TOOLS=("${_CLAUDE_DO_TOOLS_DEFAULT[@]}")
    fi
}

_claude_save_tools() {
    mkdir -p "$_CLAUDE_ASK_CONFIG_DIR"
    printf '%s\n' "${_CLAUDE_DO_TOOLS[@]}" > "$_CLAUDE_DO_TOOLS_FILE"
}

# Turn a bare command ("docker") into a Bash rule ("Bash(docker:*)"); pass
# through tool names and already-formed rules unchanged.
_claude_norm_tool() {
    case "$1" in
        *'('*)                    printf '%s' "$1" ;;   # already a rule
        Bash|Read|Write|Edit|MultiEdit|Grep|Glob|LS|NotebookEdit)
                                  printf '%s' "$1" ;;   # tool name
        *)                        printf 'Bash(%s:*)' "$1" ;;
    esac
}

_claude_load_tools

# --- core -----------------------------------------------------------------
# Every ask re-sends the folder's whole conversation history, so a thread gets
# progressively slower as it grows (measured: 3.3s at 12KB, 5.6s at 550KB,
# 12.1s at 1.6MB — while process startup is only 0.09s). Past this size we start
# a fresh thread so asks stay near the ~3.3s floor. Set to a huge number to
# disable rotation, or lower it to rotate sooner.
_CLAUDE_ASK_MAX_KB=250

# Show elapsed time after each ask. Toggle with: ask-timer on|off
_CLAUDE_ASK_TIMER=1

# Locate a session's transcript by globbing, rather than reconstructing Claude's
# cwd->project path encoding (which is undocumented and version-dependent).
_ask_session_file() { ls -1 "$HOME"/.claude/projects/*/"$1".jsonl 2>/dev/null | head -1; }
_ask_session_kb() {
    local f; f=$(_ask_session_file "$1")
    if [ -n "$f" ]; then du -k "$f" 2>/dev/null | cut -f1; else echo 0; fi
}

# Was this session created by ask? Sessions we mint carry an "ask: <folder>"
# name. Rotation is gated on this so we can only ever abandon our OWN threads —
# never an ordinary interactive claude session. (Rotating never deletes
# anything; it just stops resuming that id. This is belt-and-braces.)
_ask_is_ask_session() {
    local f; f=$(_ask_session_file "$1")
    [ -n "$f" ] || return 1
    head -c 4096 "$f" 2>/dev/null | grep -q '"agentName":"ask:'
}

# Milliseconds since epoch. EPOCHREALTIME avoids forking; the [.,] handles
# locales that use a comma as the decimal separator.
_ask_now_ms() {
    local e=${EPOCHREALTIME:-}
    if [ -n "$e" ]; then e=${e/[.,]/}; echo $(( e / 1000 )); else date +%s%3N; fi
}

_ask_timer() {
    [ -n "${_CLAUDE_ASK_TIMER:-}" ] || return 0
    local ms=$(( $(_ask_now_ms) - $1 ))
    printf '  ⏱ %d.%02ds\n' $(( ms / 1000 )) $(( (ms % 1000) / 10 )) >&2
}

# Progress dots while waiting, so a slow answer doesn't look like a hang.
# Set _CLAUDE_ASK_DOTS= to disable.
_CLAUDE_ASK_DOTS=1

# Wait for $1, printing a dot every 0.4s. Only animates when stderr is a
# terminal, so pipes and scripts stay clean. Dots are erased when done.
_ask_wait_dots() {
    local pid=$1 n=0
    if [ -z "${_CLAUDE_ASK_DOTS:-}" ] || [ ! -t 2 ]; then
        wait "$pid"; return $?
    fi
    while kill -0 "$pid" 2>/dev/null; do
        printf '.' >&2; n=$(( n + 1 )); sleep 0.4
    done
    [ "$n" -gt 0 ] && printf '\r%*s\r' "$n" '' >&2
    wait "$pid"
}

# Run claude in the background so we can show progress, buffering its streams so
# the dots never interleave with the answer. stdout/stderr stay separate.
_ask_claude() {
    local out err rc pid had_m=0
    out=$(mktemp) || { claude "$@"; return $?; }
    err=$(mktemp) || { rm -f "$out"; claude "$@"; return $?; }
    # An interactive shell announces background jobs ("[1] 12345" ... "[1]+ Done
    # claude ..."), which is noise here. Turning monitor mode off silences it;
    # as a bonus the child then shares our process group, so Ctrl-C reaches it
    # directly rather than relying solely on the trap below.
    case $- in *m*) had_m=1; set +m ;; esac
    # Two different notices to silence: the launch line "[1] 12345" (suppressed
    # by redirecting stderr of the group that starts the job) and the async
    # "[1]+ Done ..." line (suppressed by monitor mode being off, above).
    { claude "$@" >"$out" 2>"$err" & } 2>/dev/null
    pid=$!
    # Running claude in the background puts it outside the foreground process
    # group, so Ctrl-C no longer reaches it — kill it ourselves, and don't leave
    # temp files behind. 130 is the conventional SIGINT exit status.
    trap 'kill "$pid" 2>/dev/null; rm -f "$out" "$err"; trap - INT; return 130' INT
    _ask_wait_dots "$pid"
    rc=$?
    trap - INT
    [ "$had_m" = 1 ] && set -m
    cat "$out"
    cat "$err" >&2
    rm -f "$out" "$err"
    return $rc
}

# _ask_run <prompt...>: run claude in the current folder's session, granting the
# curated allowlist. Blocked commands are reported with an 'ask-allow' hint.
_ask_run() {
    local sid t0 kb rc
    t0=$(_ask_now_ms)
    sid="${_CLAUDE_SESSIONS[$PWD]}"

    # Rotate an oversized thread before it slows everything down — but only if
    # ask created it, so an ordinary claude session is never abandoned.
    if [ -n "$sid" ]; then
        kb=$(_ask_session_kb "$sid")
        if [ "${kb:-0}" -gt "${_CLAUDE_ASK_MAX_KB:-250}" ] && _ask_is_ask_session "$sid"; then
            echo "  ↻ thread was ${kb}KB — started a fresh one to stay fast (ask-id for details)" >&2
            sid=""
        fi
    fi

    if [ -n "$sid" ]; then
        _ask_claude -p --model "$_CLAUDE_ASK_MODEL" --append-system-prompt "$_CLAUDE_ASK_SYSPROMPT" \
            --allowedTools "${_CLAUDE_DO_TOOLS[@]}" --resume "$sid" "$*"
        rc=$?
        if [ $rc -eq 0 ]; then _ask_timer "$t0"; return 0; fi
        echo "(no saved session for $PWD — starting a new one)" >&2
    fi
    sid=$(uuidgen)
    _CLAUDE_SESSIONS[$PWD]="$sid"
    # --name tags the session so ask threads are tellable apart from normal
    # claude sessions (shows in 'claude -r' / /resume, and in 'ask-sessions').
    _ask_claude -p --model "$_CLAUDE_ASK_MODEL" --append-system-prompt "$_CLAUDE_ASK_SYSPROMPT" \
        --allowedTools "${_CLAUDE_DO_TOOLS[@]}" --name "ask: ${PWD##*/}" --session-id "$sid" "$*"
    rc=$?
    _ask_timer "$t0"
    return $rc
}

# ask: ask AND act in the current folder — answers questions, and can edit
# files / run git / run tests (curated allowlist). Conversational: follow-ups in
# the same folder remember. cd elsewhere -> its own thread; cd back -> resumes.
ask() { _claude_activate; _ask_run "$@"; }

# askdo: kept as an alias so old muscle memory still works — same as ask.
askdo() { ask "$@"; }

# ask1: quick one-off — no memory, no actions.
ask1() { _claude_activate; claude -p --model "$_CLAUDE_ASK_MODEL" "$*"; }

# askdir: one-off question seeded with the current directory's file listing.
askdir() {
    _claude_activate
    { echo "Current directory: $PWD"; echo "Files:"; ls -la; echo "---"; echo "Question: $*"; } \
        | claude -p --model "$_CLAUDE_ASK_MODEL" "Answer the question using the directory listing above as context."
}

# --- safe pasting ---------------------------------------------------------
# Pasting at the bash prompt is hazardous because every line is executed as a
# command (and a heredoc will swallow the lot into a file). These read the paste
# as DATA instead — nothing runs unless you explicitly confirm.

# askp [question]: paste text (Ctrl-D to finish), then ask about it.
#   e.g.  askp what does this error mean      <paste>  Ctrl-D
askp() {
    local q="$*" text
    echo "-- paste text, then press Ctrl-D --" >&2
    text=$(cat)
    [ -z "$text" ] && { echo "(nothing pasted)" >&2; return 1; }
    _claude_activate
    _ask_run "${q:-Explain the following pasted text.}

--- pasted ---
$text"
}

# runp: paste command(s) (Ctrl-D), review them, confirm, then run.
#   Markdown code fences are stripped, so pasting a ```bash block works.
runp() {
    local text reply
    echo "-- paste command(s), then press Ctrl-D --" >&2
    text=$(cat | sed '/^[[:space:]]*```/d')
    [ -z "${text//[[:space:]]/}" ] && { echo "(nothing pasted)" >&2; return 1; }
    echo "----- will run -----" >&2
    printf '%s\n' "$text" >&2
    echo "--------------------" >&2
    # stdin holds the paste, so read the confirmation from the terminal itself.
    # No terminal (script/pipe) -> fail safe and run nothing.
    if ! { [ -r /dev/tty ] && read -r -p "Run this? [y/N] " reply </dev/tty; } 2>/dev/null; then
        echo "(no terminal available to confirm — cancelled)" >&2
        return 1
    fi
    case "$reply" in
        y|Y) eval "$text" ;;
        *)   echo "cancelled" >&2; return 1 ;;
    esac
}

# --- sessions -------------------------------------------------------------
# ask-new: forget this folder's thread; next ask starts clean.
ask-new() { unset "_CLAUDE_SESSIONS[$PWD]"; echo "Fresh Claude session for $PWD."; }

# ask-id: show this folder's session id, size, and how close it is to rotating.
ask-id() {
    local sid="${_CLAUDE_SESSIONS[$PWD]}"
    if [ -z "$sid" ]; then echo "<none yet for $PWD — run 'ask'>"; return; fi
    local kb; kb=$(_ask_session_kb "$sid")
    echo "$sid"
    echo "  folder : $PWD"
    echo "  size   : ${kb}KB of ${_CLAUDE_ASK_MAX_KB:-250}KB (rotates past that)"
    echo "  file   : $(_ask_session_file "$sid")"
}

# ask-sessions: list sessions created by ask. They're tagged with an
# "ask: <folder>" name at creation, which is what distinguishes them from
# ordinary interactive claude sessions. Only the head of each transcript is
# scanned, so this stays fast even with many large files.
ask-sessions() {
    local f name kb found=0
    printf '%-7s  %-26s  %s\n' "SIZE" "NAME" "SESSION ID"
    for f in "$HOME"/.claude/projects/*/*.jsonl; do
        [ -e "$f" ] || continue
        name=$(head -c 4096 "$f" 2>/dev/null | grep -m1 -o '"agentName":"ask:[^"]*"')
        [ -n "$name" ] || continue
        name=${name#\"agentName\":\"}; name=${name%\"}
        kb=$(du -k "$f" | cut -f1)
        printf '%-7s  %-26s  %s\n' "${kb}KB" "$name" "$(basename "$f" .jsonl)"
        found=1
    done
    [ "$found" = 1 ] || echo "(no ask sessions yet)"
}

# ask-timer [on|off]: show elapsed time after each ask.
ask-timer() {
    case "${1:-status}" in
        on)  _CLAUDE_ASK_TIMER=1; echo "timer: ON" ;;
        off) unset _CLAUDE_ASK_TIMER; echo "timer: OFF" ;;
        *)   if [ -n "${_CLAUDE_ASK_TIMER:-}" ]; then echo "timer: ON"; else echo "timer: OFF"; fi ;;
    esac
}

# --- allowlist management -------------------------------------------------
# ask-tools: show the current allowlist.
ask-tools() { printf '%s\n' "${_CLAUDE_DO_TOOLS[@]}"; }

# ask-allow <cmd>...: allow command(s) now and for future terminals.
#   e.g. ask-allow docker mv   ->   adds Bash(docker:*) Bash(mv:*)
ask-allow() {
    local c t
    for c in "$@"; do
        t=$(_claude_norm_tool "$c")
        printf '%s\n' "${_CLAUDE_DO_TOOLS[@]}" | grep -qxF -- "$t" || _CLAUDE_DO_TOOLS+=("$t")
    done
    _claude_save_tools
    echo "Allowed: $* (this + new terminals). Now $(( ${#_CLAUDE_DO_TOOLS[@]} )) rules."
}

# ask-deny <cmd>...: remove command(s) from the allowlist.
ask-deny() {
    local c t existing drop keep=()
    for existing in "${_CLAUDE_DO_TOOLS[@]}"; do
        drop=0
        for c in "$@"; do
            t=$(_claude_norm_tool "$c")
            [ "$existing" = "$t" ] && drop=1
        done
        [ "$drop" -eq 0 ] && keep+=("$existing")
    done
    _CLAUDE_DO_TOOLS=("${keep[@]}")
    _claude_save_tools
    echo "Removed: $*. Now $(( ${#_CLAUDE_DO_TOOLS[@]} )) rules."
}

# ask-tools-edit: open the allowlist in $EDITOR, then reload it.
ask-tools-edit() { "${EDITOR:-nano}" "$_CLAUDE_DO_TOOLS_FILE"; _claude_load_tools; echo "Reloaded."; }

# ask-tools-reset: restore the built-in defaults.
ask-tools-reset() { _CLAUDE_DO_TOOLS=("${_CLAUDE_DO_TOOLS_DEFAULT[@]}"); _claude_save_tools; echo "Reset to defaults ($(( ${#_CLAUDE_DO_TOOLS[@]} )) rules)."; }

# --- auto-ask -------------------------------------------------------------
# After you've used any ask command in this terminal, an unknown command falls
# through to ask instead of "command not found". So:
#   $ ask why is X                 (activates auto-ask)
#   $ what is the 17gb disk cache  (no 'ask' -> still routed to ask)
# The fallback uses the same allowlist as ask, so blocked commands tell you how
# to enable them (ask-allow ...). Only allowlisted commands ever run, so a typo
# can at worst trigger a safe, curated command — never rm/dd/etc.
# Off by default until the first ask; toggle any time with: ask-auto on|off

# Flip auto-ask on, unless the user has explicitly turned it off this session.
_claude_activate() { [ -z "${_CLAUDE_ASK_AUTO_OFF:-}" ] && _CLAUDE_ASK_AUTO=1; }

# Preserve any pre-existing handler (e.g. Fedora's package suggester) once, so
# re-sourcing this file doesn't wrap our own handler around itself.
if [ -z "${_CLAUDE_CNF_INSTALLED:-}" ]; then
    if declare -F command_not_found_handle >/dev/null 2>&1; then
        eval "_claude_prev_cnf_handle() $(declare -f command_not_found_handle | tail -n +2)"
    fi
    _CLAUDE_CNF_INSTALLED=1
fi

# Does this look like a natural-language question, rather than a typo'd command
# or a pasted line of code/markdown? Pasting a block into the terminal runs
# EVERY line as a command; without this guard each stray line fires an LLM call.
_ask_looks_like_question() {
    [ "$#" -ge 3 ] || return 1                 # 1-2 words -> almost certainly a typo
    case "$*" in
        '```'*|'#'*|'-'*|'*'*|'/'*|'~'*|'$'*|'>'*|'|'*) return 1 ;;  # markdown/path/shell
        *'>>'*|*'&&'*|*'||'*|*'$('*|*'|'*|*';'*)        return 1 ;;  # shell plumbing = code
    esac
    return 0
}

# Backstop: a big paste can still produce many question-shaped lines. Rate-limit
# auto-ask to 6 per 60s so a paste can't spray LLM calls.
#
# NOTE: bash runs command_not_found_handle in a SEPARATE EXECUTION ENVIRONMENT
# (a subshell), so anything we assign there is lost when it returns — the
# counter has to live in a file, and we can't flip _CLAUDE_ASK_AUTO off from
# here. Over the limit we simply skip (report not-found) until the window rolls.
# $$ stays the parent shell's PID inside a subshell, so the file is per-terminal.
_ask_burst_ok() {
    local f="${XDG_RUNTIME_DIR:-/tmp}/claude-ask-burst-$$"
    local now=${EPOCHSECONDS:-0} t0=0 n=0
    [ -r "$f" ] && read -r t0 n < "$f" 2>/dev/null
    [ -z "$t0" ] && t0=0
    [ -z "$n" ] && n=0
    if [ $(( now - t0 )) -gt 60 ]; then t0=$now; n=0; fi
    n=$(( n + 1 ))
    printf '%s %s\n' "$t0" "$n" > "$f" 2>/dev/null
    if [ "$n" -gt 6 ]; then
        echo "auto-ask: too many unknown commands at once (looks like a paste) — skipping." >&2
        echo "          use 'ask-auto off' before pasting blocks of text." >&2
        return 1
    fi
    return 0
}

command_not_found_handle() {
    # Route to ask only when auto is on, the input looks like a question, we're
    # under the burst limit, and we're not already inside a fallback (the
    # reentrancy guard stops an infinite loop if claude/uuidgen ever go missing).
    if [ -n "${_CLAUDE_ASK_AUTO:-}" ] && [ -z "${_CLAUDE_CNF_IN:-}" ] \
       && _ask_looks_like_question "$@" && _ask_burst_ok; then
        local _CLAUDE_CNF_IN=1
        _ask_run "$@"
        return $?
    fi
    if declare -F _claude_prev_cnf_handle >/dev/null 2>&1; then
        _claude_prev_cnf_handle "$@"
    else
        echo "bash: $1: command not found" >&2
        return 127
    fi
}

# ask-auto [on|off]: control whether unknown commands fall through to ask.
ask-auto() {
    case "${1:-status}" in
        on)  unset _CLAUDE_ASK_AUTO_OFF; _CLAUDE_ASK_AUTO=1
             _CLAUDE_ASK_BURST_N=0; _CLAUDE_ASK_BURST_T0=${EPOCHSECONDS:-0}
             echo "auto-ask: ON — unknown commands go to ask." ;;
        off) _CLAUDE_ASK_AUTO_OFF=1; unset _CLAUDE_ASK_AUTO
             echo "auto-ask: OFF — unknown commands report 'command not found'." ;;
        *)   if [ -n "${_CLAUDE_ASK_AUTO:-}" ]; then echo "auto-ask: ON"; else echo "auto-ask: OFF (turns ON after your first ask)"; fi ;;
    esac
}

# --- help -----------------------------------------------------------------
ask-help() {
    cat <<EOF
claude-ask — ask Claude Code from the terminal (current model: ${_CLAUDE_ASK_MODEL:-haiku})

  ASK
    ask <q>            Ask AND act in the current folder — answers, and can edit
                       files / run git / run tests (curated allowlist).
                       Conversational: follow-ups in the same folder remember.
    askdo <q>          Same as ask (kept for old muscle memory).
    ask1 <q>           Quick one-off — no memory, no actions.
    askdir <q>         One-off, seeded with the folder's file listing (ls -la).

  PASTING (safe — the paste is read as data, never executed)
    askp [q]           Paste text (Ctrl-D), then ask about it.
    runp               Paste command(s) (Ctrl-D), review, confirm, then run.

  AUTO
    ask-auto on|off    After your first ask, an unknown command falls through to
                       ask instead of "command not found". Blocked commands tell
                       you the 'ask-allow' to enable them.

  SESSIONS
    ask-new            Forget this folder's thread; next ask starts clean.
    ask-id             Show this folder's session id, size, and rotate limit.
    ask-sessions       List all ask-created sessions (tagged "ask: <folder>").
    ask-timer on|off   Show elapsed time after each ask (default on).
                       Dots print while waiting; _CLAUDE_ASK_DOTS= disables.
                       Threads auto-rotate past \${_CLAUDE_ASK_MAX_KB}KB to stay fast.

  ALLOWLIST (what ask may run — persists to ~/.config/claude-ask/allowlist)
    ask-tools          Show the allowlist.
    ask-allow <c>...   Allow command(s), e.g. ask-allow docker mv.
    ask-deny  <c>...   Remove command(s).
    ask-tools-edit     Edit the allowlist in \$EDITOR, then reload.
    ask-tools-reset    Restore built-in defaults.

  Model: edit _CLAUDE_ASK_MODEL in claude-ask.sh (haiku | sonnet | opus).
  Help:  ask-help          Repo: github.com/CraigBorrows/claude-ask
EOF
}
askhelp() { ask-help; }
