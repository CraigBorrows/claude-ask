# Claude Code terminal helpers

# Model used by the ask helpers. 'haiku' = fastest (good for quick shell Q&A);
# switch to 'opus' for deeper answers, or 'sonnet' for a middle ground.
_CLAUDE_ASK_MODEL="haiku"

# ask-help: print the command cheatsheet.
ask-help() {
    cat <<EOF
claude-ask — ask Claude Code from the terminal (current model: ${_CLAUDE_ASK_MODEL:-haiku})

  ASK (answer only)
    ask <q>            Conversational, scoped to the current folder; follow-ups remember.
    ask1 <q>           One-off, no memory.
    askdir <q>         One-off, seeded with the folder's file listing (ls -la).

  ACT (do things — curated allowlist)
    askdo <instr>      Let Claude edit files / run git / run tests in this folder.

  SESSIONS
    ask-new            Forget this folder's thread; next 'ask' here starts clean.
    ask-id             Show this folder's session id.

  ALLOWLIST (what askdo may run — persists to ~/.config/claude-ask/allowlist)
    askdo-list         Show the current allowlist.
    askdo-allow <c>... Allow command(s), e.g. askdo-allow docker mv.
    askdo-deny  <c>... Remove command(s).
    askdo-edit         Edit the allowlist in \$EDITOR, then reload.
    askdo-reset        Restore built-in defaults.

  Model: edit _CLAUDE_ASK_MODEL in claude-ask.sh (haiku | sonnet | opus).
  Help:  ask-help          Repo: github.com/CraigBorrows/claude-ask
EOF
}
askhelp() { ask-help; }

# Per-(terminal x folder) conversation map. Claude Code scopes sessions by
# directory, so we track one session id per folder visited in this terminal.
declare -A _CLAUDE_SESSIONS 2>/dev/null

# ask: conversational question about the current folder.
#   First 'ask' in a given folder (this terminal) starts a session; later 'ask's
#   in that same folder resume it, so follow-ups work. cd elsewhere -> its own
#   thread; cd back -> resumes the earlier one. New terminal starts fresh.
ask() {
    local sid="${_CLAUDE_SESSIONS[$PWD]}"
    if [ -n "$sid" ]; then
        claude -p --model "$_CLAUDE_ASK_MODEL" --resume "$sid" "$*" && return
        echo "(no saved session for $PWD — starting a new one)" >&2
    fi
    sid=$(uuidgen)
    _CLAUDE_SESSIONS[$PWD]="$sid"
    claude -p --model "$_CLAUDE_ASK_MODEL" --session-id "$sid" "$*"
}

# Commands askdo may run unattended. Anything NOT listed (rm, dd, mkfs, mv,
# chmod, chown, curl, wget, sudo, ...) is auto-denied, not run.
# NOTE: this stops casual footguns like a stray `rm`, but tools that run code
# (python, node, make, npm) can still do anything a script tells them to — it's
# a guardrail, not a sandbox. Only 'askdo' in folders you'd let it act in.
#
# These are the built-in DEFAULTS (the seed). The live list is kept in
# $_CLAUDE_DO_TOOLS_FILE and edited on the fly with askdo-allow / askdo-deny /
# askdo-list / askdo-edit / askdo-reset. Persisted there, it survives new
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
)

_CLAUDE_ASK_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-ask"
_CLAUDE_DO_TOOLS_FILE="$_CLAUDE_ASK_CONFIG_DIR/allowlist"

# Load the live allowlist into _CLAUDE_DO_TOOLS: prefer the user file, else seed
# from the built-in defaults.
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

# askdo-list: show the current allowlist.
askdo-list() { printf '%s\n' "${_CLAUDE_DO_TOOLS[@]}"; }

# askdo-allow <cmd>...: allow command(s) now and for future terminals.
#   e.g. askdo-allow docker mv   ->   adds Bash(docker:*) Bash(mv:*)
askdo-allow() {
    local c t
    for c in "$@"; do
        t=$(_claude_norm_tool "$c")
        printf '%s\n' "${_CLAUDE_DO_TOOLS[@]}" | grep -qxF -- "$t" || _CLAUDE_DO_TOOLS+=("$t")
    done
    _claude_save_tools
    echo "Allowed: $* (this + new terminals). Now $(( ${#_CLAUDE_DO_TOOLS[@]} )) rules."
}

# askdo-deny <cmd>...: remove command(s) from the allowlist.
askdo-deny() {
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

# askdo-edit: open the allowlist file in $EDITOR, then reload it.
askdo-edit() { "${EDITOR:-nano}" "$_CLAUDE_DO_TOOLS_FILE"; _claude_load_tools; echo "Reloaded."; }

# askdo-reset: restore the built-in defaults.
askdo-reset() { _CLAUDE_DO_TOOLS=("${_CLAUDE_DO_TOOLS_DEFAULT[@]}"); _claude_save_tools; echo "Reset to defaults ($(( ${#_CLAUDE_DO_TOOLS[@]} )) rules)."; }

# askdo: let Claude actually DO things in the current folder — edit files, run
# git, run tests — using only the curated allowlist above. Shares this folder's
# 'ask' session, so "fix what you just described" works. New terminal = fresh.
askdo() {
    local sid="${_CLAUDE_SESSIONS[$PWD]}"
    if [ -n "$sid" ]; then
        claude -p --model "$_CLAUDE_ASK_MODEL" --allowedTools "${_CLAUDE_DO_TOOLS[@]}" --resume "$sid" "$*" && return
        echo "(no saved session for $PWD — starting a new one)" >&2
    fi
    sid=$(uuidgen)
    _CLAUDE_SESSIONS[$PWD]="$sid"
    claude -p --model "$_CLAUDE_ASK_MODEL" --allowedTools "${_CLAUDE_DO_TOOLS[@]}" --session-id "$sid" "$*"
}

# ask-new: forget this folder's thread; next 'ask' here starts clean.
ask-new() { unset "_CLAUDE_SESSIONS[$PWD]"; echo "Fresh Claude session for $PWD."; }

# ask-id: show this folder's current session id.
ask-id() { echo "${_CLAUDE_SESSIONS[$PWD]:-<none yet for $PWD — run 'ask'>}"; }

# ask1: a true one-off — no memory, ignores the folder session entirely.
ask1() { claude -p --model "$_CLAUDE_ASK_MODEL" "$*"; }

# askdir: one-off question seeded with the current directory's file listing.
askdir() {
    { echo "Current directory: $PWD"; echo "Files:"; ls -la; echo "---"; echo "Question: $*"; } \
        | claude -p --model "$_CLAUDE_ASK_MODEL" "Answer the question using the directory listing above as context."
}
