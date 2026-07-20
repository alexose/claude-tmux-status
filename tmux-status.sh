#!/bin/bash
# Recolor the current tmux window to reflect Claude Code's state.
#
# This hook ONLY changes the window's *style* (the color of its entry in the tmux
# status bar). It never touches the window *name* — your title is left exactly as
# you set it, 100% of the time. It also locks the window so nothing else can rename
# it either: automatic-rename off stops tmux naming it after the foreground process
# (e.g. "bash", or "2.1.210" — Claude names its process after its version), and
# allow-rename off stops the shell's title escape sequences from doing the same.
#
#   busy      reverse video    Claude is thinking or running a tool
#   waiting   green (col 22)    Claude finished / is waiting on you (plays a chime)
#   exited    default           styling cleared when Claude Code exits
#
# When a turn ends while background tasks/agents are still running, the window
# stays "busy" and the chime is deferred until the last one finishes.
#
# Dependencies: tmux, jq. Silently no-ops when not inside tmux.

[ -z "$TMUX" ] && exit 0

INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')

# Target the pane's window by its unique id (e.g. "@5"), which is never reused.
WINDOW_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{window_id}' 2>/dev/null)
[ -z "$WINDOW_ID" ] && exit 0

# --- window styling (color only — never the name) ----------------------------

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

# Freeze the window name in place. We never rename the window ourselves; this just
# stops tmux (automatic-rename) and programs in the pane (allow-rename, e.g. the
# shell's title escapes) from renaming it, so your title stays put.
lock_name() {
    tmux set-window-option -t "$WINDOW_ID" automatic-rename off
    tmux set-window-option -t "$WINDOW_ID" allow-rename off
}

# --- "done" sound, played only when you're NOT looking at this window ---------
#
# Config (all optional, via environment):
#   CLAUDE_TMUX_SOUND         Sound to play. A path, a bare macOS system-sound
#                             name (e.g. "Glass"), or "off" to disable.
#                             Default: Pop.
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
    local snd="${CLAUDE_TMUX_SOUND:-Pop}"
    [ "$snd" = "off" ] && return 0
    [ -f "$snd" ] || snd="/System/Library/Sounds/${snd}.aiff"
    [ -f "$snd" ] || return 0
    command -v afplay >/dev/null 2>&1 || return 0
    # Play in its own session, not just backgrounded. Claude tears down the hook's
    # process group when this script returns; a plain "afplay &" is in that group
    # and gets killed mid-sound, which made the chime intermittent. `setsid` (via
    # perl, always present on macOS) moves it to a new session so it survives.
    if command -v perl >/dev/null 2>&1; then
        perl -e 'use POSIX qw(setsid); setsid(); exec @ARGV' \
            afplay "$snd" >/dev/null 2>&1 </dev/null &
    else
        afplay "$snd" >/dev/null 2>&1 </dev/null &
    fi
}

# True (0) when a background task (shell or agent launched with run_in_background)
# is still running, per the Stop payload — the turn ended but the work hasn't, so
# we keep the window "busy" and hold the chime until the last one finishes.
background_running() {
    local n
    n=$(echo "$INPUT" | jq -r '[.background_tasks[]? | select(.status=="running")] | length' 2>/dev/null)
    [ "${n:-0}" -gt 0 ]
}

case "$EVENT" in
    SessionStart)
        lock_name
        # Tidy up window options left by older, name-managing versions of this hook.
        tmux set-window-option -t "$WINDOW_ID" -u @claude_orig_name 2>/dev/null
        tmux set-window-option -t "$WINDOW_ID" -u @claude_saved_auto 2>/dev/null
        tmux set-window-option -t "$WINDOW_ID" -u @claude_saved_allow 2>/dev/null
        ;;
    UserPromptSubmit)
        lock_name          # in case the SessionStart event was missed
        set_active
        ;;
    PreToolUse)
        set_active
        ;;
    Stop|Notification)
        if background_running; then
            # Turn ended but background work is still going — stay "busy" and hold
            # the chime until the last background task finishes.
            set_active
            exit 0
        fi
        set_done
        # Chime — but only when you're not already watching this window.
        should_play_sound && play_done_sound
        ;;
    SessionEnd)
        # Clear styling. The name lock is left in place so the title stays put.
        clear_style
        ;;
esac
