import Testing
@testable import SwitchBarCore

@Test
func reescribirClaudeJsonNoSeConfundeConLogin() {
    var tracker = ActiveIdentityTracker(profileID: "cuenta-a")

    #expect(
        tracker.observe(
            profileID: "cuenta-a",
            expectedAppProfileID: nil
        ) == .unchanged
    )
}

@Test
func unCambioRealDistingueSuOrigen() {
    var manual = ActiveIdentityTracker(profileID: "cuenta-a")
    #expect(
        manual.observe(
            profileID: "cuenta-b",
            expectedAppProfileID: nil
        ) == .manual
    )

    var app = ActiveIdentityTracker(profileID: "cuenta-a")
    #expect(
        app.observe(
            profileID: "cuenta-b",
            expectedAppProfileID: "cuenta-b"
        ) == .appInitiated
    )
}
