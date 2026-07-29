import Foundation
import CoreGraphics

/// Real `DisplayBrightnessProviding`, built from ticket 02's documented
/// findings (`docs/brightness-api-research.md`): the built-in display's
/// Nominal range (0–100%) is driven via `DisplayServices.framework`'s
/// `DisplayServicesSetBrightness`, which takes the exact `Float` 0.0...1.0
/// value Control Center's own slider reads and writes — no translation
/// needed beyond dividing by 100.
///
/// Extended Brightness / Boost (100–200%, the EDR-trigger + gamma-table
/// technique) is ticket 05's job. Until then, percentages above 100 are
/// clamped to the Nominal ceiling here rather than left unhandled, since
/// `BrightnessController` itself tracks the full 0...200 range.
final class LiveDisplayBrightnessProvider: DisplayBrightnessProviding {
    private typealias SetBrightnessFunc = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let displayID: CGDirectDisplayID
    private let setBrightness: SetBrightnessFunc?

    init() {
        self.displayID = Self.resolveBuiltInDisplayID()
        self.setBrightness = Self.loadSetBrightnessSymbol()
    }

    func apply(percentage: Double) {
        guard let setBrightness else { return }
        let nominalPercentage = min(max(percentage, 0), BrightnessController.nominalCeilingPercentage)
        let value = Float(nominalPercentage / BrightnessController.nominalCeilingPercentage)
        _ = setBrightness(displayID, value)
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
}
