import Observation

/// Drives the first-run onboarding flow: welcome, permission request,
/// confirmation, shown at most once, ever. The persisted
/// `hasCompletedOnboarding` flag is set on completing all three steps *or*
/// skipping from the permissions step, so it is never shown again after the
/// very first run, whichever path was taken.
@Observable
@MainActor
final class OnboardingModel {
    enum Step: CaseIterable, Hashable {
        case welcome
        case permissions
        case confirmation
    }

    private(set) var step: Step = .welcome
    /// The shared permission status, also read by Settings and the key tap.
    let permissions: PermissionsModel

    var accessibilityGranted: Bool { permissions.accessibilityGranted }

    /// Wired by whatever presents this model (the onboarding window
    /// controller) to dismiss itself once onboarding is done — the model has
    /// no notion of a window. Not observation-tracked: it's set once by the
    /// presenter and never read by any SwiftUI view.
    @ObservationIgnored
    var onFinished: () -> Void = {}

    private let persistence: BrightnessPersisting
    /// Internal bookkeeping only, never read by a view — not
    /// observation-tracked, matching `BrightnessController`'s own
    /// non-UI-facing properties.
    @ObservationIgnored
    private var hasFinished = false

    init(persistence: BrightnessPersisting, permissions: PermissionsModel) {
        self.persistence = persistence
        self.permissions = permissions
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
    /// without requesting anything further, so the slider stays usable
    /// without any permission.
    func skip() {
        complete()
    }

    /// The Grant button: shows macOS's prompt the first time, and opens the
    /// Accessibility pane after that (see `PermissionsModel.requestOrOpenSettings`).
    func requestAccessibility() {
        permissions.requestOrOpenSettings(.accessibility)
    }

    /// Re-reads the permission. The grant happens in System Settings after
    /// the prompt call returns, so the permissions step calls this on a short
    /// poll while the row is still waiting.
    func refreshPermissions() {
        permissions.refresh()
    }

    private func complete() {
        guard !hasFinished else { return }
        hasFinished = true
        persistence.save(hasCompletedOnboarding: true)
        onFinished()
    }
}
