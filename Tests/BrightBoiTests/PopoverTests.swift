import AppKit
import SwiftUI
import Testing
@testable import BrightBoi

/// The popover's slider geometry, presets, header, banners and helpers.
@MainActor
@Suite("Popover")
struct PopoverTests {
    // MARK: Geometry

    private func geometry(
        width: CGFloat = 252,
        supportsBoost: Bool = true,
        ceiling: Double = 200
    ) -> BoostSliderGeometry {
        BoostSliderGeometry(width: width, knobDiameter: 18, supportsBoost: supportsBoost, ceiling: ceiling)
    }

    @Test func endpointsSitOneKnobRadiusInsideTheRow() {
        let g = geometry()
        #expect(g.x(for: 0) == 9)
        #expect(g.x(for: 200) == CGFloat(243))
        #expect(g.percentage(atX: 9) == 0)
        #expect(g.percentage(atX: 243) == 200)
    }

    @Test func dragPastEitherEndClamps() {
        let g = geometry()
        #expect(g.percentage(atX: -40) == 0)
        #expect(g.percentage(atX: 0) == 0)
        #expect(g.percentage(atX: 400) == 200)
    }

    @Test func boundaryIsAtTheMidpointOfTheRow() {
        let g = geometry()
        #expect(abs(g.boundaryX - 126) < 0.001)
        #expect(abs(g.x(for: 100) - g.width / 2) < 0.001)
    }

    @Test func positionAndPercentageRoundTrip() {
        let g = geometry()
        for percentage in stride(from: 0.0, through: 200.0, by: 5) {
            #expect(abs(g.percentage(atX: g.x(for: percentage)) - percentage) < 0.0001)
        }
    }

    @Test func withoutBoostTheTrackEndsAtOneHundred() {
        let g = geometry(supportsBoost: false, ceiling: 150)
        #expect(g.x(for: 100) == CGFloat(243))
        #expect(g.boundaryX == g.x(for: 100))
        #expect(g.ceilingX == g.boundaryX)
        #expect(g.percentage(atX: 243) == 100)
        #expect(!g.hasUnreachableTail)
        #expect(g.segments.count == 1)
    }

    @Test func ceilingOf150FallsThreeQuartersAcrossTheTrack() {
        let g = geometry(ceiling: 150)
        #expect(abs(g.ceilingX - (g.inset + g.trackWidth * 0.75)) < 0.001)
        #expect(g.hasUnreachableTail)
    }

    @Test func ceilingOf200DrawsNoTail() {
        let g = geometry(ceiling: 200)
        #expect(g.ceilingX == g.x(for: 200))
        #expect(!g.hasUnreachableTail)
        #expect(g.segments.count == 2)
    }

    @Test func ceilingIsHeldInsideTheBoostRange() {
        #expect(geometry(ceiling: 40).reachableMaximum == 100)
        #expect(geometry(ceiling: 900).reachableMaximum == 200)
    }

    @Test func cutsLeaveGapsAtTheBoundaryAndTheCeiling() {
        let g = geometry(ceiling: 150)
        let segments = g.segments
        #expect(segments.count == 3)
        let boundary = g.trackOffset(for: 100)
        let ceiling = g.trackOffset(for: 150)
        #expect(segments[0].lowerBound == 0)
        #expect(abs(segments[0].upperBound - (boundary - BoostSliderGeometry.gapWidth / 2)) < 0.001)
        #expect(abs(segments[1].lowerBound - (boundary + BoostSliderGeometry.gapWidth / 2)) < 0.001)
        #expect(abs(segments[1].upperBound - (ceiling - BoostSliderGeometry.gapWidth / 2)) < 0.001)
        #expect(abs(segments[2].lowerBound - (ceiling + BoostSliderGeometry.gapWidth / 2)) < 0.001)
        #expect(segments[2].upperBound == g.trackWidth)
    }

    // MARK: Presets

    @Test func withoutBoostThereIsNoBoostPresetAndNoDuplicate() {
        let presets = BrightnessMenuContent.quickSetPresets(supportsBoost: false)
        #expect(presets.allSatisfy { !$0.isBoost })
        #expect(Set(presets.map(\.percentage)).count == presets.count)
        #expect(!presets.contains { $0.title == "Max boi" })
    }

    @Test func withBoostMaxBoiTargetsTheTopOfTheTrack() {
        let presets = BrightnessMenuContent.quickSetPresets(supportsBoost: true)
        #expect(Set(presets.map(\.percentage)).count == presets.count)
        #expect(presets.last == .init(title: "Max boi", percentage: 200, isBoost: true))
        #expect(presets.filter(\.isBoost).count == 1)
    }

