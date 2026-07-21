#!/usr/bin/env bash
# Symlink claude-ask.sh into ~/.bashrc.d/ so it is auto-sourced by ~/.bashrc.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target_dir="$HOME/.bashrc.d"

mkdir -p "$target_dir"
ln -sf "$repo_dir/claude-ask.sh" "$target_dir/claude-ask.sh"

echo "Linked $target_dir/claude-ask.sh -> $repo_dir/claude-ask.sh"
echo "Open a new terminal or run: source $target_dir/claude-ask.sh"
