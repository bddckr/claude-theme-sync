# Claude Theme Sync

Automatically sync [Claude Code](https://claude.ai/code) theme with macOS dark/light mode — **live, in already-running sessions**.

When you toggle macOS appearance, this daemon flips a custom `AutoSync` theme file that Claude Code watches, so open sessions repaint without a restart.

## Installation

```bash
git clone https://github.com/alfredomtx/claude-theme-sync.git
cd claude-theme-sync
./install.sh
```

That's it! The daemon is now running and will start automatically on login.

## Requirements

- macOS
- Xcode Command Line Tools (`xcode-select --install`)
- [Claude Code](https://claude.ai/code)

## How It Works

1. A lightweight Swift daemon listens to macOS appearance-change notifications.
2. On a change it writes a custom theme file, `<config>/themes/autosync.json`, flipping only its `base` between `dark` and `light`.
3. Claude Code watches its `themes/` folder and hot-reloads, so any running session set to the **AutoSync** theme repaints without a restart.

> The theme is named **AutoSync**, not `auto` — Claude Code has a built-in `auto` theme (startup-only detection); a custom `auto` would collide with it.

It keeps every config root in sync — the default `~/.claude` and the `~/.claude-personal` root used by a `CLAUDE_CONFIG_DIR=$HOME/.claude-personal claude` alias.

## One-time setup

In each Claude Code (regular and `claude-personal`): run `/theme` and pick **AutoSync** once (not the built-in `auto`). That's the theme the daemon drives.

> If `<config>/themes/` didn't exist when a session started, restart that session once — Claude Code only starts watching the folder if it exists at launch. The installer's first run creates it, so this only bites pre-existing sessions.

## Commands

```bash
# Check if running
launchctl list | grep claude-theme-sync

# View logs
tail -f ~/.claude/theme-sync/claude-theme-sync.log

# Restart
launchctl unload ~/Library/LaunchAgents/com.claude.theme-sync.plist
launchctl load ~/Library/LaunchAgents/com.claude.theme-sync.plist
```

## Uninstall

```bash
~/.claude/theme-sync/uninstall.sh
```

## Technical Details

The live-reload channel is Claude Code's custom-theme watcher, not the `theme` key in `~/.claude.json` (which is read only at startup). The daemon maintains `<config>/themes/autosync.json`:

```json
{
  "name": "AutoSync",
  "base": "dark",
  "overrides": {}
}
```

On `AppleInterfaceThemeChangedNotification` it rewrites only `base` (preserving any `name`/`overrides` you've added). Dark/light is read from the global-domain `AppleInterfaceStyle` pref via `CFPreferences` (forced resync each time, since `UserDefaults` caches and can report the old value in the notification handler).

**Caveat:** a repaint lands when the agent is idle — Claude Code doesn't switch theme mid-generation ([#30690](https://github.com/anthropics/claude-code/issues/30690)).

## License

MIT
