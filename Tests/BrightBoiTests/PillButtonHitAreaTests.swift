import AppKit
import SwiftUI
import Testing
@testable import BrightBoi

/// Synthesized clicks on real views: the whole drawn pill has to respond, not
/// just its text. Clicks go through `NSWindow.sendEvent`, the same path a
/// real mouse takes, and the pill's extent is found by sweeping clicks across
/// the window rather than by trusting layout numbers.
@MainActor
@Suite("Pill button hit areas", .serialized)
struct PillButtonHitAreaTests {
    private final class Counter {
        var count = 0
    }

    /// Every window opened by a test, so each test can close them again.
    fileprivate static var openWindows: [NSWindow] = []

    private func closeWindows() {
        for window in Self.openWindows { window.orderOut(nil) }
        Self.openWindows = []
    }

    @MainActor
    private struct Harness<V: View> {
        let window: NSWindow
        let hosting: NSHostingView<V>

        init(_ view: V) {
            hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: .aqua)
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            // Shown, but far off every screen: SwiftUI only routes events to
            // a window that is on screen.
            window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
            window.orderFrontRegardless()
            PillButtonHitAreaTests.openWindows.append(window)
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
        }

        var bounds: NSRect { hosting.bounds }

        /// A left click at `point` (window coordinates, origin bottom-left).
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

    /// The bounding box of every point in `region` whose click makes `didFire`
    /// report a new activation, or nil when none does. `rebuild` is called
    /// after a hit for actions that only fire once.
    private func hitBounds(
        in region: NSRect,
        step: CGFloat,
        click: (CGPoint) -> Void,
        didFire: () -> Bool,
        rebuild: () -> Void = {}
    ) -> NSRect? {
        var box: NSRect?
        var y = region.minY
        while y <= region.maxY {
            var x = region.minX
            while x <= region.maxX {
                click(CGPoint(x: x, y: y))
                if didFire() {
                    let point = NSRect(x: x, y: y, width: 0, height: 0)
                    box = box.map { $0.union(point) } ?? point
                    rebuild()
                }
                x += step
            }
            y += step
        }
        return box
    }

    // MARK: The style itself

    /// A plain button in a 160x70 window, laid out by a wrapper that reports
    /// the styled button's frame.
    private struct Probe: View {
        var counter: Counter
        var frame: Binding<CGRect>

