import AppKit
import Foundation

// @main lives here (NOT in a file named main.swift, and NOT on the SwiftUI App struct).
@main
struct Entry {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--emit"), i + 1 < CommandLine.arguments.count {
            let event = CommandLine.arguments[i + 1]
            let sid = (i + 2 < CommandLine.arguments.count) ? CommandLine.arguments[i + 2] : "debug-session"
            emitDebug(event: event, sessionId: sid)
            return
        }
        if CommandLine.arguments.contains("--dump") {
            runDump()                                         // headless data-layer test, no GUI
            return
        }
        if CommandLine.arguments.contains("--selfcheck") {
            runSelfCheck()                                    // headless resolveState assertions, no GUI
            return
        }
        NSApplication.shared.setActivationPolicy(.accessory)  // suppress Dock flash before the App launches
        ClaudeVitalsApp.main()                                // App protocol's static main()
    }

    static func runDump() {
        let snap = buildSnapshot()
        print("running=\(snap.running)  subagents_running=\(snap.subsRunning)  blocks=\(snap.blocks.count)\n")
        for b in snap.blocks {
            let repo = b.repo.padding(toLength: 28, withPad: " ", startingAt: 0)
            let state = b.state.padding(toLength: 14, withPad: " ", startingAt: 0)
            print("\(b.dot.glyph) \(repo) \(state) "
                + "ctx \(String(format: "%5.1f", b.ctxPct))%  "
                + "\(human(b.inTok + b.outTok)) tok  $\(String(format: "%.2f", b.cost))  "
                + "\(b.turns)t/\(b.tools)tools  sub \(b.subsRunning)/\(b.subsTotal)  "
                + "\(b.branch)  \(b.age)s"
                + (b.title.isEmpty ? "" : "  \"\(b.title)\""))
        }
        if let u = RateLimitFetcher.fetchSync() {
            let f = u.fiveH.map { String(format: "%.0f%%", $0) } ?? "-"
            let w = u.sevenD.map { String(format: "%.0f%%", $0) } ?? "-"
            print("\nusage (live)  5h=\(f) (resets \(resetIn(u.fiveHReset) ?? "?"))  "
                + "7d=\(w) (resets \(resetIn(u.sevenDReset) ?? "?"))  status=\(u.status ?? "?")")
        } else {
            print("\nusage  (unavailable - token/network)")
        }
    }

    /// resolveState is a pure function and --dump never carries hook state, so nothing else exercises
    /// the hook-merge logic on this machine; XCTest needs Xcode, which isn't installed here.
    static func runSelfCheck() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let heuristic: (dot: Dot, state: String) = (.runningTool, "running tool")
        func check(_ name: String, _ cond: Bool) {
            guard cond else { print("FAIL \(name)"); exit(1) }
            print("ok \(name)")
        }
        func hook(_ dot: Dot, _ state: String, at: TimeInterval, alive: Bool = true) -> HookStatus {
            HookStatus(dot: dot, state: state, toolName: nil, alive: alive, at: now.addingTimeInterval(at))
        }

        let r1 = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: false, hook: nil, transcriptMtime: now, now: now)
        check("noHookFallsBackToHeuristic", r1.dot == .runningTool && r1.state == "running tool" && r1.live && !r1.usedHook)

        let r2 = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: false, hook: hook(.waitingPermission, "needs permission", at: -2), transcriptMtime: now, now: now)
        check("freshHookWins", r2.dot == .waitingPermission && r2.usedHook)

        let staleHook = hook(.waitingPermission, "needs permission", at: -(HOOK_FRESH_S + 1))
        let r3 = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: false, hook: staleHook, transcriptMtime: now.addingTimeInterval(-(HOOK_FRESH_S + 1)), now: now)
        check("staleHookIgnoredWhenLivenessUnconfirmed", r3.dot == .runningTool && !r3.usedHook)

        let permHook = hook(.waitingPermission, "needs permission", at: -120)
        let r4 = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: true, hook: permHook, transcriptMtime: now.addingTimeInterval(-120), now: now)
        check("stalePermissionSurvivesWhileLivenessConfirmed", r4.dot == .waitingPermission && r4.usedHook)

        // Supersession only applies to a supersedable state; a local heuristic distinct from the hook's
        // dot keeps the assertion from passing for the wrong reason.
        let toolHook = hook(.runningTool, "running Bash", at: -120)
        let r5 = resolveState(heuristic: (.waiting, "waiting prompt"), isLive: true, liveConfirmed: true, hook: toolHook, transcriptMtime: now.addingTimeInterval(-1), now: now)
        check("hookSupersededWhenTranscriptAdvancesPastWindow", r5.dot == .waiting && !r5.usedHook)

        // A pending permission prompt is exempt from supersession: a sibling tool_result landing
        // while the user decides must not revoke the badge.
        let r6 = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: true, hook: permHook, transcriptMtime: now.addingTimeInterval(-1), now: now)
        check("supersededExemptForPendingPermission", r6.dot == .waitingPermission && r6.usedHook)

        // Pins the strict `>` threshold: exactly HOOK_FRESH_S past the hook is NOT yet superseded.
        let r7 = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: true, hook: toolHook, transcriptMtime: now.addingTimeInterval(-120 + HOOK_FRESH_S), now: now)
        check("notSupersededAtExactBoundary", r7.dot == .runningTool && r7.state == "running Bash" && r7.usedHook)

        let r8 = resolveState(heuristic: heuristic, isLive: true, liveConfirmed: false, hook: hook(.ended, "ended", at: 0, alive: false), transcriptMtime: now, now: now)
        check("hookLivenessOverridesProcessLiveness", r8.dot == .ended && r8.usedHook && !r8.live)

        // Newer hook events: decoding and state mapping.
        func dec(_ json: String) -> HookEvent? { try? JSONDecoder().decode(HookEvent.self, from: Data(json.utf8)) }
        func st(_ d: Dot) -> HookStatus { HookStatus(dot: d, state: "x", toolName: "T", alive: true, at: now) }
        func dot(_ d: Dot, _ e: HookEvent) -> Dot? { applyHookEvent(st(d), e, at: now)?.dot }

        let nf = dec(#"{"hook_event_name":"StopFailure","session_id":"s","error":"rate_limit","agent_type":"general-purpose","permission_mode":"auto","effort":{"level":"high"},"source":"startup","trigger":"auto","notification_type":"idle_prompt","agent_id":"a1"}"#)
        check("decodesNewFields", nf?.error == "rate_limit" && nf?.effortLevel == "high" && nf?.permission_mode == "auto"
              && nf?.agent_type == "general-purpose" && nf?.agent_id == "a1" && nf?.source == "startup"
              && nf?.trigger == "auto" && nf?.notification_type == "idle_prompt")
        let old = dec(#"{"hook_event_name":"Stop","session_id":"s"}"#)
        check("oldPayloadDecodes", old != nil && old?.source == nil && old?.trigger == nil && old?.error == nil
              && old?.notification_type == nil && old?.agent_id == nil && old?.agent_type == nil
              && old?.permission_mode == nil && old?.effortLevel == nil)
        let odd = dec(#"{"hook_event_name":"StopFailure","session_id":"s","effort":"high","error":{"type":"x"}}"#)
        check("oddFieldShapesStillDecode", odd != nil && odd?.effortLevel == nil && odd?.error == nil
              && odd.flatMap { applyHookEvent(st(.runningModel), $0, at: now)?.state } == "failed: unknown")

        let sf = applyHookEvent(st(.runningModel), HookEvent(event: "StopFailure", session_id: "s", error: "rate_limit"), at: now)
        check("stopFailureGoesFailed", sf?.dot == .failed && sf?.state == "failed: rate limit" && sf?.toolName == nil)
        check("subagentStopFailureIgnored", dot(.runningModel, HookEvent(event: "StopFailure", session_id: "s", error: "rate_limit", agent_id: "a1")) == .runningModel)
        check("sessionStartCompactKeepsState", dot(.runningModel, HookEvent(event: "SessionStart", session_id: "s", source: "compact")) == .runningModel)
        check("sessionStartStartupGoesWaiting", dot(.runningModel, HookEvent(event: "SessionStart", session_id: "s", source: "startup")) == .waiting)
        check("sessionStartWithoutSourceGoesWaiting", dot(.runningModel, HookEvent(event: "SessionStart", session_id: "s")) == .waiting)
        let pc = applyHookEvent(st(.runningTool), HookEvent(event: "PreCompact", session_id: "s", trigger: "auto"), at: now)
        check("autoPreCompactWhileRunning", pc?.dot == .compacting && pc?.state == "compacting")
        check("autoPreCompactWhileWaitingIgnored", dot(.waiting, HookEvent(event: "PreCompact", session_id: "s", trigger: "auto")) == .waiting)
        check("manualPreCompactFromWaiting", dot(.waiting, HookEvent(event: "PreCompact", session_id: "s", trigger: "manual")) == .compacting)
        check("postCompactAutoResumesRunning", dot(.compacting, HookEvent(event: "PostCompact", session_id: "s", trigger: "auto")) == .runningModel)
        check("postCompactManualGoesWaiting", dot(.compacting, HookEvent(event: "PostCompact", session_id: "s", trigger: "manual")) == .waiting)
        check("latePostCompactIgnored", dot(.runningModel, HookEvent(event: "PostCompact", session_id: "s", trigger: "manual")) == .runningModel)
        check("toolFailureAndDenialGoRunningModel",
              dot(.runningTool, HookEvent(event: "PostToolUseFailure", session_id: "s")) == .runningModel
              && dot(.waitingPermission, HookEvent(event: "PermissionDenied", session_id: "s")) == .runningModel)
        check("interruptedToolGoesWaiting",
              dot(.runningTool, HookEvent(event: "PostToolUseFailure", session_id: "s", is_interrupt: true)) == .waiting
              && dot(.runningTool, HookEvent(event: "PostToolUseFailure", session_id: "s", is_interrupt: false)) == .runningModel
              && dec(#"{"hook_event_name":"PostToolUseFailure","session_id":"s","is_interrupt":true}"#)?.is_interrupt == true)
        let idleN = HookEvent(event: "Notification", session_id: "s", notification_type: "idle_prompt")
        check("idlePromptOnlyWhileRunning", dot(.runningTool, idleN) == .waiting && dot(.failed, idleN) == .failed)
        let permN = HookEvent(event: "Notification", session_id: "s", notification_type: "permission_prompt")
        let pn = applyHookEvent(st(.runningTool), permN, at: now)
        check("permissionPromptOnlyWhileRunning", pn?.dot == .waitingPermission && pn?.state == "needs permission" && dot(.waiting, permN) == .waiting)
        let plainN = HookEvent(event: "Notification", session_id: "s")
        check("untypedNotificationStillNoop", dot(.runningTool, plainN) == .runningTool && applyHookEvent(nil, plainN, at: now) == nil)

        // failed is sticky while liveness is confirmed, and alerts.
        let failedHook = hook(.failed, "failed", at: -120)
        let rf1 = resolveState(heuristic: (.idle, "idle"), isLive: true, liveConfirmed: true, hook: failedHook, transcriptMtime: now.addingTimeInterval(-1), now: now)
        check("failedSurvivesSupersessionWhileLivenessConfirmed", rf1.dot == .failed && rf1.usedHook)
        let rf2 = resolveState(heuristic: (.idle, "idle"), isLive: true, liveConfirmed: false, hook: failedHook, transcriptMtime: now.addingTimeInterval(-1), now: now)
        check("failedFallsBackWhenLivenessUnconfirmed", rf2.dot == .idle && !rf2.usedHook)
        func card(_ d: Dot) -> Block {
            Block(sessionId: "a", repo: "repo-a", title: "", cwd: "", branch: "", age: 0, dot: d, state: "",
                  ctx: 0, ctxLimit: 200_000, ctxPct: 0, model: "?", inTok: 0, outTok: 0, cw: 0, cr: 0,
                  cost: 0, turns: 0, tools: 0, subsTotal: 0, subsRunning: 0, live: true, pids: 1)
        }
        var t1 = TransitionTracker()
        _ = t1.update([card(.runningModel)])
        check("runningToFailedAlertsFailed", t1.update([card(.failed)]) == [Alert(repo: "repo-a", kind: .failed)])
        var t2 = TransitionTracker()
        check("autoCompactionIsSilent", [Dot.runningModel, .compacting, .runningModel].allSatisfy { t2.update([card($0)]).isEmpty })
        var t3 = TransitionTracker()
        _ = t3.update([card(.compacting)])
        check("manualCompactFinishingChimes", t3.update([card(.waiting)]) == [Alert(repo: "repo-a", kind: .finished)])

        // Ring and cost ignore synthetic API-error lines; the ring follows compaction.
        let real = #"{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":10,"cache_read_input_tokens":300000,"cache_creation_input_tokens":0}}}"#
        let synth = #"{"type":"assistant","isApiErrorMessage":true,"message":{"model":"<synthetic>","stop_reason":"stop_sequence","usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        let boundary = #"{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"manual","preTokens":300010,"postTokens":23336}}"#
        let bareBoundary = #"{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto"}}"#
        func ctxOf(_ ls: [String]) -> (ctx: Int, limit: Int, model: String) {
            deriveContext(parseLines(Data(ls.joined(separator: "\n").utf8), dropFirstPartial: false))
        }
        let rs = ctxOf([real, synth])
        check("ringSkipsSyntheticLine", rs.ctx == 300010 && rs.limit == 1_000_000 && rs.model == "claude-opus-4-8")
        let rb = ctxOf([real, boundary])
        check("ringUsesCompactBoundary", rb.ctx == 23336 && rb.limit == 1_000_000 && rb.model == "claude-opus-4-8")
        check("ringIgnoresOlderBoundary", ctxOf([boundary, real]).ctx == 300010)
        check("ringIgnoresBoundaryWithoutPostTokens", ctxOf([real, bareBoundary]).ctx == 300010)
        let costFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        let sonnet = #"{"type":"assistant","message":{"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":1000000,"output_tokens":0}}}"#
        try? Data((sonnet + "\n" + synth + "\n").utf8).write(to: costFile)
        let eff = TranscriptParser().effort(path: costFile.path)
        try? FileManager.default.removeItem(at: costFile)
        check("costIgnoresSyntheticModel", eff.model == "claude-sonnet-4-6" && abs(eff.cost - 3.0) < 1e-9)

        // Menu-bar ring window: the chosen window below the limit, the blocking one at it.
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

        exit(0)
    }

    static func emitDebug(event: String, sessionId: String) {
        let json = #"{"hook_event_name":"\#(event)","session_id":"\#(sessionId)","tool_name":"Bash"}"#
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { print("socket() failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { p in
            VITALS_SOCK.withCString { strncpy(p, $0, sunPathSize - 1) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        if r != 0 { print("connect() failed - is the app running?"); close(fd); return }
        _ = json.withCString { write(fd, $0, strlen($0)) }
        close(fd)
        print("emitted \(event) for \(sessionId)")
    }
}
