import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var rightClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if AppEnv.isBundled { Notifier.shared.bootstrap() }
        installContextMenu()
    }

    /// MenuBarExtra's status-bar button. SwiftUI doesn't expose it, so find it in the view tree.
    private static func statusButton() -> NSButton? {
        func button(in view: NSView?) -> NSButton? {
            guard let view else { return nil }
            if let b = view as? NSButton, view.className == "NSStatusBarButton" { return b }
            return view.subviews.lazy.compactMap { button(in: $0) }.first
        }
        return NSApp.windows.lazy.filter { $0.className == "NSStatusBarWindow" }
            .compactMap { button(in: $0.contentView) }.first
    }

    /// Right-click (or control-click) on the menu-bar icon shows a menu with Quit instead of opening
    /// the popover. MenuBarExtra has no API for this, so a local event monitor catches the click
    /// before the status-bar button sees it.
    private func installContextMenu() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            let isContextClick = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard isContextClick, event.window?.className == "NSStatusBarWindow",
                  let button = Self.statusButton() else { return event }
            let menu = NSMenu()
            menu.addItem(withTitle: "Quit Claude Vitals", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            NSMenu.popUpContextMenu(menu, with: event, for: button)
            return nil
        }
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
