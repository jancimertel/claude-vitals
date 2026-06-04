import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if AppEnv.isBundled { Notifier.shared.bootstrap() }
    }
}

// No @main here — Entry.main() calls ClaudeVitalsApp.main() (App protocol's static main()).
struct ClaudeVitalsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            MenuLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}
