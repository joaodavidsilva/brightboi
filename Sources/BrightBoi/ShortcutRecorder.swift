import AppKit
import SwiftUI

/// The state and behaviour behind the two shortcut pills in Settings. One
/// recorder serves both, so only one pill can be armed at a time.
///
/// Armed, it listens for the next key combination (through the key tap's
/// capture mode, so bare F1/F2 and combos already in use work, plus a local
/// key monitor for what the tap can't see). It disarms, leaving the shortcut
/// as it was, on a second click on the pill, Escape, Tab, a click elsewhere,
/// the Settings window losing focus, or after `timeout`. Key presses in other
/// windows of the app, such as the popover's ⌘Q and ⌘,, are never consumed.
@MainActor
@Observable
final class ShortcutRecorder {
    struct Rejection: Equatable {
        let press: BrightnessController.KeyPress
        let message: String
    }

    /// The pill waiting for a key, if any.
    private(set) var armed: BrightnessController.KeyPress?
    /// The reason the last recorded combo was refused, shown on that pill.
    private(set) var rejection: Rejection?

    /// How long a pill waits for a key before giving up.
    let timeout: Duration
    /// How long a rejection stays visible.
    let rejectionDuration: Duration

    @ObservationIgnored private let controller: BrightnessController
    @ObservationIgnored private let context: () -> ShortcutContext
    @ObservationIgnored private let announce: (String) -> Void
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void

    @ObservationIgnored private var anchors: [BrightnessController.KeyPress: WeakView] = [:]
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var rejectionTask: Task<Void, Never>?

    private struct WeakView {
        weak var view: NSView?
    }

    init(
        controller: BrightnessController,
        timeout: Duration = .seconds(30),
        rejectionDuration: Duration = .seconds(3),
        context: @escaping () -> ShortcutContext = { ShortcutContext.current() },
        announce: @escaping (String) -> Void = { AccessibilityNotification.Announcement($0).post() },
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.controller = controller
        self.timeout = timeout
        self.rejectionDuration = rejectionDuration
        self.context = context
        self.announce = announce
        self.sleep = sleep
    }

    // MARK: - Arming

    /// A click on a pill: arms it, replacing any other armed pill, or
    /// disarms it when it is already armed.
    func toggle(_ press: BrightnessController.KeyPress) {
        if armed == press {
            cancel()
        } else {
            arm(press)
        }
    }

    /// Disarms without changing the shortcut.
    func cancel() {
        guard armed != nil else { return }
        disarm()
    }

