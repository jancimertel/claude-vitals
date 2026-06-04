import AppKit
import SwiftUI

/// Edge detector: fire alerts only on running -> waiting transitions (not every poll).
struct TransitionTracker {
    private var prev: [String: Dot] = [:]

    mutating func update(_ blocks: [Block]) -> [String] {
        var justWaiting: [String] = []
        var seen = Set<String>()
        for b in blocks {
            seen.insert(b.sessionId)
            if let was = prev[b.sessionId], was.isRunning, b.dot == .waiting {
                justWaiting.append(b.repo)
            }
            prev[b.sessionId] = b.dot
        }
        prev = prev.filter { seen.contains($0.key) }   // prune ended sessions
        return justWaiting
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var snap: Snapshot = .empty
    @Published var usage: RateUsage?      // real subscription usage (live, from rate-limit headers)
    @Published var labelImage: NSImage?   // colored usage-loader glyph (nil -> fall back to dot)

    private let collector = Collector()
    private var tracker = TransitionTracker()
    private var loop: Task<Void, Never>?
    private var usageLoop: Task<Void, Never>?
    private var lastUsageFetch: Date = .distantPast

    init() { start(); startUsage() }

    deinit { loop?.cancel(); usageLoop?.cancel() }

    private func start() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let s = await self.collector.snapshot()
                self.apply(s)
                let busy = s.running > 0 || s.subsRunning > 0
                try? await Task.sleep(for: .seconds(busy ? 1.5 : 5))
            }
        }
    }

    /// Fetch real usage at most once per 5 min, and ONLY while Claude agents are active (no idle
    /// quota spend). Ticks every 30s to check the gate; keeps the last good value on failure.
    private func startUsage() {
        usageLoop = Task { [weak self] in
            var primed = false
            while !Task.isCancelled {
                guard let self else { return }
                let active = self.snap.running > 0 || self.snap.subsRunning > 0
                // Prime once on launch regardless of activity (one ~1-token call) so the menu bar shows
                // real usage immediately; thereafter fetch only while active, at most once per 5 min.
                if !primed || (active && Date().timeIntervalSince(self.lastUsageFetch) >= 300) {
                    primed = true
                    self.lastUsageFetch = Date()
                    if let u = await RateLimitFetcher.fetch() {
                        self.usage = u
                        self.labelImage = self.renderLabelImage()
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
        for repo in tracker.update(s.blocks) {
            Chime.play()
            if AppEnv.isBundled { Notifier.shared.notifyWaiting(repo: repo) }
        }
        snap = s
        labelImage = renderLabelImage()
    }

    /// Render the menu-bar usage loader to a (non-template, colored) image. Nil when there's no
    /// fresh rate-limit data, so MenuLabel falls back to the running-status dot.
    private func renderLabelImage() -> NSImage? {
        guard let pct = freshUsage?.maxPct else { return nil }   // max(5h session, 7d weekly)
        let renderer = ImageRenderer(content: LoaderRing(pct: pct, size: 18))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let img = renderer.nsImage else { return nil }
        img.isTemplate = false   // keep the green/amber/red color in the menu bar
        return img
    }

    var runningCount: Int { snap.running }
    var subsRunning: Int { snap.subsRunning }

    /// Show the last fetched usage regardless of age (the strip displays how old it is). Fetching is
    /// gated on activity, so the value may be minutes old — that's surfaced as "updated Xm ago".
    var freshUsage: RateUsage? { usage }

    /// Text beside the glyph: just the running count (the usage % now lives inside the ring).
    var menuText: String {
        guard runningCount > 0 else { return "" }
        return subsRunning > 0 ? "\(runningCount)·\(subsRunning)" : "\(runningCount)"
    }
}
