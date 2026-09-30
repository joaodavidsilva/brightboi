import AppKit
import Foundation

/// Keeps exactly one copy of BrightBoi running. Without this, two copies
/// share the same persisted percentage and both drive
/// `CGSetDisplayTransferByTable` independently — the second one's
/// `BoostEngagement` adopts whatever gamma table is already live as its own
/// "original" baseline, so its scaling compounds on top of the first
/// instead of replacing it.
///
/// The shipping app and the debug "BrightBoi Dev" build have different bundle
/// identifiers but drive the same panel, so both count as the same owner.
/// A copy of the *other* identity is never quit silently: the user is asked.
///
/// `shouldSurvive` is the pure decision, unit-tested directly; `acquire()`
/// wraps it with the real `NSRunningApplication`/`DistributedNotificationCenter`
/// side effects and can't be exercised the same way (it depends on actually
/// running processes).
@MainActor
enum SingleInstanceGuard {
    /// One other running copy's identifying facts, as read from
    /// `NSRunningApplication`.
    struct OtherInstance {
        var version: String
        var launchDate: Date
        var pid: Int32
    }

    /// Every bundle identifier that drives the built-in panel.
    static let releaseBundleIdentifier = "com.ptlghost.BrightBoi"

    /// The identity of a local debug build.
    static let devBundleIdentifier = "com.ptlghost.BrightBoi.dev"

    static let knownBundleIdentifiers = [releaseBundleIdentifier, devBundleIdentifier]

    /// The known identifiers other than `identifier`: the copies that are a
    /// different identity of this app rather than another instance of it.
    static func otherIdentifiers(than identifier: String) -> [String] {
        knownBundleIdentifiers.filter { $0 != identifier }
    }

    /// The name the user knows a copy by, for the conflict alert.
    static func displayName(forBundleIdentifier identifier: String) -> String {
        identifier == devBundleIdentifier ? "BrightBoi Dev" : "BrightBoi"
    }

    /// Text of the alert shown when a copy with the other identity is running.
    static func conflictAlertText(myName: String, otherName: String) -> (message: String, detail: String) {
        (
            "\(otherName) is already running",
            "\(otherName) and \(myName) both control the built-in display, so only one can run at a time. Quit \(otherName) to continue with \(myName)."
        )
    }

    /// The system-wide center copies of the app talk to each other through.
    static var systemCenter: NotificationCenter { DistributedNotificationCenter.default() }

    static let revealNotificationName = Notification.Name("com.ptlghost.BrightBoi.reveal")

    private static let terminationTimeout: TimeInterval = 5
    private static let terminationPollInterval: TimeInterval = 0.1

    /// `true` when this copy should keep starting; `false` when an
    /// equal-or-newer copy is already running and this one should defer to
    /// it instead. A strictly newer `CFBundleVersion` always wins outright
    /// (an in-place upgrade replacing an older running copy); otherwise the
    /// earliest launch survives, ties breaking on the lower pid so exactly
    /// one side of two near-simultaneous launches always wins.
    static func shouldSurvive(myVersion: String, myLaunchDate: Date, myPID: Int32, others: [OtherInstance]) -> Bool {
        for other in others {
            switch myVersion.compare(other.version, options: .numeric) {
            case .orderedDescending:
                continue
            case .orderedAscending:
                return false
            case .orderedSame:
                if other.launchDate < myLaunchDate { return false }
                if other.launchDate == myLaunchDate, other.pid < myPID { return false }
            }
        }
        return true
    }

    /// Finds every other running copy with the same bundle identifier,
    /// decides who survives, and either quits the losing side(s) or exits
    /// this process — before anything else touches the display, the login
    /// item list or the key tap. A running copy with the other identity is
    /// handled by asking the user. Returns `true` when this launch should
    /// continue.
    static func acquire() -> Bool {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.ptlghost.BrightBoi"
        guard acquireAgainstSameIdentity(bundleIdentifier) else { return false }
        return resolveOtherIdentity(than: bundleIdentifier)
    }

    private static func runningCopies(of identifier: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    private static func acquireAgainstSameIdentity(_ bundleIdentifier: String) -> Bool {
        let others = runningCopies(of: bundleIdentifier)
        guard !others.isEmpty else { return true }

        let myVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let myLaunchDate = NSRunningApplication.current.launchDate ?? Date()
        let myPID = ProcessInfo.processInfo.processIdentifier
        let otherFacts = others.map { app -> OtherInstance in
            let version = app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleVersion"] as? String } ?? "0"
            return OtherInstance(version: version, launchDate: app.launchDate ?? .distantPast, pid: app.processIdentifier)
        }

        guard shouldSurvive(myVersion: myVersion, myLaunchDate: myLaunchDate, myPID: myPID, others: otherFacts) else {
            revealRunningCopy()
            return false
        }

        guard quitAndWait(others) else {
            // A stubborn old copy didn't quit in time — defer to it rather
            // than double-drive the display alongside it.
            revealRunningCopy()
            return false
        }
        return true
    }

    /// Asks the user before quitting a copy with the other identity (the
    /// release while running a dev build, or the reverse). Declining, or a
    /// copy that will not quit, leaves the other copy running and this one
    /// exits.
    private static func resolveOtherIdentity(than bundleIdentifier: String) -> Bool {
        let otherCopies = otherIdentifiers(than: bundleIdentifier).flatMap(runningCopies(of:))
        guard let first = otherCopies.first else { return true }

        let otherName = displayName(forBundleIdentifier: first.bundleIdentifier ?? "")
        let text = conflictAlertText(myName: displayName(forBundleIdentifier: bundleIdentifier), otherName: otherName)
        let alert = NSAlert()
        alert.messageText = text.message
        alert.informativeText = text.detail
        alert.addButton(withTitle: "Quit \(otherName)")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, quitAndWait(otherCopies) else {
            revealRunningCopy()
            return false
        }
        return true
    }

    private static func quitAndWait(_ apps: [NSRunningApplication]) -> Bool {
        for app in apps {
            _ = app.terminate()
        }
        let deadline = Date().addingTimeInterval(terminationTimeout)
        while apps.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(terminationPollInterval))
        }
        return apps.allSatisfy(\.isTerminated)
    }

    /// Signals the already-running copy to open its Settings window, so that
    /// starting BrightBoi again always shows the user something, even when
    /// the running copy's menu bar item is hidden. `center` is the system-wide
    /// distributed center; a test passes a private one.
    static func revealRunningCopy(center: NotificationCenter = systemCenter) {
        if let distributed = center as? DistributedNotificationCenter {
            distributed.postNotificationName(revealNotificationName, object: nil, userInfo: nil, deliverImmediately: true)
        } else {
            center.post(name: revealNotificationName, object: nil)
        }
    }

    /// Called once by the surviving copy so a later launch attempt reveals
    /// this one (by opening Settings) instead of starting a second process.
    /// Returns the observer, for a caller that wants to stop listening.
    @discardableResult
    static func observeReveal(
        center: NotificationCenter = systemCenter,
        _ onReveal: @escaping @MainActor () -> Void
    ) -> NSObjectProtocol {
        center.addObserver(forName: revealNotificationName, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                onReveal()
            }
        }
    }
}
