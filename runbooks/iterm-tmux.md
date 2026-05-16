# iTerm2 + tmux Runbook

> **Owner:** <your-name> | **Last verified:** 2026-04-27

## Auth

- **Method:** SSH key-based auth between machines
- **Vault:** N/A
- **Secret name:** N/A
- **Env var:** N/A
- **Fetch creds:** N/A — SSH keys in `~/.ssh/`
- **MCP server:** N/A

## Architecture

Sessions run on a central server (currently Mac Studio). Laptop connects via SSH + tmux `-CC` integration mode. Future: Mac Mini replaces Studio as server.

```
MacBook Pro (client) → SSH → Mac Studio (server) → tmux server
```

Config repo: https://github.com/<your-username>/iterm-config (private)

## Common Operations

### List sessions
```bash
tmux ls
# or via shell function:
cca --list            # local
cca --list-studio     # remote
```

### Create/attach named session
```bash
cca --studio --name "my-task"    # SSH to Studio, tmux new-session -A
occ --studio --name "my-task"    # same for OCC context
cca --resume                     # local, claude --resume
```

### Rename session (from Claude Code)
```bash
/rename "My Session Name"
# Hook chain: built-in /rename → rename-on-prompt.sh → rename-session.sh --no-tui
# Renames: Claude banner + tmux session + tmux window + iTerm session
```

### Rename session (from shell)
```bash
tmux rename-session -t old-name new-name
# or Ctrl+B then $
```

### Save/restore sessions
tmux-resurrect + tmux-continuum handle this automatically.
- Auto-save every 15 min
- Auto-restore on tmux server start
- Pane contents captured

### Split panes
In tmux `-CC` mode, native iTerm shortcuts work:
- **Cmd+D** → vertical split
- **Cmd+Shift+D** → horizontal split

Without `-CC`, use tmux prefix:
- **Ctrl+B %** → vertical split
- **Ctrl+B "** → horizontal split

## <your-org>-Specific IDs

| Resource | Value |
|----------|-------|
| Studio SSH hosts | `studio-lan` (LAN IP), `studio` (mDNS: <host>.local) |
| Laptop SSH hosts | `mbp-lan` (LAN IP), `mbp` (mDNS: macbook-pro) |
| tmux binary | `/opt/homebrew/bin/tmux` |
| Config repo | `<your-username>/iterm-config` |

## iTerm Settings

| Key | Value | Why |
|-----|-------|-----|
| `OpenTmuxWindowsIn` | 1 | tmux -CC windows → native iTerm tabs |
| `TmuxSyncClipboard` | true | tmux copy → macOS clipboard |
| `OpenArrangementAtStartup` | false | tmux owns layout, not iTerm |
| `GlobalKeyMap` | 16 bindings | Pane nav, resize, tabs, profile switching |

Settings are in the plist: `~/Library/Preferences/com.googlecode.iterm2.plist`. Edit via `defaults` or Python `plistlib`.

## Shell Functions

`_ssh_try`, `cca`, `occ` live in `~/.zshrc` on both machines. Canonical copy in `<your-username>/iterm-config/shell-functions.sh`.

`_ssh_try` attempts LAN IP first (fast, 2s timeout), falls back to mDNS hostname on SSH failure (rc=255).

`_cca_pane_session` generates per-pane tmux session names from `ITERM_SESSION_ID` (sanitized — colons replaced with hyphens).

## Gotchas

- **tmux session names reject `:` and `.`** — `rename-session.sh` sanitizes them to hyphens via `tr ':.' '--'`
- **`tmux -CC` mode** makes Cmd+D/Cmd+Shift+D work natively — no custom iTerm keybindings needed for splits
- **`destroy-unattached off`** is required in tmux.conf — without it, sessions die when the last client disconnects
- **DHCP IP changes** — LAN IPs shift; `_ssh_try` falls back to mDNS but SSH `known_hosts` may reject the new key. Use `StrictHostKeyChecking=accept-new` or clean the old entry
- **iTerm `OpenTmuxWindowsIn`** — 1=native tabs (correct), 2=native windows (splits each tmux window into a separate iTerm window, cluttered)
- **iTerm GlobalKeyMap vs per-profile Keyboard Map** — Global applies to all profiles. Per-profile keybindings for universal shortcuts (like splits) break when switching profiles
- **`/rename` hook renames tmux session AND window** — prior to 2026-04-27 it only renamed the window, so `tmux ls` / `ts` still showed UUID names
- **`automatic-rename on` clobbers scripted window names** — tmux default overwrites `rename-window` with the current process name (zsh, claude, etc.) within seconds. `rename-session.sh` now sets `set-option -w automatic-rename off` after renaming to prevent this. Session names (`rename-session`) are NOT affected by `automatic-rename`
- **Saved window arrangements are redundant with tmux** — iTerm arrangements open blank shells that don't auto-attach to tmux sessions. Let tmux own the layout

## Troubleshooting

| Symptom | Resolution |
|---------|------------|
| `ts` shows UUID names after `/rename` | Verify `rename-session.sh` has `tmux rename-session` (not just `rename-window`). Run `tmux rename-session -t UUID "name"` to fix existing |
| SSH "Host key verification failed" after IP change | `ssh-keygen -R <old-ip>` then reconnect with `StrictHostKeyChecking=accept-new` |
| Cmd+D opens iTerm split instead of tmux split | Not in `-CC` mode. Connect with `tmux -CC attach` or use `cca --studio --cc` |
| Sessions gone after reboot | Check tmux-resurrect: `ls ~/.tmux/resurrect/`. If empty, continuum wasn't saving — verify `@continuum-save-interval` in tmux.conf |
| iTerm plist changes don't take effect | Restart iTerm. Running `defaults write` while iTerm is open may be overwritten on quit |

## Resolved Issues

| Date | Issue | Root Cause | Fix |
|------|-------|-----------|-----|
| 2026-04-27 | `/rename` didn't update tmux session name, only window name | `rename-session.sh` called `tmux rename-window` but not `tmux rename-session` | Added `tmux rename-session` before `rename-window` in the script |
| 2026-04-27 | Colons in session names silently mangled by tmux | tmux rejects `:` and `.` in session names | Added `tr ':.' '--'` to `sanitize()` in `rename-session.sh` |
| 2026-04-27 | Studio iTerm missing pane nav keybindings | Keybindings were never copied from laptop; laptop uses GlobalKeyMap, not per-profile | Copied 16 global keybindings via plistlib |
| 2026-04-27 | Studio `OpenTmuxWindowsIn=2` caused window explosion | Each tmux window opened as separate iTerm window | Set to 1 (native tabs) matching laptop |
| 2026-04-28 | `/rename` window name didn't persist — reverted to process name | tmux `automatic-rename on` (default) overwrites `rename-window` with current process | `rename-session.sh` now calls `set-option -w automatic-rename off` after renaming |
| 2026-04-28 | `/start-task` didn't rename tmux session | No rename step in `start-task.md` skill | Added step 8.5 calling `rename-session.sh --no-tui` with task slug |
