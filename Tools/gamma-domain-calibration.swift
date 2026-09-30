// Settles by eye whether the display's transfer table scales linear light or
// the gamma-encoded signal, and finds the factor at which the top of the range
// starts to clip. See "Calibrating the Boost factor" in
// docs/brightness-api-research.md.
//
// Run:  swift Tools/gamma-domain-calibration.swift
//
// Needs no photometer, only eyes. It covers the built-in display with a
// 0-255 grey step wedge, engages EDR, and lets you raise the table factor with
// the arrow keys until the brightest steps merge into one. The factor is
// written at most a few seconds at a time and restored on every exit path
// (Esc, Q, Ctrl-C, or the timeout).
//
// Keys: Up/Down = factor +/- 0.05, Right/Left = +/- 0.25, R = back to 1.0,
//       Return = print the current factor and headroom, Esc or Q = quit.

import AppKit
import MetalKit

let maximumFactor: Float = 3.4
let trialSeconds: TimeInterval = 6

func builtInDisplayID() -> CGDirectDisplayID? {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return ids.first { CGDisplayIsBuiltin($0) != 0 }
}

func findBuiltIn() -> (CGDirectDisplayID, NSScreen)? {
    guard let id = builtInDisplayID(),
          let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) else { return nil }
    return (id, screen)
}

guard let (foundID, foundScreen) = findBuiltIn() else {
    print("No active built-in display.")
    exit(1)
}
let displayID = foundID
let screen = foundScreen

let capacity = max(CGDisplayGammaTableCapacity(displayID), 256)
var baseRed = [CGGammaValue](repeating: 0, count: Int(capacity))
var baseGreen = baseRed, baseBlue = baseRed
var sampleCount: UInt32 = 0
guard CGGetDisplayTransferByTable(displayID, capacity, &baseRed, &baseGreen, &baseBlue, &sampleCount) == .success, sampleCount > 0 else {
    print("Could not read the display's table.")
    exit(1)
}
let count = Int(sampleCount)
baseRed = Array(baseRed.prefix(count)); baseGreen = Array(baseGreen.prefix(count)); baseBlue = Array(baseBlue.prefix(count))

func write(factor: Float) {
    let r = baseRed.map { $0 * factor }, g = baseGreen.map { $0 * factor }, b = baseBlue.map { $0 * factor }
    CGSetDisplayTransferByTable(displayID, UInt32(count), r, g, b)
}

func restore() {
    CGSetDisplayTransferByTable(displayID, UInt32(count), baseRed, baseGreen, baseBlue)
}

// A step wedge: 17 vertical bars from 0 to 255 in steps of 16 (last is 255).
final class WedgeView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let steps = 17
        let width = bounds.width / CGFloat(steps)
        for step in 0..<steps {
            let value = CGFloat(min(step * 16, 255)) / 255
            NSColor(srgbRed: value, green: value, blue: value, alpha: 1).setFill()
            NSRect(x: CGFloat(step) * width, y: 0, width: width + 1, height: bounds.height).fill()
        }
    }
}

final class Controller: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var overlay: NSWindow!
    var factor: Float = 1.0
    var timer: Timer?
    var deadline = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let overlayView = MTKView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), device: MTLCreateSystemDefaultDevice())
        overlayView.colorPixelFormat = .rgba16Float
        overlayView.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        overlayView.clearColor = MTLClearColorMake(0.016, 0.016, 0.016, 0.01)
        (overlayView.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
        overlayView.preferredFramesPerSecond = 5
        overlay = NSWindow(contentRect: CGRect(x: screen.frame.minX, y: screen.frame.maxY - 1, width: 1, height: 1), styleMask: [], backing: .buffered, defer: false)
        overlay.level = .screenSaver
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.ignoresMouseEvents = true
        overlay.contentView = overlayView
        overlay.orderFrontRegardless()

        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver - 1
        window.contentView = WedgeView()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        print("Step wedge up. Nominal brightness must be at 100%, Night Shift and True Tone off.")
        print("Raise the factor until the brightest steps merge. Linear light merges near the headroom (about 3.2); gamma-encoded near 1.70.")

        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in self?.key(event); return nil }
    }

    func bump(_ delta: Float) {
        factor = min(max(factor + delta, 1.0), maximumFactor)
        write(factor: factor)
        deadline = Date().addingTimeInterval(trialSeconds)
        report()
    }

    func report() {
        print(String(format: "factor %.2f   headroom %.2f", factor, screen.maximumExtendedDynamicRangeColorComponentValue))
    }

    /// Any factor above 1.0 is dropped after `trialSeconds`, so a forgotten trial cannot leave the panel at peak.
    func tick() {
        if factor > 1.0, Date() > deadline {
            factor = 1.0
            write(factor: 1.0)
            print("Timed out: back to 1.00")
        }
    }

    func key(_ event: NSEvent) {
        switch event.keyCode {
        case 126: bump(0.05)
        case 125: bump(-0.05)
        case 124: bump(0.25)
        case 123: bump(-0.25)
        case 15: factor = 1.0; write(factor: 1.0); report()
        case 36: report()
        case 53, 12: quit()
        default: break
        }
    }

    func quit() {
        restore()
        print("Restored the display's table.")
        NSApp.terminate(nil)
    }
}

signal(SIGINT) { _ in restore(); exit(0) }
signal(SIGTERM) { _ in restore(); exit(0) }
atexit { restore() }

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
