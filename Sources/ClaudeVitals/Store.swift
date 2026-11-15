import AppKit
import SwiftUI

enum AlertKind: Sendable { case finished, needsPermission, failed }
struct Alert: Sendable, Equatable { let repo: String; let kind: AlertKind }

/// Edge detector: fire alerts only on running -> waiting/permission/failed transitions (not every poll).
struct TransitionTracker {
    private var prev: [String: Dot] = [:]

    mutating func update(_ blocks: [Block]) -> [Alert] {
        var alerts: [Alert] = []
        var seen = Set<String>()
        for b in blocks {
            seen.insert(b.sessionId)
            if let was = prev[b.sessionId], was.isRunning {
                if b.dot == .waitingPermission { alerts.append(Alert(repo: b.repo, kind: .needsPermission)) }
                else if b.dot == .failed { alerts.append(Alert(repo: b.repo, kind: .failed)) }
                else if b.dot == .waiting { alerts.append(Alert(repo: b.repo, kind: .finished)) }
            }
            prev[b.sessionId] = b.dot
        }
        prev = prev.filter { seen.contains($0.key) }   // prune ended sessions
        return alerts
    }
}

/// What the menu-bar label draws.
@MainActor
final class MenuLabelModel: ObservableObject {
    @Published var image: NSImage?   // colored usage-loader glyph (nil -> fall back to dot)
    @Published var running = 0
}

@MainActor
final class Store: ObservableObject {
    /// The latest snapshot. Not published: MenuBarExtra keeps the popover's view tree alive while
    /// it's closed, so publishing every hook event re-rendered the hidden popover. It draws `shown`.
    private(set) var snap: Snapshot = .empty
    /// What the popover draws: follows `snap` while the popover is open or the card count changes,
    /// and catches up as it opens.
    @Published private(set) var shown: Snapshot = .empty
    @Published var usage: RateUsage?      // real subscription usage (live, from rate-limit headers)
    /// The menu-bar label's state, in its own object so ring animations and the running dot don't
    /// re-render the popover either.
    let label = MenuLabelModel()

    var popoverOpen = false {
        didSet { if popoverOpen { catchUp() } }
    }

    /// Hand the popover the latest snapshot. Also called on the click that opens it, since the
    /// visibility notice behind `popoverOpen` lands only after the window is on screen.
    func catchUp() { shown = snap }
    @Published var theme = AppTheme.saved {
        didSet {
            AppTheme.saved = theme
            Theme.current = theme
            renderedKey = []                  // same buckets, new colors: force a re-render
            updateLabelImage()
        }
    }

    /// Which window the menu-bar ring shows below the limit. Set from the right-click menu.
    @Published var menuSource = MenuSource.saved {
        didSet {
            MenuSource.saved = menuSource
            renderedKey = []                  // the new window can round to the same buckets: force a re-render
            updateLabelImage()
        }
    }

