# Menu-bar ring source: 5h or whichever is higher

## Intent

The menu-bar ring always shows the 5h window (`RateUsage.menuPct = fiveH ?? sevenD`, since
`8fae151`). Before that it showed `max(5h, 7d)`. Let the user choose between the two, from the
existing right-click menu on the menu-bar icon.

## Goals

- Right-click menu gets a "Menu Bar Shows:" section with two checkmarked items:
  "5-Hour Window" (default, today's behavior) and "Whichever Is Higher".
- The choice persists in `UserDefaults` and redraws the ring immediately when changed.
- Being blocked is never hidden: if either window is at or above 100%, the ring shows the
  at-limit state (heartbeat + draining countdown), in both modes.

## Non-goals

- No weekly-only option.
- No gear icon, settings panel or settings window. The footer is unchanged.
- No indicator of which window the ring is showing in "higher" mode (the popover lists both).

## Behavior

- Below the limit (both windows < 100%): ring shows `fiveH ?? sevenD` in 5h mode, `max(fiveH, sevenD)`
  in higher mode.
- At the limit (any window >= 100%), either mode: ring shows that window's percent, the heartbeat,
  and drains toward that window's reset. If both are at the limit, use the later reset, since the
  user stays blocked until then.
- `limitDrain`, `limitResetPassed` and the sweep loop all follow the same window as the percent.
  The percent and its reset must always come from one window.

## Approaches considered

- Gear icon in the footer opening a native menu: visible, but a second menu for two settings.
- Gear opening an in-popover panel: themed, but ~3x the work and fights the popover sizing workaround.
- Separate Settings window: heavy for a menu-bar-only app.
- **Chosen: items in the existing right-click menu.** Launch at Login already lives there; no new UI.
- Considered dropping the countdown in higher mode; kept it, because one at-limit rule for both
  modes is less code, and a weekly wait without a drain would show a frozen full ring for days.

## Left to the builder

- Name of the `UserDefaults` key and the Swift type for the mode.
- How `RateUsage` exposes the chosen percent/reset pair (for example one method returning both).
