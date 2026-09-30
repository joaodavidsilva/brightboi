import AppKit
import CoreGraphics
import Testing
@testable import BrightBoi

@Suite("Key tap matching")
struct KeyTapMatchingTests {

    private let defaultPlan = KeyTapPlan(remap: .defaultShortcut)

    /// The `data1` of a brightness media key event: key code in the top 16
    /// bits, the key-down state (0x0A) or key-up state (0x0B) in the next byte.
    private func data1(keyCode: Int32, down: Bool = true, isRepeat: Bool = false) -> Int {
        (Int(keyCode) << 16) | ((down ? 0x0A : 0x0B) << 8) | (isRepeat ? 1 : 0)
    }

    // MARK: Plan

    @Test("the default remap uses both media keys and no hot keys")
    func defaultRemapPlan() {
        #expect(defaultPlan.usesMediaKeys)
        #expect(defaultPlan.hotKeys.isEmpty)
    }

    @Test("custom combos become hot keys, leaving no media key to watch")
    func customPlan() {
        let raise = KeyCombo(modifiers: [.control, .option], keyCode: 0x7E)
        let lower = KeyCombo(modifiers: [.control, .option], keyCode: 0x7D)
        let plan = KeyTapPlan(remap: KeyRemapShortcut(raise: raise, lower: lower))
        #expect(plan.usesMediaKeys == false)
        #expect(plan.hotKeys.map(\.combo) == [raise, lower])
        #expect(plan.hotKeys.map(\.press) == [.raise, .lower])
    }

    @Test("a remap with one direction custom watches only the other direction's media key")
    func mixedPlan() {
        let lower = KeyCombo(modifiers: [.control, .option], keyCode: 0x7D)
        let plan = KeyTapPlan(remap: KeyRemapShortcut(raise: .f2, lower: lower))
        #expect(plan.raiseMediaKey == true)
        #expect(plan.lowerMediaKey == false)
        #expect(plan.hotKeys.map(\.combo) == [lower])
    }

    @Test("the same combo on both directions registers once, for Raise")
    func duplicateComboRegistersOnce() {
        let combo = KeyCombo(modifiers: [.control], keyCode: 0x7E)
        let plan = KeyTapPlan(remap: KeyRemapShortcut(raise: combo, lower: combo))
        #expect(plan.hotKeys.map(\.press) == [.raise])
    }

    @Test("a swapped remap sends brightness down to Raise and brightness up to Lower")
    func swappedPlanMapsMediaKeys() {
        let plan = KeyTapPlan(remap: KeyRemapShortcut(raise: .f1, lower: .f2))
        #expect(plan.usesMediaKeys)
        #expect(plan.hotKeys.isEmpty)
        #expect(KeyTapMatcher.mediaKeyPress(subtype: 8, data1: data1(keyCode: 3), flags: [], plan: plan) == .raise)
        #expect(KeyTapMatcher.mediaKeyPress(subtype: 8, data1: data1(keyCode: 2), flags: [], plan: plan) == .lower)
    }

    @Test("Raise on brightness down beside a custom Lower leaves brightness up to macOS")
    func mixedSwappedPlan() {
        let lower = KeyCombo(modifiers: [.control, .option], keyCode: 0x7D)
        let plan = KeyTapPlan(remap: KeyRemapShortcut(raise: .f1, lower: lower))
        #expect(KeyTapMatcher.mediaKeyPress(subtype: 8, data1: data1(keyCode: 3), flags: [], plan: plan) == .raise)
        #expect(KeyTapMatcher.mediaKeyPress(subtype: 8, data1: data1(keyCode: 2), flags: [], plan: plan) == nil)
        #expect(plan.hotKeys.map(\.combo) == [lower])
    }

    @Test("media events read as F1 for down and F2 for up, under the same modifier policy")
    func mediaKeyCombos() {
        #expect(KeyTapMatcher.mediaKeyCombo(subtype: 8, data1: data1(keyCode: 3), flags: []) == .f1)
        #expect(KeyTapMatcher.mediaKeyCombo(subtype: 8, data1: data1(keyCode: 2), flags: [.maskShift]) == .f2)
        #expect(KeyTapMatcher.mediaKeyCombo(subtype: 8, data1: data1(keyCode: 2), flags: [.maskControl]) == nil)
        #expect(KeyTapMatcher.mediaKeyCombo(subtype: 8, data1: data1(keyCode: 2, down: false), flags: []) == nil)
        #expect(KeyTapMatcher.mediaKeyCombo(subtype: 8, data1: data1(keyCode: 0), flags: []) == nil)
    }