        var body: some View {
            Button("Label") { counter.count += 1 }
                .buttonStyle(PillButtonStyle(horizontalPadding: 14, verticalPadding: 7))
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { frame.wrappedValue = proxy.frame(in: .global) }
                })
                .frame(width: 160, height: 70)
        }
    }

    @Test("the clickable area is exactly the drawn pill, padding included")
    func pillStyleHitAreaMatchesDrawnFrame() throws {
        defer { closeWindows() }
        let counter = Counter()
        var drawn = CGRect.zero
        let harness = Harness(Probe(counter: counter, frame: Binding(get: { drawn }, set: { drawn = $0 })))
        let flippedY = harness.bounds.height - drawn.maxY
        #expect(drawn.width > 60 && drawn.height > 20)

        // Just inside each edge of the drawn pill the click fires; just
        // outside it does not.
        func fires(_ x: CGFloat, _ y: CGFloat) -> Bool {
            let before = counter.count
            harness.click(at: CGPoint(x: x, y: y))
            return counter.count > before
        }
        let minY = flippedY, maxY = flippedY + drawn.height
        // (Corners are rounded, so test just inside the middle of each edge.)
        let midX = (drawn.minX + drawn.maxX) / 2, midY = (minY + maxY) / 2
        for (x, y) in [(drawn.minX + 1, midY), (drawn.maxX - 1, midY), (midX, minY + 1), (midX, maxY - 1)] {
            #expect(fires(x, y), "inside \(x),\(y)")
        }
        for (x, y) in [(drawn.minX - 2, (minY + maxY) / 2), (drawn.maxX + 2, (minY + maxY) / 2),
                       ((drawn.minX + drawn.maxX) / 2, minY - 2), ((drawn.minX + drawn.maxX) / 2, maxY + 2)] {
            #expect(!fires(x, y), "outside \(x),\(y)")
        }
    }

    // MARK: Onboarding

    private func onboardingPermissions(
        openedPane: Counter = Counter()
    ) -> (Harness<OnboardingView>, OnboardingModel, FakeBrightnessPersistence, FakePermissionsChecker) {
        let checker = FakePermissionsChecker()
        checker.stubbedAccessibilityGranted = false
        let persistence = FakeBrightnessPersistence()
        let model = OnboardingModel(
            persistence: persistence,
            permissions: PermissionsModel(checker: checker, openURL: { _ in openedPane.count += 1 })
        )
        model.advance()
        return (Harness(OnboardingView(model: model)), model, persistence, checker)
    }

    @Test("Skip responds across its whole pill, not only on its words")
    func skipRespondsAcrossThePill() throws {
        defer { closeWindows() }
        var (harness, model, persistence, _) = onboardingPermissions()
        let width = OnboardingView.contentSize.width
        func rebuild() { (harness, model, persistence, _) = onboardingPermissions() }

        // Down the left padding, a column well clear of the words, over the
        // Skip row only: the main button above it also moves on to the
        // confirmation, so the sweep stays below it.
        let column = NSRect(x: 34, y: 36, width: 0, height: 44)
        let box = try #require(hitBounds(
            in: column, step: 3,
            click: { harness.click(at: $0) },
            didFire: { model.step == .confirmation },
            rebuild: rebuild
        ))
        #expect(box.height >= 24, "the pill is well over the label's 15pt, at least 24pt tall, got \(box.height)")

        // And at both far ends of the pill's width, on its middle line.
        for x in [width - 34, 34] {
            rebuild()
            harness.click(at: CGPoint(x: x, y: box.midY))
            #expect(persistence.saveHasCompletedOnboardingCallCount == 1, "x \(x)")
        }
    }

    @Test("Grant responds in the padding around its label")
    func grantRespondsInItsPadding() throws {
        defer { closeWindows() }
        let openedPane = Counter()
        let (harness, _, _, checker) = onboardingPermissions(openedPane: openedPane)
        var seen = 0
        let total = { checker.requestAccessibilityCallCount + openedPane.count }
        // The Grant row sits at the right of the window, in its upper half.
        let region = NSRect(x: 250, y: 225, width: 102, height: 70)
        let box = try #require(hitBounds(
            in: region, step: 4,
            click: { harness.click(at: $0) },
            didFire: { defer { seen = total() }; return total() > seen }
        ))
        // Label "Grant" alone is about 15pt tall and 34pt wide.
        #expect(box.height >= 22, "got \(box.height)")
        #expect(box.width >= 40, "got \(box.width)")
    }

    @Test("Continue responds across its full width")
    func continueRespondsAcrossItsWidth() throws {
        defer { closeWindows() }
        // The 324pt-wide pill starts 28pt in; click just inside its left edge.
        var hit = false
        for y in stride(from: 84.0, through: 118.0, by: 3.0) where !hit {
            let probe = onboardingPermissions()
            probe.0.click(at: CGPoint(x: 32, y: y))
            if probe.1.step == .confirmation { hit = true }
        }
        #expect(hit)
    }

    // MARK: Donation

    @Test("Not today responds in the padding around its label")
    func notTodayRespondsInItsPadding() throws {
        defer { closeWindows() }
        let dismissed = Counter()
        let harness = Harness(DonationView(keyState: DonationWindowKeyState(), onDismiss: { dismissed.count += 1 }, openURL: { _ in false }))
        var seen = 0
        // The button sits under the body text, near the window's lower middle.
        let region = NSRect(x: 100, y: 40, width: 180, height: 70)
        let box = try #require(hitBounds(
            in: region, step: 4,
            click: { harness.click(at: $0) },
            didFire: { defer { seen = dismissed.count }; return dismissed.count > seen }
        ))
        // "Not today" on its own is about 15pt tall and 62pt wide.
        #expect(box.height >= 24, "got \(box.height)")
        #expect(box.width >= 70, "got \(box.width)")
    }

    @Test("Buy me a coffee closes the window once the page opened, and stays up if it did not")
    func coffeeButtonDismissesOnlyAfterASuccessfulOpen() throws {
        defer { closeWindows() }
        for opens in [true, false] {
            let dismissed = Counter()
            let opened = Counter()
            let harness = Harness(DonationView(
                keyState: DonationWindowKeyState(),
                onDismiss: { dismissed.count += 1 },
                openURL: { _ in opened.count += 1; return opens }
            ))
            // Down the left padding of the coffee button, clear of every other control.
            let column = NSRect(x: 40, y: 0, width: 0, height: harness.bounds.height)
            var seen = 0
            _ = try #require(hitBounds(
                in: column, step: 4,
                click: { harness.click(at: $0) },
                didFire: { defer { seen = opened.count }; return opened.count > seen }
            ))
            #expect((dismissed.count > 0) == opens)
        }
    }
}
