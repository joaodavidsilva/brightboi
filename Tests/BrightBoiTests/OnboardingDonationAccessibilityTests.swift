import AppKit
import SwiftUI
import Testing
@testable import BrightBoi

/// Onboarding, the donation window and the key-press HUD: what assistive
/// technology sees, and that every pill button's accessibility frame is
/// exactly what responds to a click.
@MainActor
@Suite("Onboarding and donation accessibility", .serialized, accessibilityAvailable)
struct OnboardingDonationAccessibilityTests {
    private struct Onboarding {
        let host: OffscreenHost<OnboardingView>
        let model: OnboardingModel
        let persistence: FakeBrightnessPersistence
        let checker: FakePermissionsChecker
        let openedPane: CallCount
    }

    private func onboarding(step: OnboardingModel.Step = .welcome, granted: Bool = false) -> Onboarding {
        let checker = FakePermissionsChecker()
        checker.stubbedAccessibilityGranted = granted
        let persistence = FakeBrightnessPersistence()
        let openedPane = CallCount()
        let model = OnboardingModel(
            persistence: persistence,
            permissions: PermissionsModel(checker: checker, openURL: { _ in openedPane.value += 1 })
        )
        while model.step != step { model.advance() }
        return Onboarding(host: OffscreenHost(OnboardingView(model: model)), model: model, persistence: persistence, checker: checker, openedPane: openedPane)
    }

    private func donation(
        dismissed: CallCount = CallCount(),
        opened: CallCount = CallCount()
    ) -> OffscreenHost<DonationView> {
        OffscreenHost(DonationView(
            keyState: DonationWindowKeyState(),
            onDismiss: { dismissed.value += 1 },
            openURL: { _ in opened.value += 1; return true }
        ))
    }

    // MARK: Structure

    @Test("each onboarding step has one heading, and the page dots read Step N of 3 as static text")
    func onboardingHeadingsAndDots() {
        defer { OffscreenWindows.closeAll() }
        let expected: [(OnboardingModel.Step, String)] = [
            (.welcome, "Hey, I'm BrightBoi."),
            (.permissions, "One permission, then I'll be quiet."),
            (.confirmation, "You're up top now."),
        ]
        for (index, (step, title)) in expected.enumerated() {
            let page = onboarding(step: step)
            let tree = page.host.tree
            #expect(tree.nodes(role: .heading).map(\.name) == [title], "\(step)")
            let dots = tree.nodes(role: .staticText).filter { $0.value.hasPrefix("Step ") }
            #expect(dots.map(\.value) == ["Step \(index + 1) of 3"], "\(step)")
            OffscreenWindows.closeAll()
        }
    }

    @Test("the permission row reads as name, purpose, then status, as one element")
    func permissionRowReadsInOrder() throws {
        defer { OffscreenWindows.closeAll() }
        let page = onboarding(step: .permissions)
        let row = try #require(page.host.tree.nodes.first { $0.spoken.hasPrefix("Accessibility, ") })
        #expect(row.spoken == OnboardingCopy.permissionRowLabel(title: "Accessibility", subtitle: OnboardingCopy.permissionSubtitle, granted: false))
        #expect(row.role == NSAccessibility.Role.staticText.rawValue)
        #expect(page.host.tree.buttonNames == ["Grant Accessibility", "Continue without the keys", "Skip — slider only"])

        let done = onboarding(step: .permissions, granted: true)
        let doneRow = try #require(done.host.tree.nodes.first { $0.spoken.hasPrefix("Accessibility, ") })
        #expect(doneRow.spoken.hasSuffix(", Granted"))
        #expect(!done.host.tree.buttonNames.contains("Grant Accessibility"))
        #expect(!done.host.tree.buttonNames.contains("Skip — slider only"))
    }

    @Test("every onboarding step and the donation window: nothing blank, no glyphs, no shared button names")
    func windowsAreWellFormed() {
        defer { OffscreenWindows.closeAll() }
        var trees: [(String, AXTree)] = []
        for step in OnboardingModel.Step.allCases {
            trees.append(("onboarding \(step)", onboarding(step: step).host.tree))
        }
        trees.append(("donation", donation().tree))
        for (name, tree) in trees {
            #expect(tree.blankElements.isEmpty, "\(name): \(tree.blankElements.map(\.summary))")
            #expect(tree.nodes(role: .image).isEmpty, "\(name): decorative glyphs are hidden")
            #expect(tree.nodes.allSatisfy { $0.role != NSAccessibility.Role.unknown.rawValue }, "\(name): \n\(tree.dump)")
            #expect(Set(tree.buttonNames).count == tree.buttonNames.count, "\(name): \(tree.buttonNames)")
        }
    }

    @Test("the donation window has a heading and its two buttons, and hints Esc only once it can take it")
    func donationStructure() {
        defer { OffscreenWindows.closeAll() }
        let tree = donation().tree
        #expect(tree.nodes(role: .heading).map(\.name) == ["Free app. Expensive boi."])
        #expect(tree.buttonNames == ["Buy me a coffee", "Not today"])
        #expect(!tree.nodes(role: .staticText).contains { $0.value == "or press Esc" })
    }

