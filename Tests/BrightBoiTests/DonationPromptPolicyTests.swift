import Foundation
import Testing
@testable import BrightBoi

@Suite("DonationPromptPolicy")
struct DonationPromptPolicyTests {
    private static let day: TimeInterval = 86_400
    private let first = Date(timeIntervalSince1970: 1_700_000_000)

    private func show(
        daysAfterFirst: Double,
        lastPromptDaysAgo: Double? = nil,
        onboardingShowing: Bool = false,
        isLoginLaunch: Bool = false,
        hasFirstLaunch: Bool = true
    ) -> Bool {
        let now = first.addingTimeInterval(daysAfterFirst * Self.day)
        return DonationPromptPolicy.shouldShow(
            now: now,
            firstLaunch: hasFirstLaunch ? first : nil,
            lastPrompt: lastPromptDaysAgo.map { now.addingTimeInterval(-$0 * Self.day) },
            onboardingShowing: onboardingShowing,
            isLoginLaunch: isLoginLaunch
        )
    }

    @Test("not on the first day, nor on day 6")
    func notBeforeAWeek() {
        #expect(show(daysAfterFirst: 0) == false)
        #expect(show(daysAfterFirst: 6) == false)
    }

    @Test("from day 7 on, when it has never been shown")
    func firstPromptAtDaySeven() {
        #expect(show(daysAfterFirst: 7) == true)
        #expect(show(daysAfterFirst: 90) == true)
    }

    @Test("after a prompt: not on day 0 or 29, again on day 30")
    func repeatsEveryThirtyDays() {
        #expect(show(daysAfterFirst: 100, lastPromptDaysAgo: 0) == false)
        #expect(show(daysAfterFirst: 100, lastPromptDaysAgo: 29) == false)
        #expect(show(daysAfterFirst: 100, lastPromptDaysAgo: 30) == true)
    }

    @Test("never while onboarding is showing")
    func neverOverOnboarding() {
        #expect(show(daysAfterFirst: 30, onboardingShowing: true) == false)
    }

    @Test("never on a login launch")
    func neverOnLoginLaunch() {
        #expect(show(daysAfterFirst: 30, isLoginLaunch: true) == false)
    }

    @Test("a fresh install with no dates shows nothing")
    func freshInstall() {
        #expect(show(daysAfterFirst: 30, hasFirstLaunch: false) == false)
    }

    @Test("a last-prompt date in the future (clock set back) does not show")
    func futurePromptDate() {
        #expect(show(daysAfterFirst: 100, lastPromptDaysAgo: -5) == false)
    }

    @Test("an uptime under three minutes is a login launch")
    func loginLaunchHeuristic() {
        #expect(DonationPromptPolicy.isLikelyLoginLaunch(systemUptime: 20) == true)
        #expect(DonationPromptPolicy.isLikelyLoginLaunch(systemUptime: 179) == true)
        #expect(DonationPromptPolicy.isLikelyLoginLaunch(systemUptime: 180) == false)
        #expect(DonationPromptPolicy.isLikelyLoginLaunch(systemUptime: 50_000) == false)
    }

    // MARK: Launch-time bookkeeping

    @Test("the first launch records the date and shows nothing")
    func firstLaunchRecordsDate() {
        let persistence = FakeBrightnessPersistence()
        let shown = DonationPromptPolicy.prepareLaunchPrompt(
            persistence: persistence, now: first, systemUptime: 10_000, onboardingShowing: true
        )
        #expect(shown == false)
        #expect(persistence.storedFirstLaunchDate == first)
        #expect(persistence.storedLastDonationPromptDate == nil)
    }

    @Test("an existing install without dates starts its week at upgrade")
    func upgradeStartsTheWeek() {
        let persistence = FakeBrightnessPersistence()
        persistence.storedHasCompletedOnboarding = true
        #expect(DonationPromptPolicy.prepareLaunchPrompt(
            persistence: persistence, now: first, systemUptime: 10_000, onboardingShowing: false
        ) == false)
        let later = first.addingTimeInterval(8 * Self.day)
        #expect(DonationPromptPolicy.prepareLaunchPrompt(
            persistence: persistence, now: later, systemUptime: 10_000, onboardingShowing: false
        ) == true)
        #expect(persistence.storedFirstLaunchDate == first)
        #expect(persistence.storedLastDonationPromptDate == later)
    }

    @Test("a login launch does not use up the prompt; the next ordinary launch shows it")
    func loginLaunchKeepsThePrompt() {
        let persistence = FakeBrightnessPersistence()
        persistence.storedFirstLaunchDate = first
        let now = first.addingTimeInterval(9 * Self.day)
        #expect(DonationPromptPolicy.prepareLaunchPrompt(
            persistence: persistence, now: now, systemUptime: 30, onboardingShowing: false
        ) == false)
        #expect(persistence.storedLastDonationPromptDate == nil)
        #expect(DonationPromptPolicy.prepareLaunchPrompt(
            persistence: persistence, now: now.addingTimeInterval(3600), systemUptime: 5_000, onboardingShowing: false
        ) == true)
    }

    @Test("a second launch right after a prompt shows nothing")
    func secondLaunchIsQuiet() {
        let persistence = FakeBrightnessPersistence()
        persistence.storedFirstLaunchDate = first
        let now = first.addingTimeInterval(9 * Self.day)
        #expect(DonationPromptPolicy.prepareLaunchPrompt(
            persistence: persistence, now: now, systemUptime: 5_000, onboardingShowing: false
        ) == true)
        #expect(DonationPromptPolicy.prepareLaunchPrompt(
            persistence: persistence, now: now.addingTimeInterval(600), systemUptime: 5_000, onboardingShowing: false
        ) == false)
    }
}
