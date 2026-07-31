import AppKit
import IOKit.hid

/// Real `PermissionsChecking`, reading the same two system permissions
/// `RealKeyTap` depends on — read-only, never requests/prompts (that stays
/// `RealKeyTap`'s responsibility, tied to actually installing the tap).
final class RealPermissionsChecker: PermissionsChecking {
    func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
}
