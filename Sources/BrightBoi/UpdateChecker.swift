import AppKit
import Foundation
import Observation

/// The part of GitHub's "latest release" answer BrightBoi uses.
struct LatestRelease: Decodable, Equatable, Sendable {
    var tagName: String
    var htmlURL: URL

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

/// Fetches the newest published release. Injected so the decision logic can
/// be tested without a network.
protocol ReleaseFetching: Sendable {
    /// The latest release, or `nil` when none is published (HTTP 404).
    /// Any other failure throws.
    func fetchLatestRelease() async throws -> LatestRelease?
}

/// The real fetcher: one unauthenticated GET to GitHub's API.
struct GitHubReleaseFetcher: ReleaseFetching {
    enum FetchError: Error {
        case unexpectedStatus(Int)
        case notHTTP
    }

    static let latestReleaseURL = URL(string: "https://api.github.com/repos/joaodavidsilva/brightboi/releases/latest")!

    /// Built separately so the URL and headers can be checked without sending it.
    static func makeRequest() -> URLRequest {
        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    func fetchLatestRelease() async throws -> LatestRelease? {
        let (data, response) = try await URLSession.shared.data(for: Self.makeRequest())
        guard let http = response as? HTTPURLResponse else { throw FetchError.notHTTP }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw FetchError.unexpectedStatus(http.statusCode) }
        return try JSONDecoder().decode(LatestRelease.self, from: data)
    }
}

/// What the update check remembers between launches.
protocol UpdateCheckPersisting: AnyObject {
    /// `nil` until the user answers the one-time question.
    var automaticChecksEnabled: Bool? { get set }
    /// When the last automatic or manual check started, if ever.
    var lastCheckDate: Date? { get set }
    /// How many times the app has started, to ask the question from the
    /// second launch on.
    var launchCount: Int { get set }
}

/// `UserDefaults`-backed `UpdateCheckPersisting`.
final class RealUpdateCheckPersistence: UpdateCheckPersisting {
    static let automaticChecksKey = "com.ptlghost.BrightBoi.automaticUpdateChecks"
    static let lastCheckKey = "com.ptlghost.BrightBoi.lastUpdateCheck"
    static let launchCountKey = "com.ptlghost.BrightBoi.launchCount"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var automaticChecksEnabled: Bool? {
        get { defaults.object(forKey: Self.automaticChecksKey) as? Bool }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.automaticChecksKey)
            } else {
                defaults.removeObject(forKey: Self.automaticChecksKey)
            }
        }
    }

    var lastCheckDate: Date? {
        get { defaults.object(forKey: Self.lastCheckKey) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.lastCheckKey)
            } else {
                defaults.removeObject(forKey: Self.lastCheckKey)
            }
        }
    }

    var launchCount: Int {
        get { defaults.object(forKey: Self.launchCountKey) as? Int ?? 0 }
        set { defaults.set(newValue, forKey: Self.launchCountKey) }
    }
}

/// A newer release than the running one.
struct AvailableUpdate: Equatable, Sendable {
    var version: ReleaseVersion
    var pageURL: URL
}

/// Looks for a newer BrightBoi on GitHub. It never contacts GitHub until the
/// user has agreed to automatic checks or asks for a check themselves.
@MainActor
@Observable
final class UpdateChecker {
    /// The result of a check the user asked for.
    enum ManualStatus: Equatable {
        case idle
        case checking
        case upToDate
        case failed
    }

    /// The longest an automatic check waits between two attempts.
    static let automaticCheckInterval: TimeInterval = 24 * 3600
    /// How often a running app re-examines whether a check is due.
    static let pollInterval: Duration = .seconds(3600)
    /// The app launch from which the automatic-check question is asked.
    static let consentLaunchCount = 2

    private(set) var availableUpdate: AvailableUpdate?
    private(set) var manualStatus: ManualStatus = .idle
    private(set) var automaticChecksEnabled: Bool?
    private(set) var launchCount: Int

