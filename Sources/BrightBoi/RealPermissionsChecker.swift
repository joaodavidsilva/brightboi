import AppKit
import IOKit.hid

/// Real `PermissionsChecking`, reading (and, via onboarding, requesting) the
/// same two system permissions `RealKeyTap`'s event tap depends on.
final class RealPermissionsChecker: PermissionsChecking {
    func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Referenced by its raw key name rather than the
    /// `kAXTrustedCheckOptionPrompt` global: that `Unmanaged<CFString>`
    /// constant fails Swift 6 strict-concurrency checking as shared mutable
    /// global state, and the key name itself is a stable, documented part of
    /// the `AXIsProcessTrustedWithOptions` API.
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}
