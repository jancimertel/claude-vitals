# Menu-Bar Ring Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick, from the right-click menu, whether the menu-bar ring shows the 5h window or whichever window is higher, while any full window always shows the at-limit state.

**Architecture:** A pure `RateUsage.ring(_:)` picks one window (percent + reset) for a `MenuSource`. It replaces `menuPct`/`menuReset`, so `updateLabelImage`, `limitDrain`, `limitResetPassed` and the sweep loop all follow the same window. `AppDelegate` takes ownership of the `Store`, so the right-click menu can read and set `store.menuSource`.

**Tech Stack:** Swift 6, SwiftUI `MenuBarExtra`, AppKit `NSMenu`, `UserDefaults`.

**Spec:** `docs/superpowers/specs/2026-11-14-menu-bar-source-design.md`

## Global Constraints

- Build on this machine with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build`. XCTest is not installed, so `swift test` fails; pure-logic checks go in `--selfcheck` (`Sources/ClaudeVitals/Entry.swift`, `runSelfCheck`).
- Menu copy, exact: section header `Menu Bar Shows:`, items `5-Hour Window` and `Whichever Is Higher`.
- Default mode is 5h (today's behavior). Unknown or missing saved value means 5h.
- Only two modes. No weekly-only option.
- At the limit means `pct >= 100`, as in the existing `limitDrain`.
- Do not commit unless the user asks. `Store.swift` and `Views.swift` already hold unrelated uncommitted work (the loading animation, the footer overlay); leave it intact.

## Review Focus

- A full window whose reset header is missing: no drain is possible. Expect the full window with a known reset to win; if neither has one, show the higher one with no countdown, no crash. Test in Task 1.
- Switching modes while at the limit: the drain must not restart. Both modes pick the same window at the limit, so `limitDrain`'s saved `limitReset` key stays the same. Test in Task 1.
- The weekly reset passes while in 5h mode: `current()` zeroes the weekly window, and the ring goes back to the 5h value. Test in Task 1.
- A tie below the limit in higher mode: pick 5h and its reset. Test in Task 1.
- A garbage saved value in `UserDefaults` falls back to 5h. Test in Task 1.

---

### Task 1: `MenuSource` and `RateUsage.ring(_:)`

**Files:**
- Modify: `Sources/ClaudeVitals/UsageFetcher.swift:13-20` (replace `menuPct` and `menuReset`; keep `maxPct`)
- Modify: `Sources/ClaudeVitals/Store.swift:167, 185, 200, 210` (the four callers)
- Test: `Sources/ClaudeVitals/Entry.swift`, `runSelfCheck` (append before `exit(0)`)

**Interfaces:**
- Produces:
  - `enum MenuSource: String, CaseIterable { case fiveHour, higher }` in `UsageFetcher.swift`, with `var title: String` (`"5-Hour Window"`, `"Whichever Is Higher"`) and `static var saved: MenuSource { get set }` backed by `UserDefaults` key `"menuSource"`, defaulting to `.fiveHour` (same pattern as `AppTheme.saved`).
  - `struct RingWindow: Equatable, Sendable { var pct: Double; var reset: Date? }`
  - `extension RateUsage { func ring(_ source: MenuSource) -> RingWindow? }`

- [ ] **Step 1: Write the failing checks** in `runSelfCheck`, using the existing `check(_:_:)` helper:

```swift
let r1h = now.addingTimeInterval(3600), r3d = now.addingTimeInterval(3 * 86400)
func u(_ f: Double?, _ fr: Date?, _ w: Double?, _ wr: Date?) -> RateUsage {
    RateUsage(fiveH: f, sevenD: w, fiveHReset: fr, sevenDReset: wr, status: nil, capturedAt: now)
}
check("ring5hBelowLimit", u(40, r1h, 70, r3d).ring(.fiveHour) == RingWindow(pct: 40, reset: r1h))
check("ringHigherBelowLimit", u(40, r1h, 70, r3d).ring(.higher) == RingWindow(pct: 70, reset: r3d))
check("ringHigherTiePicks5h", u(50, r1h, 50, r3d).ring(.higher) == RingWindow(pct: 50, reset: r1h))
check("ring5hFallsBackToWeekly", u(nil, nil, 30, r3d).ring(.fiveHour) == RingWindow(pct: 30, reset: r3d))
check("ringWeeklyFullOverrides5h", u(20, r1h, 100, r3d).ring(.fiveHour) == RingWindow(pct: 100, reset: r3d))
check("ringBothFullPicksLaterReset", u(100, r1h, 100, r3d).ring(.fiveHour) == RingWindow(pct: 100, reset: r3d))
check("ringModesAgreeAtLimit", u(100, r1h, 60, r3d).ring(.fiveHour) == u(100, r1h, 60, r3d).ring(.higher))
check("ringFullWithKnownResetWins", u(100, nil, 100, r3d).ring(.fiveHour) == RingWindow(pct: 100, reset: r3d))
check("ringWeeklyResetPassedBackTo5h",
      u(20, r1h, 100, now.addingTimeInterval(-1)).current(now: now).ring(.fiveHour) == RingWindow(pct: 20, reset: r1h))
