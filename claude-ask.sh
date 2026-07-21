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
