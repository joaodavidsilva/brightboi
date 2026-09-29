import Foundation
import CoreGraphics
import AppKit
import MetalKit

/// Owns the one piece of state Extended Brightness / Boost needs across
/// calls: the display's original gamma table (captured on first engagement)
/// and the EDR overlay that keeps system-wide EDR headroom available while
/// boosted. Used by `LiveDisplayBrightnessProvider`.
///
/// The overlay is created lazily on first engagement but then kept alive for
/// the rest of the process's life — engaging/disengaging toggles its clear
/// color and EDR flag rather than mounting/tearing down the
/// `NSWindow`/`MTKView`/`CAMetalLayer` each time. Repeatedly destroying that
/// Metal-backed window (closing it, releasing its layer) reliably crashed
/// with `EXC_BAD_ACCESS` during autorelease-pool drain on this hardware/OS —
/// the window server doesn't expect that churn. Leaving one overlay mounted
/// permanently is both simpler and empirically stable; disengaging still
/// fully restores the gamma table and drops
/// `maximumExtendedDynamicRangeColorComponentValue` back to 1.0 (verified
/// live, though the panel itself takes ~15–20s to visually ramp back down —
/// a hardware characteristic, not a logic bug).
///
/// Reimplemented independently from the technique description in
/// `docs/brightness-api-research.md` — BrightIntosh (GPLv3) was read for
/// research only, not copied.
///
/// `@MainActor`: `EDROverlayWindow` is main-thread-only (`NSWindow`/`MTKView`),
/// and `apply(percentage:)` — the only caller of `engage`/`disengage` — is
/// only ever driven synchronously from the main thread today (the slider
/// binding, the key tap), mirroring the whole app's implicit single-threaded
/// UI-driven design.
@MainActor
final class BoostEngagement {
    private let displayID: CGDirectDisplayID
    private var baselineGammaTable: GammaTable?
    /// The table this instance itself last wrote to the display — compared
    /// against the live table before `disengage()` restores anything, so a
    /// second copy (or another booster) that took over the display in the
    /// meantime doesn't get its table clobbered by a stale restore.
    private var lastWrittenGammaTable: GammaTable?
    private var overlay: EDROverlayWindow?
    private var currentFactor: CGGammaValue = 1.0
    private var wakeObserver: NSObjectProtocol?

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reapplyAfterWake()
            }
        }
    }

    isolated deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Captures the display's current gamma table as the Boost baseline on
    /// first engagement, then scales it by `factor` on every call. Refuses
    /// to engage if the captured table already looks scaled — another
    /// process (a second BrightBoi, or a third-party booster such as
    /// BrightIntosh) is already boosting this display, and adopting its
    /// table as the baseline would compound the scaling on top of theirs.
    /// Also refuses if the capture itself fails, rather than silently
    /// reporting success while nothing was actually scaled or mounted.
    @discardableResult
    func engage(factor: CGGammaValue) -> BrightnessApplyOutcome {
        if baselineGammaTable == nil {
            guard let captured = GammaTable.capture(displayID: displayID) else { return .captureFailed }
            guard !captured.looksAlreadyBoosted else { return .boostBlockedByOtherApp }
            baselineGammaTable = captured
        }
        currentFactor = factor
        if overlay == nil {
            let overlay = EDROverlayWindow()
            overlay.mount()
            self.overlay = overlay
        } else if let overlay {
            overlay.engageEDR()
        }
        let scaled = baselineGammaTable?.scaled(by: factor)
        scaled?.apply(to: displayID)
        lastWrittenGammaTable = scaled
        return .applied
    }

    func disengage() {
        guard let baselineGammaTable else { return }
        // Restoring the specific captured table for `displayID` is already
        // scoped to the built-in display — per the spec's scope boundary,
        // Boost must never touch an external monitor. (An earlier version of
        // this also called `CGDisplayRestoreColorSyncSettings()`, which
        // resets ColorSync for *every* connected display; removed as a real
        // scope violation, not just belt-and-suspenders.)
        //
        // Only restore if the table we last wrote is still the one live on
        // the display — if it isn't, another process took over the display
        // while this one was boosted, and writing our old baseline back
        // would stomp on whatever that process left there.
        if let lastWrittenGammaTable, let live = GammaTable.capture(displayID: displayID), !live.matches(lastWrittenGammaTable) {
            self.baselineGammaTable = nil
            self.lastWrittenGammaTable = nil
            if let overlay {
                overlay.disengageEDR()
            }
            return
        }
        baselineGammaTable.apply(to: displayID)
        if let overlay {
            overlay.disengageEDR()
        }
        self.baselineGammaTable = nil
        self.lastWrittenGammaTable = nil
    }

    /// Per `docs/brightness-api-research.md`: "the EDR overlay must persist
    /// for the entire time the user is boosted, and needs sleep/wake...
    /// handling... this is nontrivial recurring-maintenance logic." macOS
    /// resets the display's gamma table across sleep/wake, so if the Mac
    /// wakes while still boosted, reapply the same captured baseline scaled
    /// by the last-set factor. Continuous drift-polling while awake (the
    /// research doc's other suggestion) is deliberately not implemented here
    /// — no drift was observed during live verification, and adding a
    /// recurring timer for a not-yet-observed problem would be speculative;
    /// this can be revisited if drift is actually seen in practice.
    private func reapplyAfterWake() {
        guard let baselineGammaTable else { return }
        let scaled = baselineGammaTable.scaled(by: currentFactor)
        scaled.apply(to: displayID)
        lastWrittenGammaTable = scaled
    }
}

