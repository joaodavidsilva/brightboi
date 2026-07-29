import Foundation
import ServiceManagement

/// Real `LoginItemRegistering`, backed by `SMAppService.mainApp` — the
/// current-macOS API for registering the app itself (no separate helper
/// tool/LaunchAgent) as a login item, surfaced in System Settings' Login
/// Items list. Only registers when not already `.enabled`, so a relaunch
/// doesn't re-trigger registration every session.
final class RealLoginItemService: LoginItemRegistering {
    func registerForLaunchAtLogin() {
        let service = SMAppService.mainApp
        guard service.status != .enabled else { return }

        do {
            try service.register()
        } catch {
            FileHandle.standardError.write(Data("BrightBoi: failed to register login item: \(error)\n".utf8))
        }
    }
}
