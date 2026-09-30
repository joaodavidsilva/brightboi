import AppKit

/// Quits BrightBoi and opens a fresh copy of the running bundle. Some
/// permission changes only take hold in a new process, which is the last
/// resort when the key tap still cannot be created after a grant.
enum AppRelauncher {
    /// A helper shell waits a second, so this copy has finished quitting (and
    /// released its single-instance claim) before the new one starts.
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", path]
        do {
            try helper.run()
        } catch {
            Log.keyTap.error("Could not start the relaunch helper: \(error.localizedDescription, privacy: .public)")
            return
        }
        NSApp.terminate(nil)
    }
}
