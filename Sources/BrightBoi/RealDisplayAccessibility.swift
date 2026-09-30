import AppKit

/// Real `DisplayAccessibilityProviding`: the system's Invert Colors setting,
/// read from `NSWorkspace`, with live change notifications.
///
/// Color Filters (greyscale, tints) have no public signal and are not
/// covered.
@MainActor
final class RealDisplayAccessibility: DisplayAccessibilityProviding {
    private var observer: NSObjectProtocol?
    private var onChange: (() -> Void)?

    var invertsColors: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldInvertColors
    }

    func startObserving(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onChange?()
            }
        }
    }

    isolated deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