/// Wraps `CGGetDisplayTransferByTable`/`CGSetDisplayTransferByTable` (public,
/// documented CoreGraphics APIs) at the 256-sample resolution the research
/// spike verified works. Not `private` so `BrightnessControllerTests`-style
/// unit tests can exercise `looksAlreadyBoosted` and `matches` directly via
/// `@testable import`.
struct GammaTable: Equatable {
    static let sampleCount: UInt32 = 256

    /// The live built-in panel's table peaks at `0.99999994`, comfortably
    /// under 1.0 — a captured table whose peak clears this by more than
    /// float noise has already been scaled by something else.
    private static let alreadyBoostedThreshold: CGGammaValue = 1.0 + 1e-3

    /// Read-back can be quantized to the hardware LUT, so an exact
    /// floating-point match is too strict for "is this still our table".
    private static let matchTolerance: CGGammaValue = 1e-3

    var red: [CGGammaValue]
    var green: [CGGammaValue]
    var blue: [CGGammaValue]

    static func capture(displayID: CGDirectDisplayID) -> GammaTable? {
        var red = [CGGammaValue](repeating: 0, count: Int(sampleCount))
        var green = [CGGammaValue](repeating: 0, count: Int(sampleCount))
        var blue = [CGGammaValue](repeating: 0, count: Int(sampleCount))
        var actualSampleCount: UInt32 = 0
        let result = CGGetDisplayTransferByTable(displayID, sampleCount, &red, &green, &blue, &actualSampleCount)
        guard result == .success else {
            FileHandle.standardError.write(Data("BrightBoi: CGGetDisplayTransferByTable failed (\(result.rawValue))\n".utf8))
            return nil
        }
        return GammaTable(red: red, green: green, blue: blue)
    }

    /// `true` when this table's peak sample is already well above identity
    /// — the signal that whatever produced it had already scaled it up, per
    /// `isAlreadyBoosted(red:green:blue:)`.
    var looksAlreadyBoosted: Bool {
        Self.isAlreadyBoosted(red: red, green: green, blue: blue)
    }

    /// Extracted as a pure function over raw samples (rather than reading
    /// `self`) so tests can exercise it against an identity ramp, a ×2 ramp,
    /// and a real vcgt-like ramp without constructing a `GammaTable` through
    /// `capture`.
    static func isAlreadyBoosted(red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue]) -> Bool {
        let peak = [red, green, blue].compactMap { $0.max() }.max() ?? 0
        return peak > alreadyBoostedThreshold
    }

    /// Per-sample comparison within `matchTolerance`, rather than exact
    /// equality — used by `BoostEngagement.disengage()` to check the table
    /// it's about to restore over is still the one it wrote, not another
    /// process's table from taking over the display in the meantime.
    func matches(_ other: GammaTable) -> Bool {
        guard red.count == other.red.count, green.count == other.green.count, blue.count == other.blue.count else { return false }
        return zip(red, other.red).allSatisfy { abs($0 - $1) <= Self.matchTolerance }
            && zip(green, other.green).allSatisfy { abs($0 - $1) <= Self.matchTolerance }
            && zip(blue, other.blue).allSatisfy { abs($0 - $1) <= Self.matchTolerance }
    }

    func scaled(by factor: CGGammaValue) -> GammaTable {
        GammaTable(
            red: red.map { $0 * factor },
            green: green.map { $0 * factor },
            blue: blue.map { $0 * factor }
        )
    }

    /// A failure here (e.g. mid-restore) would silently leave the display
    /// stuck over-brightened, so it's worth surfacing even though there's no
    /// UI to show it in — matches the dlopen/dlsym failure logging in
    /// `LiveDisplayBrightnessProvider`.
    func apply(to displayID: CGDirectDisplayID) {
        // `CGSetDisplayTransferByTable` takes `const CGGammaValue *`, so the
        // arrays can be passed directly — no need to copy them into `var`s
        // first just to take their address.
        let result = CGSetDisplayTransferByTable(displayID, UInt32(red.count), red, green, blue)
        if result != .success {
            FileHandle.standardError.write(Data("BrightBoi: CGSetDisplayTransferByTable failed (\(result.rawValue))\n".utf8))
        }
    }
}

