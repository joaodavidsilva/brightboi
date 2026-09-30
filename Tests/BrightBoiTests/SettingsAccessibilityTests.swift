import AppKit
import SwiftUI
import Testing
@testable import BrightBoi

/// The Settings window: its accessibility tree (names, values, headings,
/// grouping), its native grouped-form structure, and every action button
/// clicked with the system-facing actions stubbed.
@MainActor
@Suite("Settings accessibility", .serialized, accessibilityAvailable)
struct SettingsAccessibilityTests {
    /// Counts of what the window's buttons reached for, instead of reaching it.
    @MainActor
    private final class Stubs {
        let quit = CallCount()
        let openLoginItems = CallCount()
        let relaunch = CallCount()
        let support = CallCount()

        var actions: SettingsView.Actions {
            SettingsView.Actions(
                quit: { [quit] in quit.value += 1 },
                openLoginItems: { [openLoginItems] in openLoginItems.value += 1 },
                relaunch: { [relaunch] in relaunch.value += 1 }
            )
        }
    }

    private func settings(_ rig: ControllerRig, stubs: Stubs = Stubs()) -> OffscreenHost<SettingsView> {
        OffscreenHost(SettingsView(
            controller: rig.controller,
            permissions: rig.permissions,
            onShowSupport: { [support = stubs.support] in support.value += 1 },
            actions: stubs.actions
        ))
    }

    private let customShortcut = KeyRemapShortcut(
        raise: KeyCombo(modifiers: [.control, .option], keyCode: 126),
        lower: KeyCombo(modifiers: [.control, .option], keyCode: 125)
    )

    // MARK: #12 names

