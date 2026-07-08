#!/bin/bash
# Update tmux window name based on Claude Code hook events.
#
# Installed as a Claude Code hook (see README). Renames the tmux window that
# Claude is running in to reflect its current state, and recolors the window's
# entry in the status bar:
#
#   thinking...   reverse video   Claude is processing your prompt
#   <tool-name>   reverse video   Claude is running a tool (e.g. "bash", "edit")
#   <original>    green (col 22)  Claude finished / is waiting on you
#   <original>    default         Claude Code exited
#
# The window's pre-Claude name is saved on the first prompt of a turn and
# restored when Claude stops, so switching away and back is lossless.
#
# Dependencies: tmux, jq. Silently no-ops when not inside tmux.

[ -z "$TMUX" ] && exit 0

INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Use TMUX_PANE to target the correct window (the one Claude runs in)
WINDOW_ID=$(tmux display-message -t "$TMUX_PANE" -p '#I' 2>/dev/null)
[ -z "$WINDOW_ID" ] && exit 0

SAVE_FILE="/tmp/claude-tmux-original-name-${WINDOW_ID}"

set_active() {
    tmux set-window-option -t "$WINDOW_ID" window-status-current-style "reverse"
    tmux set-window-option -t "$WINDOW_ID" window-status-style "reverse"
}

set_done() {
    tmux set-window-option -t "$WINDOW_ID" window-status-current-style "bg=colour22"
    tmux set-window-option -t "$WINDOW_ID" window-status-style "bg=colour22"
}

clear_style() {
    tmux set-window-option -t "$WINDOW_ID" -u window-status-current-style
    tmux set-window-option -t "$WINDOW_ID" -u window-status-style
}

case "$EVENT" in
    UserPromptSubmit)
        # Save original window name before we start changing it
        if [ ! -f "$SAVE_FILE" ]; then
            tmux display-message -t "$WINDOW_ID" -p '#W' > "$SAVE_FILE"
        fi
        tmux rename-window -t "$WINDOW_ID" "thinking..."
        set_active
        ;;
    PreToolUse)
        TOOL_LOWER=$(echo "${TOOL:-tool}" | tr '[:upper:]' '[:lower:]')
        tmux rename-window -t "$WINDOW_ID" "$TOOL_LOWER"
        set_active
        ;;
    Stop|Notification)
        # Restore original window name with a "done" highlight
        set_done
        if [ -f "$SAVE_FILE" ]; then
            ORIGINAL=$(cat "$SAVE_FILE")
            rm -f "$SAVE_FILE"
            tmux rename-window -t "$WINDOW_ID" "$ORIGINAL"
        fi
        ;;
    SessionEnd)
        # Clear all styling when Claude Code exits
        clear_style
        if [ -f "$SAVE_FILE" ]; then
            ORIGINAL=$(cat "$SAVE_FILE")
            rm -f "$SAVE_FILE"
            tmux rename-window -t "$WINDOW_ID" "$ORIGINAL"
        fi
        ;;
esac
