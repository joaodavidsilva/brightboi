import Foundation
import Testing
@testable import BrightBoi

/// A fetcher that answers from a script and counts its calls. It is only
/// touched from the main actor in these tests.
private final class FakeReleaseFetcher: ReleaseFetching, @unchecked Sendable {
    enum Answer {
        case release(LatestRelease?)
        case failure
    }

    struct Failure: Error {}

    var answer: Answer
    private(set) var callCount = 0

    init(_ answer: Answer) {
        self.answer = answer
    }

    func fetchLatestRelease() async throws -> LatestRelease? {
        callCount += 1
        switch answer {
        case .release(let release): return release
        case .failure: throw Failure()
        }
    }
}

private final class FakeUpdateStore: UpdateCheckPersisting {
    var automaticChecksEnabled: Bool?
    var lastCheckDate: Date?
    var launchCount = 0
}

private let testStart = Date(timeIntervalSince1970: 1_800_000_000)

private func release(_ tag: String, page: String = "https://github.com/joaodavidsilva/brightboi/releases/tag/v1.2.0") -> LatestRelease {
    LatestRelease(tagName: tag, htmlURL: URL(string: page)!)
}

@Suite("ReleaseVersion")
struct ReleaseVersionTests {
    @Test("a leading v is ignored")
    func leadingV() {
        #expect(ReleaseVersion("v1.2.0") == ReleaseVersion("1.2.0"))
        #expect(ReleaseVersion("v1.2.0")?.displayString == "1.2.0")
    }

    @Test("missing components count as zero")
    func padding() {
        #expect(ReleaseVersion("1.1") == ReleaseVersion("1.1.0"))
        #expect(ReleaseVersion("1") == ReleaseVersion("1.0.0"))
        #expect(ReleaseVersion("1.1")!.hashValue == ReleaseVersion("1.1.0")!.hashValue)
        #expect(ReleaseVersion("1.1")! < ReleaseVersion("1.1.1")!)
    }

    @Test("components compare as numbers, not text")
    func numericComparison() {
        #expect(ReleaseVersion("1.10.0")! > ReleaseVersion("1.9.0")!)
        #expect(ReleaseVersion("2.0")! > ReleaseVersion("1.99.99")!)
    }

    @Test("anything that is not plain numbers has no version")
    func invalid() {
        #expect(ReleaseVersion("1.2.0-beta1") == nil)
        #expect(ReleaseVersion("") == nil)
        #expect(ReleaseVersion("v") == nil)
        #expect(ReleaseVersion("1..2") == nil)
        #expect(ReleaseVersion("latest") == nil)
        #expect(ReleaseVersion("1.2.x") == nil)
        #expect(ReleaseVersion("-1.2") == nil)
    }
}

@Suite("GitHub release fetching")
struct GitHubReleaseFetchingTests {
    private static let fixture = """
    {
      "url": "https://api.github.com/repos/joaodavidsilva/brightboi/releases/1",
      "html_url": "https://github.com/joaodavidsilva/brightboi/releases/tag/v1.2.0",
      "id": 1,
      "tag_name": "v1.2.0",
      "name": "BrightBoi 1.2.0",
      "draft": false,
      "prerelease": false,
      "assets": [{"name": "BrightBoi-1.2.0.zip"}]
    }
    """

    @Test("the releases/latest JSON decodes to a tag and a page")
    func decodesFixture() throws {
        let decoded = try JSONDecoder().decode(LatestRelease.self, from: Data(Self.fixture.utf8))
        #expect(decoded.tagName == "v1.2.0")
        #expect(decoded.htmlURL.absoluteString == "https://github.com/joaodavidsilva/brightboi/releases/tag/v1.2.0")
    }

    @Test("JSON without the expected fields fails to decode")
    func rejectsWrongShape() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(LatestRelease.self, from: Data(#"{"message":"Not Found"}"#.utf8))
        }
    }

    @Test("the request is a GET for the latest release with GitHub's headers")
    func request() {
        let request = GitHubReleaseFetcher.makeRequest()
        #expect(request.url?.absoluteString == "https://api.github.com/repos/joaodavidsilva/brightboi/releases/latest")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }
}

@MainActor
@Suite("UpdateChecker")
struct UpdateCheckerTests {
    private static let start = testStart

    private final class Clock {
        var date = testStart
    }

    private struct Harness {
        let checker: UpdateChecker
        let fetcher: FakeReleaseFetcher
        let store: FakeUpdateStore
        let clock: Clock
        let opened: OpenedURLs
    }

    private final class OpenedURLs {
        var urls: [URL] = []
    }

