# Claude Code terminal helpers

# Model used by the ask helpers. 'haiku' = fastest (good for quick shell Q&A);
# switch to 'opus' for deeper answers, or 'sonnet' for a middle ground.
_CLAUDE_ASK_MODEL="haiku"

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
# _ask_run <mode> <prompt...>: run claude in the current folder's session.
#   mode 'act'  -> grants the allowlist (can edit files / run git / etc.)
#   mode 'read' -> grants nothing (answer only, cannot modify anything)
_ask_run() {
    local mode="$1"; shift
    local tools=()
    [ "$mode" = act ] && tools=(--allowedTools "${_CLAUDE_DO_TOOLS[@]}")
    local sid="${_CLAUDE_SESSIONS[$PWD]}"
    if [ -n "$sid" ]; then
        claude -p --model "$_CLAUDE_ASK_MODEL" "${tools[@]}" --resume "$sid" "$*" && return
        echo "(no saved session for $PWD — starting a new one)" >&2
    fi
    sid=$(uuidgen)
    _CLAUDE_SESSIONS[$PWD]="$sid"
    claude -p --model "$_CLAUDE_ASK_MODEL" "${tools[@]}" --session-id "$sid" "$*"
}

# ask: ask AND act in the current folder — answers questions, and can edit
# files / run git / run tests (curated allowlist). Conversational: follow-ups in
# the same folder remember. cd elsewhere -> its own thread; cd back -> resumes.
ask() { _claude_activate; _ask_run act "$@"; }

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

# --- sessions -------------------------------------------------------------
# ask-new: forget this folder's thread; next ask starts clean.
ask-new() { unset "_CLAUDE_SESSIONS[$PWD]"; echo "Fresh Claude session for $PWD."; }

# ask-id: show this folder's current session id.
ask-id() { echo "${_CLAUDE_SESSIONS[$PWD]:-<none yet for $PWD — run 'ask'>}"; }

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
# The fallback is READ-ONLY on purpose: an explicit 'ask' can act, but a typo
# that trips the fallback only gets answered — it can never edit or run git.
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

command_not_found_handle() {
    # Route to a READ-ONLY ask only when auto is on AND we're not already inside
    # a fallback (the reentrancy guard stops an infinite loop if claude/uuidgen
    # ever go missing).
    if [ -n "${_CLAUDE_ASK_AUTO:-}" ] && [ -z "${_CLAUDE_CNF_IN:-}" ]; then
        local _CLAUDE_CNF_IN=1
        _ask_run read "$@"
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
             echo "auto-ask: ON — unknown commands go to ask (read-only)." ;;
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

  AUTO
    ask-auto on|off    After your first ask, an unknown command falls through to
                       a read-only ask instead of "command not found".

  SESSIONS
    ask-new            Forget this folder's thread; next ask starts clean.
    ask-id             Show this folder's session id.

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
