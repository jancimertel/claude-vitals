import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: 1)
    }
}

/// App color theme, chosen in the footer. Classic is the original look; Aurora follows the app
/// icon: slate-navy surfaces and a teal → sky → indigo → violet accent range.
enum AppTheme: String, CaseIterable, Identifiable {
    case classic, aurora
    var id: Self { self }
    var title: String { self == .classic ? "Classic" : "Aurora" }

    // The key predates Aurora covering the whole popover; kept so the saved choice survives.
    static var saved: AppTheme {
        get { UserDefaults.standard.string(forKey: "gaugeTheme").flatMap(AppTheme.init) ?? .classic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "gaugeTheme") }
    }

    fileprivate var palette: Palette { self == .classic ? .classic : .aurora }
}

struct Palette {
    let bgWindow, scrim, card, cardHover, inset, hairline: Color
    let textPrimary, textSecondary, textTertiary, accent: Color
    let runningModel, runningTool, waiting, idle, danger: Color
    /// Context-ring colors at <60%, <80%, <90%, and above.
    let ring: [Color]
    /// Usage-gauge colors at <25%, <50%, <70%, <88%, and above.
    let usage: [Color]

    static let classic = Palette(
        bgWindow: Color(hex: 0x0E1014), scrim: Color(hex: 0x16191F), card: Color(hex: 0x1B1F27),
        cardHover: Color(hex: 0x222732), inset: Color(hex: 0x0F1216), hairline: Color(hex: 0x2A2F3A),
        textPrimary: Color(hex: 0xF2F4F8), textSecondary: Color(hex: 0xAEB6C2),
        textTertiary: Color(hex: 0x6E7682), accent: Color(hex: 0x7C9CF5),
        runningModel: Color(hex: 0x34D399), runningTool: Color(hex: 0x38BDF8),
        waiting: Color(hex: 0xFBBF24), idle: Color(hex: 0x6B7280), danger: Color(hex: 0xF87171),
        ring: [0x34D399, 0xFBBF24, 0xFB923C, 0xF87171].map { Color(hex: $0) },
        usage: [0x34D399, 0x84CC16, 0xFACC15, 0xF97316, 0xEF4444].map { Color(hex: $0) })

    static let aurora = Palette(
        bgWindow: Color(hex: 0x111623), scrim: Color(hex: 0x171D2C), card: Color(hex: 0x1C2333),
        cardHover: Color(hex: 0x242C3F), inset: Color(hex: 0x0F131D), hairline: Color(hex: 0x2C3446),
        textPrimary: Color(hex: 0xF1F5F9), textSecondary: Color(hex: 0xA9B4C8),
        textTertiary: Color(hex: 0x6B7790), accent: Color(hex: 0x818CF8),
        runningModel: Color(hex: 0x2DD4BF), runningTool: Color(hex: 0x38BDF8),
        // Pink is not in the icon; it marks the states that need you, so it must stand apart.
        waiting: Color(hex: 0xF472B6), idle: Color(hex: 0x64748B), danger: Color(hex: 0xF472B6),
        ring: [0x2DD4BF, 0x818CF8, 0xC084FC, 0xF472B6].map { Color(hex: $0) },
        usage: [0x2DD4BF, 0x38BDF8, 0x818CF8, 0xC084FC, 0xF472B6].map { Color(hex: $0) })
}

/// Colors for the current theme. Views read these statics, so the popover re-creates its content
/// (`.id(store.theme)`) when the theme changes; otherwise unchanged child views keep old colors.
enum Theme {
    // Written only on the main thread, from Store.theme's didSet.
    nonisolated(unsafe) static var current: AppTheme = .saved
    private static var p: Palette { current.palette }

    static var bgWindow: Color { p.bgWindow }
    static var scrim: Color { p.scrim }
    static var card: Color { p.card }
    static var cardHover: Color { p.cardHover }
    static var inset: Color { p.inset }
    static var hairline: Color { p.hairline }

    static var textPrimary: Color { p.textPrimary }
    static var textSecondary: Color { p.textSecondary }
    static var textTertiary: Color { p.textTertiary }
    static var accent: Color { p.accent }

    static var runningModel: Color { p.runningModel }
    static var runningTool: Color { p.runningTool }
    static var waiting: Color { p.waiting }
    static var idle: Color { p.idle }
    static var danger: Color { p.danger }

    static func ring(_ pct: Double) -> Color {
        p.ring[pct < 60 ? 0 : pct < 80 ? 1 : pct < 90 ? 2 : 3]
    }

    /// Subscription-usage gauge color (discrete breakpoints).
    static func usage(_ pct: Double, _ theme: AppTheme) -> Color {
        theme.palette.usage[pct < 25 ? 0 : pct < 50 ? 1 : pct < 70 ? 2 : pct < 88 ? 3 : 4]
    }

    /// The menu-bar intro's gray (LoadingDot), before there's a reading to color. Aurora's secondary
    /// text on its navy tile. Classic has no tile and the image can't follow the menu bar's
    /// appearance, so a mid gray that reads on light and dark bars.
    static func loading(_ theme: AppTheme) -> Color {
        theme == .aurora ? theme.palette.textSecondary : Color(hex: 0x8E8E93)
    }

    static func state(_ d: Dot) -> Color {
        switch d {
        case .runningModel:      return runningModel
        case .runningTool:       return runningTool
        case .waiting:           return waiting
        case .waitingPermission: return waiting
        case .idle:              return idle
        case .ended:             return idle
        }
    }
}