    private func make(
        current: String? = "1.1.0",
        answer: FakeReleaseFetcher.Answer = .release(nil),
        enabled: Bool? = nil,
        launchCount: Int = 0,
        lastCheck: Date? = nil
    ) -> Harness {
        let fetcher = FakeReleaseFetcher(answer)
        let store = FakeUpdateStore()
        store.automaticChecksEnabled = enabled
        store.launchCount = launchCount
        store.lastCheckDate = lastCheck
        let clock = Clock()
        let opened = OpenedURLs()
        let checker = UpdateChecker(
            currentVersion: current,
            fetcher: fetcher,
            store: store,
            now: { clock.date },
            openURL: { opened.urls.append($0) }
        )
        return Harness(checker: checker, fetcher: fetcher, store: store, clock: clock, opened: opened)
    }

    // MARK: Pure decisions

    @Test("an automatic check needs a yes and 24 hours since the last one")
    func automaticCheckDue() {
        let now = Self.start
        #expect(UpdateChecker.isAutomaticCheckDue(enabled: nil, lastCheck: nil, now: now) == false)
        #expect(UpdateChecker.isAutomaticCheckDue(enabled: false, lastCheck: nil, now: now) == false)
        #expect(UpdateChecker.isAutomaticCheckDue(enabled: true, lastCheck: nil, now: now) == true)
        #expect(UpdateChecker.isAutomaticCheckDue(enabled: true, lastCheck: now.addingTimeInterval(-23 * 3600), now: now) == false)
        #expect(UpdateChecker.isAutomaticCheckDue(enabled: true, lastCheck: now.addingTimeInterval(-24 * 3600), now: now) == true)
        // A clock set back must not cause extra checks.
        #expect(UpdateChecker.isAutomaticCheckDue(enabled: true, lastCheck: now.addingTimeInterval(3600), now: now) == false)
    }

    @Test("the question is asked from the second launch, until it is answered")
    func consentOffer() {
        #expect(UpdateChecker.shouldOfferConsent(enabled: nil, launchCount: 1) == false)
        #expect(UpdateChecker.shouldOfferConsent(enabled: nil, launchCount: 2) == true)
        #expect(UpdateChecker.shouldOfferConsent(enabled: true, launchCount: 5) == false)
        #expect(UpdateChecker.shouldOfferConsent(enabled: false, launchCount: 5) == false)
    }

    @Test("only a strictly newer, numeric release on github.com is offered")
    func updateDecision() {
        let current = ReleaseVersion("1.1.0")
        #expect(UpdateChecker.update(from: release("v1.2.0"), current: current)?.version.displayString == "1.2.0")
        #expect(UpdateChecker.update(from: release("v1.10.0"), current: ReleaseVersion("1.9.0")) != nil)
        #expect(UpdateChecker.update(from: release("v1.1"), current: current) == nil)
        #expect(UpdateChecker.update(from: release("v1.0.9"), current: current) == nil)
        #expect(UpdateChecker.update(from: release("v1.2.0-beta1"), current: current) == nil)
        #expect(UpdateChecker.update(from: nil, current: current) == nil)
        #expect(UpdateChecker.update(from: release("v1.2.0"), current: nil) == nil)
        #expect(UpdateChecker.update(from: release("v1.2.0", page: "http://github.com/x"), current: current) == nil)
        #expect(UpdateChecker.update(from: release("v1.2.0", page: "https://example.com/x"), current: current) == nil)
    }

    // MARK: Automatic checks

    @Test("nothing is fetched until the user says yes")
    func noRequestWithoutConsent() async {
        let h = make(enabled: nil)
        await h.checker.checkIfDue()
        #expect(h.fetcher.callCount == 0)

        h.checker.start()
        for _ in 0..<20 { await Task.yield() }
        h.checker.stop()
        #expect(h.fetcher.callCount == 0)
        #expect(h.store.lastCheckDate == nil)
    }

    @Test("a no keeps it off")
    func declinedNeverFetches() async {
        let h = make(enabled: nil)
        h.checker.setAutomaticChecksEnabled(false)
        await h.checker.checkIfDue()
        #expect(h.fetcher.callCount == 0)
        #expect(h.store.automaticChecksEnabled == false)
        #expect(h.checker.shouldOfferConsent == false)
    }

    @Test("an enabled check runs once, then waits 24 hours")
    func throttled() async {
        let h = make(answer: .release(release("v1.2.0")), enabled: true)
        await h.checker.checkIfDue()
        #expect(h.fetcher.callCount == 1)
        #expect(h.store.lastCheckDate == Self.start)
        #expect(h.checker.availableUpdate?.version.displayString == "1.2.0")

        h.clock.date = Self.start.addingTimeInterval(23 * 3600)
        await h.checker.checkIfDue()
        #expect(h.fetcher.callCount == 1)

        h.clock.date = Self.start.addingTimeInterval(25 * 3600)
        await h.checker.checkIfDue()
        #expect(h.fetcher.callCount == 2)
    }

