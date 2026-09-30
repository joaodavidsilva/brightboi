import Foundation

/// The words onboarding shows where they depend on what this Mac and this
/// launch can really do, kept as pure functions so each variant can be tested
/// and the view only lays them out.
enum OnboardingCopy {
    private static var step: Int { Int(BrightnessController.percentageGranularity) }

    /// The welcome step's promise. A Mac without Boost headroom is not
    /// promised 1000 nits.
    static func welcomeBody(supportsBoost: Bool) -> String {
        if supportsBoost {
            return "Your screen has been holding out on you. macOS stops the slider at 500 nits; the panel is rated for 1000. I go all the way there."
        }
        return "I keep your brightness exactly where you put it: clean \(step)% steps, the slider and keys in sync, safe from auto-brightness."
    }

    /// The line under the permission step's title.
    static func permissionsIntro(accessibilityGranted: Bool) -> String {
        accessibilityGranted
            ? "Already granted — you're set."
            : "This is only for the F1/F2 keys. The slider works without it."
    }

    static let permissionSubtitle = "Lets me take over the brightness keys"

    /// The permission step's main button: it never claims more than it does.
    static func permissionsContinueTitle(accessibilityGranted: Bool) -> String {
        accessibilityGranted ? "Continue" : "Continue without the keys"
    }

    /// What the permission row says to VoiceOver: name, what it is for, then
    /// the status.
    static func permissionRowLabel(title: String, subtitle: String, granted: Bool) -> String {
        "\(title), \(subtitle), \(granted ? "Granted" : "Not granted")"
    }

    /// What the last step says and shows.
    struct Confirmation: Equatable {
        var body: String
        /// Whether the Nominal/Boost illustration belongs: only on a Mac
        /// that can actually boost.
        var showsIllustration: Bool
    }

    /// Chosen from the live state when the step is shown: whether Boost is
    /// available, and whether the brightness keys are really being taken
    /// over (granting Accessibility can still fail to start the key tap).
    static func confirmation(supportsBoost: Bool, keyRemapActive: Bool) -> Confirmation {
        switch (supportsBoost, keyRemapActive) {
        case (true, true):
            Confirmation(
                body: "I live in the menu bar. Click the sun icon, or just hit F2 past where it used to stop.",
                showsIllustration: true
            )
        case (true, false):
            Confirmation(
                body: "I live in the menu bar — click the sun. Want F1/F2 to go past 100%? Turn on Accessibility in Settings any time.",
                showsIllustration: true
            )
        case (false, true):
            Confirmation(
                body: "I live in the menu bar — click the sun, or use F1/F2 in \(step)% steps.",
                showsIllustration: false
            )
        case (false, false):
            Confirmation(
                body: "I live in the menu bar — click the sun. Want F1/F2 to move in \(step)% steps? Turn on Accessibility in Settings any time.",
                showsIllustration: false
            )
        }
    }
}
