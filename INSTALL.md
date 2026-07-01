# Install guide

Claude Vitals has two parts:

1. **The app** - a macOS menu-bar app that shows live status of your Claude Code sessions.
   Works on its own with zero configuration (reads `~/.claude` + the process list).
2. **The plugin (optional)** - a Claude Code plugin whose hooks push lifecycle events to the
   app for *instant, precise* status (permission prompts, turn/tool transitions, sub-agents).
   Without it the app still works, just via polling (1.5-5s) instead of push.

## 1. Build and run the app

Requires macOS 14+ and the Swift toolchain (Xcode Command Line Tools: `xcode-select --install`).

```bash
git clone https://github.com/jancimertel/claude-vitals.git
cd claude-vitals
./make_app.sh          # builds release + ad-hoc-signs ClaudeVitals.app
open ClaudeVitals.app  # menu-bar glyph appears
```

Dev run without bundling: `swift run ClaudeVitals` (or `swift run ClaudeVitals --dump` for a headless snapshot).

## 2. Install the plugin (optional, for fast triggers)

### Preferred: marketplace install

From inside a Claude Code session:

```
/plugin marketplace add jancimertel/claude-vitals
/plugin install claude-vitals@jancimertel
/plugin list
```

At user scope this applies to every session in every repo (VS Code + CLI). Hooks resolve
`${CLAUDE_PLUGIN_ROOT}` automatically - no machine-specific paths. Disable anytime via `/plugin`.

### Fallback: no `/plugin` command

If your Claude Code build lacks the `/plugin` command, register the hooks directly:

```bash
./install.sh
```

This copies the hook script to `~/.claude-vitals/emit.sh` and merges the hooks into
`~/.claude/settings.json` (user scope, backup written to `settings.json.bak-vitals`). It is
idempotent and preserves any other hooks you have.

## 3. Verify

- In a session, run `/hooks` - the claude-vitals hooks should be listed (no restart needed).
- Trigger a Bash permission prompt in any repo - the app card flips to `needs permission`
  near-instantly. Finish a turn - the chime fires immediately.

## How it works

- **Baseline (always on):** the app tail-parses `~/.claude/projects/*.jsonl` and scrapes the
  process list, polling every 1.5-5s. This alone drives the whole display.
- **Hook overlay (when the plugin is installed):** lifecycle events arrive over a Unix domain
  socket (`~/.claude-vitals/vitals.sock`) and become the authoritative, low-latency source of
  session *state*, while the transcript stays the source of tokens/context/cost. Fresh hook
  state wins for a session; otherwise the app falls back to the transcript heuristic - so
  un-instrumented sessions behave exactly as without the plugin.

## Uninstall

- Marketplace: `/plugin uninstall claude-vitals@jancimertel`.
- Fallback: remove the `"hooks"` block from `~/.claude/settings.json` (or restore
  `~/.claude/settings.json.bak-vitals`), and `rm -rf ~/.claude-vitals`.
- Quit the app from its menu-bar Quit button.