    @Test("a failed automatic check is silent and still counts as an attempt")
    func automaticFailureIsSilent() async {
        let h = make(answer: .failure, enabled: true)
        await h.checker.checkIfDue()
        #expect(h.fetcher.callCount == 1)
        #expect(h.checker.manualStatus == .idle)
        #expect(h.checker.availableUpdate == nil)
        #expect(h.store.lastCheckDate == Self.start)
    }

    @Test("saying yes persists the answer and checks right away")
    func yesChecksNow() async {
        let h = make(answer: .release(release("v1.2.0")), enabled: nil)
        h.checker.setAutomaticChecksEnabled(true)
        #expect(h.store.automaticChecksEnabled == true)
        for _ in 0..<50 where h.fetcher.callCount == 0 { await Task.yield() }
        #expect(h.fetcher.callCount == 1)
    }

    @Test("launches are counted and the second one brings the question")
    func launchCounting() {
        let h = make(launchCount: 0)
        h.checker.start()
        #expect(h.store.launchCount == 1)
        #expect(h.checker.shouldOfferConsent == false)
        h.checker.stop()

        let second = make(launchCount: 1)
        second.checker.start()
        #expect(second.store.launchCount == 2)
        #expect(second.checker.shouldOfferConsent == true)
        second.checker.stop()
    }

    // MARK: Manual checks

    @Test("a manual check works without consent and offers a newer release")
    func manualFindsUpdate() async {
        let h = make(answer: .release(release("v1.2.0")), enabled: nil)
        await h.checker.checkNow()
        #expect(h.fetcher.callCount == 1)
        #expect(h.checker.availableUpdate != nil)
        #expect(h.checker.manualStatus == .idle)
        #expect(UpdateChecker.availableText(for: h.checker.availableUpdate!) == "BrightBoi 1.2.0 is available")

        h.checker.openAvailableUpdate()
        #expect(h.opened.urls == [URL(string: "https://github.com/joaodavidsilva/brightboi/releases/tag/v1.2.0")!])
    }

    @Test("a manual check against the same version says up to date")
    func manualUpToDate() async {
        let h = make(answer: .release(release("v1.1.0")))
        await h.checker.checkNow()
        #expect(h.checker.manualStatus == .upToDate)
        #expect(h.checker.availableUpdate == nil)
    }

    @Test("no published release (404) counts as no update, not a failure")
    func manualNoRelease() async {
        let h = make(answer: .release(nil))
        await h.checker.checkNow()
        #expect(h.checker.manualStatus == .upToDate)
    }

    @Test("a failed manual check says so")
    func manualFailure() async {
        let h = make(answer: .failure)
        await h.checker.checkNow()
        #expect(h.checker.manualStatus == .failed)
        #expect(UpdateChecker.failureText == "Couldn't check for updates")
    }

    @Test("a manual failure keeps an update found earlier")
    func failureKeepsFoundUpdate() async {
        let h = make(answer: .release(release("v1.2.0")))
        await h.checker.checkNow()
        h.fetcher.answer = .failure
        await h.checker.checkNow()
        #expect(h.checker.manualStatus == .failed)
        #expect(h.checker.availableUpdate != nil)
    }

    @Test("a bundle without a version never offers an update")
    func noCurrentVersion() async {
        let h = make(current: nil, answer: .release(release("v9.0.0")))
        await h.checker.checkNow()
        #expect(h.checker.availableUpdate == nil)
    }

    @Test("opening with no update available does nothing")
    func openWithoutUpdate() {
        let h = make()
        h.checker.openAvailableUpdate()
        #expect(h.opened.urls.isEmpty)
    }

    // MARK: Persistence

    @Test("the real store uses the documented keys and round-trips")
    func realStore() {
        let name = "BrightBoiTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = RealUpdateCheckPersistence(defaults: defaults)
        #expect(store.automaticChecksEnabled == nil)
        #expect(store.lastCheckDate == nil)
        #expect(store.launchCount == 0)

        store.automaticChecksEnabled = true
        store.lastCheckDate = Self.start
        store.launchCount = 3
        #expect(defaults.object(forKey: "com.ptlghost.BrightBoi.automaticUpdateChecks") as? Bool == true)
        #expect(defaults.object(forKey: "com.ptlghost.BrightBoi.lastUpdateCheck") as? Date == Self.start)
        #expect(store.launchCount == 3)

        store.automaticChecksEnabled = nil
        #expect(store.automaticChecksEnabled == nil)
    }
}