/// The public-API EDR trigger from `docs/brightness-api-research.md`: a 1x1px,
/// borderless, always-on-top, transparent window whose content is an
/// EDR-capable Metal layer. Rendering one frame cleared to a value > 1.0 is
/// what makes `NSScreen.maximumExtendedDynamicRangeColorComponentValue`
/// exceed 1.0 system-wide, which is what lets gamma factors above identity
/// actually brighten the panel instead of clamping at white. Reverting the
/// clear color and EDR flag back to identity lets the window server drop
/// that headroom back down without needing to tear down the window itself.
@MainActor
private final class EDROverlayWindow: NSObject, MTKViewDelegate {
    /// > 1.0 to force EDR engagement; research measured this panel's max EDR
    /// headroom at ~3.2x once triggered (see `docs/brightness-api-research.md`),
    /// so any value in `(1.0, 3.2]` works here — 1.6 is simply comfortably
    /// inside that range, not itself a brightness anchor (the *gamma factor*
    /// in `BoostEngagement`, anchored 1.0...2.0, is what controls perceived
    /// brightness).
    private static let edrClearValue: Double = 1.6
    private static let identityClearValue: Double = 1.0

    private var window: NSWindow?
    private var metalView: MTKView?
    private var commandQueue: MTLCommandQueue?

    func mount() {
        guard window == nil, let screen = NSScreen.main, let device = MTLCreateSystemDefaultDevice() else { return }

        let metalView = MTKView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), device: device)
        metalView.autoResizeDrawable = false
        metalView.drawableSize = CGSize(width: 1, height: 1)
        metalView.colorPixelFormat = .rgba16Float
        metalView.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        metalView.clearColor = MTLClearColorMake(Self.edrClearValue, Self.edrClearValue, Self.edrClearValue, 1.0)
        metalView.preferredFramesPerSecond = 5
        metalView.delegate = self
        if let layer = metalView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.isOpaque = false
            layer.pixelFormat = .rgba16Float
        }

        commandQueue = device.makeCommandQueue()

        let overlayWindow = NSWindow(
            contentRect: CGRect(x: 0, y: screen.frame.height - 1, width: 1, height: 1),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        overlayWindow.level = .screenSaver
        overlayWindow.isOpaque = false
        overlayWindow.hasShadow = false
        overlayWindow.backgroundColor = .clear
        overlayWindow.ignoresMouseEvents = true
        overlayWindow.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
        overlayWindow.contentView = metalView
        overlayWindow.orderFrontRegardless()

        self.window = overlayWindow
        self.metalView = metalView
    }

    func engageEDR() {
        if let layer = metalView?.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
        }
        metalView?.clearColor = MTLClearColorMake(Self.edrClearValue, Self.edrClearValue, Self.edrClearValue, 1.0)
    }

    /// Flipping the clear color back to ≤1.0 alone did not reliably drop
    /// `maximumExtendedDynamicRangeColorComponentValue` back to 1.0
    /// (verified live: it stayed pinned at ~3.2). The layer's own
    /// `wantsExtendedDynamicRangeContent` flag has to flip off too for the
    /// window server to release the headroom reservation.
    func disengageEDR() {
        if let layer = metalView?.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = false
        }
        metalView?.clearColor = MTLClearColorMake(Self.identityClearValue, Self.identityClearValue, Self.identityClearValue, 1.0)
    }

    func draw(in view: MTKView) {
        guard let commandQueue,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor),
              let drawable = view.currentDrawable else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
