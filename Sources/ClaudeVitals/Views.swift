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
                    .foregroundStyle(store.runningCount > 0 ? .green : .secondary)
            }
            // Just the ring/circle in the menu bar — the running count lives in the popover header.
        }
    }
}

/// Circular usage gauge used both in the menu bar (rendered to an image) and the popover.
/// green → amber → orange → red, with a filled center when ≥100% (limit exceeded).
struct LoaderRing: View {
    let pct: Double
    var size: CGFloat = 18

    private var clamped: Double { min(max(pct, 0), 100) }
    var body: some View {
        let color = Theme.usage(pct)
        ZStack {
            Circle().stroke(Color.gray.opacity(0.4), lineWidth: size * 0.13)
            Circle().trim(from: 0, to: clamped / 100)
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(clamped.rounded()))")            // the % inside the ring
                .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                .foregroundStyle(color)
                .frame(width: size * 0.92)
        }
        .frame(width: size, height: size)
    }
}

/// Strip under the header showing the two subscription windows as bars (only when data is fresh).
struct UsageStripView: View {
    let usage: RateUsage
    var narrow = false                                 // single-column popover: too tight for one row
    var body: some View {
        // TimelineView re-evaluates on open (and every 15s while open) so the "updated" age and reset
        // countdowns are current each time the popover appears — no API call, just the clock.
        TimelineView(.periodic(from: .now, by: 15)) { ctx in
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
        .help("Subscription usage from Anthropic rate-limit headers; refreshed \u{2264}5 min while agents are active")
    }

    private func updated(_ now: Date) -> some View {
        Text("updated \(ageStr(Int(max(0, now.timeIntervalSince(usage.capturedAt)))))")
            .font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
    }

    @ViewBuilder private func bar(_ label: String, _ pct: Double?, _ reset: Date?, _ now: Date) -> some View {
        if let pct {
            let c = Theme.usage(pct)
            HStack(spacing: 6) {
                Text(label).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.25)).frame(width: 64, height: 5)
                    Capsule().fill(c).frame(width: 64 * min(max(pct, 0), 100) / 100, height: 5)
                }
                Text("\(Int(pct))%").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(pct >= 100 ? Color(hex: 0xF87171) : Theme.textPrimary)
                if let r = resetIn(reset, now: now) {
                    Text("· \(r)").font(.system(size: 9)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}

// MARK: - Popover

struct PopoverView: View {
    @ObservedObject var store: Store

    private func columns(_ n: Int) -> Int { n <= 1 ? 1 : n <= 4 ? 2 : 3 }

    var body: some View {
        let blocks = store.snap.blocks
        let cols = columns(blocks.count)
        let compact = blocks.count > 6

        VStack(spacing: 0) {
            HeaderView(store: store)
            if let u = store.freshUsage {
                Divider().overlay(Theme.hairline)
                UsageStripView(usage: u, narrow: cols == 1)
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
                }
                .frame(maxHeight: 560)
            }

            Divider().overlay(Theme.hairline)
            FooterView(store: store)
        }
        .frame(width: CGFloat(cols) * 264 + CGFloat(cols - 1) * 10 + 24)
        .background(Theme.bgWindow.opacity(0.92))
        .background(.ultraThinMaterial)
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
            }
            if s.subsRunning > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(Theme.runningTool)
                    Text("\(s.subsRunning) sub-agents")
                        .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            stat(human(s.totalIn + s.totalOut) + " tok")
            stat(String(format: "$%.2f", s.totalCost))
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
                ContextRing(pct: block.ctxPct, tokens: block.ctx)
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
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { EditorLauncher.open(cwd: block.cwd) }
        .help("Open \(block.cwd) in VS Code")
    }

    private var effortRow: some View {
        HStack(spacing: 8) {
            metric("arrow.up", human(block.inTok))
            metric("arrow.down", human(block.outTok))
            metric("arrow.triangle.2.circlepath", human(block.cw + block.cr))
            Spacer(minLength: 0)
            Text(String(format: "$%.2f", block.cost))
                .font(.system(size: 10, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.textPrimary)
            Text("\(block.turns)t").font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.textTertiary)
            Text("\(block.tools)⚙").font(.system(size: 10)).monospacedDigit().foregroundStyle(Theme.textTertiary)
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
            Spacer(minLength: 0)
            Text(ageStr(block.age)).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
        }
    }
}

// MARK: - Pieces

struct ContextRing: View {
    let pct: Double
    let tokens: Int
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
    }
}

struct StateBadge: View {
    let dot: Dot
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            PulseDot(color: Theme.state(dot), active: dot.isRunning, size: 6)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.state(dot))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Theme.state(dot).opacity(0.14), in: Capsule())
        .fixedSize()
    }
}

struct PulseDot: View {
    let color: Color
    let active: Bool
    var size: CGFloat = 8
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .opacity(active ? (on ? 0.35 : 1) : 1)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                       value: on)
            .onAppear { on = active }
            .onChange(of: active) { _, nowActive in on = nowActive }   // restart pulse on idle->running cycles
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

    var body: some View {
        HStack(spacing: 12) {
            Button { store.refreshNow() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)

            if LaunchAtLogin.available {
                Toggle("Launch at login", isOn: $launch)
                    .toggleStyle(.switch).controlSize(.mini)
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
