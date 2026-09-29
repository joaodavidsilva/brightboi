import AppKit
import Foundation
import CoreGraphics

/// Real `DisplayBrightnessProviding`, built from ticket 02's documented
/// findings (`docs/brightness-api-research.md`): the built-in display's
/// Nominal range (0–100%) is driven via `DisplayServices.framework`'s
/// `DisplayServicesSetBrightness`, which takes the exact `Float` 0.0...1.0
/// value Control Center's own slider reads and writes — no translation
/// needed beyond dividing by 100.
///
/// Extended Brightness / Boost (100–200%) is delegated to `BoostEngagement`
/// (`BoostEngagement.swift`) — the *other* mechanism ticket 02 confirmed
/// working, since there is no reliable private "set brightness past 1.0"
/// symbol on this hardware/OS. Anchored per ADR-0002: factor 1.0 (500 nits,
/// Nominal ceiling) at 100%, factor 2.0 (1000 nits sustained) at 200%.
///
/// `@MainActor`: satisfies `DisplayBrightnessProviding`'s isolation, and its
/// own `NSScreen` lookups and `BoostEngagement` are main-thread-only anyway.
@MainActor
final class LiveDisplayBrightnessProvider: DisplayBrightnessProviding {
    private typealias SetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias GetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private let displayID: CGDirectDisplayID
    private let setBrightness: SetBrightnessFunc?
    private let getBrightness: GetBrightnessFunc?
    private let boostEngagement: BoostEngagement

    init() {
        let displayID = Self.resolveBuiltInDisplayID()
        self.displayID = displayID
        self.setBrightness = Self.loadSetBrightnessSymbol()
        self.getBrightness = Self.loadGetBrightnessSymbol()
        self.boostEngagement = BoostEngagement(displayID: displayID)
    }

    func apply(percentage: Double) -> BrightnessApplyOutcome {
        applyNominal(percentage: percentage)
        return applyBoost(percentage: percentage)
    }

    private func applyNominal(percentage: Double) {
        guard let setBrightness else { return }
        let nominalPercentage = min(max(percentage, 0), BrightnessController.nominalCeilingPercentage)
        let value = Float(nominalPercentage / BrightnessController.nominalCeilingPercentage)
        _ = setBrightness(displayID, value)
    }

    /// `nil` when the symbol couldn't be loaded or the call itself fails
    /// (return code != 0) — notably in clamshell mode, where
    /// `resolveBuiltInDisplayID` falls back to `CGMainDisplayID()` (the
    /// external display), which this getter can't read. A read-only call
    /// with no side effects, so it's safe to call from `BrightnessController.init`
    /// as well as afterwards to notice a change made outside BrightBoi.
    func currentNominalPercentage() -> Double? {
        guard let getBrightness else { return nil }
        var value: Float = 0
        let result = getBrightness(displayID, &value)
        guard result == 0 else { return nil }
        return Double(value) * BrightnessController.nominalCeilingPercentage
    }

    /// The Boost-only half of adopting a brightness change made outside
    /// BrightBoi: releases the scaled gamma table and EDR headroom without
    /// touching Nominal, since Nominal is already at whatever the outside
    /// change set it to.
    func adoptExternalNominal() {
        boostEngagement.disengage()
    }

    /// Per ADR-0003: real EDR headroom (`maximumExtendedDynamicRangeColorComponentValue`
    /// > 1.0) means Boost is physically available; ~1.0 means this Mac's
    /// built-in display has no reserved headroom to exploit (e.g. MacBook
    /// Air). No hardcoded Mac-model table.
    func supportsExtendedBrightness() -> Bool {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        let builtInScreen = NSScreen.screens.first { screen in
            (screen.deviceDescription[screenNumberKey] as? NSNumber)?.uint32Value == displayID
        }
        return (builtInScreen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0) > 1.0
    }

    private func applyBoost(percentage: Double) -> BrightnessApplyOutcome {
        guard percentage > BrightnessController.nominalCeilingPercentage else {
            boostEngagement.disengage()
            return .applied
        }

        let boostRange = BrightnessController.maximumPercentage - BrightnessController.nominalCeilingPercentage
        let boostFraction = min(max(percentage - BrightnessController.nominalCeilingPercentage, 0), boostRange) / boostRange
        let factor = CGGammaValue(1.0 + boostFraction)
        return boostEngagement.engage(factor: factor)
    }

    /// Per the spec's scope boundary (built-in display only, never an
    /// external monitor): find the active display flagged built-in via
    /// `CGDisplayIsBuiltin`, rather than assuming `CGMainDisplayID()` (which
    /// would be wrong if an external display were set as the main display).
    /// Falls back to `CGMainDisplayID()` in the unlikely case no built-in
    /// display is reported active (e.g. closed-clamshell mode).
    private static func resolveBuiltInDisplayID() -> CGDirectDisplayID {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        return displays.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
    }

    /// `DisplayServices.framework` is private and undocumented — Apple can
    /// change or remove this symbol in a future macOS update (accepted risk,
    /// see ADR-0001). If it can't be loaded, brightness changes become a
    /// silent no-op rather than crashing the menu bar app.
    private static func loadSetBrightnessSymbol() -> SetBrightnessFunc? {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_NOW
        ) else {
            FileHandle.standardError.write(Data("BrightBoi: could not dlopen DisplayServices.framework\n".utf8))
            return nil
        }
        guard let symbol = dlsym(handle, "DisplayServicesSetBrightness") else {
            FileHandle.standardError.write(Data("BrightBoi: could not dlsym DisplayServicesSetBrightness\n".utf8))
            return nil
        }
        return unsafeBitCast(symbol, to: SetBrightnessFunc.self)
    }

    private static func loadGetBrightnessSymbol() -> GetBrightnessFunc? {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_NOW
        ) else {
            FileHandle.standardError.write(Data("BrightBoi: could not dlopen DisplayServices.framework\n".utf8))
            return nil
        }
        guard let symbol = dlsym(handle, "DisplayServicesGetBrightness") else {
            FileHandle.standardError.write(Data("BrightBoi: could not dlsym DisplayServicesGetBrightness\n".utf8))
            return nil
        }
        return unsafeBitCast(symbol, to: GetBrightnessFunc.self)
    }
}
