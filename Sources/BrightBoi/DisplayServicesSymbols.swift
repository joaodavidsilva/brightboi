import CoreGraphics
import Foundation

/// The private `DisplayServices.framework` symbols brightness control needs,
/// loaded once at runtime. The framework is undocumented, so Apple can rename
/// or remove any of these in a macOS update; each symbol is optional and a
/// missing one is logged and reported upward (`NominalControlStatus`) instead
/// of crashing the menu bar app.
struct DisplayServicesSymbols {
    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    private static let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    let setBrightness: SetBrightness?
    let getBrightness: GetBrightness?
    /// Reports whether the system allows the display's brightness to change
    /// right now. `false` for an external display, and expected to be `false`
    /// while a reference preset locks brightness.
    let canChangeBrightness: CanChangeBrightness?

    static func load() -> DisplayServicesSymbols {
        guard let handle = dlopen(frameworkPath, RTLD_NOW) else {
            Log.display.error("Could not load DisplayServices.framework")
            return DisplayServicesSymbols(setBrightness: nil, getBrightness: nil, canChangeBrightness: nil)
        }
        return DisplayServicesSymbols(
            setBrightness: symbol(named: "DisplayServicesSetBrightness", in: handle, as: SetBrightness.self),
            getBrightness: symbol(named: "DisplayServicesGetBrightness", in: handle, as: GetBrightness.self),
            canChangeBrightness: symbol(named: "DisplayServicesCanChangeBrightness", in: handle, as: CanChangeBrightness.self)
        )
    }

    private static func symbol<T>(named name: String, in handle: UnsafeMutableRawPointer, as type: T.Type) -> T? {
        guard let address = dlsym(handle, name) else {
            Log.display.error("Could not find \(name, privacy: .public) in DisplayServices.framework")
            return nil
        }
        return unsafeBitCast(address, to: type)
    }
}

/// Whether BrightBoi can set the built-in display's Nominal (0-100%)
/// brightness right now. Boost (above 100%) uses the gamma table and does not
/// depend on it, so the two causes of unavailability stay separate: the
/// popover words them differently.
enum NominalControlStatus: Equatable {
    case available
    /// `DisplayServicesSetBrightness` could not be loaded, typically because
    /// a macOS update changed or removed it.
    case symbolMissing
    /// The system reports that brightness cannot change on this display
    /// right now, for example under a reference display preset.
    case lockedBySystem

    /// The status for a given state of the symbols. `canChange` is `nil` when
    /// that symbol is missing or no display could be asked: the set symbol
    /// alone decides then, since refusing to try would disable a control that
    /// may well work.
    static func resolve(hasSetSymbol: Bool, canChange: Bool?) -> NominalControlStatus {
        guard hasSetSymbol else { return .symbolMissing }
        return canChange == false ? .lockedBySystem : .available
    }
}