    // MARK: Keyboard and accessibility

    @Test func steppingMovesByTheGranularity() {
        #expect(BoostSlider.steppedPercentage(from: 100, steps: 1) == 105)
        #expect(BoostSlider.steppedPercentage(from: 100, steps: -1) == 95)
    }

    @Test func steppingDownNeverReachesZero() {
        #expect(BoostSlider.steppedPercentage(from: 5, steps: -1) == 5)
        #expect(BoostSlider.steppedPercentage(from: 10, steps: -1) == 5)
        #expect(BoostSlider.steppedPercentage(from: 0, steps: -1) == 0)
        #expect(BoostSlider.steppedPercentage(from: 0, steps: 1) == 5)
        #expect(BoostSlider.guardedTarget(0, from: 5) == 5)
    }

    @Test func accessibilityValueNamesBoostAndMaximum() {
        #expect(BoostSlider.accessibilityValue(percentage: 60, reachableMaximum: 200) == "60 percent")
        #expect(BoostSlider.accessibilityValue(percentage: 150, reachableMaximum: 200) == "150 percent, boosted")
        #expect(BoostSlider.accessibilityValue(percentage: 150, reachableMaximum: 150) == "150 percent, boosted, maximum")
        #expect(BoostSlider.accessibilityValue(percentage: 100, reachableMaximum: 100) == "100 percent, maximum")
        #expect(BoostSlider.accessibilityValue(percentage: 120, reachableMaximum: 150, boostCeiling: 150) == "120 percent, boosted, Boost Ceiling 150 percent")
        #expect(BoostSlider.accessibilityValue(percentage: 120, reachableMaximum: 200, boostCeiling: 200) == "120 percent, boosted")
    }

