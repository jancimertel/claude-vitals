import Foundation

/// Gate for bundle-only APIs (UNUserNotifications, SMAppService) that crash/throw under `swift run`.
enum AppEnv {
    static var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }
}
