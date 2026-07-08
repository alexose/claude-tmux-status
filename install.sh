#!/bin/bash
# Install the Claude Code -> tmux status hook.
#
#   - Copies tmux-status.sh into ~/.claude/hooks/
#   - Merges the required hook events into ~/.claude/settings.json (backed up first)
#
# Idempotent: safe to re-run. Requires jq.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required (brew install jq)"; exit 1; }

echo "Installing hook script -> $HOOKS_DIR/tmux-status.sh"
mkdir -p "$HOOKS_DIR"
cp "$SCRIPT_DIR/tmux-status.sh" "$HOOKS_DIR/tmux-status.sh"
chmod +x "$HOOKS_DIR/tmux-status.sh"

echo "Merging hooks into $SETTINGS"
mkdir -p "$CLAUDE_DIR"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

BACKUP="$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
cp "$SETTINGS" "$BACKUP"
echo "  backup: $BACKUP"

# Deep-merge our hook events into existing settings. For each event we append
# our hook only if it isn't already present, so re-running won't duplicate it.
jq -s '
  def add_hook(events):
    reduce events[] as $e (.;
      .hooks[$e] = ((.hooks[$e] // []) +
        (if any((.hooks[$e] // [])[]?; .hooks[]?.command == "~/.claude/hooks/tmux-status.sh")
         then [] else [{matcher:"", hooks:[{type:"command", command:"~/.claude/hooks/tmux-status.sh"}]}] end)));
  .[0] | add_hook(["UserPromptSubmit","PreToolUse","Stop","Notification","SessionEnd"])
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

echo "Done. Restart any running Claude Code sessions to pick up the hooks."
