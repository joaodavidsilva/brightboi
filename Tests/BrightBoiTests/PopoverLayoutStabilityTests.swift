import AppKit
import SwiftUI
import Testing
@testable import BrightBoi

/// The popover must not change size while the slider is dragged, including
/// across 100% where Boost engages. Sizes are the hosted view's own fitting
/// size, so the test measures what `MenuBarExtra` would size its window to.
/// Banners that report a real change (battery, thermal, display off) are
/// still allowed to change the height.
@MainActor
@Suite("Popover layout stability", .serialized)
struct PopoverLayoutStabilityTests {
    private enum Look: CaseIterable {
        case light, dark, lightIncreased, darkIncreased

        /// The high-contrast names are the system's own appearance names for
        /// Increase Contrast. A missing one is reported, not crashed on.
        var appearance: NSAppearance? {
            switch self {
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            case .lightIncreased: NSAppearance(named: NSAppearance.Name("NSAppearanceNameAccessibilityHighContrastAqua"))
            case .darkIncreased: NSAppearance(named: NSAppearance.Name("NSAppearanceNameAccessibilityHighContrastDarkAqua"))
            }
        }
    }

    private func hosting(_ rig: ControllerRig, look: Look = .light) -> NSHostingView<BrightnessMenuContent> {
        let view = NSHostingView(rootView: BrightnessMenuContent(
            controller: rig.controller, updates: nil, settings: .inert(), quit: {}
        ))
        let appearance = look.appearance
        #expect(appearance != nil, "appearance for \(look) is not available")
        view.appearance = appearance
        return view
    }

    /// The fitting size after the view has caught up with the controller.
    private func size(of view: NSHostingView<BrightnessMenuContent>) -> CGSize {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.03))
        view.layoutSubtreeIfNeeded()
        return view.fittingSize
    }

    /// The popover's size at each level, dragged through with one live view.
    private func heights(_ rig: ControllerRig, at levels: [Double], look: Look = .light) -> [Double: CGFloat] {
        let view = hosting(rig, look: look)
        var result: [Double: CGFloat] = [:]
        for level in levels {
            rig.controller.setPercentageFromDrag(level)
            result[level] = size(of: view).height
        }
        return result
    }

    private func expectEqualHeights(_ heights: [Double: CGFloat], _ context: String) {
        let values = Set(heights.values)
        #expect(values.count == 1, "\(context): heights differ, \(heights.sorted { $0.key < $1.key })")
    }

    @Test("95%, 100%, 105%, 150% and 200% give the same height, in every look", arguments: Look.allCases)
    private func heightIsStableAcrossBoost(look: Look) {
        let rig = ControllerRig(storedPercentage: 95)
        expectEqualHeights(heights(rig, at: [95, 100, 105, 150, 200, 105, 95], look: look), "\(look)")
    }

    @Test("a fresh popover at each level has the same height too")
    func freshPopoverHasTheSameHeightAtEachLevel() {
        var all: [Double: CGFloat] = [:]
        for level in [95.0, 100, 105, 150, 200] {
            all[level] = size(of: hosting(ControllerRig(storedPercentage: level))).height
        }
        expectEqualHeights(all, "fresh")
    }

    @Test("the popover keeps its size when a drag crosses 100%")
    func sizeIsSameAt95And105() {
        let rig = ControllerRig(storedPercentage: 95)
        let view = hosting(rig)
        let below = size(of: view)
        rig.controller.setPercentageFromDrag(105)
        #expect(size(of: view) == below)
        #expect(below.width == 280)
    }

    @Test("a display without Boost has no footnote slot and is shorter")
    func noBoostNoSlot() {
        let withBoost = size(of: hosting(ControllerRig(supportsBoost: true, storedPercentage: 50))).height
        let without = size(of: hosting(ControllerRig(supportsBoost: false, storedPercentage: 50))).height
        #expect(without < withBoost)
        let rig = ControllerRig(supportsBoost: false, storedPercentage: 50)
        let view = hosting(rig)
        let before = size(of: view).height
        rig.controller.setPercentageFromDrag(100)
        #expect(size(of: view).height == before)
    }

    @Test("Boost paused by Invert Colors keeps one height across the boosted levels only")
    func pausedVariantIsStableWhileBoosted() {
        let rig = ControllerRig(storedPercentage: 150)
        rig.displayAccessibility.stubbedInvertsColors = true
        rig.displayAccessibility.simulateChange()
        #expect(rig.controller.currentState.isBoostPaused)
        expectEqualHeights(heights(rig, at: [105, 150, 200, 120]), "paused")
        // Below 100% Boost is not paused, so its banner goes away: that is a
        // real change of state and is allowed to change the height. With
        // Invert Colors on, a drag across 100% therefore still resizes; this
        // records that limit so it stays deliberate.
        let nominal = heights(rig, at: [95])[95] ?? 0
        let boosted = heights(rig, at: [105])[105] ?? 0
        #expect(nominal != boosted)
    }

    @Test("an advisory that is already showing keeps one height across the boosted range")
    func advisoryVariantsAreStable() {
        let onBattery = ControllerRig(storedPercentage: 180)
        onBattery.power.stubbedIsOnBatteryPower = true
        onBattery.power.simulateChange()
        #expect(onBattery.controller.batteryAdvisoryVisible)
        expectEqualHeights(heights(onBattery, at: [180, 190, 200, 185]), "battery")

        let remapDown = ControllerRig(storedPercentage: 95, storedKeyRemapEnabled: true, keyTapStarts: false)
        #expect(remapDown.controller.currentState.keyRemapEnabled && !remapDown.controller.keyRemapActive)
        expectEqualHeights(heights(remapDown, at: [95, 100, 105, 200]), "key remap inactive")
    }

    @Test("banners for real state changes still change the height")
    func realBannersStillResize() {
        let plain = size(of: hosting(ControllerRig(storedPercentage: 150))).height

        let battery = ControllerRig(storedPercentage: 180)
        battery.power.stubbedIsOnBatteryPower = true
        battery.power.simulateChange()
        #expect(size(of: hosting(battery)).height > plain)

        let hot = ControllerRig(storedPercentage: 150)
        hot.thermal.stubbedThermalState = .serious
        hot.thermal.simulateChange()
        #expect(hot.controller.thermalAdvisory != nil)
        #expect(size(of: hosting(hot)).height > plain)

        let off = ControllerRig(storedPercentage: 50, builtInDisplayAvailable: false)
        let on = ControllerRig(storedPercentage: 50)
        #expect(size(of: hosting(off)).height != size(of: hosting(on)).height)
    }

    @Test("the footnote slot is reserved only where Boost is possible")
    func reservationRule() {
        func state(supportsBoost: Bool, available: Bool, percentage: Double) -> BrightnessController.State {
            let rig = ControllerRig(supportsBoost: supportsBoost, storedPercentage: percentage, builtInDisplayAvailable: available)
            return rig.controller.currentState
        }
        #expect(BrightnessMenuContent.reservesBoostFootnote(for: state(supportsBoost: true, available: true, percentage: 50)))
        #expect(BrightnessMenuContent.reservesBoostFootnote(for: state(supportsBoost: true, available: true, percentage: 150)))
        #expect(!BrightnessMenuContent.reservesBoostFootnote(for: state(supportsBoost: false, available: true, percentage: 50)))
        #expect(!BrightnessMenuContent.reservesBoostFootnote(for: state(supportsBoost: true, available: false, percentage: 50)))
    }
}
