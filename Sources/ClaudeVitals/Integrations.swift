import AppKit
import ServiceManagement
import UserNotifications

/// System chime on running->waiting (works unbundled — the robust fallback).
enum Chime {
    static func play() { NSSound(named: "Glass")?.play() }
}

/// UNUserNotifications. CRASHES with no bundle id, so every call is guarded by AppEnv.isBundled.
final class Notifier: Sendable {
    static let shared = Notifier()

    func bootstrap() {
        guard AppEnv.isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyWaiting(repo: String) {
        guard AppEnv.isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = repo
        content.body = "Agent finished — waiting for your prompt"
        content.sound = nil   // NSSound already chimes; avoid a double-ding
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

/// Open the repo in VS Code; fall back to bundle id, then `/usr/bin/open`.
enum EditorLauncher {
    static func open(cwd: String) {
        guard !cwd.isEmpty else { return }
        let url = URL(fileURLWithPath: cwd)
        let ws = NSWorkspace.shared
        if let app = ws.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            ws.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-a", "Visual Studio Code", cwd]
            try? p.run()
        }
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
