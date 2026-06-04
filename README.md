# Claude Vitals (Swift / SwiftUI)

A native macOS **menu-bar** app showing live Claude Code session status across every codebase —
side-by-side cards with state, context-fill ring, and effort/cost. Reads `~/.claude` and the process
list only. **No network, no API, no Apple Developer account.**

This is the Swift rewrite of an earlier Python `rumps` prototype; the data layer was verified to
match it exactly.

---

## Run

**Dev (unbundled):**
```bash
cd claude-vitals
swift run                # menu-bar app
swift run ClaudeVitals --dump   # headless: print the snapshot and exit (data-layer test)
```

**Real app (bundled — enables notifications + launch-at-login):**
```bash
./make_app.sh            # builds release, wraps into an ad-hoc-signed ClaudeVitals.app
open ClaudeVitals.app
# or move it to /Applications
```

Requires only the Swift toolchain (Xcode Command Line Tools). Built/verified on Swift 6.2 / macOS 26.

---

## What it shows

**Menu bar:** a **usage loader ring** + text.
- The ring = `max(5h, weekly)` **subscription usage %**, green→amber→red, filled center at **≥100% (limit exceeded)**. This is the primary glyph whenever fresh usage data exists.
- Text = running session count while busy, else the usage %; `🔔` prefix when a session is waiting.
- When there's no fresh usage data (no session has rendered a status line lately), the ring falls back to a status dot: `○` idle · `●N` N running · 🔔 waiting.

**Popover (click the glyph):**
- **Header** — running count, sub-agents running, and total tokens / cost *this session*.
- **Cards** (1–3 column grid, one per active session):
  - **Context ring** — circular gauge, green→amber→orange→red as the window fills, % + token count.
  - **State badge** — 🟢 running model · 🔧 running tool · 🟡 waiting prompt · ⚪️ idle (pulses while running).
  - repo name, git branch, model.
  - **Effort row** — ↑input ↓output tokens, cache, $cost, turns, tool-calls.
  - **Sub-agent chips** — a dot per running sub-agent + total.
  - **Click a card** → opens that repo in VS Code.
- **Footer** — Refresh, Launch-at-login toggle (bundled only), Quit.

**Alerts** — when a session transitions running → waiting, a one-shot chime (always) + notification
(bundled). Edge-triggered, so no repeated dinging.

---

## Subscription usage loader (5h / weekly)

Shows the **real** 5-hour ("session") and 7-day ("weekly") utilization — the same numbers as
`/usage`. The values aren't stored on disk anywhere; they arrive only in Anthropic's
**unified rate-limit response headers**. So the app reads them directly:

- `RateLimitFetcher` reads the Claude Code OAuth token from the Keychain
  (`security find-generic-password -s "Claude Code-credentials"`), then makes a **minimal
  `/v1/messages` call** (`max_tokens: 1`, ~1 token — `count_tokens` doesn't return the headers).
- Parses `anthropic-ratelimit-unified-{5h,7d}-utilization` (→ %), `-reset` (→ countdown), `-status`.
- Polled every **2 min**; the glyph shows `max(5h, 7d)%`. On auth/network failure it keeps the last
  good value (Claude Code refreshes the token as you use it).

The popover strip shows both windows as bars with reset countdowns (`5h 11% · 4h34m`).

**Notes:** this uses your own subscription token against the API (unofficial — could change), and each
check spends ~1 token of your quota. First run may show a one-time Keychain prompt — click
**Always Allow**. No token or credential is ever written or logged.

## How it works (data layer)

Same sources as the Python prototype, all verified:

- **Live sessions** — `/usr/bin/pgrep -f 'native-binary/claude.*stream-json'` → PIDs;
  `/usr/sbin/lsof` → each PID's cwd. Liveness is matched to a session by **encoded project-dir name**
  (robust even if a transcript header lacks `cwd`).
- **Transcripts** — `~/.claude/projects/<encoded-path>/<uuid>.jsonl`; file mtime = activity.
- **State** — scans the tail backward for the last `user`/`assistant` line (transcripts end with
  non-conversational lines) + file age.
- **Context %** — latest `usage` line, `input + cache_read + cache_creation` ÷ window (200k, or 1M).
- **Effort/cost** — incremental byte-offset parse (only newly appended bytes each poll), per-model
  pricing table.
- **Sub-agents** — `<uuid>/subagents/agent-*.jsonl`; mtime < 10s ⇒ running.

Polling is adaptive: **1.5s** while anything runs, **5s** idle. Parsing runs off the main thread
(a `Collector` actor); the UI publishes on the main actor.

---

## Source map

| File | Responsibility |
|---|---|
| `Entry.swift` | `@main`; `--dump` branch vs launching the GUI; sets `.accessory` (no Dock icon). |
| `App.swift` | `MenuBarExtra(.window)` scene + `AppDelegate`. |
| `Models.swift` | Tolerant Codable transcript subset; `Dot`/`Block`/`Snapshot`/`Effort`. |
| `Collector.swift` | pgrep/lsof, candidate files, state/context/sub-agents, `buildSnapshot`, `Collector` actor. |
| `TranscriptParser.swift` | Incremental effort cache (mtime+offset gated) + pricing. |
| `Store.swift` | `@MainActor` observable store, adaptive poll loop, running→waiting edge detection. |
| `Views.swift` | Popover, header, session card, context ring, pulse dot, footer, menu-bar label. |
| `Integrations.swift` | Notifications, chime, VS Code launcher, launch-at-login (all bundle-guarded). |
| `Theme.swift` | Dark color tokens. `AppEnv.swift` | bundle detection gating bundle-only APIs. |
| `make_app.sh` | Wrap release binary into a signed `.app` (Info.plist, `LSUIElement`). |

---

## Notes

- **Personal use needs no signing/account** — `make_app.sh` ad-hoc signs (`codesign -s -`), which is
  enough for notifications and launch-at-login on your own machine. Sharing with others would need
  notarization.
- **Cost is a public-rate estimate** (sums per-message `usage`), good for relative comparison.
- Built quality-checked: a multi-lens adversarial review pass fixed cache-invalidation,
  liveness-detection, animation-restart, and state-detection edge cases.
