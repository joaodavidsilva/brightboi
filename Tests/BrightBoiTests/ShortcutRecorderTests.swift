import Foundation
import Testing
@testable import BrightBoi

@MainActor
@Suite("Shortcut recorder")
struct ShortcutRecorderTests {

    private struct Fixture {
        let recorder: ShortcutRecorder
        let controller: BrightnessController
        let keyTap: FakeKeyTap
        let persistence: FakeBrightnessPersistence
        let announcements: Announcements
    }

    private final class Announcements {
        var messages: [String] = []
    }

    private let up = KeyCombo(modifiers: [.control, .option], keyCode: 0x7E)
    private let down = KeyCombo(modifiers: [.control, .option], keyCode: 0x7D)

    private func makeFixture(
        timeout: Duration = .seconds(30),
        rejectionDuration: Duration = .seconds(3),
        context: ShortcutContext = ShortcutContext(),
        sleeper: ManualSleeper? = nil
    ) -> Fixture {
        let persistence = FakeBrightnessPersistence()
        let keyTap = FakeKeyTap()
        let controller = BrightnessController(
            displayBrightness: FakeDisplayBrightnessProvider(),
            autoBrightnessToggle: FakeAutoBrightnessToggle(),
            loginItemService: FakeLoginItemService(),
            persistence: persistence,
            keyTap: keyTap,
            powerSource: FakePowerSourceProvider(),
            thermalState: FakeThermalStateProvider(),
            bundleLocation: FakeBundleLocationProvider(),
            displayAccessibility: FakeDisplayAccessibility(),
            permissions: PermissionsModel(checker: FakePermissionsChecker(), openURL: { _ in }),
            schedule: ManualPersistScheduler().schedule,
            keyTapWatchSchedule: ManualPersistScheduler().schedule
        )
        controller.start()
        let announcements = Announcements()
        let recorder = ShortcutRecorder(
            controller: controller,
            timeout: timeout,
            rejectionDuration: rejectionDuration,
            context: { context },
            announce: { announcements.messages.append($0) },
            sleep: { duration in
                if let sleeper {
                    await sleeper.sleep(duration)
                } else {
                    try? await Task.sleep(for: duration)
                }
            }
        )
        return Fixture(recorder: recorder, controller: controller, keyTap: keyTap, persistence: persistence, announcements: announcements)
    }

    @Test("clicking a pill arms it and starts capture")
    func clickArms() {
        let f = makeFixture()
        f.recorder.toggle(.raise)
        #expect(f.recorder.armed == .raise)
        #expect(f.keyTap.isCapturing)
        f.recorder.teardown()
    }

    @Test("clicking the armed pill again disarms it without changing the shortcut")
    func secondClickDisarms() {
        let f = makeFixture()
        f.recorder.toggle(.raise)
        f.recorder.toggle(.raise)
        #expect(f.recorder.armed == nil)
        #expect(f.keyTap.isCapturing == false)
        #expect(f.controller.currentState.keyRemapShortcut == .defaultShortcut)
    }

    @Test("arming the second pill disarms the first")
    func onlyOnePillArmed() {
        let f = makeFixture()
        f.recorder.toggle(.raise)
        f.recorder.toggle(.lower)
        #expect(f.recorder.armed == .lower)
        #expect(f.keyTap.isCapturing)
        #expect(f.keyTap.endCaptureCallCount == 1)
        f.recorder.teardown()
    }

    @Test("a captured combo is applied to the armed direction and ends the capture")
    func captureApplies() {
        let f = makeFixture()
        f.recorder.toggle(.raise)
        f.keyTap.simulateCapture(up)
        #expect(f.recorder.armed == nil)
        #expect(f.recorder.rejection == nil)
        #expect(f.controller.currentState.keyRemapShortcut == KeyRemapShortcut(raise: up, lower: .f1))
        #expect(f.keyTap.endCaptureCallCount == 1)
    }

    @Test("recording Raise then Lower keeps both")
    func twoRecordingsBothStick() {
        let f = makeFixture()
        f.recorder.toggle(.raise)
        f.keyTap.simulateCapture(up)
        f.recorder.toggle(.lower)
        f.keyTap.simulateCapture(down)
        let expected = KeyRemapShortcut(raise: up, lower: down)
        #expect(f.persistence.storedKeyRemapShortcut == expected)
        #expect(f.keyTap.lastStartedRemap == expected)
    }

    @Test("a reserved combo is refused with its reason and leaves the shortcut alone")
    func reservedComboRefused() {
        let f = makeFixture()
        f.recorder.toggle(.raise)
        f.keyTap.simulateCapture(KeyCombo(modifiers: [.command], keyCode: 0x0D)) // ⌘W
        #expect(f.recorder.rejection == .init(press: .raise, message: "Reserved by macOS"))
        #expect(f.recorder.armed == nil)
        #expect(f.controller.currentState.keyRemapShortcut == .defaultShortcut)
        #expect(f.announcements.messages.last == "Reserved by macOS")
    }

