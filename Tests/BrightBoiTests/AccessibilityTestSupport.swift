import AppKit
import ApplicationServices
import SwiftUI
import Testing
@testable import BrightBoi

/// Shared support for tests that host a real view in a window that is shown
/// but sits far off every screen, and read what assistive technology would
/// see from its accessibility tree.

/// Every window opened by these tests, closed again by `OffscreenWindows.closeAll()`.
@MainActor
enum OffscreenWindows {
    fileprivate static var open: [NSWindow] = []

    static func closeAll() {
        for window in open {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        open = []
    }
}

/// A view hosted in an off-screen window. `orderFrontRegardless` puts it "on
/// screen" so SwiftUI lays out, builds its accessibility tree and routes
/// events, but at -30000,-30000 no display ever shows it.
@MainActor
struct OffscreenHost<V: View> {
    let window: NSWindow
    let hosting: NSHostingView<V>

    init(_ view: V, title: String? = nil, appearance: NSAppearance.Name = .aqua) {
        AXSession.activate()
        hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let title { window.title = title }
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        OffscreenWindows.open.append(window)
        settle()
    }

    /// Lets SwiftUI finish a layout and display pass, plus a short run-loop
    /// turn for work it defers (accessibility elements, focus).
    func settle() {
        AXSession.activate()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        hosting.layoutSubtreeIfNeeded()
    }

    var bounds: NSRect { hosting.bounds }

    /// An element's accessibility frame (screen coordinates) in window
    /// coordinates, the space clicks are sent in.
    func windowFrame(of node: AXNode) -> NSRect { window.convertFromScreen(node.frame) }

    /// Clicks at `point` and reports whether `fired` changed.
    func clickFires(at point: CGPoint, fired: () -> Int) -> Bool {
        let before = fired()
        click(at: point)
        return fired() > before
    }

    /// A key press and release through `NSWindow.sendEvent`, the way the
    /// window receives a key from the keyboard.
    func press(key keyCode: UInt16, characters: String) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
            )!
            window.sendEvent(event)
        }
    }

    /// The accessibility tree below the hosting view, flattened.
    var tree: AXTree { AXTree(root: hosting) }

    /// A left click at `point` (window coordinates, origin bottom-left),
    /// through `NSWindow.sendEvent` like a real mouse.
    func click(at point: CGPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
            window.sendEvent(event)
        }
    }
}

/// One accessibility element, as a plain value.
struct AXNode {
    var depth: Int
    var role: String
    var subrole: String
    var label: String
    var title: String
    var value: String
    /// What VoiceOver speaks for the value (AXValueDescription), such as
    /// "150 percent, boosted", where `value` holds the raw number.
    var valueDescription: String
    var help: String
    /// Screen coordinates (origin bottom-left), as accessibility reports them.
    var frame: NSRect
    var actions: [String]
    var element: AnyObject

    /// What VoiceOver would name the element.
    var name: String { label.isEmpty ? title : label }
    /// What VoiceOver reads for the element: its name, or for text its value.
    var spoken: String { name.isEmpty ? value : name }
    /// Nothing for VoiceOver to say: no name, no value.
    var isBlank: Bool { name.isEmpty && value.isEmpty }

    var summary: String {
        let pad = String(repeating: "  ", count: depth)
        let sub = subrole.isEmpty ? "" : "/\(subrole)"
        return "\(pad)\(role)\(sub) label=\"\(label)\" title=\"\(title)\" value=\"\(value)\" valueDesc=\"\(valueDescription)\" help=\"\(help)\" frame=\(Int(frame.width))x\(Int(frame.height)) actions=\(actions)"
    }

    /// The legacy press, increment and decrement entry points, straight on
    /// the element. Tests use them only on elements whose actions are stubbed.
    @discardableResult func press() -> Bool { element.accessibilityPerformPress?() ?? false }
    @discardableResult func increment() -> Bool { element.accessibilityPerformIncrement?() ?? false }
    @discardableResult func decrement() -> Bool { element.accessibilityPerformDecrement?() ?? false }
}

/// A flat, assertable list of the accessibility elements below a root.
struct AXTree {
    let nodes: [AXNode]