    // MARK: Capture

    @Test("a captured key-down carries its modifiers")
    func capturedKeyDown() {
        let combo = KeyTapMatcher.capturedCombo(keyCode: 0x7E, flags: [.maskControl, .maskAlternate])
        #expect(combo == KeyCombo(modifiers: [.control, .option], keyCode: 0x7E))
    }

    @Test("Escape and Tab belong to the recorder, not to a shortcut")
    func recorderControlKeys() {
        #expect(KeyTapMatcher.capturedCombo(keyCode: 0x35, flags: []) == nil)
        #expect(KeyTapMatcher.capturedCombo(keyCode: 0x30, flags: []) == nil)
        #expect(KeyTapMatcher.capturedCombo(keyCode: 0x30, flags: [.maskShift]) == nil)
        // With other modifiers they are ordinary candidates, refused or not by the rules.
        #expect(KeyTapMatcher.capturedCombo(keyCode: 0x30, flags: [.maskControl]) != nil)
        #expect(KeyTapMatcher.capturedCombo(keyCode: 0x35, flags: [.maskCommand]) != nil)
    }

    // MARK: Media keys

    @Test("a bare brightness-up media event raises")
    func bareBrightnessUpRaises() {
        let press = KeyTapMatcher.mediaKeyPress(subtype: 8, data1: data1(keyCode: 2), flags: [], plan: defaultPlan)
        #expect(press == .raise)
    }

    @Test("a bare brightness-down media event lowers")
    func bareBrightnessDownLowers() {
        let press = KeyTapMatcher.mediaKeyPress(subtype: 8, data1: data1(keyCode: 3), flags: [], plan: defaultPlan)
        #expect(press == .lower)
    }

    @Test("a media key-up, another key and another subtype are not matched")
    func otherMediaEventsIgnored() {
        #expect(KeyTapMatcher.mediaKeyPress(subtype: 8, data1: data1(keyCode: 2, down: false), flags: [], plan: defaultPlan) == nil)
        #expect(KeyTapMatcher.mediaKeyPress(subtype: 8, data1: data1(keyCode: 0), flags: [], plan: defaultPlan) == nil)
        #expect(KeyTapMatcher.mediaKeyPress(subtype: 7, data1: data1(keyCode: 2), flags: [], plan: defaultPlan) == nil)
    }

    @Test("Shift and Option-Shift stay with BrightBoi")
    func shiftCombinationsAreMatched() {
        #expect(KeyTapMatcher.mediaKeyPress(subtype: 8, data1: data1(keyCode: 2), flags: [.maskShift], plan: defaultPlan) == .raise)
        #expect(KeyTapMatcher.mediaKeyPress(subtype: 8, data1: data1(keyCode: 2), flags: [.maskAlternate, .maskShift], plan: defaultPlan) == .raise)
    }

    @Test("Control, Option and Command pass through to macOS")
    func systemModifiersPassThrough() {
        for flags: CGEventFlags in [.maskControl, .maskAlternate, .maskCommand, [.maskCommand, .maskShift], [.maskControl, .maskShift], [.maskControl, .maskAlternate]] {
            #expect(KeyTapMatcher.mediaKeyPress(subtype: 8, data1: data1(keyCode: 2), flags: flags, plan: defaultPlan) == nil)
        }
    }

    @Test("the Fn flag that function keys carry does not matter")
    func functionFlagIgnored() {
        let press = KeyTapMatcher.mediaKeyPress(subtype: 8, data1: data1(keyCode: 2), flags: [.maskSecondaryFn], plan: defaultPlan)
        #expect(press == .raise)
    }

    @Test("a direction moved off its default no longer matches its media key")
    func reconfiguredDirectionReturnsKeyToMacOS() {
        let plan = KeyTapPlan(remap: KeyRemapShortcut(raise: KeyCombo(modifiers: [.control], keyCode: 0x7E), lower: .f1))
        #expect(KeyTapMatcher.mediaKeyPress(subtype: 8, data1: data1(keyCode: 2), flags: [], plan: plan) == nil)
        #expect(KeyTapMatcher.mediaKeyPress(subtype: 8, data1: data1(keyCode: 3), flags: [], plan: plan) == .lower)
    }