    @Test("the windows announce their names, which their hidden title bars never draw")
    func windowTitles() {
        let rig = ControllerRig()
        let welcome = OnboardingWindowController(
            model: OnboardingModel(persistence: FakeBrightnessPersistence(), permissions: rig.permissions),
            controller: rig.controller,
            onClose: {}
        )
        #expect(welcome.windowTitle == "Welcome to BrightBoi")
        #expect(DonationWindowController(onClose: {}).windowTitle == "Support BrightBoi")
    }

    @Test("the key-press HUD is hidden from accessibility, which gets a spoken announcement instead")
    func hudIsHidden() {
        defer { OffscreenWindows.closeAll() }
        let rig = ControllerRig(storedPercentage: 150)
        let host = OffscreenHost(BrightnessHUDView(state: rig.controller.currentState))
        #expect(host.tree.nodes.isEmpty, "\(host.tree.dump)")
    }

    // MARK: Accessibility frames match what responds

    @Test("Skip's frame is its whole pill, across the full width")
    func skipFrame() throws {
        defer { OffscreenWindows.closeAll() }
        OffscreenHost<OnboardingView>.expectFrameClicks(button: "Skip — slider only", make: {
            let page = onboarding(step: .permissions)
            return (page.host, { page.persistence.saveHasCompletedOnboardingCallCount })
        })
        let page = onboarding(step: .permissions)
        let frame = page.host.windowFrame(of: try #require(page.host.tree.node(named: "Skip — slider only")))
        #expect(frame.width == OnboardingView.contentSize.width - 2 * OnboardingView.buttonInset)
        #expect(frame.height >= 24)
    }

    @Test("Grant's frame is its padded pill")
    func grantFrame() throws {
        defer { OffscreenWindows.closeAll() }
        // The window's own two counters together: the system prompt, or its pane.
        OffscreenHost<OnboardingView>.expectFrameClicks(button: "Grant Accessibility", make: {
            let page = onboarding(step: .permissions)
            return (page.host, { page.checker.requestAccessibilityCallCount + page.openedPane.value })
        })
        let page = onboarding(step: .permissions)
        let frame = page.host.windowFrame(of: try #require(page.host.tree.node(named: "Grant Accessibility")))
        #expect(frame.height >= 22, "taller than its 15pt label, got \(frame.height)")
        #expect(frame.width >= 50, "wider than its 34pt label, got \(frame.width)")
    }

    @Test("the main button's frame is its full-width pill on each step")
    func primaryButtonFrames() throws {
        defer { OffscreenWindows.closeAll() }
        OffscreenHost<OnboardingView>.expectFrameClicks(button: "Let's go", make: {
            let page = onboarding()
            return (page.host, { page.model.step == .permissions ? 1 : 0 })
        })
        OffscreenHost<OnboardingView>.expectFrameClicks(button: "Continue without the keys", make: {
            let page = onboarding(step: .permissions)
            return (page.host, { page.model.step == .confirmation ? 1 : 0 })
        })
        let page = onboarding()
        let frame = page.host.windowFrame(of: try #require(page.host.tree.node(named: "Let's go")))
        #expect(frame.width == OnboardingView.contentSize.width - 2 * OnboardingView.buttonInset)
    }

    @Test("Not today and Buy me a coffee: frames are what responds, and Not today has a generous target")
    func donationFrames() throws {
        defer { OffscreenWindows.closeAll() }
        OffscreenHost<DonationView>.expectFrameClicks(button: "Not today", make: {
            let dismissed = CallCount()
            return (donation(dismissed: dismissed), { dismissed.value })
        })
        OffscreenHost<DonationView>.expectFrameClicks(button: "Buy me a coffee", make: {
            let opened = CallCount()
            return (donation(opened: opened), { opened.value })
        })
        let frame = {
            let host = donation()
            return host.windowFrame(of: host.tree.node(named: "Not today")!)
        }()
        #expect(frame.height >= 24 && frame.width >= 70, "\(frame)")
    }

    @Test("Esc dismisses the donation window through Not today, once")
    func escapeDismissesDonation() {
        defer { OffscreenWindows.closeAll() }
        let dismissed = CallCount()
        let host = donation(dismissed: dismissed)
        host.press(key: 53, characters: "\u{1B}")
        host.settle()
        #expect(dismissed.value == 1)
    }

    @Test("the popover's quick-set pills respond across their frames")
    func quickSetFrames() {
        defer { OffscreenWindows.closeAll() }
        for (name, level) in [("Dim", 40.0), ("100%", 100.0), ("Max boi", 200.0)] {
            OffscreenHost<BrightnessMenuContent>.expectFrameClicks(button: name, clickOutside: false, make: {
                let rig = ControllerRig(storedPercentage: 65)
                let host = OffscreenHost(BrightnessMenuContent(controller: rig.controller, updates: nil, settings: .inert(), quit: {}))
                return (host, { rig.controller.currentState.percentage == level ? 1 + rig.display.appliedPercentages.count : 0 })
            })
        }
    }
}
