import Testing
@testable import BrightBoi

@Suite("OnboardingCopy")
struct OnboardingCopyTests {
    @Test("the welcome promises 1000 nits only where Boost exists")
    func welcomeDependsOnBoost() {
        #expect(OnboardingCopy.welcomeBody(supportsBoost: true).contains("1000"))
        let plain = OnboardingCopy.welcomeBody(supportsBoost: false)
        #expect(!plain.contains("1000"))
        #expect(!plain.contains("500 nits"))
        #expect(plain.contains("5% steps"))
    }

    @Test("the confirmation keeps its line when Boost and the keys both work")
    func confirmationBoostWithKeys() {
        let copy = OnboardingCopy.confirmation(supportsBoost: true, keyRemapActive: true)
        #expect(copy.body.contains("hit F2 past where it used to stop"))
        #expect(copy.showsIllustration)
    }

    @Test("without the key tap the confirmation points to Settings instead of promising keys")
    func confirmationWithoutKeys() {
        let boost = OnboardingCopy.confirmation(supportsBoost: true, keyRemapActive: false)
        #expect(boost.body.contains("Accessibility is on in Settings"))
        #expect(!boost.body.contains("just hit"))
        #expect(boost.showsIllustration)

        let plain = OnboardingCopy.confirmation(supportsBoost: false, keyRemapActive: false)
        #expect(plain.body.contains("Accessibility is on in Settings"))
        #expect(!plain.body.contains("100%"))
    }

    @Test("a Mac without Boost gets no illustration and no claim about going past where macOS stops")
    func confirmationWithoutBoost() {
        for keys in [true, false] {
            let copy = OnboardingCopy.confirmation(supportsBoost: false, keyRemapActive: keys)
            #expect(copy.showsIllustration == false)
            #expect(!copy.body.contains("used to stop"))
            #expect(!copy.body.contains("past 100%"))
        }
        #expect(OnboardingCopy.confirmation(supportsBoost: false, keyRemapActive: true).body
            == "I live in the menu bar — click the sun, or use F1/F2 in 5% steps.")
    }

    @Test("the permission step's button and line follow whether Accessibility is granted")
    func permissionsStepCopy() {
        #expect(OnboardingCopy.permissionsContinueTitle(accessibilityGranted: false) == "Continue without the keys")
        #expect(OnboardingCopy.permissionsContinueTitle(accessibilityGranted: true) == "Continue")
        #expect(OnboardingCopy.permissionsIntro(accessibilityGranted: true) == "Already granted — you're set.")
        #expect(OnboardingCopy.permissionsIntro(accessibilityGranted: false).contains("F1/F2"))
    }

    @Test("the row label reads the name, then what it is for, then the status")
    func permissionRowLabel() {
        #expect(OnboardingCopy.permissionRowLabel(title: "Accessibility", subtitle: "Lets me", granted: false)
            == "Accessibility, Lets me, Not granted")
        #expect(OnboardingCopy.permissionRowLabel(title: "Accessibility", subtitle: "Lets me", granted: true)
            == "Accessibility, Lets me, Granted")
    }
}