    @Test("a real systemDefined event decodes to the same verdicts")
    func realEventRoundTrip() throws {
        func media(keyCode: Int32, flags: NSEvent.ModifierFlags) -> CGEvent? {
            NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8,
                data1: (Int(keyCode) << 16) | (0x0A << 8), data2: -1
            )?.cgEvent
        }
        let bare = try #require(media(keyCode: 2, flags: []))
        let nsBare = try #require(NSEvent(cgEvent: bare))
        #expect(KeyTapMatcher.mediaKeyPress(subtype: nsBare.subtype.rawValue, data1: nsBare.data1, flags: bare.flags, plan: defaultPlan) == .raise)

        let control = try #require(media(keyCode: 2, flags: .control))
        let nsControl = try #require(NSEvent(cgEvent: control))
        #expect(KeyTapMatcher.mediaKeyPress(subtype: nsControl.subtype.rawValue, data1: nsControl.data1, flags: control.flags, plan: defaultPlan) == nil)
    }

    @Test("the repeat bit of a media key is read")
    func repeatBit() {
        #expect(KeyTapMatcher.isMediaKeyRepeat(data1: data1(keyCode: 2, isRepeat: true)))
        #expect(!KeyTapMatcher.isMediaKeyRepeat(data1: data1(keyCode: 2)))
    }

    // MARK: Key-down fallback

    @Test("a key-down F2 is never matched, with or without modifiers")
    func functionKeyDownNotMatched() {
        for flags: CGEventFlags in [[], [.maskShift], [.maskControl], [.maskSecondaryFn]] {
            #expect(KeyTapMatcher.keyDownPress(keyCode: KeyCombo.f2VirtualKeyCode, flags: flags, fallback: []) == nil)
        }
    }

    @Test("the key-down fallback matches a combo macOS refused as a hot key, exactly")
    func keyDownFallbackMatches() {
        let combo = KeyCombo(modifiers: [.control, .option], keyCode: 0x7E)
        let fallback = [(press: BrightnessController.KeyPress.raise, combo: combo)]
        #expect(KeyTapMatcher.keyDownPress(keyCode: 0x7E, flags: [.maskControl, .maskAlternate], fallback: fallback) == .raise)
        #expect(KeyTapMatcher.keyDownPress(keyCode: 0x7E, flags: [.maskControl], fallback: fallback) == nil)
        #expect(KeyTapMatcher.keyDownPress(keyCode: 0x7D, flags: [.maskControl, .maskAlternate], fallback: fallback) == nil)
    }

    // MARK: Modifiers

    @Test("cgEventFlags map to the same modifiers as the NSEvent flags")
    func modifiersFromCGFlags() {
        #expect(KeyCombo.Modifiers(cgEventFlags: [.maskCommand, .maskShift, .maskSecondaryFn]) == [.command, .shift])
        #expect(KeyCombo.Modifiers(cgEventFlags: [.maskControl, .maskAlternate]) == [.control, .option])
    }

    @Test("carbonModifiers maps to cmdKey, optionKey, controlKey and shiftKey")
    func carbonModifiers() {
        #expect(KeyCombo.Modifiers([.command]).carbonModifiers == 256)
        #expect(KeyCombo.Modifiers([.shift]).carbonModifiers == 512)
        #expect(KeyCombo.Modifiers([.option]).carbonModifiers == 2048)
        #expect(KeyCombo.Modifiers([.control]).carbonModifiers == 4096)
        #expect(KeyCombo.Modifiers([.control, .option]).carbonModifiers == 4096 | 2048)
        #expect(KeyCombo.Modifiers([]).carbonModifiers == 0)
    }

    // MARK: Repeat limiter

    @Test("a repeat arriving sooner than the minimum interval is throttled, a first press never is")
    func limiterThrottlesFastRepeats() {
        var limiter = KeyRepeatLimiter(minimumInterval: 0.06)
        #expect(limiter.isThrottled(isRepeat: false, at: 0) == false)
        limiter.recordApplied(at: 0)

        #expect(limiter.isThrottled(isRepeat: true, at: 0.015) == true)
        #expect(limiter.isThrottled(isRepeat: true, at: 0.059) == true)
        #expect(limiter.isThrottled(isRepeat: true, at: 0.061) == false)
        #expect(limiter.isThrottled(isRepeat: false, at: 0.001) == false)
    }

    @Test("a repeat is never throttled before anything was applied")
    func limiterStartsOpen() {
        let limiter = KeyRepeatLimiter()
        #expect(limiter.isThrottled(isRepeat: true, at: 100) == false)
    }
}

