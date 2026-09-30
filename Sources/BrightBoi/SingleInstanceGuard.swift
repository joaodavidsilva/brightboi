import AppKit
import Foundation

/// Keeps exactly one copy of BrightBoi running. Without this, two copies
/// share the same persisted percentage and both drive
/// `CGSetDisplayTransferByTable` independently — the second one's
/// `BoostEngagement` adopts whatever gamma table is already live as its own
/// "original" baseline, so its scaling compounds on top of the first
/// instead of replacing it.
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
    /// item list or the key tap. Returns `true` when this launch should
    /// continue.
    static func acquire() -> Bool {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.ptlghost.BrightBoi"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
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

        for other in others {
            _ = other.terminate()
        }
        let deadline = Date().addingTimeInterval(terminationTimeout)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(terminationPollInterval))
        }
        guard others.allSatisfy(\.isTerminated) else {
            // A stubborn old copy didn't quit in time — defer to it rather
            // than double-drive the display alongside it.
            revealRunningCopy()
            return false
        }
        return true
    }

    /// Signals the already-running copy to open its Settings window, so that
    /// starting BrightBoi again always shows the user something, even when
    /// the running copy's menu bar item is hidden.
    private static func revealRunningCopy() {
        DistributedNotificationCenter.default().postNotificationName(
            revealNotificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Called once by the surviving copy so a later launch attempt reveals
    /// this one (by opening Settings) instead of starting a second process.
    static func observeReveal(_ onReveal: @escaping @MainActor () -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: revealNotificationName, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                onReveal()
            }
        }
    }
}
