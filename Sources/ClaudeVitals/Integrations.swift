import AppKit
import ServiceManagement
import UserNotifications

/// System chime on running->waiting (works unbundled — the robust fallback).
enum Chime {
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "chimeEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "chimeEnabled") }
    }
    static func play() {
        guard enabled else { return }
        NSSound(named: "Glass")?.play()
    }
}

/// UNUserNotifications. CRASHES with no bundle id, so every call is guarded by AppEnv.isBundled.
final class Notifier: Sendable {
    static let shared = Notifier()

    func bootstrap() {
        guard AppEnv.isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ alert: Alert) {
        guard AppEnv.isBundled else { return }
        let content = UNMutableNotificationContent()
        switch alert.kind {
        case .finished:
            content.title = alert.repo
            content.body = "Agent finished - waiting for your prompt"
        case .needsPermission:
            content.title = alert.repo
            content.body = "Agent needs permission to continue"
        }
        content.sound = nil   // NSSound already chimes; avoid a double-ding
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

/// Launch-at-login via SMAppService (needs a bundled, signed .app).
enum LaunchAtLogin {
    static var available: Bool { AppEnv.isBundled }

    static var isEnabled: Bool {
        guard available else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func set(_ on: Bool) {
        guard available else { return }
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // first enable triggers the system Login Items approval flow; ignore transient errors
        }
    }
}
