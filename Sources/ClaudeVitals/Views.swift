import CoreText
import SwiftUI

// MARK: - Menu-bar label

struct MenuLabel: View {
    @ObservedObject var store: Store
    var body: some View {
        HStack(spacing: 3) {
            if let img = store.labelImage {
                Image(nsImage: img)               // usage loader ring (colored)
            } else {
                Image(systemName: store.runningCount > 0 ? "circle.fill" : "circle")
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(store.runningCount > 0 ? Theme.runningModel : .secondary)
            }
            // Just the ring/circle in the menu bar — the running count lives in the popover header.
        }
    }
}

/// Aurora's menu-bar tile: the glyph on the icon's navy, so it reads as the app on any menu bar.
struct MenuTile<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(width: 22, height: 22)
            // The icon's lighter navy: Theme.bgWindow is too close to a dark menu bar to show.
            .background(Color(hex: 0x252C3D), in: Circle())
    }
}

/// Menu-bar dot for Aurora when there's no usage data: filled while sessions run, hollow when idle.
struct StatusDot: View {
    let running: Bool
    var body: some View {
        if running {
            Circle().fill(Theme.runningModel).frame(width: 9, height: 9)
        } else {
            Circle().stroke(Theme.textSecondary, lineWidth: 1.5).frame(width: 9, height: 9)
        }
    }
}

/// Circular usage gauge used both in the menu bar (rendered to an image) and the popover.
/// Colored per `theme` (see Theme.usage).
struct LoaderRing: View {
    let pct: Double
    let theme: AppTheme
    var size: CGFloat = 18
    /// At the limit: the share of the wait until the reset still left (1 → 0). The ring shows this
    /// instead of the usage, emptying as the reset approaches.
    var drain: Double? = nil
    /// At the limit: how much of the heartbeat trace is drawn, left to right (the once-a-minute sweep).
    var sweep: Double = 1

    private var clamped: Double { min(max(pct, 0), 100) }
    private var fill: Double { clamped >= 100 ? min(max(drain ?? 1, 0), 1) : clamped / 100 }
    var body: some View {
        let color = Theme.usage(pct, theme)
        let lineWidth = size * 0.13
        ZStack {
            // Inset by half the line width so the stroke stays inside `size`: ImageRenderer clips
            // anything past the frame, which cut off the ring's outer edge in the menu bar.
            Circle().inset(by: lineWidth / 2).trim(from: 0, to: fill)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if clamped >= 100 {
                // At the limit, which lasts until the reset: "100" doesn't fit inside the ring, so
                // show a heartbeat trace instead.
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(color)
                    .mask {
                        GeometryReader { g in Rectangle().frame(width: g.size.width * sweep) }
                    }
            } else {
                let number = "\(Int(clamped.rounded()))"      // the % inside the ring
                let ink = Self.inkBounds(number, size: size * 0.44)
                Text(number)
                    .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(color)
                    // Center the ink, not the line box: the box leaves digits ~0.4pt high (room for
                    // descenders) and some, like "1", off to one side. Visible at menu-bar size.
                    .alignmentGuide(HorizontalAlignment.center) { $0[.leading] + ink.midX }
                    .alignmentGuide(VerticalAlignment.center) { $0[.firstTextBaseline] - ink.midY }
            }
        }
        .frame(width: size, height: size)
    }

    /// The ink of `text` in the ring's font, relative to the text origin (x right, y up from the
    /// baseline).
    private static func inkBounds(_ text: String, size: CGFloat) -> CGRect {
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    }
}

