# Claude Code terminal helpers

# Model used by the ask helpers. 'haiku' = fastest (good for quick shell Q&A);
# switch to 'opus' for deeper answers, or 'sonnet' for a middle ground.
_CLAUDE_ASK_MODEL="haiku"

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

# Commands askdo may run unattended. Anything NOT listed here (rm, dd, mkfs,
# mv, chmod, chown, curl, wget, sudo, ...) is auto-denied, not run. Edit freely.
# NOTE: this stops casual footguns like a stray `rm`, but tools that run code
# (python, node, make, npm) can still do anything a script tells them to — it's
# a guardrail, not a sandbox. Only 'askdo' in folders you'd let it act in.
_CLAUDE_DO_TOOLS=(
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
