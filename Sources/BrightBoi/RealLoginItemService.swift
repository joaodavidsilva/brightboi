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

    func unregisterFromLaunchAtLogin() {
        let service = SMAppService.mainApp
        // `.requiresApproval` still shows an entry in System Settings' Login
        // Items pending approval — only `.notRegistered` means there's
        // genuinely nothing left to remove. Mirroring the `.enabled`-only
        // skip in `registerForLaunchAtLogin` here would leave a
        // `.requiresApproval` entry behind after unchecking the box.
        guard service.status != .notRegistered else { return }

        do {
            try service.unregister()
        } catch {
            FileHandle.standardError.write(Data("BrightBoi: failed to unregister login item: \(error)\n".utf8))
        }
    }
}
