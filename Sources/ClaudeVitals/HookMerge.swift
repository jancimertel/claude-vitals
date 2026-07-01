import Foundation

/// Per-session precedence: a hook event newer than HOOK_FRESH_S is authoritative for state and liveness;
/// otherwise the existing transcript heuristic drives the card (so un-instrumented sessions are unchanged
/// and a session whose plugin was disabled degrades gracefully after one window).
func resolveState(heuristic: (dot: Dot, state: String), isLive: Bool, hook: HookStatus?, now: Date)
    -> (dot: Dot, state: String, live: Bool, usedHook: Bool) {
    if let h = hook, now.timeIntervalSince(h.at) < HOOK_FRESH_S {
        return (h.dot, h.state, h.alive, true)
    }
    return (heuristic.dot, heuristic.state, isLive, false)
}
