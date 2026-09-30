import AppKit
import IOKit.hid

/// Real `PermissionsChecking`, reading and requesting the system permissions
/// the key tap may depend on.
final class RealPermissionsChecker: PermissionsChecking {
    func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// `IOHIDCheckAccess` is the one read that tells a denial from a question
    /// macOS has not asked yet; `CGPreflightListenEventAccess` only reports a
    /// Bool for the same permission.
    func inputMonitoringAccess() -> PermissionAccess {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: .granted
        case kIOHIDAccessTypeDenied: .denied
        default: .unknown
        }
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
        _ = CGRequestListenEventAccess()
    }
}
