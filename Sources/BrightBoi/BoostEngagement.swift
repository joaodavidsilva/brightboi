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
final class BoostEngagement {
    private let displayID: CGDirectDisplayID
    private var baselineGammaTable: GammaTable?
    private var overlay: EDROverlayWindow?
    private var currentFactor: CGGammaValue = 1.0
    private var wakeObserver: NSObjectProtocol?

    /// `EDROverlayWindow` is `@MainActor` (it touches `NSWindow`/`MTKView`).
    /// `BoostEngagement` itself stays nonisolated rather than propagating
    /// `@MainActor` up through `DisplayBrightnessProviding` and
    /// `BrightnessController` — `apply(percentage:)` is only ever driven
    /// synchronously from the main thread today (the slider binding; the
    /// future real key tap per ticket 07 will need the same invariant),
    /// mirroring the whole app's implicit single-threaded UI-driven design.
    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reapplyAfterWake()
        }
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    func engage(factor: CGGammaValue) {
        currentFactor = factor
        if baselineGammaTable == nil {
            baselineGammaTable = GammaTable.capture(displayID: displayID)
        }
        if overlay == nil {
            overlay = MainActor.assumeIsolated {
                let overlay = EDROverlayWindow()
                overlay.mount()
                return overlay
            }
        } else if let overlay {
            MainActor.assumeIsolated { overlay.engageEDR() }
        }
        baselineGammaTable?.scaled(by: factor).apply(to: displayID)
    }

    func disengage() {
        guard let baselineGammaTable else { return }
        // Restoring the specific captured table for `displayID` is already
        // scoped to the built-in display — per the spec's scope boundary,
        // Boost must never touch an external monitor. (An earlier version of
        // this also called `CGDisplayRestoreColorSyncSettings()`, which
        // resets ColorSync for *every* connected display; removed as a real
        // scope violation, not just belt-and-suspenders.)
        baselineGammaTable.apply(to: displayID)
        if let overlay {
            MainActor.assumeIsolated { overlay.disengageEDR() }
        }
        self.baselineGammaTable = nil
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
        baselineGammaTable.scaled(by: currentFactor).apply(to: displayID)
    }
}

/// Wraps `CGGetDisplayTransferByTable`/`CGSetDisplayTransferByTable` (public,
/// documented CoreGraphics APIs) at the 256-sample resolution the research
/// spike verified works.
private struct GammaTable {
    static let sampleCount: UInt32 = 256

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
        var r = red, g = green, b = blue
        let result = CGSetDisplayTransferByTable(displayID, UInt32(r.count), &r, &g, &b)
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