    init(root: AnyObject) {
        var nodes: [AXNode] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ element: AnyObject, depth: Int) {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return }
            if depth > 0 { nodes.append(Self.node(for: element, depth: depth)) }
            for child in (element.accessibilityChildren?() ?? []) { walk(child as AnyObject, depth: depth + 1) }
        }
        walk(root, depth: 0)
        self.nodes = nodes
    }

    private static func node(for element: AnyObject, depth: Int) -> AXNode {
        func text(_ value: Any?) -> String {
            switch value {
            case let string as String: string
            case let number as NSNumber: number.stringValue
            case nil: ""
            default: "\(value!)"
            }
        }
        // Optional chaining through `AnyObject` turns a missing method into nil.
        let value: Any? = element.accessibilityValue?() ?? nil
        return AXNode(
            depth: depth,
            role: element.accessibilityRole?()?.rawValue ?? "",
            subrole: element.accessibilitySubrole?()?.rawValue ?? "",
            label: element.accessibilityLabel?() ?? "",
            title: element.accessibilityTitle?() ?? "",
            value: text(value),
            valueDescription: valueDescription(of: element),
            help: element.accessibilityHelp?() ?? "",
            frame: element.accessibilityFrame?() ?? .zero,
            actions: actionNames(of: element),
            element: element
        )
    }

    private static func valueDescription(of element: AnyObject) -> String {
        let selector = NSSelectorFromString("accessibilityValueDescription")
        guard element.responds(to: selector) else { return "" }
        return element.perform(selector)?.takeUnretainedValue() as? String ?? ""
    }

    /// The legacy action names (AXPress, AXIncrement, AXDecrement ...) an
    /// element answers to.
    private static func actionNames(of element: AnyObject) -> [String] {
        let selector = NSSelectorFromString("accessibilityActionNames")
        guard element.responds(to: selector),
              let names = element.perform(selector)?.takeUnretainedValue() as? [String] else { return [] }
        return names
    }

    var dump: String { nodes.map(\.summary).joined(separator: "\n") }

    func nodes(role: NSAccessibility.Role) -> [AXNode] { nodes.filter { $0.role == role.rawValue } }
    func node(named name: String, role: NSAccessibility.Role? = nil) -> AXNode? {
        nodes.first { $0.name == name && (role == nil || $0.role == role!.rawValue) }
    }
}

/// Makes this process answer accessibility queries the way it does for a
/// real client. SwiftUI builds its accessibility tree lazily, only for a
/// process that an assistive client has asked about, and a test process is
/// not an application until it has an activation policy. The one query made
/// here is against this very process; nothing else on the Mac is touched.
@MainActor
enum AXSession {

    /// Whether this process may query itself (the host of the tests must be
    /// trusted for Accessibility). Tests that read the tree require it.
    nonisolated static var isAvailable: Bool { AXIsProcessTrusted() }

    static func activate() {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.finishLaunching()
        var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &value)
    }
}

/// A controller wired to fakes only, for views under test.
@MainActor
struct ControllerRig {
    let controller: BrightnessController
    let display = FakeDisplayBrightnessProvider()
    let persistence = FakeBrightnessPersistence()
    let keyTap = FakeKeyTap()
    let loginItems = FakeLoginItemService()
    let permissionsChecker = FakePermissionsChecker()
    let permissions: PermissionsModel
    let opened: OpenedURLs
    let power = FakePowerSourceProvider()
    let thermal = FakeThermalStateProvider()
    let displayAccessibility = FakeDisplayAccessibility()

    /// Records what the permissions model was asked to open, instead of opening it.
    final class OpenedURLs {
        var urls: [URL] = []
    }

    init(
        supportsBoost: Bool = true,
        storedPercentage: Double? = 50,
        storedBoostCeiling: Double? = nil,
        storedKeyRemapEnabled: Bool? = nil,
        storedKeyRemapShortcut: KeyRemapShortcut? = nil,
        builtInDisplayAvailable: Bool = true,
        keyTapStarts: Bool = true,
        accessibilityGranted: Bool = true,
        inputMonitoring: PermissionAccess = .granted,
        loginItemStatus: LoginItemStatus = .notRegistered
    ) {
        loginItems.stubbedStatus = loginItemStatus
        permissionsChecker.stubbedInputMonitoringAccess = inputMonitoring
        display.stubbedSupportsExtendedBrightness = supportsBoost
        display.stubbedIsBuiltInDisplayAvailable = builtInDisplayAvailable
        persistence.storedPercentage = storedPercentage
        persistence.storedBoostCeiling = storedBoostCeiling
        persistence.storedKeyRemapEnabled = storedKeyRemapEnabled
        persistence.storedKeyRemapShortcut = storedKeyRemapShortcut
        persistence.storedHasCompletedOnboarding = true
        keyTap.startSucceeds = keyTapStarts
        permissionsChecker.stubbedAccessibilityGranted = accessibilityGranted
        let opened = OpenedURLs()
        self.opened = opened
        permissions = PermissionsModel(checker: permissionsChecker, openURL: { opened.urls.append($0) })
        controller = BrightnessController(
            displayBrightness: display,
            autoBrightnessToggle: FakeAutoBrightnessToggle(),
            loginItemService: loginItems,
            persistence: persistence,
            keyTap: keyTap,
            powerSource: power,
            thermalState: thermal,
            bundleLocation: FakeBundleLocationProvider(),
            displayAccessibility: displayAccessibility,
            permissions: permissions,
            schedule: ManualPersistScheduler().schedule,
            keyTapWatchSchedule: ManualPersistScheduler().schedule
        )
        controller.start()
    }
}

