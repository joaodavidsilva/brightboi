/// A one-time read of Accessibility/Input Monitoring status, captured at app
/// startup (constructed alongside `BrightnessController` in `BrightBoiApp`)
/// and handed to the Settings window as a plain value — never re-queried on
/// window focus or a timer, per the spec's Out of Scope.
struct PermissionsSnapshot: Equatable {
    var accessibilityGranted: Bool
    var inputMonitoringGranted: Bool

    init(checker: PermissionsChecking) {
        accessibilityGranted = checker.accessibilityGranted()
        inputMonitoringGranted = checker.inputMonitoringGranted()
    }
}