check("ringNoData", u(nil, nil, nil, nil).ring(.higher) == nil)
UserDefaults.standard.set("bogus", forKey: "menuSource")
check("menuSourceGarbageIsFiveHour", MenuSource.saved == .fiveHour)
UserDefaults.standard.removeObject(forKey: "menuSource")
```

- [ ] **Step 2: Run, verify it fails to compile**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build`
Expected: FAIL, `cannot find type 'RingWindow'` / `has no member 'ring'`.

- [ ] **Step 3: Implement `MenuSource`, `RingWindow` and `ring(_:)`** in `UsageFetcher.swift`. Delete `menuPct` and `menuReset`. The selection rule:

```
windows = [(fiveH, fiveHReset), (sevenD, sevenDReset)] with a non-nil pct, in that order
full = windows where pct >= 100
if full non-empty: return the full window with the latest non-nil reset;
                   if none has a reset, the one with the highest pct (5h on a tie)
fiveHour: return windows.first          // 5h, else weekly
higher:   return the max pct, 5h on a tie
```

Update the doc comments: the ring shows the chosen window below the limit, and the blocking window at the limit.

- [ ] **Step 4: Switch the four `Store` callers to `ring(menuSource)`.** Until Task 2 adds the property, use `ring(MenuSource.saved)`. `updateLabelImage` uses `.pct`. `limitDrain` and `limitResetPassed` use `.pct` and `.reset`. The sweep loop keeps reading `self.usage` as it does today.

- [ ] **Step 5: Build and run the checks**

Run: `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build && .build/debug/ClaudeVitals --selfcheck`
Expected: every line `ok ...`, exit code 0. Includes the 8 existing checks.

### Task 2: Store property and right-click menu items

**Files:**
- Modify: `Sources/ClaudeVitals/Store.swift:32-39` (add the property beside `theme`)
- Modify: `Sources/ClaudeVitals/App.swift` (store ownership, menu items)

**Interfaces:**
- Consumes: `MenuSource`, `MenuSource.saved`, `MenuSource.title`, `RateUsage.ring(_:)` from Task 1.
- Produces: `@Published var menuSource: MenuSource` on `Store`, and `let store = Store()` on `AppDelegate`.

- [ ] **Step 1: Add `@Published var menuSource = MenuSource.saved` to `Store`.** Its `didSet` saves to `MenuSource.saved`, sets `renderedPct = -2` and calls `updateLabelImage()`, the same as `theme`'s. Replace the Task 1 `MenuSource.saved` reads in the four callers with `menuSource`.

- [ ] **Step 2: Move `Store` ownership to `AppDelegate`.** Add `let store = Store()` to `AppDelegate`. Delete `@StateObject private var store` from `ClaudeVitalsApp` and pass `delegate.store` to `PopoverView` and `MenuLabel`. Reason: the right-click menu lives in `AppDelegate` and must reach the store.

- [ ] **Step 3: Add the menu section in `installContextMenu`**, above the Launch at Login block, in this order:

```
Menu Bar Shows:          (disabled header item, or NSMenuItem.sectionHeader(title:) on macOS 14+)
  5-Hour Window          (checkmark when store.menuSource == .fiveHour)
  Whichever Is Higher    (checkmark when store.menuSource == .higher)
──────────────
Launch at Login          (unchanged, only when LaunchAtLogin.available)
──────────────
Quit Claude Vitals  ⌘Q
```

Each item uses `@objc func pickMenuSource(_ sender: NSMenuItem)` on `AppDelegate`, with the `MenuSource` in `representedObject` (its `rawValue`), and sets `store.menuSource`. Show the section even when usage data is missing. Update the `installContextMenu` doc comment, which lists the menu's items.

- [ ] **Step 4: Build and check by hand**

Run: `./make_app.sh --install`
Expected in the running app:
- Right-click shows the menu above, with `5-Hour Window` checked on first launch.
- With weekly above 5h, picking `Whichever Is Higher` changes the ring's number right away. Picking `5-Hour Window` changes it back.
- Quit and relaunch: the choice is kept.
- `.build/debug/ClaudeVitals --selfcheck` still prints all `ok`.