    @Test("a combo that needs a modifier, or belongs to the other direction, says so")
    func specificMessages() {
        let f = makeFixture()
        f.recorder.toggle(.raise)
        f.keyTap.simulateCapture(KeyCombo(modifiers: [.shift], keyCode: 0x00))
        #expect(f.recorder.rejection?.message == "Add ⌘ or ⌃")

        f.recorder.toggle(.raise)
        f.keyTap.simulateCapture(.f1)
        #expect(f.recorder.rejection?.message == "Already used for Lower")
    }

    @Test("a system hot key is refused")
    func systemHotKeyRefused() {
        let taken = KeyCombo(modifiers: [.control], keyCode: 0x7B)
        let f = makeFixture(context: ShortcutContext(systemReserved: [taken]))
        f.recorder.toggle(.lower)
        f.keyTap.simulateCapture(taken)
        #expect(f.recorder.rejection == .init(press: .lower, message: "Reserved by macOS"))
    }

    @Test("arming again clears a rejection that is still showing")
    func armingClearsRejection() {
        let f = makeFixture()
        f.recorder.toggle(.raise)
        f.keyTap.simulateCapture(KeyCombo(modifiers: [], keyCode: 0x0B))
        #expect(f.recorder.rejection != nil)
        f.recorder.toggle(.raise)
        #expect(f.recorder.rejection == nil)
        #expect(f.recorder.armed == .raise)
        f.recorder.teardown()
    }

    @Test("two rejections in a row each stay for the full duration")
    func secondRejectionKeepsFullDuration() async throws {
        let sleeper = ManualSleeper()
        let f = makeFixture(sleeper: sleeper)
        f.recorder.toggle(.raise)
        f.keyTap.simulateCapture(KeyCombo(modifiers: [], keyCode: 0x0B))
        f.recorder.toggle(.raise)
        f.keyTap.simulateCapture(KeyCombo(modifiers: [], keyCode: 0x0B))
        // Sleeps start in order: armed timeout, first rejection, armed
        // timeout, second rejection. The first rejection's timer runs out
        // here, but it was replaced, so it must not clear the second.
        await sleeper.releaseNext()
        await sleeper.releaseNext()
        await sleeper.releaseNext()
        #expect(f.recorder.rejection != nil)
        await sleeper.releaseNext()
        await settle { f.recorder.rejection == nil }
        #expect(f.recorder.rejection == nil)
    }

    @Test("an armed pill gives up after the timeout")
    func timesOut() async throws {
        let sleeper = ManualSleeper()
        let f = makeFixture(sleeper: sleeper)
        f.recorder.toggle(.raise)
        #expect(f.recorder.armed == .raise)
        await sleeper.releaseNext()
        await settle { f.recorder.armed == nil }
        #expect(f.recorder.armed == nil)
        #expect(f.keyTap.isCapturing == false)
    }

    @Test("arming announces the recording for VoiceOver")
    func armingAnnounces() {
        let f = makeFixture()
        f.recorder.toggle(.lower)
        #expect(f.announcements.messages.last == "Recording the Lower shortcut. Press a key combination, or Escape to cancel.")
        f.recorder.teardown()
    }

    @Test("Escape disarms and is consumed; Tab and Shift-Tab disarm and move focus on")
    func controlKeys() {
        let f = makeFixture()
        f.recorder.toggle(.raise)
        #expect(f.recorder.handleKey(keyCode: 0x35, modifiers: []) == true)
        #expect(f.recorder.armed == nil)

        for modifiers: KeyCombo.Modifiers in [[], [.shift]] {
            f.recorder.toggle(.raise)
            #expect(f.recorder.handleKey(keyCode: 0x30, modifiers: modifiers) == false)
            #expect(f.recorder.armed == nil)
        }
        #expect(f.controller.currentState.keyRemapShortcut == .defaultShortcut)
    }

    @Test("a key pressed while disarmed is not consumed")
    func disarmedKeysPassThrough() {
        let f = makeFixture()
        #expect(f.recorder.handleKey(keyCode: 0x0D, modifiers: [.command]) == false)
    }

    @Test("a key pressed in the window while armed is recorded through the key path too")
    func keyPathRecords() {
        let f = makeFixture()
        f.recorder.toggle(.raise)
        #expect(f.recorder.handleKey(keyCode: 0x7E, modifiers: [.control, .option]) == true)
        #expect(f.controller.currentState.keyRemapShortcut.raise == up)
    }

    @Test("a plain F1 or F2 key-down is refused, since only the media key can be F1 or F2")
    func bareFunctionKeyDownRefused() {
        let f = makeFixture()
        f.recorder.toggle(.raise)
        #expect(f.recorder.handleKey(keyCode: 0x7A, modifiers: []) == true)
        #expect(f.recorder.armed == nil)
        #expect(f.recorder.rejection?.message == ShortcutRejection.useBrightnessKey.message)
        #expect(f.controller.currentState.keyRemapShortcut == .defaultShortcut)
        f.recorder.teardown()
    }

    @Test("teardown disarms and clears the rejection")
    func teardownClears() {
        let f = makeFixture()
        f.recorder.toggle(.raise)
        f.keyTap.simulateCapture(KeyCombo(modifiers: [], keyCode: 0x0B))
        f.recorder.toggle(.lower)
        f.recorder.teardown()
        #expect(f.recorder.armed == nil)
        #expect(f.recorder.rejection == nil)
        #expect(f.keyTap.isCapturing == false)
    }
}
