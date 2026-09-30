import CoreGraphics
import Foundation

/// Calls `onChange` on the main thread once a display reconfiguration has
/// finished: a display plugged in or removed, the lid opened or closed, a
/// resolution, arrangement or colour-profile change. Backed by
/// `CGDisplayRegisterReconfigurationCallback`, which fires for every display
/// involved and once more before each change begins; only the completed
/// notifications count, and a burst of them is coalesced into one call.
/// `NSApplication.didChangeScreenParametersNotification` is not guaranteed to
/// announce all of these, so this is the primary signal.
@MainActor
final class DisplayReconfigurationObserver {
    /// Holds the observer weakly for the C callback, which must not keep it
    /// alive and may outlive it by one delivery.
    private final class Reference: @unchecked Sendable {
        weak var observer: DisplayReconfigurationObserver?
    }

    private static let callback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
        guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
        let reference = Unmanaged<Reference>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                reference.observer?.scheduleChange()
            }
        }
    }

    private let onChange: () -> Void
    private let reference: Unmanaged<Reference>
    private var changePending = false

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let reference = Reference()
        self.reference = Unmanaged.passRetained(reference)
        reference.observer = self
        CGDisplayRegisterReconfigurationCallback(Self.callback, self.reference.toOpaque())
    }

    isolated deinit {
        CGDisplayRemoveReconfigurationCallback(Self.callback, reference.toOpaque())
        reference.release()
    }

    private func scheduleChange() {
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.changePending = false
                self?.onChange()
            }
        }
    }
}