    @ObservationIgnored private let currentVersion: ReleaseVersion?
    @ObservationIgnored private let fetcher: ReleaseFetching
    @ObservationIgnored private let store: UpdateCheckPersisting
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let openURL: (URL) -> Void
    @ObservationIgnored private var isChecking = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(
        currentVersion: String?,
        fetcher: ReleaseFetching,
        store: UpdateCheckPersisting,
        now: @escaping () -> Date = { Date() },
        openURL: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) {
        self.currentVersion = currentVersion.flatMap(ReleaseVersion.init)
        self.fetcher = fetcher
        self.store = store
        self.now = now
        self.openURL = openURL
        self.automaticChecksEnabled = store.automaticChecksEnabled
        self.launchCount = store.launchCount
    }

    /// The checker the app uses: this bundle's version, GitHub, `UserDefaults`.
    static func live() -> UpdateChecker {
        UpdateChecker(
            currentVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            fetcher: GitHubReleaseFetcher(),
            store: RealUpdateCheckPersistence()
        )
    }

    // MARK: Decisions

    /// Whether an automatic check is due: the user said yes, and none was
    /// started in the last 24 hours. A last check dated in the future (the
    /// clock was set back) counts as recent, so a wrong clock cannot make it
    /// check more often.
    static func isAutomaticCheckDue(enabled: Bool?, lastCheck: Date?, now: Date) -> Bool {
        guard enabled == true else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= automaticCheckInterval
    }

    /// Whether the one-time question should be in the popover: not answered
    /// yet, and this is at least the second launch.
    static func shouldOfferConsent(enabled: Bool?, launchCount: Int) -> Bool {
        enabled == nil && launchCount >= consentLaunchCount
    }

    /// The release to offer, or `nil` when it is not newer than the running
    /// version, is a pre-release or unparseable tag, or its page is not on
    /// github.com.
    static func update(from release: LatestRelease?, current: ReleaseVersion?) -> AvailableUpdate? {
        guard let release, let current, let latest = ReleaseVersion(release.tagName), latest > current else { return nil }
        guard release.htmlURL.scheme == "https", release.htmlURL.host() == "github.com" else { return nil }
        return AvailableUpdate(version: latest, pageURL: release.htmlURL)
    }

    var shouldOfferConsent: Bool {
        Self.shouldOfferConsent(enabled: automaticChecksEnabled, launchCount: launchCount)
    }

    // MARK: Text

    static func availableText(for update: AvailableUpdate) -> String {
        "BrightBoi \(update.version.displayString) is available"
    }

    static let consentText = "Check for updates automatically? It contacts github.com once a day."
    static let failureText = "Couldn't check for updates"
    static let upToDateText = "BrightBoi is up to date"
    static let checkingText = "Checking for updates…"

    // MARK: Lifecycle

    /// Counts this launch, runs a check if one is due, and keeps looking
    /// hourly while the app runs. Does nothing on the network unless the user
    /// has agreed to automatic checks.
    func start() {
        launchCount += 1
        store.launchCount = launchCount
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Records the answer to the one-time question, or a later change made in
    /// Settings. Saying yes checks right away when one is due.
    func setAutomaticChecksEnabled(_ enabled: Bool) {
        automaticChecksEnabled = enabled
        store.automaticChecksEnabled = enabled
        if enabled {
            Task { await checkIfDue() }
        }
    }

    /// Runs the automatic check when it is due. Failures are silent.
    func checkIfDue() async {
        guard Self.isAutomaticCheckDue(enabled: automaticChecksEnabled, lastCheck: store.lastCheckDate, now: now()) else { return }
        _ = await performCheck()
    }

    /// The user-initiated check behind "Check for Updates…".
    func checkNow() async {
        guard !isChecking else { return }
        manualStatus = .checking
        let succeeded = await performCheck()
        manualStatus = succeeded ? (availableUpdate == nil ? .upToDate : .idle) : .failed
    }

    /// Opens the release page of the available update.
    func openAvailableUpdate() {
        guard let availableUpdate else { return }
        openURL(availableUpdate.pageURL)
    }

    /// Fetches and applies the result; `false` when the request failed. The
    /// attempt is recorded either way, so a failing network is not retried
    /// more than once a day.
    private func performCheck() async -> Bool {
        guard !isChecking else { return false }
        isChecking = true
        defer { isChecking = false }
        store.lastCheckDate = now()
        do {
            let release = try await fetcher.fetchLatestRelease()
            availableUpdate = Self.update(from: release, current: currentVersion)
            return true
        } catch {
            Log.updates.error("Update check failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
