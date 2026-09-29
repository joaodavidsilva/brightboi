import Foundation
import ServiceManagement

/// Real `LoginItemRegistering`, backed by `SMAppService.mainApp` — the
/// current-macOS API for registering the app itself (no separate helper
/// tool/LaunchAgent) as a login item, surfaced in System Settings' Login
/// Items list. Deliberately thin: it neither skips a redundant `register()`
/// nor swallows an error — `BrightnessController` reads `status` itself to
/// decide whether calling `register()`/`unregister()` makes sense, and
/// handles whatever they throw.
final class RealLoginItemService: LoginItemRegistering {
    var status: LoginItemStatus {
        LoginItemStatus(SMAppService.mainApp.status)
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

private extension LoginItemStatus {
    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered: self = .notRegistered
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }
}
