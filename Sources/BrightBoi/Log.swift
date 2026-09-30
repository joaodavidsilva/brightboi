import OSLog

/// The app's `os.Logger` instances, one per area, so a report can be
/// narrowed in Console.app with `subsystem:com.ptlghost.BrightBoi`. A process
/// launched from Finder or as a login item has its standard error sent to
/// /dev/null, which is why nothing here writes there.
///
/// Error codes and identifiers are logged `privacy: .public` at the call
/// sites, so Console shows them instead of `<private>`.
enum Log {
    static let subsystem = "com.ptlghost.BrightBoi"

    /// Display brightness, the gamma table and the EDR overlay.
    static let display = Logger(subsystem: subsystem, category: "display")
    /// The brightness-key event tap.
    static let keyTap = Logger(subsystem: subsystem, category: "keyTap")
    /// macOS auto-brightness.
    static let autoBrightness = Logger(subsystem: subsystem, category: "autoBrightness")
    /// Launch at login.
    static let loginItem = Logger(subsystem: subsystem, category: "loginItem")
}

/// Remembers which failure codes were already reported, so a call that fails
/// the same way on every slider tick logs once instead of flooding the log.
struct DistinctCodeTracker {
    private var seen: Set<Int32> = []

    /// `true` the first time `code` is passed in, `false` afterwards.
    mutating func isNew(_ code: Int32) -> Bool {
        seen.insert(code).inserted
    }

    /// Forgets every code, so the next failure is reported again. Called
    /// after a success: a later failure is a new event, not a repeat.
    mutating func reset() {
        seen.removeAll()
    }
}
