import Foundation
import Testing
@testable import ClaudeSwitchCore

private func estado(_ uuid: String, fiveHour: Double?, sevenDay: Double? = 0, opus: Double? = nil, needsLogin: Bool = false, sinDatos: Bool = false) -> AccountUsageState {
    if sinDatos { return AccountUsageState(accountUuid: uuid, usage: nil, needsLogin: needsLogin) }
    let snapshot = UsageSnapshot(
        fiveHour: fiveHour.map { UsageWindow(utilization: $0, resetsAt: nil) },
        sevenDay: sevenDay.map { UsageWindow(utilization: $0, resetsAt: nil) },
        sevenDayOpus: opus.map { UsageWindow(utilization: $0, resetsAt: nil) },
        fetchedAt: Date()
    )
    return AccountUsageState(accountUuid: uuid, usage: snapshot, needsLogin: needsLogin)
}

private let politica = AutoSwitchPolicy()

@Test func noDisparaBajoElUmbral() {
    #expect(politica.decision(active: estado("a", fiveHour: 89.9), all: [estado("b", fiveHour: 0)]) == nil)
}

@Test func noDisparaSinDatosDeUso() {
    #expect(politica.decision(active: estado("a", fiveHour: nil, sinDatos: true), all: [estado("b", fiveHour: 0)]) == nil)
}

@Test func disparaYEligeLaDeMenorUsoDe5h() {
    let decision = politica.decision(
        active: estado("a", fiveHour: 95),
        all: [estado("a", fiveHour: 95), estado("b", fiveHour: 40), estado("c", fiveHour: 10)]
    )
    #expect(decision == "c")
}

@Test func descartaCuentasConSemanalAgotado() {
    let decision = politica.decision(
        active: estado("a", fiveHour: 95),
        all: [estado("b", fiveHour: 5, sevenDay: 96), estado("c", fiveHour: 50, sevenDay: 20)]
    )
    #expect(decision == "c")
}

@Test func descartaCuentasConOpusAgotado() {
    let decision = politica.decision(
        active: estado("a", fiveHour: 95),
        all: [estado("b", fiveHour: 5, opus: 97), estado("c", fiveHour: 50, opus: 10)]
    )
    #expect(decision == "c")
}

@Test func descartaCuentasSinSesionOSinDatos() {
    let decision = politica.decision(
        active: estado("a", fiveHour: 95),
        all: [estado("b", fiveHour: 5, needsLogin: true), estado("c", fiveHour: nil, sinDatos: true), estado("d", fiveHour: 30)]
    )
    #expect(decision == "d")
}

@Test func sinCandidatasDevuelveNil() {
    let decision = politica.decision(
        active: estado("a", fiveHour: 95),
        all: [estado("b", fiveHour: 92), estado("c", fiveHour: 10, sevenDay: 99)]
    )
    #expect(decision == nil)
}

@Test func empateEn5hSeResuelvePorMargenSemanal() {
    // b y c empatan en 5 h; c tiene más margen semanal ponderado.
    let decision = politica.decision(
        active: estado("a", fiveHour: 95),
        all: [estado("b", fiveHour: 20, sevenDay: 80, opus: 50), estado("c", fiveHour: 20, sevenDay: 10, opus: 5)]
    )
    #expect(decision == "c")
}

@Test func opusNuloCuentaComoMargenCompleto() {
    // Sin ventana de Opus, ese término aporta margen completo.
    let decision = politica.decision(
        active: estado("a", fiveHour: 95),
        all: [estado("b", fiveHour: 20, sevenDay: 50, opus: 90), estado("c", fiveHour: 20, sevenDay: 50, opus: nil)]
    )
    #expect(decision == "c")
}

@Test func umbralPersonalizadoSeRespeta() {
    let estricta = AutoSwitchPolicy(triggerThreshold: 50, weeklyCeiling: 95)
    #expect(estricta.decision(active: estado("a", fiveHour: 55), all: [estado("b", fiveHour: 10)]) == "b")
    #expect(estricta.decision(active: estado("a", fiveHour: 45), all: [estado("b", fiveHour: 10)]) == nil)
}