    private func arm(_ press: BrightnessController.KeyPress) {
        if armed != nil { disarm() }
        clearRejection()
        armed = press
        controller.beginShortcutCapture { [weak self] combo in
            self?.submit(combo)
        }
        installMonitors()
        timeoutTask = Task { [weak self, timeout, sleep] in
            await sleep(timeout)
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
        announce("Recording the \(press.label) shortcut. Press a key combination, or Escape to cancel.")
    }

    private func disarm() {
        armed = nil
        controller.endShortcutCapture()
        removeMonitors()
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    /// Call when the pills leave the screen.
    func teardown() {
        cancel()
        clearRejection()
    }

    // MARK: - Recording

    /// Applies `combo` to the armed pill, or shows why it can't be used.
    func submit(_ combo: KeyCombo) {
        guard let press = armed else { return }
        disarm()

        if let reason = controller.currentState.keyRemapShortcut.rejection(of: combo, for: press, context: context()) {
            reject(reason.message, for: press)
        } else if !controller.setKeyRemapCombo(combo, for: press) {
            reject(ShortcutRejection.reservedByMacOS.message, for: press)
        }
    }

    private func reject(_ message: String, for press: BrightnessController.KeyPress) {
        rejection = Rejection(press: press, message: message)
        announce(message)
        rejectionTask?.cancel()
        rejectionTask = Task { [weak self, rejectionDuration, sleep] in
            await sleep(rejectionDuration)
            guard !Task.isCancelled else { return }
            self?.rejection = nil
        }
    }

    private func clearRejection() {
        rejectionTask?.cancel()
        rejectionTask = nil
        rejection = nil
    }

    // MARK: - Events

    /// Remembers the view behind a pill, so a click can be told apart as
    /// landing on the armed pill or elsewhere, and its window found.
    func register(_ view: NSView, for press: BrightnessController.KeyPress) {
        anchors[press] = WeakView(view: view)
    }

    private var armedWindow: NSWindow? {
        armed.flatMap { anchors[$0]?.view?.window }
    }

    private func installMonitors() {
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors always run on the main thread.
            nonisolated(unsafe) let event = event
            nonisolated(unsafe) var result: NSEvent? = event
            MainActor.assumeIsolated { if let self { result = self.handleKeyDown(event) } }
            return result
        }
        let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            nonisolated(unsafe) let event = event
            nonisolated(unsafe) var result: NSEvent? = event
            MainActor.assumeIsolated { if let self { result = self.handleClick(event) } }
            return result
        }
        monitors = [keys, clicks].compactMap { $0 }

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, let armed = self.armedWindow, window === armed else { return }
                    self.cancel()
                }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
        ]
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // Only the Settings window records; the popover's own shortcuts keep working.
        guard let window = armedWindow, event.window === window else { return event }
        let consumed = handleKey(
            keyCode: Int64(event.keyCode),
            modifiers: KeyCombo.Modifiers(nsEventModifierFlags: event.modifierFlags)
        )
        return consumed ? nil : event
    }

    /// Treats a key pressed in the Settings window while armed: Escape
    /// cancels, Tab and Shift-Tab cancel and move focus on as usual, anything
    /// else is the recorded combo. Returns whether the key is consumed.
    func handleKey(keyCode: Int64, modifiers: KeyCombo.Modifiers) -> Bool {
        guard armed != nil else { return false }
        if KeyTapMatcher.isRecorderControlKey(keyCode: keyCode, modifiers: modifiers) {
            cancel()
            return keyCode == 0x35
        }
        let combo = KeyCombo(modifiers: modifiers, keyCode: keyCode)
        // Only the media-key path may produce F1 or F2; a plain key-down of
        // them would be accepted and then never fire.
        if combo == .f1 || combo == .f2, let press = armed {
            disarm()
            reject(ShortcutRejection.useBrightnessKey.message, for: press)
            return true
        }
        submit(combo)
        return true
    }

    private func handleClick(_ event: NSEvent) -> NSEvent? {
        guard let view = armed.flatMap({ anchors[$0]?.view }), let window = view.window else { return event }
        let onArmedPill = event.window === window
            && view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        // A click on the armed pill is its own toggle.
        if !onArmedPill { cancel() }
        return event
    }
}

extension BrightnessController.KeyPress {
    /// The name of the direction, as Settings words it.
    var label: String {
        switch self {
        case .raise: "Raise"
        case .lower: "Lower"
        }
    }
}

/// An invisible view behind a pill that tells the recorder where the pill is.
private struct PillAnchor: NSViewRepresentable {
    var onView: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        onView(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        onView(view)
    }
}

/// A small clickable pill showing one direction's combo. Click it to record a
/// new one: it shows an accent border and an Esc hint while armed, and the
/// reason in red when a combo is refused.
struct ShortcutPill: View {
    var press: BrightnessController.KeyPress
    var combo: KeyCombo
    var recorder: ShortcutRecorder

    var body: some View {
        let isArmed = recorder.armed == press
        let rejection = recorder.rejection?.press == press ? recorder.rejection?.message : nil

        Button {
            recorder.toggle(press)
        } label: {
            label(isArmed: isArmed, rejection: rejection)
                .font(Theme.Typography.control)
        }
        .buttonStyle(PillButtonStyle(fill: .fillGrouped, horizontalPadding: 10, verticalPadding: 5))
        .overlay {
            if isArmed {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .background(PillAnchor { recorder.register($0, for: press) })
        .accessibilityLabel("\(press.label) brightness shortcut")
        .accessibilityValue(isArmed ? "Recording. Press a key combination, or Escape to cancel" : combo.spokenName)
        .accessibilityHint("Press to record a new shortcut")
    }

    @ViewBuilder
    private func label(isArmed: Bool, rejection: String?) -> some View {
        if isArmed {
            HStack(spacing: 6) {
                Text("Type shortcut…").foregroundStyle(Color.textRow)
                Text("esc to cancel")
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Color.textTertiary)
            }
        } else if let rejection {
            Text(rejection).foregroundStyle(Color.recorderError)
        } else {
            Text(combo.displayString).foregroundStyle(Color.textRow)
        }
    }
}
