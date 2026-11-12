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

/// Color scheme for the usage gauge (menu-bar ring and popover bars), chosen in the footer.
enum GaugeTheme: String, CaseIterable, Identifiable {
    case classic, aurora
    var id: Self { self }
    var title: String { self == .classic ? "Classic" : "Aurora" }

    /// Menu-bar dot shown while sessions run but there's no usage data yet.
    var runningDot: Color { self == .classic ? .green : Color(hex: 0x2DD4BF) }

    static var saved: GaugeTheme {
        get { UserDefaults.standard.string(forKey: "gaugeTheme").flatMap(GaugeTheme.init) ?? .classic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "gaugeTheme") }
    }
}

enum Theme {
    static let bgWindow = Color(hex: 0x0E1014)
    static let scrim = Color(hex: 0x16191F)
    static let card = Color(hex: 0x1B1F27)
    static let cardHover = Color(hex: 0x222732)
    static let inset = Color(hex: 0x0F1216)
    static let hairline = Color(hex: 0x2A2F3A)

    static let textPrimary = Color(hex: 0xF2F4F8)
    static let textSecondary = Color(hex: 0xAEB6C2)
    static let textTertiary = Color(hex: 0x6E7682)
    static let accent = Color(hex: 0x7C9CF5)

    static let runningModel = Color(hex: 0x34D399)
    static let runningTool = Color(hex: 0x38BDF8)
    static let waiting = Color(hex: 0xFBBF24)
    static let idle = Color(hex: 0x6B7280)

    static func ring(_ pct: Double) -> Color {
        if pct < 60 { return Color(hex: 0x34D399) }
        if pct < 80 { return Color(hex: 0xFBBF24) }
        if pct < 90 { return Color(hex: 0xFB923C) }
        return Color(hex: 0xF87171)
    }

    /// Subscription-usage gauge color for the chosen theme (discrete breakpoints).
    static func usage(_ pct: Double, _ theme: GaugeTheme) -> Color {
        switch theme {
        case .classic:                                // green near 0 → red near 100
            switch pct {
            case ..<25: return Color(hex: 0x34D399)   // green
            case ..<50: return Color(hex: 0x84CC16)   // lime
            case ..<70: return Color(hex: 0xFACC15)   // yellow
            case ..<88: return Color(hex: 0xF97316)   // orange
            default:    return Color(hex: 0xEF4444)   // red
            }
        case .aurora:                                 // the app icon's ring: teal → violet
            switch pct {
            case ..<25: return Color(hex: 0x2DD4BF)   // teal
            case ..<50: return Color(hex: 0x38BDF8)   // sky
            case ..<70: return Color(hex: 0x818CF8)   // indigo
            case ..<88: return Color(hex: 0xC084FC)   // violet
            default:    return Color(hex: 0xF472B6)   // pink: not in the icon, kept so near-limit still stands out
            }
        }
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