/// Strip under the header showing the two subscription windows as bars (only when data is fresh).
struct UsageStripView: View {
    let usage: RateUsage
    let theme: AppTheme
    var narrow = false                                 // single-column popover: too tight for one row
    var body: some View {
        // TimelineView re-evaluates on open (and every 15s while open) so the "updated" age and reset
        // countdowns are current each time the popover appears — no API call, just the clock.
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
            let usage = usage.current(now: ctx.date)
            if narrow {
                // Stack the windows so each bar gets the full width instead of being crammed on one line.
                VStack(alignment: .leading, spacing: 6) {
                    bar("5h", usage.fiveH, usage.fiveHReset, ctx.date)
                    bar("7d", usage.sevenD, usage.sevenDReset, ctx.date)
                    updated(ctx.date)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 16) {
                    bar("5h", usage.fiveH, usage.fiveHReset, ctx.date)
                    bar("7d", usage.sevenD, usage.sevenDReset, ctx.date)
                    Spacer(minLength: 0)
                    updated(ctx.date)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.scrim)
    }

    private func updated(_ now: Date) -> some View {
        Text("updated \(ageStr(Int(max(0, now.timeIntervalSince(usage.capturedAt)))))")
            .font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
            .help("Subscription usage, last fetched at \(usage.capturedAt.formatted(date: .omitted, time: .shortened)). "
                  + "Refreshed at most every 5 min while agents are active.")
    }

    private func barHelp(_ label: String, _ pct: Double, _ reset: Date?, _ now: Date) -> String {
        let window = label == "5h" ? "5-hour session limit" : "Weekly limit"
        var s = "\(window): \(Int(pct))% used"
        if let reset, let r = resetIn(reset, now: now) {
            s += ", resets in \(r) (\(reset.formatted(date: .abbreviated, time: .shortened)))"
        }
        return s
    }

    @ViewBuilder private func bar(_ label: String, _ pct: Double?, _ reset: Date?, _ now: Date) -> some View {
        if let pct {
            let c = Theme.usage(pct, theme)
            HStack(spacing: 6) {
                Text(label).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline).frame(width: 64, height: 5)
                    Capsule().fill(c).frame(width: 64 * min(max(pct, 0), 100) / 100, height: 5)
                }
                Text("\(Int(pct))%").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(pct >= 100 ? Theme.danger : Theme.textPrimary)
                if let r = resetIn(reset, now: now) {
                    Text("· \(r)").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                }
            }
            .help(barHelp(label, pct, reset, now))
        }
    }
}

// MARK: - Popover

struct PopoverView: View {
    @ObservedObject var store: Store
    @State private var visible = false
    @State private var gridHeight: CGFloat = 0
    @State private var contentSize: CGSize = .zero

    /// Room left for the grid under the header, usage strip and footer.
    private var maxGridHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 800) - 200 }

    private func columns(_ n: Int) -> Int { n <= 1 ? 1 : n <= 4 ? 2 : 3 }

    var body: some View {
        let blocks = store.snap.blocks
        let cols = columns(blocks.count)
        let compact = blocks.count > 6

        VStack(spacing: 0) {
            HeaderView(store: store)
            if let u = store.freshUsage {
                Divider().overlay(Theme.hairline)
                UsageStripView(usage: u, theme: store.theme, narrow: cols == 1)
            }
            Divider().overlay(Theme.hairline)

            if blocks.isEmpty {
                EmptyStateView()
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(264), spacing: 10), count: cols),
                              spacing: 10) {
                        ForEach(blocks) { SessionCardView(block: $0, compact: compact) }
                    }
                    .padding(12)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { gridHeight = $0 }
                }
                // Show every card; scroll only once the grid would run off the screen.
                .frame(height: min(gridHeight, maxGridHeight))
            }

            Divider().overlay(Theme.hairline)
            FooterView(store: store, narrow: cols == 1)
        }
        .id(store.theme)                               // rebuild so every child picks up the new Theme colors
        .frame(width: CGFloat(cols) * 264 + CGFloat(cols - 1) * 10 + 24)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.bgWindow.opacity(0.92))
        .background(.ultraThinMaterial)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { contentSize = $0 }
        .background(WindowFitter(size: contentSize))
        .background(WindowVisibilityReader(visible: $visible))
        .environment(\.popoverVisible, visible)
    }
}

// MARK: - Popover window sizing