@Suite("Key tap conflicts")
struct KeyTapConflictTests {

    private func tap(pid: pid_t, active: Bool = true, enabled: Bool = true, mask: UInt64 = 1 << 14) -> EventTapSnapshot {
        EventTapSnapshot(processID: pid, isActiveFilter: active, isEnabled: enabled, eventsOfInterest: mask)
    }

    private let ownPID: pid_t = 100

    @Test("only active, enabled taps watching system-defined events, owned by others, are candidates")
    func candidateFiltering() {
        let taps = [
            tap(pid: 1),
            tap(pid: 2, active: false),
            tap(pid: 3, enabled: false),
            tap(pid: 4, mask: 1 << 10),
            tap(pid: ownPID)
        ]
        #expect(KeyTapConflictResolver.candidates(in: taps, ownProcessID: ownPID).map(\.processID) == [1])
    }

    @Test("a lone candidate is named")
    func loneCandidateNamed() {
        let pid = KeyTapConflictResolver.namedProcessID(in: [tap(pid: 7)], ownProcessID: ownPID) { _ in nil }
        #expect(pid == 7)
    }

    @Test("several candidates are not named unless exactly one is a known brightness-key tool")
    func ambiguousCandidates() {
        let taps = [tap(pid: 7), tap(pid: 8)]
        #expect(KeyTapConflictResolver.namedProcessID(in: taps, ownProcessID: ownPID) { _ in nil } == nil)

        let oneKnown = KeyTapConflictResolver.namedProcessID(in: taps, ownProcessID: ownPID) {
            $0 == 8 ? "app.monitorcontrol.MonitorControl" : "com.example.Other"
        }
        #expect(oneKnown == 8)

        let twoKnown = KeyTapConflictResolver.namedProcessID(in: taps, ownProcessID: ownPID) {
            $0 == 8 ? "app.monitorcontrol.MonitorControl" : "fyi.lunar.Lunar"
        }
        #expect(twoKnown == nil)
    }

    @Test("pass-through taps alone produce no candidate")
    func passThroughTapsAreNotCandidates() {
        let taps = [tap(pid: 5, active: false), tap(pid: 6, mask: 0x1c00)]
        #expect(KeyTapConflictResolver.namedProcessID(in: taps, ownProcessID: ownPID) { _ in nil } == nil)
    }

    @Test("a press seen at the HID level but not by BrightBoi's tap counts as intercepted")
    func monitorDetectsSwallowedPress() {
        var monitor = KeyInterceptionMonitor()
        monitor.observedAtHID(timestamp: 42)
        #expect(monitor.wasIntercepted(timestamp: 42) == true)
    }

    @Test("a press BrightBoi's tap received is not intercepted")
    func monitorIgnoresReceivedPress() {
        var monitor = KeyInterceptionMonitor()
        monitor.observedAtHID(timestamp: 42)
        monitor.receivedByTap(timestamp: 42)
        #expect(monitor.wasIntercepted(timestamp: 42) == false)
    }

    @Test("the message names the app when known and stays generic otherwise")
    func messageWording() {
        #expect(KeyTapConflict(appName: "Lunar").message.hasPrefix("Lunar is intercepting the brightness keys"))
        #expect(KeyTapConflict(appName: nil).message.hasPrefix("Another app is intercepting the brightness keys"))
        #expect(KeyTapConflict(appName: nil).message.contains("Turn off brightness-key handling in that app"))
    }
}

@Suite("Captured key-downs of the brightness keys")
struct CapturedBrightnessKeyTests {
    @Test("a bare F1 or F2 key-down is not a captured combo")
    func bareFunctionKeyDown() {
        #expect(KeyTapMatcher.capturedCombo(keyCode: 0x7A, flags: []) == nil)
        #expect(KeyTapMatcher.capturedCombo(keyCode: 0x78, flags: [.maskSecondaryFn]) == nil)
        #expect(KeyTapMatcher.capturedCombo(keyCode: 0x7A, flags: [.maskControl]) != nil)
    }
}
