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
# restored when Claude stops, so switching away and back is lossless. While
# Claude owns the window its name is locked (allow-rename off) so the shell can't
# clobber your title with "bash".
#
# Dependencies: tmux, jq. Silently no-ops when not inside tmux.

[ -z "$TMUX" ] && exit 0

INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Resolve the pane's window by its unique id (e.g. "@5"), not its index — the
# index gets reused as windows come and go, which would let stale state from a
# previous window leak into a new one. Every `-t` below accepts this id.
WINDOW_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{window_id}' 2>/dev/null)
[ -z "$WINDOW_ID" ] && exit 0

# The original name and the pre-Claude rename settings live in tmux user options
# *on the window object itself*, not a /tmp file. Tying them to the live window
# means a killed session can't leave a stale file that later gets restored onto
# an unrelated window — that was the "keeps reverting to bash" bug.
NAME_OPT="@claude_orig_name"

wopt()       { tmux show-window-options -t "$WINDOW_ID" -v "$1" 2>/dev/null; }
set_wopt()   { tmux set-window-option -t "$WINDOW_ID" "$1" "$2"; }
unset_wopt() { tmux set-window-option -t "$WINDOW_ID" -u "$1" 2>/dev/null; }

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

# --- window-name preservation -------------------------------------------------

# Lock the window name so only this script changes it. automatic-rename off stops
# tmux renaming the window after its foreground process; allow-rename off stops
# programs in the pane (notably the shell's title escape sequences) from
# overwriting it with things like "bash". Our own `tmux rename-window` still
# works — allow-rename only gates in-band escape sequences. The pre-Claude values
# are saved once so SessionEnd can hand the window back exactly as we found it.
take_ownership() {
    if [ -z "$(wopt @claude_saved_auto)" ]; then
        set_wopt @claude_saved_auto  "$(wopt automatic-rename)"
        set_wopt @claude_saved_allow "$(wopt allow-rename)"
    fi
    set_wopt automatic-rename off
    set_wopt allow-rename off
}

release_ownership() {
    local a r
    a=$(wopt @claude_saved_auto); r=$(wopt @claude_saved_allow)
    # Restoring automatic-rename to "on" intentionally lets tmux resume naming the
    # window after its command — that's what a user with auto-rename on expects.
    set_wopt automatic-rename "${a:-on}"
    set_wopt allow-rename "${r:-on}"
    unset_wopt @claude_saved_auto
    unset_wopt @claude_saved_allow
}

# Remember your title once per turn-cycle. Only runs when nothing is stashed yet,
# and never captures our own transient states, so an interrupted turn can't get a
# tool name recorded as the "original".
capture_name() {
    [ -n "$(wopt "$NAME_OPT")" ] && return
    local cur
    cur=$(tmux display-message -t "$WINDOW_ID" -p '#W')
    case "$cur" in ""|"thinking...") return ;; esac
    set_wopt "$NAME_OPT" "$cur"
}

restore_name() {
    local orig
    orig=$(wopt "$NAME_OPT")
    [ -n "$orig" ] && tmux rename-window -t "$WINDOW_ID" "$orig"
    unset_wopt "$NAME_OPT"
}

case "$EVENT" in
    SessionStart)
        # Take ownership of the window name up front so nothing (tmux auto-rename
        # or the shell's title escapes) can clobber it while Claude runs here.
        take_ownership
        ;;
    UserPromptSubmit)
        take_ownership          # in case the SessionStart event was missed
        capture_name
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
        restore_name
        # Chime — but only when you're not already watching this window.
        should_play_sound && play_done_sound
        ;;
    SessionEnd)
        # Clear styling, restore the name, and hand rename settings back.
        clear_style
        restore_name
        release_ownership
        ;;
esac
