import AppKit
import Observation

/// Which permission a request or a System Settings link is about.
enum PermissionKind: Equatable {
    case accessibility
    case inputMonitoring
}

/// The one place the app reads Accessibility and Input Monitoring status,
/// shared by onboarding, Settings and the key tap. The status is re-read on
/// discrete events (onboarding step, Settings and the popover appearing, a
/// system notification, the key tap's short retry poll while it is down),
/// never on a long-lived timer, and `refresh()` tells observers when a
/// permission was newly granted so the key tap can be retried at once.
@Observable
@MainActor
final class PermissionsModel {
    private(set) var accessibilityGranted: Bool
    private(set) var inputMonitoring: PermissionAccess

    var inputMonitoringGranted: Bool { inputMonitoring == .granted }

    /// Whether the event tap may be blocked by a missing Input Monitoring
    /// permission: Key Remap is on, Accessibility is granted and the tap
    /// still is not running. Whether this Mac needs Input Monitoring for the
    /// tap is only known from the tap itself failing, so the row is offered
    /// only then.
    func needsInputMonitoring(keyRemapEnabled: Bool, keyTapActive: Bool) -> Bool {
        keyRemapEnabled && accessibilityGranted && !keyTapActive && !inputMonitoringGranted
    }

    @ObservationIgnored private let checker: PermissionsChecking
    @ObservationIgnored private let openURL: (URL) -> Void
    @ObservationIgnored private var grantObservers: [() -> Void] = []
    /// Whether the Accessibility prompt was already shown in this launch.
    /// macOS can show it again, but a second click on an untrusted app is
    /// more useful as a shortcut to the right pane.
    @ObservationIgnored private var hasRequestedAccessibility = false
    @ObservationIgnored private var distributedObserver: NSObjectProtocol?

    static let accessibilityPaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let inputMonitoringPaneURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    init(
        checker: PermissionsChecking,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.checker = checker
        self.openURL = openURL
        self.accessibilityGranted = checker.accessibilityGranted()
        self.inputMonitoring = checker.inputMonitoringAccess()
    }

    /// Calls `handler` after a `refresh()` finds a permission that was not
    /// granted before now is.
    func addGrantObserver(_ handler: @escaping () -> Void) {
        grantObservers.append(handler)
    }

    /// Re-reads both permissions. Cheap and never prompts.
    func refresh() {
        let wasAccessibilityGranted = accessibilityGranted
        let wasInputMonitoringGranted = inputMonitoringGranted

        let accessibility = checker.accessibilityGranted()
        let inputMonitoring = checker.inputMonitoringAccess()
        if accessibility != accessibilityGranted { accessibilityGranted = accessibility }
        if inputMonitoring != self.inputMonitoring { self.inputMonitoring = inputMonitoring }

        let gainedAccessibility = accessibility && !wasAccessibilityGranted
        let gainedInputMonitoring = inputMonitoring == .granted && !wasInputMonitoringGranted
        if gainedAccessibility || gainedInputMonitoring {
            for observer in grantObservers { observer() }
        }
    }

    /// Asks for `kind` in the way that works for the state macOS is in, so one
    /// click never shows the system prompt and System Settings together:
    ///
    /// - Accessibility: the first attempt in a launch shows the system prompt
    ///   (which lists the app and links to the pane); later attempts while
    ///   still untrusted open the pane directly.
    /// - Input Monitoring, not yet asked: only the system prompt.
    /// - Input Monitoring, turned down or never switched on: the request is
    ///   repeated, which makes sure the app is listed, and the pane opens.
    func requestOrOpenSettings(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            if accessibilityGranted { return }
            if hasRequestedAccessibility {
                openURL(Self.accessibilityPaneURL)
            } else {
                hasRequestedAccessibility = true
                checker.requestAccessibility()
            }
        case .inputMonitoring:
            switch checker.inputMonitoringAccess() {
            case .granted:
                break
            case .unknown:
                checker.requestInputMonitoring()
            case .denied:
                checker.requestInputMonitoring()
                openURL(Self.inputMonitoringPaneURL)
            }
        }
        refresh()
    }

    /// Re-reads the status when macOS announces an Accessibility change.
    /// `AXIsProcessTrusted()` lags the notification slightly, so the read is
    /// delayed. The notification is undocumented, which is why the key tap's
    /// own short poll does not rely on it.
    func startObservingSystemNotifications() {
        guard distributedObserver == nil else { return }
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }
}
