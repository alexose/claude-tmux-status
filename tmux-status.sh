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

# --- "done" sound, played only when you're NOT looking at this window ---------
#
# Config (all optional, via environment):
#   CLAUDE_TMUX_SOUND         Sound to play. A path, a bare macOS system-sound
#                             name (e.g. "Glass"), or "off" to disable.
#                             Default: Glass.
#   CLAUDE_TMUX_TERMINAL_APP  Comma-separated macOS app name(s) to treat as
#                             "your terminal" (e.g. "iTerm2" or "Ghostty,Code").
#                             Auto-falls back to a list of common terminals —
#                             needed because tmux overwrites $TERM_PROGRAM, so we
#                             can't reliably auto-detect the host terminal.
#
# macOS only (uses lsappinfo + afplay); a silent no-op elsewhere.

frontmost_app() {
    lsappinfo info -only name "$(lsappinfo front 2>/dev/null)" 2>/dev/null \
        | sed -n 's/.*="\(.*\)"$/\1/p'
}

frontmost_is_terminal() {
    local front="$1"
    [ -z "$front" ] && return 1
    if [ -n "$CLAUDE_TMUX_TERMINAL_APP" ]; then
        case ",$CLAUDE_TMUX_TERMINAL_APP," in
            *",$front,"*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    case "$front" in
        iTerm2|Terminal|Ghostty|WezTerm|Alacritty|kitty|Kitty|Hyper|Warp|\
        Code|Cursor|Tabby|Rio|rio|Terminus)
            return 0 ;;
        *) return 1 ;;
    esac
}

# True (0) when a sound should play: you're not currently looking at the window
# Claude just finished in — either your terminal isn't frontmost, or it is but a
# different tmux window is active.
should_play_sound() {
    [ "$(uname)" = "Darwin" ] || return 1
    frontmost_is_terminal "$(frontmost_app)" || return 0
    local active
    active=$(tmux display-message -t "$WINDOW_ID" -p '#{window_active}' 2>/dev/null)
    [ "$active" = "1" ] && return 1   # frontmost terminal AND this window active
    return 0
}

play_done_sound() {
    local snd="${CLAUDE_TMUX_SOUND:-Glass}"
    [ "$snd" = "off" ] && return 0
    [ -f "$snd" ] || snd="/System/Library/Sounds/${snd}.aiff"
    [ -f "$snd" ] || return 0
    command -v afplay >/dev/null 2>&1 || return 0
    afplay "$snd" >/dev/null 2>&1 &   # detached so the hook returns immediately
}

case "$EVENT" in
    SessionStart)
        # tmux's automatic-rename names a window after its foreground process.
        # Claude Code sets its process title to its version (e.g. "2.1.204"), so
        # tmux would name the window that until our first rename fires. Turn it
        # off up front so the window keeps its real name and our states stick.
        tmux set-window-option -t "$WINDOW_ID" automatic-rename off
        ;;
    UserPromptSubmit)
        # Save original window name before we start changing it. Guard against a
        # name tmux already auto-set to Claude's process title (== pane command),
        # so we never restore "2.1.204" as the "original" name.
        if [ ! -f "$SAVE_FILE" ]; then
            CURRENT=$(tmux display-message -t "$WINDOW_ID" -p '#W')
            CMD=$(tmux display-message -t "$WINDOW_ID" -p '#{pane_current_command}')
            [ "$CURRENT" = "$CMD" ] && CURRENT="zsh"
            printf '%s' "$CURRENT" > "$SAVE_FILE"
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
        # Chime — but only when you're not already watching this window.
        should_play_sound && play_done_sound
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
