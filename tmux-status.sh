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
# Tool calls made *inside a subagent* fire PreToolUse in this same pane and carry
# an agent_id; the main agent's calls don't. We use this to keep background agents
# from clobbering your window title.
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')

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

# Lock the window name so ONLY this script ever changes it, and keep it that way.
# automatic-rename off stops tmux naming the window after its foreground process —
# which is how you get "bash" (the shell) or "2.1.210" (Claude sets its process
# title to its version). allow-rename off stops programs in the pane (the shell's
# title escapes) from doing the same. Our own `tmux rename-window` still works;
# allow-rename only gates in-band escape sequences.
#
# We deliberately do NOT restore these to "on" when Claude exits. Handing
# auto-rename back re-opens the door: the instant the shell (or a new Claude)
# becomes the foreground process, tmux clobbers your title again. Staying locked
# is the whole point — the window keeps whatever name it has until you change it.
take_ownership() {
    set_wopt automatic-rename off
    set_wopt allow-rename off
}

# A window name we must never treat as "your title" — it's a process artifact, not
# something you chose: empty, one of our own state labels, a version string (Claude
# names its process after its version), a name identical to the pane's foreground
# command, or a bare shell/interpreter name (how tmux auto-rename produced "bash"
# before we ever ran).
is_bad_name() {
    local n="$1" cmd="$2"
    case "$n" in
        ""|"thinking..."|*"agent running..."|*"agents running...") return 0 ;;
        bash|zsh|sh|fish|node|python|python3|ruby|deno|bun|tmux) return 0 ;;
    esac
    [ "$n" = "$cmd" ] && return 0
    case "$n" in [0-9]*.[0-9]*.[0-9]*) return 0 ;; esac   # looks like a version
    return 1
}

# If the stash holds a process artifact (including ones captured by older versions
# of this script, e.g. "2.1.210"/"bash"), replace it with the pane's directory
# basename — a stable, meaningful window name. Never reads the *live* window name,
# which during a turn is our own transient state, so it's safe to call any time.
heal_stash() {
    local saved
    saved=$(wopt "$NAME_OPT")
    [ -z "$saved" ] && return
    if is_bad_name "$saved" "$(tmux display-message -t "$WINDOW_ID" -p '#{pane_current_command}')"; then
        local dir; dir=$(tmux display-message -t "$WINDOW_ID" -p '#{b:pane_current_path}')
        set_wopt "$NAME_OPT" "${dir:-shell}"
    fi
}

# Capture your title once per session, from the IDLE window name (call before we
# rename to a state). If that name is already a process artifact — because tmux
# auto-renamed the window before Claude's first hook fired — fall back to the
# directory basename rather than saving garbage.
capture_name() {
    heal_stash
    [ -n "$(wopt "$NAME_OPT")" ] && return
    local cur cmd
    cur=$(tmux display-message -t "$WINDOW_ID" -p '#W')
    cmd=$(tmux display-message -t "$WINDOW_ID" -p '#{pane_current_command}')
    if is_bad_name "$cur" "$cmd"; then
        cur=$(tmux display-message -t "$WINDOW_ID" -p '#{b:pane_current_path}')
    fi
    set_wopt "$NAME_OPT" "${cur:-shell}"
}

# Restore the saved title but KEEP it stashed — do not unset here. Stop can fire
# more than once per turn (e.g. each time a background task hands control back),
# and the original must survive every one of those until SessionEnd.
restore_name() {
    heal_stash
    local orig
    orig=$(wopt "$NAME_OPT")
    [ -n "$orig" ] && tmux rename-window -t "$WINDOW_ID" "$orig"
}

# True (0) when a background task (shell or agent launched with run_in_background)
# is still running. Read from the Stop payload's background_tasks array — the turn
# ended but the work hasn't, so we must not signal "done" yet.
background_running() {
    local n
    n=$(echo "$INPUT" | jq -r '[.background_tasks[]? | select(.status=="running")] | length' 2>/dev/null)
    [ "${n:-0}" -gt 0 ]
}

# Count of background *agents* (sub-agents launched with run_in_background) still
# running. In the Stop payload these are entries with type "subagent"; background
# shell commands are type "shell", so they don't count toward the agent tally.
running_agent_count() {
    echo "$INPUT" | jq -r '[.background_tasks[]? | select(.type=="subagent" and .status=="running")] | length' 2>/dev/null
}

case "$EVENT" in
    SessionStart)
        # Lock the window up front, then grab the current name as early as possible
        # (before we've renamed anything) so we capture your real title if it's
        # still intact.
        take_ownership
        capture_name
        ;;
    UserPromptSubmit)
        take_ownership          # in case the SessionStart event was missed
        capture_name
        tmux rename-window -t "$WINDOW_ID" "thinking..."
        set_active
        ;;
    PreToolUse)
        if [ -n "$AGENT_ID" ]; then
            # A background/sub agent's tool call. Show "busy" but DON'T rename the
            # window to its tool — that's what kept overwriting your title with
            # "bash" while a background agent worked.
            set_active
        else
            TOOL_LOWER=$(echo "${TOOL:-tool}" | tr '[:upper:]' '[:lower:]')
            tmux rename-window -t "$WINDOW_ID" "$TOOL_LOWER"
            set_active
        fi
        ;;
    Stop|Notification)
        if background_running; then
            # The turn ended but background work is still going: hold off on the
            # chime / green until the last background task actually finishes, and
            # show what's still working in "busy" style.
            AGENTS=$(running_agent_count)
            if [ "${AGENTS:-0}" -ge 2 ]; then
                tmux rename-window -t "$WINDOW_ID" "$AGENTS agents running..."
            elif [ "${AGENTS:-0}" -eq 1 ]; then
                tmux rename-window -t "$WINDOW_ID" "1 agent running..."
            else
                # only non-agent background work (e.g. a shell command) — keep
                # your real title, just styled busy.
                restore_name
            fi
            set_active
            exit 0
        fi
        # Truly done: restore original window name with a "done" highlight.
        set_done
        restore_name
        # Chime — but only when you're not already watching this window.
        should_play_sound && play_done_sound
        ;;
    SessionEnd)
        # Clear styling and restore the name. The window stays LOCKED (we don't turn
        # automatic-rename / allow-rename back on) so the restored title can't be
        # clobbered the moment the shell becomes the foreground process again.
        clear_style
        restore_name
        unset_wopt "$NAME_OPT"
        unset_wopt @claude_saved_auto     # clean up bookkeeping from older versions
        unset_wopt @claude_saved_allow
        ;;
esac
