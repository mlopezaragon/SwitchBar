import Testing
@testable import SwitchBarCore

@Test
func reescribirClaudeJsonNoSeConfundeConLogin() {
    var tracker = ActiveIdentityTracker(accountUuid: "cuenta-a")

    #expect(
        tracker.observe(
            accountUuid: "cuenta-a",
            expectedAppAccountUuid: nil
        ) == .unchanged
    )
}

@Test
func unCambioRealDistingueSuOrigen() {
    var manual = ActiveIdentityTracker(accountUuid: "cuenta-a")
    #expect(
        manual.observe(
            accountUuid: "cuenta-b",
            expectedAppAccountUuid: nil
        ) == .manual
    )

    var app = ActiveIdentityTracker(accountUuid: "cuenta-a")
    #expect(
        app.observe(
            accountUuid: "cuenta-b",
            expectedAppAccountUuid: "cuenta-b"
        ) == .appInitiated
    )
}
