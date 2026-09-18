import Foundation

/// Per-session precedence: while liveness is CONFIRMED (the registry named this exact session), hook
/// state stays authoritative until a later hook event replaces it - so an unanswered permission prompt
/// keeps its badge no matter how long the user takes to respond. HOOK_FRESH_S is the fallback gate, used
/// only when liveness can't be confirmed (process-scan guess, or nothing live): an un-instrumented
/// session, or one whose plugin got disabled mid-session, degrades to the transcript heuristic after one
/// window.
///
/// `superseded` detects "hooks stopped firing" (plugin disabled mid-session): the transcript kept
/// advancing more than HOOK_FRESH_S past the last hook event. For a pending permission prompt the
/// transcript normally does not overtake the hook this way - the pending `tool_use` line is written
/// BEFORE `PermissionRequest` fires, and the transcript then sits still while the user decides - but a
/// sibling tool call in the same parallel batch can still append a `tool_result` after the window, so
/// `waitingPermission` is exempted outright rather than trusted to timing.
///
/// ponytail: known ceiling - a DROPPED hook event (delivery is best-effort) whose contradicting transcript
/// write lands inside the window is not superseded, so a stale "running X" can persist until the next hook
/// event. Tightening the bound would misfire on ordinary parallel tool calls.
func resolveState(heuristic: (dot: Dot, state: String), isLive: Bool, liveConfirmed: Bool,
                  hook: HookStatus?, transcriptMtime: Date, now: Date)
    -> (dot: Dot, state: String, live: Bool, usedHook: Bool) {
    if let h = hook {
        let fresh = now.timeIntervalSince(h.at) < HOOK_FRESH_S
        // A pending permission prompt is exempt: hooks are demonstrably alive (one just fired), so a
        // sibling tool_result landing while the user decides must not revoke the badge - that flicker
        // would also re-fire the alert. It clears on the next hook event or when the session stops
        // being confirmed live.
        let superseded = h.dot != .waitingPermission
            && transcriptMtime.timeIntervalSince(h.at) > HOOK_FRESH_S
        if fresh || (liveConfirmed && !superseded) {
            return (h.dot, h.state, h.alive, true)
        }
    }
    return (heuristic.dot, heuristic.state, isLive, false)
}
