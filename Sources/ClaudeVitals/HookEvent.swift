import Foundation

/// Hook state wins over the transcript heuristic while its last event is newer than this.
let HOOK_FRESH_S: TimeInterval = 15

/// One lifecycle event delivered by the Claude Code plugin over the socket. Field names mirror the
/// hook stdin payload; `event` maps the payload's `hook_event_name`.
struct HookEvent: Decodable, Sendable {
    let event: String
    let session_id: String
    let cwd: String?
    let transcript_path: String?
    let tool_name: String?

    enum CodingKeys: String, CodingKey {
        case event = "hook_event_name"
        case session_id, cwd, transcript_path, tool_name
    }

    init(event: String, session_id: String, cwd: String?, transcript_path: String?, tool_name: String?) {
        self.event = event; self.session_id = session_id
        self.cwd = cwd; self.transcript_path = transcript_path; self.tool_name = tool_name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event = try c.decode(String.self, forKey: .event)
        session_id = try c.decode(String.self, forKey: .session_id)
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        transcript_path = try? c.decodeIfPresent(String.self, forKey: .transcript_path)
        tool_name = try? c.decodeIfPresent(String.self, forKey: .tool_name)
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
/// immediate re-parse (which recomputes the file-based subagent count) at the call site.
func applyHookEvent(_ prev: HookStatus?, _ e: HookEvent, at now: Date) -> HookStatus {
    var s = prev ?? HookStatus(dot: .idle, state: "idle", toolName: nil, alive: true, at: now)
    s.at = now
    switch e.event {
    case "SessionStart":      s.alive = true;  s.dot = .waiting;          s.state = "waiting prompt"; s.toolName = nil
    case "SessionEnd":        s.alive = false; s.dot = .ended;            s.state = "ended";          s.toolName = nil
    case "UserPromptSubmit":  s.dot = .runningModel; s.state = "running model"; s.toolName = nil
    case "PreToolUse":        s.dot = .runningTool;  s.state = "running \(e.tool_name ?? "tool")"; s.toolName = e.tool_name
    case "PostToolUse":       s.dot = .runningModel; s.state = "running model"; s.toolName = nil
    case "PermissionRequest": s.dot = .waitingPermission; s.state = "needs permission"; s.toolName = e.tool_name
    case "Stop":              s.dot = .waiting;      s.state = "waiting prompt"; s.toolName = nil
    // Notification is a backstop (PermissionRequest/Stop carry the real transitions); subagent events
    // only trigger a re-parse. All three just refresh the timestamp (via s.at = now above), no state change.
    case "Notification", "SubagentStart", "SubagentStop": break
    default: break
    }
    return s
}