    @Test func quickSetHintsNameTheClampedTarget() {
        let presets = BrightnessMenuContent.quickSetPresets(supportsBoost: true)
        let hints = presets.map { BrightnessMenuContent.quickSetHint(preset: $0, supportsBoost: true, boostCeiling: 150) }
        #expect(hints == ["Sets brightness to 40 percent", "Sets brightness to 100 percent", "Sets brightness to 150 percent"])

        let full = BrightnessMenuContent.quickSetHint(preset: presets[2], supportsBoost: true, boostCeiling: 200)
        #expect(full == "Sets brightness to 200 percent")

        let plain = BrightnessMenuContent.quickSetPresets(supportsBoost: false)
        #expect(plain.map { BrightnessMenuContent.quickSetHint(preset: $0, supportsBoost: false, boostCeiling: 200) }
            == ["Sets brightness to 40 percent", "Sets brightness to 100 percent"])
    }

    @Test func maxBoiAcceptsAPlainerSpokenName() {
        #expect(BrightnessMenuContent.quickSetInputLabels(title: "Max boi") == ["Max boi", "Maximum brightness"])
        #expect(BrightnessMenuContent.quickSetInputLabels(title: "Dim") == ["Dim"])
    }

    @Test func warningBannersNameTheirKindFirst() {
        #expect(BrightnessMenuContent.batteryAdvisorySpokenLabel.hasPrefix("Battery warning: Above"))
        let advisory = BrightnessController.ThermalAdvisory(requestedPercentage: 190, deliveredPercentage: 150)
        #expect(BrightnessMenuContent.thermalAdvisorySpokenLabel(advisory)
            == "Heat warning: Running hot — delivering closer to 150% than the 190% requested.")
    }

    // MARK: Controls and rows

    @Test func controlsAreDisabledOnlyWhileTheDisplayIsOff() {
        let on = makeController(percentage: 60)
        let off = makeController(percentage: 60, builtInDisplayAvailable: false)
        #expect(BrightnessMenuContent.controlsEnabled(for: on.currentState))
        #expect(!BrightnessMenuContent.controlsEnabled(for: off.currentState))
    }

    @Test func rowHighlightStrengthens() {
        #expect(MenuRowButtonStyle.highlightOpacity(isPressed: false, isHovered: false) == 0)
        #expect(MenuRowButtonStyle.highlightOpacity(isPressed: false, isHovered: true) == 0.08)
        #expect(MenuRowButtonStyle.highlightOpacity(isPressed: true, isHovered: true) == 0.15)
    }

    // MARK: Header

    private func headerHeight(isBoosted: Bool, isBoostPaused: Bool) -> CGFloat {
        NSHostingController(rootView: PopoverHeader(isBoosted: isBoosted, isBoostPaused: isBoostPaused).frame(width: 252))
            .sizeThatFits(in: CGSize(width: 252, height: CGFloat.greatestFiniteMagnitude)).height
    }

    @Test func headerIsTheSameHeightInEveryState() {
        let plain = headerHeight(isBoosted: false, isBoostPaused: false)
        #expect(plain > 0)
        #expect(headerHeight(isBoosted: true, isBoostPaused: false) == plain)
        #expect(headerHeight(isBoosted: false, isBoostPaused: true) == plain)
    }

    // MARK: Advisories wrap instead of truncating

    private func sizes(of controller: BrightnessController, updates: UpdateChecker? = nil) -> (minimum: CGFloat, ideal: CGFloat) {
        let hosting = NSHostingController(rootView: BrightnessMenuContent(controller: controller, updates: updates, settings: .inert()))
        let minimum = hosting.sizeThatFits(in: .zero).height
        let ideal = hosting.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).height
        return (minimum, ideal)
    }

    @Test func batteryAndThermalBannersKeepTheirWrappedHeightAtTheMinimumSize() {
        let controller = makeController(percentage: 185, onBattery: true, thermal: .serious)
        let (minimum, ideal) = sizes(of: controller)
        #expect(minimum == ideal)
    }

    @Test func everyBannerAtOnceStaysBoundedAndUntruncated() {
        let controller = makeController(percentage: 185, onBattery: true, thermal: .serious, inverted: true, keyTapDown: true)
        let (minimum, ideal) = sizes(of: controller)
        #expect(minimum == ideal)
        #expect(ideal < 700)
        let quiet = sizes(of: makeController(percentage: 60)).ideal
        #expect(ideal > quiet)
    }

    // MARK: Update rows

    private struct NoReleaseFetcher: ReleaseFetching {
        func fetchLatestRelease() async throws -> LatestRelease? { nil }
    }

    private final class InMemoryUpdateStore: UpdateCheckPersisting {
        var automaticChecksEnabled: Bool?
        var lastCheckDate: Date?
        var launchCount = 0
    }

    @Test func updateQuestionAddsARowThatWrapsAndGoesOnceAnswered() {
        let controller = makeController(percentage: 60)
        let store = InMemoryUpdateStore()
        store.launchCount = 2
        let updates = UpdateChecker(currentVersion: "1.1.0", fetcher: NoReleaseFetcher(), store: store)
        #expect(updates.shouldOfferConsent)

        let plain = sizes(of: controller)
        let asking = sizes(of: controller, updates: updates)
        #expect(asking.ideal > plain.ideal)
        #expect(asking.minimum == asking.ideal)

        updates.setAutomaticChecksEnabled(false)
        #expect(sizes(of: controller, updates: updates).ideal == plain.ideal)
    }

    // MARK: Fixture

    private func makeController(
        percentage: Double,
        onBattery: Bool = false,
        thermal: ProcessInfo.ThermalState = .nominal,
        inverted: Bool = false,
        keyTapDown: Bool = false,
        builtInDisplayAvailable: Bool = true
    ) -> BrightnessController {
        let display = FakeDisplayBrightnessProvider()
        display.stubbedIsBuiltInDisplayAvailable = builtInDisplayAvailable
        let accessibility = FakeDisplayAccessibility()
        accessibility.stubbedInvertsColors = inverted
        let persistence = FakeBrightnessPersistence()
        persistence.storedPercentage = percentage
        let power = FakePowerSourceProvider()
        power.stubbedIsOnBatteryPower = onBattery
        let thermalState = FakeThermalStateProvider()
        thermalState.stubbedThermalState = thermal
        let bundleLocation = FakeBundleLocationProvider()
        let keyTap = FakeKeyTap()
        keyTap.startSucceeds = !keyTapDown
        let controller = BrightnessController(
            displayBrightness: display,
            autoBrightnessToggle: FakeAutoBrightnessToggle(),
            loginItemService: FakeLoginItemService(),
            persistence: persistence,
            keyTap: keyTap,
            powerSource: power,
            thermalState: thermalState,
            bundleLocation: bundleLocation,
            displayAccessibility: accessibility,
            permissions: PermissionsModel(checker: FakePermissionsChecker(), openURL: { _ in })
        )
        controller.start()
        return controller
    }
}
