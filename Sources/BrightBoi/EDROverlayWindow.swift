import AppKit
import CoreGraphics
import MetalKit

/// The public-API EDR trigger: a 1x1 point, borderless, always-on-top window
/// whose content is an EDR-capable Metal layer. Setting the layer's
/// `wantsExtendedDynamicRangeContent` is what makes
/// `NSScreen.maximumExtendedDynamicRangeColorComponentValue` rise above 1.0,
/// which is what lets gamma factors above identity actually brighten the
/// panel instead of clamping at white; clearing the flag lets the window
/// server take the headroom back.
///
/// The window sits in the top-left corner of the built-in screen, where the
/// display's rounded corner hides the pixel, and stays invisible in every
/// other way it can: it draws (almost) nothing, opts out of screen capture
/// and sharing, and is not an accessibility element.
///
/// The window is created once and kept for the life of the process rather
/// than torn down when Boost ends. Repeatedly closing a Metal-backed window
/// and releasing its layer reliably crashed with `EXC_BAD_ACCESS` during
/// autorelease-pool drain, so disengaging only flips the EDR flag and pauses
/// rendering. While disengaged nothing is drawn and nothing wakes up.
///
/// Every part of the window is built before an instance exists, so an
/// overlay is either fully mounted or `mount(on:)` returns `nil` and the
/// caller may simply try again later.
@MainActor
final class EDROverlayWindow: NSObject, MTKViewDelegate, EDROverlaying {
    /// What the layer is cleared to while EDR is requested: premultiplied
    /// light at 1.6x SDR white and 1% opacity. Effectively invisible on one
    /// point of a rounded corner, but not fully transparent, so no
    /// compositor has grounds to skip a layer with nothing in it. The value
    /// is premultiplied (colour already multiplied by alpha); writing the
    /// unpremultiplied 1.6 here would make a bright white square.
    nonisolated static let engagedClearColor = MTLClearColorMake(0.016, 0.016, 0.016, 0.01)

    /// What the layer is cleared to while EDR is released: nothing at all.
    nonisolated static let disengagedClearColor = MTLClearColorMake(0, 0, 0, 0)

    /// Rendering rate while EDR is requested. The frame itself never
    /// changes; the loop only keeps the layer live for the window server.
    private static let engagedFramesPerSecond = 5

    private(set) var displayID: CGDirectDisplayID
    private let window: NSWindow
    private let metalView: MTKView
    private let commandQueue: MTLCommandQueue
    private var occlusionObserver: NSObjectProtocol?

    /// Whether the window is on screen and not covered. A covered overlay
    /// loses its EDR headroom after about 15 seconds.
    var isVisible: Bool {
        window.occlusionState.contains(.visible)
    }

    var onVisibilityChange: (() -> Void)?

    private init(displayID: CGDirectDisplayID, window: NSWindow, metalView: MTKView, commandQueue: MTLCommandQueue) {
        self.displayID = displayID
        self.window = window
        self.metalView = metalView
        self.commandQueue = commandQueue
        super.init()
        metalView.delegate = self
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onVisibilityChange?()
            }
        }
    }

    isolated deinit {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
    }

    /// Mounts an overlay on `displayID`'s screen, released (EDR off, not
    /// rendering). `nil` when that display has no `NSScreen` right now or
    /// Metal is unavailable — nothing is left behind in either case.
    static func mount(on displayID: CGDirectDisplayID) -> EDROverlayWindow? {
        guard let screen = BuiltInDisplay.screen(for: displayID),
              let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }

        let metalView = MTKView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), device: device)
        metalView.autoResizeDrawable = false
        metalView.drawableSize = CGSize(width: 1, height: 1)
        metalView.colorPixelFormat = .rgba16Float
        metalView.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        metalView.clearColor = disengagedClearColor
        metalView.preferredFramesPerSecond = engagedFramesPerSecond
        // Explicit drawing: nothing renders unless `draw()` is called, or the
        // loop is switched on while EDR is requested.
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = true
        if let layer = metalView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = false
            layer.isOpaque = false
            layer.pixelFormat = .rgba16Float
        }

        let window = makeWindow(frame: overlayFrame(in: screen.frame))
        window.contentView = metalView
        window.orderFrontRegardless()

        return EDROverlayWindow(displayID: displayID, window: window, metalView: metalView, commandQueue: commandQueue)
    }

    /// The overlay's frame in global screen coordinates: the 1x1 point at the
    /// top-left corner of `screenFrame`. `screenFrame.origin` is not the
    /// global origin when the screen is not the main one, so the corner is
    /// computed from the frame rather than assumed to be (0, height - 1).
    nonisolated static func overlayFrame(in screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX, y: screenFrame.maxY - 1, width: 1, height: 1)
    }

    /// The bare window: borderless, click-through, above everything, and
    /// hidden from screen capture, sharing and accessibility. Split out from
    /// `mount(on:)` so those properties can be checked without a GPU.
    static func makeWindow(frame: CGRect) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.canHide = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
        // Keeps the window out of screenshots, recordings and screen shares.
        window.sharingType = .none
        // Keeps the nameless 1x1 window out of VoiceOver's window list and
        // the app's accessibility window list. The window stays untitled on
        // purpose, so share pickers that skip untitled windows keep
        // skipping it; there is no public way to remove it from window
        // enumerators altogether.
        window.setAccessibilityElement(false)
        return window
    }

    /// Moves the window to the top-left corner of `displayID`'s screen and
    /// draws a frame there. `false` when that display has no screen (asleep,
    /// disconnected, lid closed), in which case the window stays where it is.
    @discardableResult
    func rehome(to displayID: CGDirectDisplayID) -> Bool {
        guard let screen = BuiltInDisplay.screen(for: displayID) else { return false }
        self.displayID = displayID
        let frame = Self.overlayFrame(in: screen.frame)
        if window.frame != frame {
            window.setFrame(frame, display: false)
        }
        window.orderFrontRegardless()
        metalView.draw()
        return true
    }

    /// Orders the window to the front again, for when something else at its
    /// level was ordered in over it.
    func bringToFront() {
        window.orderFrontRegardless()
    }

    /// Requests EDR headroom: sets the layer's flag, draws a frame carrying
    /// it, and keeps the render loop running for as long as it is wanted.
    func engageEDR() {
        if let layer = metalView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
        }
        metalView.clearColor = Self.engagedClearColor
        metalView.isPaused = false
        metalView.draw()
    }

    /// Releases the headroom. Flipping the clear colour alone did not
    /// reliably drop `maximumExtendedDynamicRangeColorComponentValue` back
    /// to 1.0; the layer's own flag has to flip off too. One last
    /// transparent frame replaces the EDR frame the window server holds,
    /// then rendering stops entirely.
    func disengageEDR() {
        if let layer = metalView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = false
        }
        metalView.clearColor = Self.disengagedClearColor
        metalView.draw()
        metalView.isPaused = true
    }

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor),
              let drawable = view.currentDrawable else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
