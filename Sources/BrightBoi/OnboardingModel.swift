import Observation

/// Drives the first-run onboarding flow (mockups 1e/2e): welcome, permission
/// requests, confirmation — shown at most once, ever, replacing
/// `RealKeyTap`'s previous blocking `NSAlert`. The persisted
/// `hasCompletedOnboarding` flag is set on completing all three steps *or*
/// skipping from the permissions step, matching the spec's "never shown
/// again after the very first run regardless of which path" requirement.
@Observable
@MainActor
final class OnboardingModel {
    enum Step: CaseIterable, Hashable {
        case welcome
        case permissions
        case confirmation
    }

    private(set) var step: Step = .welcome
    private(set) var accessibilityGranted: Bool
    private(set) var inputMonitoringGranted: Bool

    /// Wired by whatever presents this model (the onboarding window
    /// controller) to dismiss itself once onboarding is done — the model has
    /// no notion of a window.
    var onFinished: () -> Void = {}

    private let persistence: BrightnessPersisting
    private let permissionsChecker: PermissionsChecking
    private var hasFinished = false

    init(persistence: BrightnessPersisting, permissionsChecker: PermissionsChecking) {
        self.persistence = persistence
        self.permissionsChecker = permissionsChecker
        self.accessibilityGranted = permissionsChecker.accessibilityGranted()
        self.inputMonitoringGranted = permissionsChecker.inputMonitoringGranted()
    }

    /// `false` once `hasCompletedOnboarding` has been persisted by any path
    /// (completion or skip) — `nil` (fresh install) counts as "should show".
    static func shouldShow(persistence: BrightnessPersisting) -> Bool {
        persistence.loadHasCompletedOnboarding() != true
    }

    /// Moves to the next step, finishing on the last one — the same button
    /// action drives "Let's go", "Continue", and "Get bright", since each
    /// only differs in label, not behavior.
    func advance() {
        switch step {
        case .welcome: step = .permissions
        case .permissions: step = .confirmation
        case .confirmation: complete()
        }
    }

    /// The permissions step's escape hatch — ends onboarding immediately
    /// without requesting anything further, per the spec's "skip and still
    /// use the slider" user story.
    func skip() {
        complete()
    }

    func requestAccessibility() {
        permissionsChecker.requestAccessibility()
        accessibilityGranted = permissionsChecker.accessibilityGranted()
    }

    func requestInputMonitoring() {
        permissionsChecker.requestInputMonitoring()
        inputMonitoringGranted = permissionsChecker.inputMonitoringGranted()
    }

    private func complete() {
        guard !hasFinished else { return }
        hasFinished = true
        persistence.save(hasCompletedOnboarding: true)
        onFinished()
    }
}
