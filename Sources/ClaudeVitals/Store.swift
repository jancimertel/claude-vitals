import AppKit
import SwiftUI

enum AlertKind: Sendable { case finished, needsPermission }
struct Alert: Sendable, Equatable { let repo: String; let kind: AlertKind }

/// Edge detector: fire alerts only on running -> waiting/permission transitions (not every poll).
struct TransitionTracker {
    private var prev: [String: Dot] = [:]

    mutating func update(_ blocks: [Block]) -> [Alert] {
        var alerts: [Alert] = []
        var seen = Set<String>()
        for b in blocks {
            seen.insert(b.sessionId)
            if let was = prev[b.sessionId], was.isRunning {
                if b.dot == .waitingPermission { alerts.append(Alert(repo: b.repo, kind: .needsPermission)) }
                else if b.dot == .waiting { alerts.append(Alert(repo: b.repo, kind: .finished)) }
            }
            prev[b.sessionId] = b.dot
        }
        prev = prev.filter { seen.contains($0.key) }   // prune ended sessions
        return alerts
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var snap: Snapshot = .empty
    @Published var usage: RateUsage?      // real subscription usage (live, from rate-limit headers)
    @Published var labelImage: NSImage?   // colored usage-loader glyph (nil -> fall back to dot)
    @Published var theme = AppTheme.saved {
        didSet {
            AppTheme.saved = theme
            Theme.current = theme
            renderedPct = -2                  // same % bucket, new colors: force a re-render
            updateLabelImage()
        }
    }

    /// Which window the menu-bar ring shows below the limit. Set from the right-click menu.
    @Published var menuSource = MenuSource.saved {
        didSet {
            MenuSource.saved = menuSource
            renderedPct = -2                  // the new window can round to the same %: force a re-render
            updateLabelImage()
        }
    }

    private let collector = Collector()
    private var tracker = TransitionTracker()
    private var loop: Task<Void, Never>?
    private var usageLoop: Task<Void, Never>?
    private var sweepLoop: Task<Void, Never>?
    private var lastUsageFetch: Date = .distantPast
    private var account = AccountWatcher()
    private var renderedPct: Int = -2     // bucket the current labelImage was rendered for (see updateLabelImage)
    private var socket: EventSocket?

    init() { start(); startUsage(); startSocket(); startSweep() }

    isolated deinit { loop?.cancel(); usageLoop?.cancel(); sweepLoop?.cancel(); socket?.stop() }

    /// Hook events -> immediate targeted rebuild (no waiting for the poll tick).
    private func startSocket() {
        let s = EventSocket(path: VITALS_SOCK) { [weak self] e in
            Task { @MainActor in await self?.handleHookEvent(e) }
        }
        s.start()
        socket = s
    }

    private func handleHookEvent(_ e: HookEvent) async {
        let snap = await collector.ingest(e)
        apply(snap)
    }

    private func start() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let s = await self.collector.snapshot()
                self.apply(s)
                let busy = s.running > 0 || s.subsRunning > 0
                // Hook events push updates via the socket, so the poll is only a backstop then.
                let interval: Double = s.hookDriven ? 8 : (busy ? 2 : 8)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Fetch real usage at most once per 5 min, and ONLY while Claude agents are active (no idle
    /// quota spend). Ticks every 30s to check the gate; keeps the last good value on failure.
    /// An account switch (`/login`) triggers an immediate fetch, active or not.
    private func startUsage() {
        usageLoop = Task { [weak self] in
            var primed = false
            var recheck = false
            while !Task.isCancelled {
                guard let self else { return }
                let active = self.snap.running > 0 || self.snap.subsRunning > 0
                let switched = self.account.changed()
                // Prime once on launch regardless of activity (one ~1-token call) so the menu bar shows
                // real usage immediately; thereafter fetch only while active, at most once per 5 min.
                if !primed || switched || recheck || self.limitResetPassed()
                    || (active && Date().timeIntervalSince(self.lastUsageFetch) >= 300) {
                    primed = true
                    // /login may store the new Keychain token after it rewrites ~/.claude.json, so the
                    // first fetch can still use the old account's token. Fetch once more next tick.
                    recheck = switched
                    self.lastUsageFetch = Date()
                    if let u = await RateLimitFetcher.fetch() {
                        self.usage = u
                        self.updateLabelImage()
                    } else if switched {
                        // Never keep showing the previous account's numbers as if they were current.
                        self.usage = nil
                        self.updateLabelImage()
                    }
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func refreshNow() {
        Task { [weak self] in
            guard let self else { return }
            let s = await self.collector.snapshot()
            self.apply(s)
        }
    }

    private func apply(_ s: Snapshot) {
        for alert in tracker.update(s.blocks) {
            Chime.play()
            if AppEnv.isBundled { Notifier.shared.notify(alert) }
        }
        snap = s
        updateLabelImage()
    }

    /// Re-rasterize the menu-bar ring only when the displayed integer % (or presence of usage data)
    /// changes. The SwiftUI `ImageRenderer` rasterize is the single most expensive per-tick op, and the
    /// ring is visually identical within a 1% bucket — so gating here removes ~all redundant renders.
    private func updateLabelImage() {
        let pct = freshUsage?.ring(menuSource)?.pct
        let drain = limitDrain()
        let bucket: Int
        if let drain {
            bucket = 1000 + Int((drain * 100).rounded())     // at the limit: 1000 + % of the wait left
        } else {
            // Without usage data: -1 idle, -3 running. Aurora draws that dot itself, on its tile.
            bucket = pct.map { Int($0.rounded()) } ?? (runningCount > 0 ? -3 : -1)
        }
        guard bucket != renderedPct else { return }
        renderedPct = bucket
        labelImage = renderLabelImage(pct, drain: drain)
    }

    /// At the limit, the share of the wait until the reset that's still left: 1 when the app first
    /// sees 100%, 0 at the reset. Nil when not at the limit or the reset time is unknown. The start is
    /// saved per reset time, so relaunching the app mid-wait doesn't refill the ring.
    private func limitDrain(now: Date = Date()) -> Double? {
        guard let u = freshUsage, let w = u.ring(menuSource), w.pct >= 100, let reset = w.reset else { return nil }
        let d = UserDefaults.standard
        if d.double(forKey: "limitReset") != reset.timeIntervalSince1970 {
            d.set(reset.timeIntervalSince1970, forKey: "limitReset")
            d.set(min(u.capturedAt, now).timeIntervalSince1970, forKey: "limitSince")
        }
        let since = Date(timeIntervalSince1970: d.double(forKey: "limitSince"))
        let wait = reset.timeIntervalSince(since)
        guard wait > 0 else { return 0 }
        return min(max(reset.timeIntervalSince(now) / wait, 0), 1)
    }

    /// The limit's reset time has passed but the usage shown is from before it: fetch fresh numbers
    /// instead of waiting for the next active-session fetch.
    private func limitResetPassed() -> Bool {
        guard let w = usage?.ring(menuSource), w.pct >= 100, let reset = w.reset else { return false }
        return Date() >= reset && lastUsageFetch < reset
    }

    /// Once a minute while at the limit, draw the heartbeat trace in from left to right (~0.8s).
    /// That's 12 renders a minute, and none when below the limit.
    private func startSweep() {
        sweepLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, let pct = self.usage?.ring(self.menuSource)?.pct, let drain = self.limitDrain() else { continue }
                for k in 0...12 {
                    self.labelImage = self.renderLabelImage(pct, drain: drain, sweep: Double(k) / 12)
                    try? await Task.sleep(for: .milliseconds(66))
                }
            }
        }
    }

    /// Render the menu-bar glyph to a (non-template, colored) image: the usage loader (the window
    /// `ring(menuSource)` picks), or with no usage data, Aurora's status dot. Nil means MenuLabel
    /// falls back to Classic's SF Symbol dot. Aurora puts either glyph on a navy tile, like the app
    /// icon.
    private func renderLabelImage(_ pct: Double?, drain: Double? = nil, sweep: Double = 1) -> NSImage? {
        let glyph: AnyView
        if let pct {
            // 22pt in both themes; in Aurora the ring's outer edge meets the rim of its circle.
            glyph = AnyView(LoaderRing(pct: pct, theme: theme, size: 22, drain: drain, sweep: sweep))
        } else if theme == .aurora {
            glyph = AnyView(StatusDot(running: runningCount > 0))
        } else {
            return nil
        }
        let renderer = ImageRenderer(content: theme == .aurora ? AnyView(MenuTile { glyph }) : glyph)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let img = renderer.nsImage else { return nil }
        img.isTemplate = false   // keep the green/amber/red color in the menu bar
        return img
    }

    var runningCount: Int { snap.running }
    var subsRunning: Int { snap.subsRunning }

    /// Show the last fetched usage regardless of age (the strip displays how old it is). Fetching is
    /// gated on activity, so the value may be minutes old — that's surfaced as "updated Xm ago".
    /// Windows past their reset show 0%. The poll loop re-renders the ring within 2–8s of a reset.
    var freshUsage: RateUsage? { usage?.current() }

    /// Text beside the glyph: just the running count (the usage % now lives inside the ring).
    var menuText: String {
        guard runningCount > 0 else { return "" }
        return subsRunning > 0 ? "\(runningCount)·\(subsRunning)" : "\(runningCount)"
    }
}