// MARK: - Shared expectations

/// The tree is only built for a process an assistive client can query, so
/// tests that read it need the host running them (Terminal, Xcode, CI) to be
/// trusted for Accessibility, and are skipped where it is not.
let accessibilityAvailable = Testing.ConditionTrait.enabled(
    if: AXSession.isAvailable,
    "the test host must be trusted for Accessibility to read the accessibility tree"
)

@MainActor
final class CallCount {
    var value = 0
}

/// Roles that only hold other elements; everything else must say something.
let containerRoles: Set<String> = [
    NSAccessibility.Role.scrollArea.rawValue,
    NSAccessibility.Role.group.rawValue,
    NSAccessibility.Role.valueIndicator.rawValue,
]

extension AXTree {
    /// Names of the buttons, in tree order.
    var buttonNames: [String] { nodes(role: .button).map(\.name) }
    /// Elements that would give VoiceOver nothing to say.
    var blankElements: [AXNode] { nodes.filter { $0.isBlank && !containerRoles.contains($0.role) } }
    /// Every spoken piece of text: names, values and value descriptions.
    var spokenTexts: [String] { nodes.flatMap { [$0.name, $0.value, $0.valueDescription] }.filter { !$0.isEmpty } }
}

extension NSAccessibility.Role {
    /// The role SwiftUI gives text marked as a header.
    static let heading = NSAccessibility.Role(rawValue: "AXHeading")
}

// MARK: - Clicking across a button's accessibility frame

extension OffscreenHost {
    /// The centre of `frame` and a point just inside each edge.
    static var insidePoints: [(NSRect) -> CGPoint] {
        let inset: CGFloat = 2.5
        return [
            { CGPoint(x: $0.midX, y: $0.midY) },
            { CGPoint(x: $0.minX + inset, y: $0.midY) },
            { CGPoint(x: $0.maxX - inset, y: $0.midY) },
            { CGPoint(x: $0.midX, y: $0.minY + inset) },
            { CGPoint(x: $0.midX, y: $0.maxY - inset) },
        ]
    }

    static func insidePoints(of frame: NSRect) -> [CGPoint] { insidePoints.map { $0(frame) } }

    /// Clicks the centre and just inside each edge of `name`'s accessibility
    /// frame, each time in a fresh window from `make` (most buttons change
    /// the screen once pressed), and checks every click fired. With
    /// `clickOutside`, also checks that a click a few points past either end
    /// does not. Together these show the frame is neither larger nor smaller
    /// than what responds, and so matches the drawn pill.
    @MainActor
    static func expectFrameClicks(
        button name: String,
        clickOutside: Bool = true,
        make: () -> (OffscreenHost<V>, fired: () -> Int),
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        func button(_ host: OffscreenHost<V>) -> (AXNode, NSRect)? {
            guard let node = host.tree.node(named: name, role: .button) else { return nil }
            return (node, host.windowFrame(of: node))
        }
        let inside = Self.insidePoints
        for (index, point) in inside.enumerated() {
            let (host, fired) = make()
            guard let (_, frame) = button(host) else {
                Issue.record("no button named \(name)", sourceLocation: sourceLocation)
                return
            }
            #expect(host.clickFires(at: point(frame), fired: fired), "\(name): inside point \(index) of \(frame)", sourceLocation: sourceLocation)
        }
        guard clickOutside else { return }
        for (index, dx) in [-4.0, 4.0].enumerated() {
            let (host, fired) = make()
            guard let (_, frame) = button(host) else { return }
            let x = dx < 0 ? frame.minX + dx : frame.maxX + dx
            #expect(!host.clickFires(at: CGPoint(x: x, y: frame.midY), fired: fired), "\(name): outside end \(index) of \(frame)", sourceLocation: sourceLocation)
        }
    }
}
