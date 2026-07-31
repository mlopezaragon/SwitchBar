import Foundation
import Testing
@testable import SwitchBarCore

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

@Test func semanalGeneralDisparaAunqueCincoHorasEsteBajo() {
    let decision = politica.decision(
        active: estado("a", fiveHour: 20, sevenDay: 98, opus: 10),
        all: [
            estado("a", fiveHour: 20, sevenDay: 98, opus: 10),
            estado("b", fiveHour: 30, sevenDay: 20, opus: 20)
        ]
    )
    #expect(decision == "b")
}

@Test func fableDisparaIndependientementeDelSemanalGeneral() {
    let conFable = AutoSwitchPolicy(considersFable: true)
    let decision = conFable.decision(
        active: estado("a", fiveHour: 20, sevenDay: 10, opus: 98),
        all: [
            estado("a", fiveHour: 20, sevenDay: 10, opus: 98),
            estado("b", fiveHour: 30, sevenDay: 20, opus: 20)
        ]
    )
    #expect(decision == "b")
}

@Test func descartaCuentasConSemanalAgotado() {
    let decision = politica.decision(
        active: estado("a", fiveHour: 95),
        all: [estado("b", fiveHour: 5, sevenDay: 96), estado("c", fiveHour: 50, sevenDay: 20)]
    )
    #expect(decision == "c")
}

@Test func descartaCuentasConOpusAgotado() {
    let conFable = AutoSwitchPolicy(considersFable: true)
    let decision = conFable.decision(
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

@Test func fableNuloCuentaComoMargenCompletoCuandoEstaActivado() {
    // Sin ventana de Opus, ese término aporta margen completo.
    let conFable = AutoSwitchPolicy(considersFable: true)
    let decision = conFable.decision(
        active: estado("a", fiveHour: 95),
        all: [estado("b", fiveHour: 20, sevenDay: 50, opus: 90), estado("c", fiveHour: 20, sevenDay: 50, opus: nil)]
    )
    #expect(decision == "c")
}

@Test func umbralPersonalizadoSeRespeta() {
    let estricta = AutoSwitchPolicy(
        triggerThreshold: 50,
        weeklyThreshold: 80,
        fableThreshold: 70,
        considersFable: true
    )
    #expect(estricta.decision(active: estado("a", fiveHour: 55), all: [estado("b", fiveHour: 10)]) == "b")
    #expect(estricta.decision(active: estado("a", fiveHour: 45), all: [estado("b", fiveHour: 10)]) == nil)
    #expect(
        estricta.decision(
            active: estado("a", fiveHour: 10, sevenDay: 81, opus: 10),
            all: [estado("b", fiveHour: 10)]
        ) == "b"
    )
    #expect(
        estricta.decision(
            active: estado("a", fiveHour: 10, sevenDay: 10, opus: 71),
            all: [estado("b", fiveHour: 10)]
        ) == "b"
    )
}

@Test func umbralesSemanalYFableSonIndependientesAlElegirDestino() {
    let separada = AutoSwitchPolicy(
        triggerThreshold: 90,
        weeklyThreshold: 80,
        fableThreshold: 60,
        considersFable: true
    )
    let active = estado("a", fiveHour: 95)

    #expect(
        separada.decision(
            active: active,
            all: [
                estado("b", fiveHour: 5, sevenDay: 81, opus: 10),
                estado("c", fiveHour: 20, sevenDay: 10, opus: 20)
            ]
        ) == "c"
    )
    #expect(
        separada.decision(
            active: active,
            all: [
                estado("b", fiveHour: 5, sevenDay: 10, opus: 61),
                estado("c", fiveHour: 20, sevenDay: 10, opus: 20)
            ]
        ) == "c"
    )
}

@Test func fableAlCienNoDisparaCuandoEstaDesactivado() {
    let sinFable = AutoSwitchPolicy(considersFable: false)
    let active = estado("a", fiveHour: 20, sevenDay: 10, opus: 100)
    #expect(sinFable.shouldSwitch(active: active) == false)
    #expect(
        sinFable.decision(
            active: active,
            all: [active, estado("b", fiveHour: 10)]
        ) == nil
    )
}

@Test func cuentaConFableAgotadoSigueSiendoCandidataCuandoSeIgnora() {
    let sinFable = AutoSwitchPolicy(considersFable: false)
    let candidate = estado(
        "b",
        fiveHour: 10,
        sevenDay: 20,
        opus: 100
    )
    #expect(sinFable.isCandidate(candidate))
    #expect(
        sinFable.decision(
            active: estado("a", fiveHour: 95),
            all: [candidate]
        ) == "b"
    )
}

@Test func distingueElMotivoPorElQueSeDescartaUnaCuenta() {
    #expect(
        politica.rejection(for: estado("a", fiveHour: 10, needsLogin: true))
            == .needsLogin
    )
    #expect(
        politica.rejection(for: estado("b", fiveHour: nil, sinDatos: true))
            == .noUsageData
    )
    #expect(politica.rejection(for: estado("c", fiveHour: 95)) == .atLimit)
    #expect(
        politica.rejection(for: estado("d", fiveHour: 10, sevenDay: 99))
            == .atLimit
    )
    #expect(politica.rejection(for: estado("e", fiveHour: 10)) == nil)
}

@Test func unaCuentaEnReposoSinVentanaDeCincoHorasSigueSiendoCandidata() {
    // Sin sesión abierta (o con la ventana ya reiniciada) el endpoint no
    // devuelve tramo de 5 h: eso es consumo cero, no un dato desconocido.
    let enReposo = estado("b", fiveHour: nil, sevenDay: 40)
    #expect(politica.rejection(for: enReposo) == nil)
    #expect(
        politica.decision(active: estado("a", fiveHour: 95), all: [enReposo])
            == "b"
    )
}

@Test func laCuentaEnReposoGanaALaQueYaTieneConsumoDeCincoHoras() {
    let decision = politica.decision(
        active: estado("a", fiveHour: 95),
        all: [estado("b", fiveHour: 20), estado("c", fiveHour: nil, sevenDay: 30)]
    )
    #expect(decision == "c")
}

@Test func fableNoInfluyeEnElMargenCuandoEstaDesactivado() {
    let sinFable = AutoSwitchPolicy(considersFable: false)
    let agotado = estado("a", fiveHour: 20, sevenDay: 40, opus: 100)
    let libre = estado("b", fiveHour: 20, sevenDay: 40, opus: 0)
    #expect(sinFable.weeklyMargin(agotado) == sinFable.weeklyMargin(libre))

    let conFable = AutoSwitchPolicy(considersFable: true)
    #expect(conFable.weeklyMargin(agotado) < conFable.weeklyMargin(libre))
}
