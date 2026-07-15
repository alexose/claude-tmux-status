# claude-tmux-status

Show what [Claude Code](https://claude.com/claude-code) is doing right now, right in your **tmux status bar**.

When Claude is running inside a tmux window, this hook renames and recolors that
window's entry in the status bar to reflect Claude's live state — so you can tell
at a glance which of your windows is thinking, running a tool, or waiting on you.

![Demo of the tmux status bar tracking Claude Code's live state](demo.gif)

```
[0] 0:dash  1:b  2:mage  3:other  4:zsh  5:django  6:bash  7:zsh  8:zsh  9:bash*
                                                            └─ green = Claude finished, waiting on you
```

## States

| Window shows   | Style          | Meaning                                            |
| -------------- | -------------- | -------------------------------------------------- |
| `thinking...`  | reverse video  | Claude is processing your prompt                   |
| `<tool-name>`  | reverse video  | Claude is running a tool (e.g. `bash`, `edit`)     |
| `<original>`   | green          | Claude finished / is waiting for your input        |
| `<original>`   | default        | Claude Code exited                                 |

The window's original name is captured when Claude starts and restored when it
stops, so it survives switching away and back. The name is stashed in a tmux
window option (not a temp file), and the window is locked with `allow-rename off`
/ `automatic-rename off` so neither tmux nor the shell's title escapes can clobber
your title. That lock **stays on** — the hook does not hand it back when Claude
exits, because re-enabling `automatic-rename` lets tmux instantly re-clobber the
title the moment the shell becomes the foreground process again.

If tmux's auto-rename already overwrote your title *before* the hook first ran
(e.g. the window shows `bash`, or `2.1.210` — Claude names its process after its
version), the hook won't save that process name as your "title." It recognizes
those artifacts — bare shell/interpreter names, version strings, a name matching
the pane's command — and falls back to the working-directory basename instead. A
title already mis-saved by an older version is healed the same way.

**Background agents.** The `Stop` event fires when the main agent finishes even if
tasks launched with `run_in_background` are still working. The hook reads the
`background_tasks` field from the `Stop` payload and, if anything is still
running, holds the window in the "busy" style and defers the chime until the last
background task actually finishes — so it won't signal "done" early. When the
still-running work is background sub-agents, the window shows a live count —
`2 agents running...` (or `1 agent running...`) — which ticks down as each agent
finishes and only turns green once the last one is done. Background *shell*
commands don't count toward that tally; if that's all that's left, your real
title is shown (in the busy style) instead. Sub-agent tool calls also fire
`PreToolUse` in the same pane; those carry an `agent_id`, and the hook uses that
to keep them from renaming your window to their tool (e.g. `bash`).

## How it works

A single hook script, `tmux-status.sh`, is wired to five Claude Code hook events
(`UserPromptSubmit`, `PreToolUse`, `Stop`, `Notification`, `SessionEnd`). On each
event it reads the event payload from stdin, figures out which tmux window it's
running in (via `$TMUX_PANE`), and calls `tmux rename-window` /
`set-window-option` accordingly. It's a no-op outside tmux.

All styling is applied dynamically by the script — **no `.tmux.conf` changes are
required**.

## Sound when Claude finishes (macOS)

When Claude finishes (the window turns green), the hook can play a sound — but
**only if you're not already looking at that window**. If your terminal is
frontmost *and* Claude's tmux window is the active one, it stays silent; if
you're in another app, or another tmux window, it chimes.

It's on by default on macOS (uses `lsappinfo` + `afplay`) and a no-op elsewhere.
Configure via environment variables in your `~/.claude/settings.json` env or
shell:

| Variable                   | Default | Meaning                                                                                 |
| -------------------------- | ------- | --------------------------------------------------------------------------------------- |
| `CLAUDE_TMUX_SOUND`        | `Pop`   | A macOS system-sound name (see `/System/Library/Sounds`), a path to a sound file, or `off` to disable. |
| `CLAUDE_TMUX_TERMINAL_APP` | *(auto)* | Comma-separated app name(s) that count as "your terminal", e.g. `iTerm2` or `Ghostty,Code`. |

`CLAUDE_TMUX_TERMINAL_APP` exists because tmux overwrites `$TERM_PROGRAM`, so the
host terminal can't be auto-detected. Without it, the hook matches the frontmost
app against a built-in list of common terminals (iTerm2, Terminal, Ghostty,
WezTerm, Alacritty, kitty, Warp, Code, Cursor, …). Set it if you use a terminal
that isn't recognized, or run more than one.

## Requirements

- [tmux](https://github.com/tmux/tmux)
- [jq](https://jqlang.github.io/jq/)
- Claude Code

## Install

```bash
git clone https://github.com/alexose/claude-tmux-status.git
cd claude-tmux-status
./install.sh
```

The installer copies `tmux-status.sh` into `~/.claude/hooks/` and merges the
required hook events into `~/.claude/settings.json` (backing it up first). It's
idempotent and won't duplicate entries on re-runs. Set `CLAUDE_CONFIG_DIR` to
target a non-default config directory.

Restart any running Claude Code sessions afterward to pick up the hooks.

## Manual install

If you'd rather not run the script:

1. Copy `tmux-status.sh` to `~/.claude/hooks/tmux-status.sh` and `chmod +x` it.
2. Merge the contents of `settings.hooks.json` into your `~/.claude/settings.json`
   (combine the `hooks` blocks if you already have one).

## Uninstall

Remove the five `~/.claude/hooks/tmux-status.sh` entries from the `hooks` block in
`~/.claude/settings.json` (or restore a `settings.json.bak.*` backup the installer
made), and delete `~/.claude/hooks/tmux-status.sh`.

## License

MIT
