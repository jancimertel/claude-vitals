import Foundation

/// Freshness window: a hook this recent wins outright regardless of confirmed liveness or supersession.
/// It also doubles as the fallback gate when liveness can't be confirmed by the registry, and bounds how
/// far the transcript may advance past the last hook event before that hook is treated as superseded.
let HOOK_FRESH_S: TimeInterval = 15

/// One lifecycle event delivered by the Claude Code plugin over the socket. Field names mirror the
/// hook stdin payload; `event` maps the payload's `hook_event_name`.
struct HookEvent: Decodable, Sendable {
    let event: String
    let session_id: String
    let cwd: String?
    let transcript_path: String?
    let tool_name: String?
    let source, trigger, error, notification_type, agent_id, agent_type, permission_mode, effortLevel: String?

    enum CodingKeys: String, CodingKey {
        case event = "hook_event_name"
        case session_id, cwd, transcript_path, tool_name
        case source, trigger, error, notification_type, agent_id, agent_type, permission_mode
        case effortLevel = "effort"
    }

    /// `effort` arrives as `{"level": "..."}`, not a string.
    private struct EffortPayload: Decodable { let level: String? }

    init(event: String, session_id: String, cwd: String? = nil, transcript_path: String? = nil, tool_name: String? = nil,
         source: String? = nil, trigger: String? = nil, error: String? = nil, notification_type: String? = nil,
         agent_id: String? = nil, agent_type: String? = nil, permission_mode: String? = nil, effortLevel: String? = nil) {
        self.event = event; self.session_id = session_id
        self.cwd = cwd; self.transcript_path = transcript_path; self.tool_name = tool_name
        self.source = source; self.trigger = trigger; self.error = error; self.notification_type = notification_type
        self.agent_id = agent_id; self.agent_type = agent_type; self.permission_mode = permission_mode
        self.effortLevel = effortLevel
    }

    // New fields all use `try?`: EventSocket silently drops undecodable payloads, so an unexpected shape
    // (effort as a string, error as an object) must yield nil rather than lose the whole event.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event = try c.decode(String.self, forKey: .event)
        session_id = try c.decode(String.self, forKey: .session_id)
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        transcript_path = try? c.decodeIfPresent(String.self, forKey: .transcript_path)
        tool_name = try? c.decodeIfPresent(String.self, forKey: .tool_name)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        trigger = try? c.decodeIfPresent(String.self, forKey: .trigger)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        notification_type = try? c.decodeIfPresent(String.self, forKey: .notification_type)
        agent_id = try? c.decodeIfPresent(String.self, forKey: .agent_id)
        agent_type = try? c.decodeIfPresent(String.self, forKey: .agent_type)
        permission_mode = try? c.decodeIfPresent(String.self, forKey: .permission_mode)
        effortLevel = (try? c.decodeIfPresent(EffortPayload.self, forKey: .effortLevel))?.level
    }
}

/// The current hook-derived state for one session. `at` is receipt time (used for the freshness gate).
struct HookStatus: Sendable {
    var dot: Dot
    var state: String
    var toolName: String?
    var alive: Bool
    var at: Date
}

/// Fold one event into the running per-session status. Numbers (tokens/ctx/cost) are NOT tracked here;
/// they come from the transcript. Subagent events carry no state change - they exist only to trigger an
/// immediate re-parse (which recomputes the file-based subagent count) at the call site. Returns nil when
/// a stateless event arrives with no prior status: there is nothing real to refresh, and minting a
/// fabricated "idle" would stick under confirmed liveness. Falls through (refresh `at` only): untyped or
/// other-typed Notification, subagent StopFailure, ungated compaction events, SubagentStart/Stop, unknown.
func applyHookEvent(_ prev: HookStatus?, _ e: HookEvent, at now: Date) -> HookStatus? {
    var s = prev ?? HookStatus(dot: .idle, state: "idle", toolName: nil, alive: true, at: now)
    s.at = now
    switch e.event {
    // A compact SessionStart lands mid-turn; treating it as a fresh session would flash a false "finished".
    case "SessionStart" where e.source != "compact": s.alive = true;  s.dot = .waiting; s.state = "waiting prompt"; s.toolName = nil
    case "SessionEnd":        s.alive = false; s.dot = .ended;            s.state = "ended";          s.toolName = nil
    case "UserPromptSubmit":  s.dot = .runningModel; s.state = "running model"; s.toolName = nil
    case "PreToolUse":        s.dot = .runningTool;  s.state = "running \(e.tool_name ?? "tool")"; s.toolName = e.tool_name
    case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
                              s.dot = .runningModel; s.state = "running model"; s.toolName = nil
    case "PermissionRequest": s.dot = .waitingPermission; s.state = "needs permission"; s.toolName = e.tool_name
    case "Stop":              s.dot = .waiting;      s.state = "waiting prompt"; s.toolName = nil
    // Subagent events carry the parent's session_id, so a subagent API error must not fail the parent.
    case "StopFailure" where e.agent_id == nil:
        s.dot = .failed; s.state = "failed: \((e.error ?? "unknown").replacingOccurrences(of: "_", with: " "))"; s.toolName = nil
    // Async delivery can reorder: a late auto PreCompact after the turn ended must not resurrect "running".
    case "PreCompact" where e.trigger == "manual" || prev?.dot.isRunning == true:
        s.dot = .compacting; s.state = "compacting"; s.toolName = nil
    // Only meaningful right after PreCompact; a late PostCompact must not overwrite the next hook's state.
    case "PostCompact" where prev?.dot == .compacting:
        if e.trigger == "manual" { s.dot = .waiting; s.state = "waiting prompt" } else { s.dot = .runningModel; s.state = "running model" }
        s.toolName = nil
    // Typed notifications are backstops for missed PermissionRequest/Stop; gated on running so a late one
    // cannot overwrite a newer state (including failed).
    case "Notification" where e.notification_type == "permission_prompt" && prev?.dot.isRunning == true:
        s.dot = .waitingPermission; s.state = "needs permission"
    case "Notification" where e.notification_type == "idle_prompt" && prev?.dot.isRunning == true:
        s.dot = .waiting; s.state = "waiting prompt"; s.toolName = nil
    // Everything else carries no state, so it just refreshes `at` (set above) - and with no prior status
    // there is nothing to refresh: minting an "idle" here would stick, because confirmed liveness keeps
    // hook state authoritative until a real event replaces it.
    default: return prev == nil ? nil : s
    }
    return s
}