    /// Whether the menu-bar ring shows the time mark (see LoaderRing.passed). On unless turned off
    /// from the right-click menu.
    @Published var showTimeMark = UserDefaults.standard.object(forKey: "showTimeMark") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showTimeMark, forKey: "showTimeMark")
            updateLabelImage()                // the mark is part of the render key
        }
    }

    private let collector = Collector()
    private var tracker = TransitionTracker()
    private var loop: Task<Void, Never>?
    private var usageLoop: Task<Void, Never>?
    private var sweepLoop: Task<Void, Never>?
    private var loadingLoop: Task<Void, Never>?   // set until the menu-bar intro hands off
    private var loadingDone = false               // the first usage fetch returned
    private var lastUsageFetch: Date = .distantPast
    private var account = AccountWatcher()
    private var renderedKey: [Int] = []   // buckets the current label image was rendered for (see updateLabelImage)
    private var socket: EventSocket?

    init() { startLoading(); start(); startUsage(); startSocket(); startSweep() }

    isolated deinit {
        loop?.cancel(); usageLoop?.cancel(); sweepLoop?.cancel(); loadingLoop?.cancel(); socket?.stop()
    }

    /// The menu-bar intro, until the first usage fetch returns: a gray dot grows and opens into the
    /// ring's outline (LoadingDot). Then the outline unwinds to the reading, takes its color, and the
    /// number fades in. ~30 renders a second while it moves, none while the full ring waits.
    private func startLoading() {
        loadingLoop = Task { [weak self] in
            let start = ContinuousClock.now
            let dotTime = 0.3                                // the dot's own beat before it opens
            var grow = 0.0
            while !Task.isCancelled {
                guard let self else { return }
                if self.loadingDone { break }
                if grow < 1 {
                    let t = (ContinuousClock.now - start) / .seconds(1)
                    // The ring then eases toward full size, so it never visibly stops to wait for
                    // the fetch: 90% at ~1.2s, full (snapped from 99%) at ~2.1s.
                    grow = t < dotTime ? 0.5 * (1 - pow(1 - t / dotTime, 2))
                                       : 0.5 + 0.5 * (1 - exp(-(t - dotTime) / 0.4))
                    if grow > 0.995 { grow = 1 }
                    self.label.image = self.renderLabelImage(nil, loading: grow)
                }
                try? await Task.sleep(for: .milliseconds(grow < 1 ? 33 : 100))   // grown: just wait
            }
            guard let self else { return }
            // A fast fetch can land mid-growth: finish it quickly first.
            while grow < 1 {
                grow = min(grow + 0.15, 1)
                self.label.image = self.renderLabelImage(nil, loading: grow)
                try? await Task.sleep(for: .milliseconds(33))
            }
            if let pct = self.freshUsage?.ring(self.menuSource)?.pct {
                let drain = self.limitDrain()
                for k in 1...12 {
                    let r = 1 - pow(1 - Double(k) / 12, 3)      // ease out
                    self.label.image = self.renderLabelImage(pct, drain: drain, passed: self.ringPassed(), reveal: r)
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
            // No data (the fetch failed): cut straight to the no-usage glyph.
            self.loadingLoop = nil
            self.renderedKey = []                   // the intro drew over the image: render the real one
            self.updateLabelImage()
        }
    }

    /// The first fetch returned: the intro finishes and hands over the image (see startLoading).
    private func stopLoading() { loadingDone = true }

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
                    let fetched = await RateLimitFetcher.fetch()
                    if let u = fetched { self.usage = u }
                    self.stopLoading()
                    if fetched != nil {
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
        // While closed, still update when the card count changes: that's what changes the window's
        // size, and keeping it sized here stops the popover opening at a stale size, then jumping.
        if popoverOpen || s.blocks.count != shown.blocks.count { shown = s }
        if label.running != s.running { label.running = s.running }
        updateLabelImage()
    }

    /// Re-rasterize the menu-bar ring only when the displayed integer %, the time mark's 1% step, or
    /// the presence of usage data changes. The SwiftUI `ImageRenderer` rasterize is the single most
    /// expensive per-tick op, and the ring is visually identical within a 1% bucket — so gating here
    /// removes ~all redundant renders. The poll loop calls this every 2–8s, so the mark moves on
    /// time: a step is 3 min of the 5h window, ~1.7h of the weekly one.
    private func updateLabelImage() {
        guard loadingLoop == nil else { return }       // the loading animation owns the image
        let pct = freshUsage?.ring(menuSource)?.pct
        let drain = limitDrain()
        let passed = ringPassed()
        let key: [Int]
        if let drain {
            key = [1, Int((drain * 100).rounded())]          // at the limit: % of the wait left
        } else if let pct {
            key = [0, Int(pct.rounded()), passed.map { Int(($0 * 100).rounded()) } ?? -1]
        } else {
            // Without usage data: idle or running. Aurora draws that dot itself, on its tile.
            key = [2, runningCount > 0 ? 1 : 0]
        }
        guard key != renderedKey else { return }
        renderedKey = key
        label.image = renderLabelImage(pct, drain: drain, passed: passed)
    }

    /// Share of the ring's window already passed, for its time mark. Nil when the mark is off, at the
    /// limit (the ring shows the wait for the reset instead), or without a reset time.
    private func ringPassed(now: Date = Date()) -> Double? {
        guard showTimeMark, let w = freshUsage?.ring(menuSource), w.pct < 100 else { return nil }
        return w.passed(now: now)
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

    /// Once a minute while at the limit, a heartbeat: the trace erases from the left (~0.45s), then
    /// draws back in from the left (~0.6s), like a monitor's line. That's 32 renders a minute, and
    /// none when below the limit.
    private func startSweep() {
        sweepLoop = Task { [weak self] in
            func ease(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, let pct = self.usage?.ring(self.menuSource)?.pct, let drain = self.limitDrain() else { continue }
                for k in 1...14 {
                    let t = ease(Double(k) / 14)
                    self.label.image = self.renderLabelImage(pct, drain: drain, trace: (t, 1))
                    try? await Task.sleep(for: .milliseconds(33))
                }
                for k in 1...18 {
                    let t = ease(Double(k) / 18)
                    self.label.image = self.renderLabelImage(pct, drain: drain, trace: (0, t))
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        }
    }

    /// Render the menu-bar glyph to a (non-template, colored) image: the usage loader (the window
    /// `ring(menuSource)` picks), or with no usage data, Aurora's status dot. Nil means MenuLabel
    /// falls back to Classic's SF Symbol dot. Aurora puts either glyph on a navy tile, like the app
    /// icon. `loading` draws the intro's LoadingDot instead, in both themes; `reveal` is the intro's
    /// hand-off to the ring.
    private func renderLabelImage(_ pct: Double?, drain: Double? = nil, passed: Double? = nil,
                                  trace: (from: Double, to: Double) = (0, 1),
                                  loading: Double? = nil,
                                  reveal: Double = 1) -> NSImage? {
        let glyph: AnyView
        if let loading {
            glyph = AnyView(LoadingDot(grow: loading, theme: theme, size: 22))
        } else if let pct {
            // 22pt in both themes; in Aurora the ring's outer edge meets the rim of its circle.
            glyph = AnyView(LoaderRing(pct: pct, theme: theme, size: 22, drain: drain, trace: trace,
                                       reveal: reveal, passed: passed))
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