/// MenuBarExtra sizes its window once and doesn't follow later content changes: it keeps the
/// launch-time height (clipping the cards) or a 2-column width after dropping to 1 column.
/// Resize it to the content ourselves, keeping the top and right edges under the menu-bar item,
/// and round its corners.
struct WindowFitter: NSViewRepresentable {
    let size: CGSize
    static let cornerRadius: CGFloat = 16

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let size = size
        DispatchQueue.main.async {
            guard size.width > 0, size.height > 0, let window = nsView.window,
                  let screen = window.screen ?? NSScreen.main else { return }
            let bounds = screen.visibleFrame
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            let top = window.frame.maxY
            frame.size.height = min(frame.height, top - bounds.minY)
            frame.origin.x = max(bounds.minX, min(window.frame.maxX, bounds.maxX) - frame.width)
            frame.origin.y = top - frame.height
            var changed = frame != window.frame
            if changed { window.setFrame(frame, display: true) }
            // The system rounds this borderless window by a small radius; round it like macOS 27
            // windows instead. The frame view already clips to its bounds, so a layer radius is enough.
            if let frameView = window.contentView?.superview {
                frameView.wantsLayer = true
                if let layer = frameView.layer, layer.cornerRadius != Self.cornerRadius {
                    layer.cornerRadius = Self.cornerRadius
                    layer.cornerCurve = .continuous
                    layer.masksToBounds = true
                    changed = true
                }
            }
            if changed { window.invalidateShadow() }   // shadow follows the new corners and size
        }
    }
}

// MARK: - Popover visibility

private struct PopoverVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the MenuBarExtra window is closed. Its view tree stays alive when closed, so
    /// anything that animates continuously must check this or it redraws the hidden window every frame.
    var popoverVisible: Bool {
        get { self[PopoverVisibleKey.self] }
        set { self[PopoverVisibleKey.self] = newValue }
    }
}

/// Tracks whether the hosting window is on screen. onAppear/onDisappear are unreliable inside
/// MenuBarExtra windows, so this watches the NSWindow's occlusion state directly.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> NSView {
        let view = ObservingView()
        view.onChange = { v in DispatchQueue.main.async { if visible != v { visible = v } } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ObservingView: NSView {
        var onChange: ((Bool) -> Void)?
        nonisolated(unsafe) private var token: NSObjectProtocol?   // only touched on main + in deinit

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token) }
            token = nil
            guard let window else { onChange?(false); return }
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.report() } }   // queue: .main
            report()
        }

        private func report() {
            guard let window else { return }
            onChange?(window.isVisible && window.occlusionState.contains(.visible))
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

// MARK: - Header

struct HeaderView: View {
    @ObservedObject var store: Store

    var body: some View {
        let s = store.snap
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                PulseDot(color: store.runningCount > 0 ? Theme.runningModel : Theme.idle,
                         active: store.runningCount > 0, size: 8)
                Text("\(store.runningCount) running")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    .fixedSize()
            }
            .help("Sessions where Claude is working right now")
            if s.subsRunning > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(Theme.runningTool)
                    Text("\(s.subsRunning) sub-agents")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
                .help("Sub-agents running across all sessions")
            }
            Spacer()
            stat(human(s.totalIn + s.totalOut) + " tok")
                .help("Tokens in the sessions shown: \(s.totalIn.formatted()) in + \(s.totalOut.formatted()) out, "
                      + "plus \((s.totalCw + s.totalCr).formatted()) cache")
            stat(String(format: "$%.2f", s.totalCost))
                .help("What the sessions shown would cost at API list prices (not billed on a subscription)")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Theme.scrim)
    }

    private func stat(_ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
            Text("THIS SESSION").font(.system(size: 9)).tracking(0.4).foregroundStyle(Theme.textTertiary)
        }
    }
}

// MARK: - Session card

struct SessionCardView: View {
    let block: Block
    let compact: Bool
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ContextRing(pct: block.ctxPct, tokens: block.ctx, limit: block.ctxLimit)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(block.repo).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        StateBadge(dot: block.dot, label: block.state)
                    }
                    if !block.branch.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                            Text(block.branch).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        }
                        .foregroundStyle(Theme.textSecondary)
                    }
                    if !compact {
                        Text(block.model.replacingOccurrences(of: "claude-", with: ""))
                            .font(.system(size: 10)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    if !block.title.isEmpty {
                        Text(block.title)
                            .font(.system(size: 10)).italic()
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
            }

            effortRow
            if block.subsTotal > 0 && !compact { subRow }
        }
        .padding(12)
        .background(hover ? Theme.cardHover : Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .onHover { hover = $0 }
    }

    private var effortRow: some View {
        HStack(spacing: 8) {
            metric("arrow.up", human(block.inTok))
                .help("Input tokens: \(block.inTok.formatted())")
            metric("arrow.down", human(block.outTok))
                .help("Output tokens: \(block.outTok.formatted())")
            metric("arrow.triangle.2.circlepath", human(block.cw + block.cr))
                .help("Cache tokens: \(block.cw.formatted()) written, \(block.cr.formatted()) read")
            Spacer(minLength: 0)
            Text(String(format: "$%.2f", block.cost))
                .font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.textPrimary)
                .help("Cost at API list prices (not billed on a subscription)")
            Text("\(block.turns)t").font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.textTertiary)
                .help("Turns: replies where Claude finished and handed back to you")
            Text("\(block.tools)⚙").font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.textTertiary)
                .help("Tool calls")
        }
        .lineLimit(1).minimumScaleFactor(0.85)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
    }

    private func metric(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8)).foregroundStyle(Theme.textTertiary)
            Text(value).font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.textPrimary)
        }
    }

    private var subRow: some View {
        HStack(spacing: 4) {
            ForEach(0..<min(block.subsRunning, 6), id: \.self) { _ in
                Circle().fill(Theme.runningTool).frame(width: 5, height: 5)
            }
            Text("\(block.subsTotal) sub-agents").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                .help("\(block.subsRunning) of \(block.subsTotal) sub-agents running")
            Spacer(minLength: 0)
            Text(ageStr(block.age)).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                .help("Last activity in this session")
        }
    }
}

