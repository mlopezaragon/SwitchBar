import Testing
@testable import SwitchBarCore

@Test
func elSondeoEmpiezaPorLaActivaYReparteElResto() {
    var planner = UsageRefreshPlanner()
    let accounts = ["a", "b", "c", "d"]

    #expect(
        planner.nextAccount(
            accountUuids: accounts,
            activeAccountUuid: "c",
            blockedAccountUuids: []
        ) == "c"
    )
    #expect(
        planner.nextAccount(
            accountUuids: accounts,
            activeAccountUuid: "c",
            blockedAccountUuids: []
        ) == "a"
    )
    #expect(
        planner.nextAccount(
            accountUuids: accounts,
            activeAccountUuid: "c",
            blockedAccountUuids: []
        ) == "b"
    )
    #expect(
        planner.nextAccount(
            accountUuids: accounts,
            activeAccountUuid: "c",
            blockedAccountUuids: []
        ) == "d"
    )
}

@Test
func elSondeoSaltaCuentasEnEspera() {
    var planner = UsageRefreshPlanner()

    #expect(
        planner.nextAccount(
            accountUuids: ["a", "b", "c"],
            activeAccountUuid: "a",
            blockedAccountUuids: ["a", "b"]
        ) == "c"
    )
    #expect(
        planner.nextAccount(
            accountUuids: ["a", "b", "c"],
            activeAccountUuid: "a",
            blockedAccountUuids: ["a", "b", "c"]
        ) == nil
    )
}

@Test
func unTurnoDevueltoSeVuelveAServirEnLaSiguienteVuelta() {
    var planner = UsageRefreshPlanner()
    let accounts = ["a", "b", "c"]

    #expect(
        planner.nextAccount(
            accountUuids: accounts,
            activeAccountUuid: "a",
            blockedAccountUuids: []
        ) == "a"
    )
    let cursorAntes = planner.cursor
    #expect(
        planner.nextAccount(
            accountUuids: accounts,
            activeAccountUuid: "a",
            blockedAccountUuids: []
        ) == "b"
    )
    // «b» no llegó a consultarse: al devolver el turno vuelve a ser la
    // siguiente, en lugar de esperar una vuelta entera.
    planner.rewind(to: cursorAntes)
    #expect(
        planner.nextAccount(
            accountUuids: accounts,
            activeAccountUuid: "a",
            blockedAccountUuids: []
        ) == "b"
    )
}

@Test
func elIntervaloCompletoSeDistribuyeSinRafagas() {
    #expect(
        UsageRefreshPlanner.spacing(
            fullCycleInterval: 180,
            accountCount: 4
        ) == 45
    )
    #expect(
        UsageRefreshPlanner.spacing(
            fullCycleInterval: 180,
            accountCount: 1
        ) == 180
    )
    #expect(
        UsageRefreshPlanner.spacing(
            fullCycleInterval: 60,
            accountCount: 4
        ) == 30
    )
}
