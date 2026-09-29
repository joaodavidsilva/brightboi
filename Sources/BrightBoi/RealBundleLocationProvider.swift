import Foundation

/// Real `BundleLocationProviding`, reading `Bundle.main.bundleURL` directly.
/// Used to decide whether registering a login item is safe — see
/// `RealLoginItemService` and `BrightnessController`'s launch-at-login logic.
struct RealBundleLocationProvider: BundleLocationProviding {
    var bundlePath: String {
        Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Compares against every Applications folder `FileManager` knows about
    /// (local and user domain), each with a trailing slash so
    /// `/Applications/Utilities` passes and `/ApplicationsFoo` doesn't.
    var isInApplicationsFolder: Bool {
        let candidatePath = bundlePath
        let applicationsFolders = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        return applicationsFolders.contains { folder in
            let prefix = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            return candidatePath.hasPrefix(prefix)
        }
    }

    /// Covers App Translocation (the random read-only mount macOS uses for a
    /// single launch of a quarantined copy opened in place) and a mounted
    /// DMG — both report their volume as read-only.
    var isTranslocatedOrReadOnly: Bool {
        let url = Bundle.main.bundleURL
        if (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return true
        }
        return url.pathComponents.contains("AppTranslocation")
    }
}
