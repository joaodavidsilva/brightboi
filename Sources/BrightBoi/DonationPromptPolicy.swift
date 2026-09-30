import Foundation

/// Decides when the donation window may appear on its own: a week after the
/// first launch, then at most once a month, never over onboarding and never
/// when the app was only started by logging in. The rules
/// (`shouldShow`, `isLikelyLoginLaunch`) are pure; `prepareLaunchPrompt` is
/// the one place that reads and writes the two stored dates.
enum DonationPromptPolicy {
    /// How long after the first launch the first prompt may appear.
    static let firstPromptDelay: TimeInterval = 7 * 86_400
    /// The shortest gap between two prompts.
    static let repeatInterval: TimeInterval = 30 * 86_400
    /// A launch this soon after the Mac started is treated as a login launch.
    static let loginLaunchUptimeLimit: TimeInterval = 180

    /// Whether the window may be shown now.
    ///
    /// - `firstLaunch`: when BrightBoi first ran; `nil` means unknown, which
    ///   never shows the window.
    /// - `lastPrompt`: when the window last appeared by itself, if ever.
    /// A date in the future (the clock was set back) counts as "not long
    /// enough ago", so a wrong clock never produces an extra prompt.
    static func shouldShow(
        now: Date,
        firstLaunch: Date?,
        lastPrompt: Date?,
        onboardingShowing: Bool,
        isLoginLaunch: Bool
    ) -> Bool {
        guard !onboardingShowing, !isLoginLaunch, let firstLaunch else { return false }
        guard now.timeIntervalSince(firstLaunch) >= firstPromptDelay else { return false }
        if let lastPrompt {
            return now.timeIntervalSince(lastPrompt) >= repeatInterval
        }
        return true
    }

    /// A heuristic, not a fact: macOS does not say whether a login item or
    /// the user started the app. A launch within three minutes of the Mac
    /// starting is almost always the former, and a manual launch that soon
    /// only postpones the prompt to the next launch.
    static func isLikelyLoginLaunch(systemUptime: TimeInterval) -> Bool {
        systemUptime < loginLaunchUptimeLimit
    }

    /// The launch-time decision. Records the first launch when it is not
    /// known yet (which also starts the week for existing installs), and,
    /// when the window should appear, records the prompt right away so it
    /// counts from when it is shown rather than when it is dismissed. A
    /// login launch records nothing, so it does not use up the prompt.
    static func prepareLaunchPrompt(
        persistence: BrightnessPersisting,
        now: Date,
        systemUptime: TimeInterval,
        onboardingShowing: Bool
    ) -> Bool {
        if persistence.loadFirstLaunchDate() == nil {
            persistence.save(firstLaunchDate: now)
        }
        let show = shouldShow(
            now: now,
            firstLaunch: persistence.loadFirstLaunchDate(),
            lastPrompt: persistence.loadLastDonationPromptDate(),
            onboardingShowing: onboardingShowing,
            isLoginLaunch: isLikelyLoginLaunch(systemUptime: systemUptime)
        )
        if show { persistence.save(lastDonationPromptDate: now) }
        return show
    }
}
