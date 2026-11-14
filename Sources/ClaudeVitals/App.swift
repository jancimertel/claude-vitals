import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here, not by the App, so the right-click menu can read and change its settings.
    let store = Store()
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

    @objc private func toggleLaunchAtLogin() { LaunchAtLogin.set(!LaunchAtLogin.isEnabled) }

    @objc private func pickMenuSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let source = MenuSource(rawValue: raw) else { return }
        store.menuSource = source
    }

    /// Right-click (or control-click) on the menu-bar icon shows a menu (which usage window
    /// the ring shows, Launch at Login, Quit) instead of opening the popover. MenuBarExtra has no API
    /// for this, so a local event monitor catches the click before the status-bar button sees it.
    private func installContextMenu() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            let isContextClick = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            guard isContextClick, event.window?.className == "NSStatusBarWindow",
                  let button = Self.statusButton() else { return event }
            let menu = NSMenu()
            menu.addItem(.sectionHeader(title: "Menu Bar Shows:"))
            for source in MenuSource.allCases {
                let item = menu.addItem(withTitle: source.title, action: #selector(self.pickMenuSource(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = source.rawValue
                item.state = self.store.menuSource == source ? .on : .off
            }
            menu.addItem(.separator())
            if LaunchAtLogin.available {
                let login = menu.addItem(withTitle: "Launch at Login", action: #selector(self.toggleLaunchAtLogin), keyEquivalent: "")
                login.target = self
                login.state = LaunchAtLogin.isEnabled ? .on : .off
                menu.addItem(.separator())
            }
            menu.addItem(withTitle: "Quit Claude Vitals", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            NSMenu.popUpContextMenu(menu, with: event, for: button)
            return nil
        }
    }
}

// No @main here — Entry.main() calls ClaudeVitalsApp.main() (App protocol's static main()).
struct ClaudeVitalsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: delegate.store)
        } label: {
            MenuLabel(store: delegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}