    @Test("every switch has its own name, with its subtitle as help")
    func switchesAreNamed() {
        defer { OffscreenWindows.closeAll() }
        let host = settings(ControllerRig())
        let switches = host.tree.nodes.filter { $0.subrole == NSAccessibility.Subrole.switch.rawValue }
        #expect(switches.map(\.name) == [
            "Launch at login",
            "Turn off macOS auto-brightness while BrightBoi runs",
            "Let BrightBoi own F1/F2",
        ])
        #expect(Set(switches.map(\.name)).count == switches.count)
        #expect(switches.allSatisfy { $0.role == NSAccessibility.Role.checkBox.rawValue && $0.actions.contains("AXPress") })
        #expect(switches[0].help.isEmpty)
        #expect(switches[1].help.hasPrefix("Otherwise the light sensor"))
        #expect(switches[2].help.hasPrefix("The brightness keys step 5%"))
    }

    @Test("the Key Remap switch is named after the current shortcut")
    func remapSwitchFollowsShortcut() {
        defer { OffscreenWindows.closeAll() }
        let host = settings(ControllerRig(storedKeyRemapShortcut: customShortcut))
        let title = SettingsView.remapToggleTitle(customShortcut)
        #expect(host.tree.node(named: title, role: .checkBox) != nil, "\(host.tree.dump)")
        #expect(host.tree.node(named: "Let BrightBoi own F1/F2") == nil)
    }

    @Test("a switch named by its title is also its visible text, read once")
    func switchTitlesAreNotReadTwice() {
        defer { OffscreenWindows.closeAll() }
        let host = settings(ControllerRig())
        let staticTexts = host.tree.nodes(role: .staticText).map(\.value)
        #expect(!staticTexts.contains("Launch at login"))
        #expect(!staticTexts.contains("Let BrightBoi own F1/F2"))
        #expect(!staticTexts.contains { $0.hasPrefix("Otherwise the light sensor") })
    }

    @Test("the Boost Ceiling slider is named and valued, and its readout is not a separate item")
    func ceilingSlider() throws {
        defer { OffscreenWindows.closeAll() }
        let rig = ControllerRig(storedBoostCeiling: 150)
        let host = settings(rig)
        let slider = try #require(host.tree.node(named: "Boost ceiling", role: .slider))
        #expect(slider.valueDescription == "150 percent, 750 nits")
        #expect(host.tree.nodes(role: .slider).count == 1)
        let texts = host.tree.spokenTexts
        #expect(!texts.contains("150% · 750 nits"))
        #expect(!texts.contains("Boost ceiling") || texts.filter { $0 == "Boost ceiling" }.count == 1, "the name is spoken once")
        #expect(host.tree.nodes(role: .staticText).allSatisfy { $0.value != "Boost ceiling" })
        // Moving it by VoiceOver changes the stored ceiling.
        #expect(slider.increment())
        #expect(rig.controller.currentState.boostCeiling > 150)
        // The window redraws from the new ceiling, so the readout beside the
        // slider, built from the same state, follows it while it moves.
        host.settle()
        let moved = rig.controller.currentState
        let after = try #require(host.tree.node(named: "Boost ceiling", role: .slider))
        #expect(after.valueDescription == "\(Int(moved.boostCeiling)) percent, \(Int(moved.boostCeilingNits)) nits")
    }

    @Test("the slider's end labels are buttons with names that say what they do")
    func ceilingEndButtons() throws {
        defer { OffscreenWindows.closeAll() }
        let rig = ControllerRig()
        let host = settings(rig)
        let lower = try #require(host.tree.node(named: "Lower Boost ceiling", role: .button))
        let raise = try #require(host.tree.node(named: "Raise Boost ceiling", role: .button))
        #expect(lower.press())
        let lowered = rig.controller.currentState.boostCeiling
        #expect(lowered < 200)
        #expect(raise.press())
        #expect(rig.controller.currentState.boostCeiling > lowered)
    }

    @Test("both recorders keep their own name and value inside the form rows")
    func recordersAreNamed() throws {
        defer { OffscreenWindows.closeAll() }
        let shortcut = KeyRemapShortcut.defaultShortcut
        let host = settings(ControllerRig())
        let lower = try #require(host.tree.node(named: "Lower brightness shortcut", role: .button))
        let raise = try #require(host.tree.node(named: "Raise brightness shortcut", role: .button))
        #expect(lower.value == shortcut.lower.spokenName)
        #expect(raise.value == shortcut.raise.spokenName)
        #expect(lower.help == "Press to record a new shortcut")
        // The row's visible "Lower" / "Raise" text is not announced on top.
        #expect(host.tree.nodes(role: .staticText).allSatisfy { $0.value != "Lower" && $0.value != "Raise" })

        let custom = settings(ControllerRig(storedKeyRemapShortcut: customShortcut))
        #expect(custom.tree.node(named: "Lower brightness shortcut")?.value == customShortcut.lower.spokenName)
    }

    @Test("nothing in the window is blank to VoiceOver, in every state")
    func nothingIsBlank() {
        defer { OffscreenWindows.closeAll() }
        let rigs = [
            ControllerRig(),
            ControllerRig(storedKeyRemapShortcut: customShortcut, keyTapStarts: false, accessibilityGranted: false),
            ControllerRig(keyTapStarts: false, inputMonitoring: .denied, loginItemStatus: .requiresApproval),
            ControllerRig(supportsBoost: false),
        ]
        for rig in rigs {
            let host = settings(rig)
            #expect(host.tree.blankElements.isEmpty, "blank: \(host.tree.blankElements.map(\.summary))")
            #expect(host.tree.nodes(role: .image).isEmpty, "decorative glyphs are hidden")
            #expect(host.tree.nodes.allSatisfy { $0.role != NSAccessibility.Role.unknown.rawValue }, "\(host.tree.dump)")
        }
    }

    // MARK: #71 headings, grouping, unique buttons

    @Test("section titles are headings, and each section is one group")
    func headingsAndGroups() {
        defer { OffscreenWindows.closeAll() }
        let host = settings(ControllerRig())
        #expect(host.tree.nodes(role: .heading).map(\.name) == ["General", "Boost Ceiling", "Permissions"])
        #expect(host.tree.nodes(role: .group).count == 3)
        // Without Boost there is no ceiling section.
        let plain = settings(ControllerRig(supportsBoost: false))
        #expect(plain.tree.nodes(role: .heading).map(\.name) == ["General", "Permissions"])
        #expect(plain.tree.nodes(role: .group).count == 2)
    }

    @Test("a permission row reads as its name and state, and its button names the permission")
    func permissionRows() throws {
        defer { OffscreenWindows.closeAll() }
        let host = settings(ControllerRig(keyTapStarts: false, inputMonitoring: .denied))
        let statuses = host.tree.nodes(role: .staticText).map(\.value).filter { $0.hasSuffix("ranted") }
        #expect(statuses == ["Accessibility, Granted", "Input Monitoring, Not granted"])
        let buttons = host.tree.buttonNames.filter { $0.hasPrefix("Open System Settings") }
        #expect(buttons == ["Open System Settings for Input Monitoring"])

        let both = settings(ControllerRig(keyTapStarts: false, accessibilityGranted: false))
        #expect(both.tree.buttonNames.contains("Open System Settings for Accessibility"))
        let names = both.tree.buttonNames
        #expect(Set(names).count == names.count, "no two buttons share a name: \(names)")
    }

    @Test("no two buttons share a name in any state")
    func uniqueButtonNames() {
        defer { OffscreenWindows.closeAll() }
        let rigs = [
            ControllerRig(),
            ControllerRig(storedKeyRemapShortcut: customShortcut, keyTapStarts: false, accessibilityGranted: false),
            ControllerRig(keyTapStarts: false, inputMonitoring: .denied, loginItemStatus: .requiresApproval),
            ControllerRig(keyTapStarts: false, accessibilityGranted: true, inputMonitoring: .granted),
        ]
        for rig in rigs {
            let names = settings(rig).tree.buttonNames
            #expect(Set(names).count == names.count, "\(names)")
        }
    }

    // MARK: #87 native grouped form

    @Test("the window is a native grouped form: headers, one group per section, footers after")
    func nativeGroupedForm() throws {
        defer { OffscreenWindows.closeAll() }
        let host = settings(ControllerRig())
        let scroll = try #require(host.tree.nodes.first)
        #expect(scroll.role == NSAccessibility.Role.scrollArea.rawValue, "the form is a system list, not stacked custom rows")

        // Section title, its rows, its footer text, for each section in order.
        let topLevel = host.tree.nodes.filter { $0.depth == scroll.depth + 1 }.map(\.role)
        let heading = NSAccessibility.Role.heading.rawValue
        let group = NSAccessibility.Role.group.rawValue
        let text = NSAccessibility.Role.staticText.rawValue
        #expect(topLevel == [heading, group, heading, group, text, heading, group, text], "\(topLevel)\n\(host.tree.dump)")
        #expect(host.tree.nodes(role: .heading).allSatisfy { $0.name != $0.name.uppercased() }, "title case, not shouting")
        #expect(host.bounds.width == 480)
    }

    @Test("the window sizes to its content at 480pt wide, and shrinks without the Boost section")
    func sizesToContent() {
        defer { OffscreenWindows.closeAll() }
        let withBoost = settings(ControllerRig())
        let without = settings(ControllerRig(supportsBoost: false))
        #expect(withBoost.bounds.width == 480 && without.bounds.width == 480)
        #expect(without.bounds.height < withBoost.bounds.height)
    }

    // MARK: #46 action buttons, clicked with stubs

    /// Clicks the centre, just inside each edge, and a few points past each
    /// end of a button's accessibility frame: the first must fire `fired`,
    /// the last must not.
    private func expectWholeFrameClicks<V: View>(
        _ host: OffscreenHost<V>,
        button name: String,
        fired: @escaping () -> Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        OffscreenHost<V>.expectFrameClicks(button: name, make: { (host, fired) }, sourceLocation: sourceLocation)
    }

    @Test("Turn on… starts the Accessibility grant, then opens its pane, from a click and from VoiceOver")
    func turnOnButton() throws {
        defer { OffscreenWindows.closeAll() }
        let rig = ControllerRig(keyTapStarts: false, accessibilityGranted: false)
        let host = settings(rig)
        let node = try #require(host.tree.node(named: "Turn on…", role: .button))
        let frame = host.windowFrame(of: node)
        #expect(rig.permissionsChecker.requestAccessibilityCallCount == 0)
        host.click(at: CGPoint(x: frame.midX, y: frame.midY))
        #expect(rig.permissionsChecker.requestAccessibilityCallCount == 1, "the first ask is the system prompt")
        host.click(at: CGPoint(x: frame.minX + 3, y: frame.midY))
        #expect(rig.opened.urls == [PermissionsModel.accessibilityPaneURL], "then the pane, through the stubbed opener")
        #expect(node.press())
        #expect(rig.opened.urls.count == 2)
    }

    @Test("the permission row's button acts across its whole frame")
    func permissionRowButton() throws {
        defer { OffscreenWindows.closeAll() }
        let rig = ControllerRig(keyTapStarts: false, inputMonitoring: .denied)
        let host = settings(rig)
        expectWholeFrameClicks(host, button: "Open System Settings for Input Monitoring") { rig.opened.urls.count }
        #expect(rig.opened.urls.allSatisfy { $0 == PermissionsModel.inputMonitoringPaneURL })
    }

    @Test("Try again re-reads the permissions")
    func tryAgainButton() throws {
        defer { OffscreenWindows.closeAll() }
        // Accessibility is granted and Input Monitoring is not, while the tap is down.
        let rig = ControllerRig(keyTapStarts: false, inputMonitoring: .denied)
        let host = settings(rig)
        expectWholeFrameClicks(host, button: "Try again") { rig.permissionsChecker.accessibilityQueryCount }
    }

    @Test("Relaunch BrightBoi asks to relaunch and never quits by itself")
    func relaunchButton() throws {
        defer { OffscreenWindows.closeAll() }
        let stubs = Stubs()
        // Both permissions granted, the tap still down.
        let rig = ControllerRig(keyTapStarts: false)
        let host = settings(rig, stubs: stubs)
        expectWholeFrameClicks(host, button: "Relaunch BrightBoi") { stubs.relaunch.value }
        #expect(stubs.quit.value == 0)
    }

    @Test("Open Login Items goes through its seam")
    func openLoginItemsButton() throws {
        defer { OffscreenWindows.closeAll() }
        let stubs = Stubs()
        let rig = ControllerRig(loginItemStatus: .requiresApproval)
        let host = settings(rig, stubs: stubs)
        expectWholeFrameClicks(host, button: "Open Login Items") { stubs.openLoginItems.value }
    }

    @Test("Reset to F1/F2 restores the default shortcut from a click anywhere on the button, and from VoiceOver")
    func resetButton() throws {
        defer { OffscreenWindows.closeAll() }
        // The button goes away once it has done its job, so each click gets a fresh window.
        for point in 0..<6 {
            let rig = ControllerRig(storedKeyRemapShortcut: customShortcut)
            let host = settings(rig)
            #expect(rig.controller.currentState.keyRemapShortcut == customShortcut)
            let node = try #require(host.tree.node(named: "Reset to F1/F2", role: .button))
            let frame = host.windowFrame(of: node)
            let target = OffscreenHost<SettingsView>.insidePoints(of: frame)
            if point < target.count {
                host.click(at: target[point])
            } else {
                #expect(node.press())
            }
            #expect(rig.controller.currentState.keyRemapShortcut == .defaultShortcut, "point \(point)")
        }
    }

    @Test("Quit and Support BrightBoi go through their seams")
    func footerButtons() throws {
        defer { OffscreenWindows.closeAll() }
        let stubs = Stubs()
        let host = settings(ControllerRig(), stubs: stubs)
        expectWholeFrameClicks(host, button: "Quit BrightBoi") { stubs.quit.value }
        expectWholeFrameClicks(host, button: "Support BrightBoi…") { stubs.support.value }
    }
}
