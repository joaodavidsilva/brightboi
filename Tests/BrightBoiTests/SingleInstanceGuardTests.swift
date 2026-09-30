import Foundation
import Testing
@testable import BrightBoi

/// `SingleInstanceGuard.shouldSurvive` is the pure decision behind the
/// single-instance guard — exercised directly here, since `acquire()` itself
/// depends on real running processes and can't be unit tested the same way.
@MainActor
@Suite("SingleInstanceGuard")
struct SingleInstanceGuardTests {
    private static let now = Date()

    @Test("a strictly newer version always survives against an older one")
    func newerVersionSurvives() {
        let survives = SingleInstanceGuard.shouldSurvive(
            myVersion: "5",
            myLaunchDate: Self.now,
            myPID: 100,
            others: [.init(version: "3", launchDate: Self.now.addingTimeInterval(-60), pid: 50)]
        )
        #expect(survives == true)
    }

    @Test("an older version always defers to a newer one")
    func olderVersionDefers() {
        let survives = SingleInstanceGuard.shouldSurvive(
            myVersion: "3",
            myLaunchDate: Self.now,
            myPID: 100,
            others: [.init(version: "5", launchDate: Self.now.addingTimeInterval(-60), pid: 50)]
        )
        #expect(survives == false)
    }

    @Test("version comparison is numeric, not lexicographic (\"10\" beats \"9\")")
    func versionComparisonIsNumeric() {
        let survives = SingleInstanceGuard.shouldSurvive(
            myVersion: "10",
            myLaunchDate: Self.now,
            myPID: 100,
            others: [.init(version: "9", launchDate: Self.now.addingTimeInterval(-60), pid: 50)]
        )
        #expect(survives == true)
    }

    @Test("same version: the earlier-launched copy survives")
    func sameVersionEarlierLaunchSurvives() {
        let earlier = Self.now.addingTimeInterval(-60)
        let laterSurvives = SingleInstanceGuard.shouldSurvive(
            myVersion: "3",
            myLaunchDate: Self.now,
            myPID: 100,
            others: [.init(version: "3", launchDate: earlier, pid: 50)]
        )
        #expect(laterSurvives == false)

        let earlierSurvives = SingleInstanceGuard.shouldSurvive(
            myVersion: "3",
            myLaunchDate: earlier,
            myPID: 50,
            others: [.init(version: "3", launchDate: Self.now, pid: 100)]
        )
        #expect(earlierSurvives == true)
    }

    @Test("same version and same launch moment: the lower pid survives")
    func sameVersionSameLaunchLowerPIDSurvives() {
        let higherPIDSurvives = SingleInstanceGuard.shouldSurvive(
            myVersion: "3",
            myLaunchDate: Self.now,
            myPID: 200,
            others: [.init(version: "3", launchDate: Self.now, pid: 100)]
        )
        #expect(higherPIDSurvives == false)

        let lowerPIDSurvives = SingleInstanceGuard.shouldSurvive(
            myVersion: "3",
            myLaunchDate: Self.now,
            myPID: 100,
            others: [.init(version: "3", launchDate: Self.now, pid: 200)]
        )
        #expect(lowerPIDSurvives == true)
    }

    @Test("with no other running copies, this one always survives")
    func noOthersAlwaysSurvives() {
        let survives = SingleInstanceGuard.shouldSurvive(myVersion: "1", myLaunchDate: Self.now, myPID: 1, others: [])
        #expect(survives == true)
    }

    @Test("must out-survive every other copy, not just the first one checked")
    func mustBeatEveryOtherCopy() {
        let survives = SingleInstanceGuard.shouldSurvive(
            myVersion: "3",
            myLaunchDate: Self.now,
            myPID: 100,
            others: [
                .init(version: "1", launchDate: Self.now.addingTimeInterval(-60), pid: 10),
                .init(version: "5", launchDate: Self.now.addingTimeInterval(-60), pid: 20)
            ]
        )
        #expect(survives == false)
    }

    @Test("the shipping and dev identities are both known panel owners")
    func knownIdentifiers() {
        #expect(SingleInstanceGuard.knownBundleIdentifiers == ["com.ptlghost.BrightBoi", "com.ptlghost.BrightBoi.dev"])
    }

    @Test("the other identity of the release is the dev build, and the reverse")
    func otherIdentity() {
        #expect(SingleInstanceGuard.otherIdentifiers(than: "com.ptlghost.BrightBoi") == ["com.ptlghost.BrightBoi.dev"])
        #expect(SingleInstanceGuard.otherIdentifiers(than: "com.ptlghost.BrightBoi.dev") == ["com.ptlghost.BrightBoi"])
    }

    @Test("an unknown identifier treats both known identities as other copies")
    func unknownIdentifierSeesBoth() {
        #expect(SingleInstanceGuard.otherIdentifiers(than: "com.example.other").count == 2)
    }

    @Test("copies are named the way the user sees them")
    func displayNames() {
        #expect(SingleInstanceGuard.displayName(forBundleIdentifier: "com.ptlghost.BrightBoi") == "BrightBoi")
        #expect(SingleInstanceGuard.displayName(forBundleIdentifier: "com.ptlghost.BrightBoi.dev") == "BrightBoi Dev")
    }

    @Test("the conflict alert names the other copy")
    func conflictAlertNamesOtherCopy() {
        let text = SingleInstanceGuard.conflictAlertText(myName: "BrightBoi Dev", otherName: "BrightBoi")
        #expect(text.message == "BrightBoi is already running")
        #expect(text.detail.contains("Quit BrightBoi to continue with BrightBoi Dev"))
    }
}