// MARK: - Pieces

struct ContextRing: View {
    let pct: Double
    let tokens: Int
    var limit = 0
    var body: some View {
        ZStack {
            Circle().stroke(Theme.hairline, lineWidth: 5)
            Circle().trim(from: 0, to: min(1, max(0, pct / 100)))
                .stroke(Theme.ring(pct), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(pct))%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.textPrimary)
                Text(human(tokens)).font(.system(size: 8)).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: 52, height: 52)
        .help(limit > 0 ? "Context window: \(tokens.formatted()) of \(limit.formatted()) tokens used"
                        : "Context: \(tokens.formatted()) tokens")
    }
}

struct StateBadge: View {
    let dot: Dot
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            PulseDot(color: Theme.state(dot), active: dot.isRunning, size: 6)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.state(dot))
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        // Cap the width so a long state (e.g. a tool name) truncates instead of crowding out the repo name.
        .frame(maxWidth: 130)
        .background(Theme.state(dot).opacity(0.14), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
        .help(label)
    }
}

struct PulseDot: View {
    let color: Color
    let active: Bool
    var size: CGFloat = 8
    @Environment(\.popoverVisible) private var visible
    @State private var on = false
    // Pulse only while on screen: a repeatForever animation in the hidden popover costs ~20% CPU.
    private var pulsing: Bool { active && visible }
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .opacity(pulsing ? (on ? 0.35 : 1) : 1)
            .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                       value: on)
            .onAppear { on = pulsing }
            .id(pulsing)   // new identity drops the in-flight repeatForever; swapping the animation alone doesn't stop it
            .onChange(of: pulsing) { _, nowPulsing in on = nowPulsing }   // restart pulse on each open / idle->running
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz").font(.system(size: 28)).foregroundStyle(Theme.textTertiary)
            Text("No active Claude sessions").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            Text("Sessions appear here when Claude is working")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 130)   // fill the popover width (no empty->loaded jump)
    }
}

// MARK: - Footer

struct FooterView: View {
    @ObservedObject var store: Store
    @State private var launch = LaunchAtLogin.isEnabled
    var narrow = false                                 // single-column popover: drop the Refresh title to fit
    @State private var sound = Chime.enabled

    var body: some View {
        HStack(spacing: narrow ? 10 : 12) {
            Button { store.refreshNow() } label: {
                if narrow {
                    Image(systemName: "arrow.clockwise")
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .help("Refresh")

            Picker("Theme", selection: $store.theme) {
                ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.mini).fixedSize()
            .help("Color theme")

            Toggle("Sound", isOn: $sound)
                .toggleStyle(.switch).controlSize(.mini).fixedSize()
                .onChange(of: sound) { _, newValue in Chime.enabled = newValue }

            if LaunchAtLogin.available {
                Toggle("Launch at login", isOn: $launch)
                    .toggleStyle(.switch).controlSize(.mini).fixedSize()
                    .onChange(of: launch) { _, newValue in LaunchAtLogin.set(newValue) }
            }

            Spacer()
            Button { NSApp.terminate(nil) } label: { Text("Quit") }
                .buttonStyle(.plain)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.scrim)
    }
}
