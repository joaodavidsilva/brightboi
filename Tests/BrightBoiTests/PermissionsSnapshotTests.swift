import Testing
@testable import BrightBoi

@Suite("PermissionsSnapshot")
struct PermissionsSnapshotTests {

    @Test("reads both permissions exactly once at construction")
    func readsEachPermissionExactlyOnce() {
        let checker = FakePermissionsChecker()
        checker.stubbedAccessibilityGranted = true
        checker.stubbedInputMonitoringGranted = false

        let snapshot = PermissionsSnapshot(checker: checker)

        #expect(checker.accessibilityQueryCount == 1)
        #expect(checker.inputMonitoringQueryCount == 1)
        #expect(snapshot.accessibilityGranted == true)
        #expect(snapshot.inputMonitoringGranted == false)
    }

    @Test("a fresh construction re-queries — the 'once' guarantee is per-instance, not global")
    func freshConstructionReQueries() {
        let checker = FakePermissionsChecker()

        _ = PermissionsSnapshot(checker: checker)
        _ = PermissionsSnapshot(checker: checker)

        #expect(checker.accessibilityQueryCount == 2)
        #expect(checker.inputMonitoringQueryCount == 2)
    }
}
