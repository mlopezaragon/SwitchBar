import Foundation
import Testing
@testable import SwitchBarCore

private func estado(_ uuid: String, fiveHour: Double?, sevenDay: Double? = 0, opus: Double? = nil, needsLogin: Bool = false, sinDatos: Bool = false) -> AccountUsageState {
    if sinDatos { return AccountUsageState(id: uuid, usage: nil, needsLogin: needsLogin) }
    let snapshot = UsageSnapshot(
        fiveHour: fiveHour.map { UsageWindow(utilization: $0, resetsAt: nil) },
        sevenDay: sevenDay.map { UsageWindow(utilization: $0, resetsAt: nil) },
        sevenDayOpus: opus.map { UsageWindow(utilization: $0, resetsAt: nil) },
        fetchedAt: Date()
    )
    return AccountUsageState(id: uuid, usage: snapshot, needsLogin: needsLogin)
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

// MARK: - Reinicio semanal

private let ahora = Date(timeIntervalSince1970: 1_800_000_000)

private func horas(_ h: Double) -> Date {
    ahora.addingTimeInterval(h * 3_600)
}

private func cuenta(
    _ uuid: String,
    fiveHour: Double? = 0,
    sevenDay: Double? = 0,
    semanaEn: Double? = nil,
    opus: Double? = nil,
    fableEn: Double? = nil,
    semanaNoInformada: Bool = false
) -> AccountUsageState {
    let snapshot = UsageSnapshot(
        fiveHour: fiveHour.map { UsageWindow(utilization: $0, resetsAt: nil) },
        sevenDay: sevenDay.map { UsageWindow(utilization: $0, resetsAt: semanaEn.map(horas)) },
        sevenDayOpus: opus.map { UsageWindow(utilization: $0, resetsAt: fableEn.map(horas)) },
        fetchedAt: ahora,
        weeklyLimitUnreported: semanaNoInformada
    )
    return AccountUsageState(id: uuid, usage: snapshot, needsLogin: false)
}

private let agotada = cuenta("a", fiveHour: 95, sevenDay: 40, semanaEn: 120)

@Test func eligeLaCuentaCuyaSemanaSeReiniciaAntes() {
    // b tiene más uso de 5 h, pero su cupo semanal caduca en un día;
    // el de c dura cinco y puede esperar.
    let decision = politica.decision(
        active: agotada,
        all: [
            cuenta("b", fiveHour: 40, sevenDay: 50, semanaEn: 24),
            cuenta("c", fiveHour: 0, sevenDay: 10, semanaEn: 120)
        ],
        now: ahora
    )
    #expect(decision == "b")
}

@Test func reiniciosCercanosSeDesempatanPorElUsoDeCincoHoras() {
    let decision = politica.decision(
        active: agotada,
        all: [
            cuenta("b", fiveHour: 40, sevenDay: 50, semanaEn: 24),
            cuenta("c", fiveHour: 10, sevenDay: 50, semanaEn: 26)
        ],
        now: ahora
    )
    #expect(decision == "c")
}

@Test func unaSemanaSinEmpezarSeGuardaParaDespues() {
    // Sin fecha de reinicio la semana aún no corre: su cupo no caduca.
    let decision = politica.decision(
        active: agotada,
        all: [
            cuenta("b", fiveHour: 0, sevenDay: 0),
            cuenta("c", fiveHour: 30, sevenDay: 60, semanaEn: 100)
        ],
        now: ahora
    )
    #expect(decision == "c")
}

@Test func unaCuentaCasiEnElUmbralSoloEsUltimoRecurso() {
    // b caduca antes, pero con 3 puntos de margen habría que volver a
    // cambiar enseguida.
    let apretada = cuenta("b", fiveHour: 10, sevenDay: 92, semanaEn: 12)
    let holgada = cuenta("c", fiveHour: 20, sevenDay: 30, semanaEn: 140)
    #expect(politica.decision(active: agotada, all: [apretada, holgada], now: ahora) == "c")
    #expect(politica.decision(active: agotada, all: [apretada], now: ahora) == "b")
}

@Test func laCuentaQueYaAlcanzoSuLimiteNuncaSeElige() {
    // Por mucho que caduque en una hora, una semana al 96 % ya pasó el
    // umbral del 95 %.
    let decision = politica.decision(
        active: agotada,
        all: [
            cuenta("b", fiveHour: 0, sevenDay: 96, semanaEn: 1),
            cuenta("c", fiveHour: 50, sevenDay: 20, semanaEn: 150)
        ],
        now: ahora
    )
    #expect(decision == "c")
}

@Test func elTopePersonalCuentaComoLimiteAlElegir() {
    // Un 70 % real con un tope del 65 % es un 100 % propio.
    let compartida = cuenta("b", fiveHour: 10, sevenDay: 70, semanaEn: 10)
    let escalada = AccountUsageState(
        id: "b",
        usage: compartida.usage?.scaledToPersonalCaps(fiveHourCap: nil, weeklyCap: 65),
        needsLogin: false
    )
    #expect(politica.rejection(for: escalada) == .atLimit)
    let decision = politica.decision(
        active: agotada,
        all: [escalada, cuenta("c", fiveHour: 0, sevenDay: 20, semanaEn: 150)],
        now: ahora
    )
    #expect(decision == "c")
}

@Test func enTeamElReinicioDeFableEstimaElDeLaSemana() {
    let team = cuenta("b", fiveHour: 30, sevenDay: nil, opus: 0, fableEn: 20, semanaNoInformada: true)
    let max = cuenta("c", fiveHour: 0, sevenDay: 20, semanaEn: 100)
    #expect(politica.decision(active: agotada, all: [team, max], now: ahora) == "b")
}

// MARK: - Adelantarse al cupo que caduca

private let anticipa = AutoSwitchPolicy(anticipatesExpiringQuota: true)
private let activaHolgada = cuenta("a", fiveHour: 30, sevenDay: 40, semanaEn: 100)

@Test func seAdelantaAUnCupoSemanalQueVaAPerderse() {
    let caduca = cuenta("b", fiveHour: 0, sevenDay: 60, semanaEn: 10)
    #expect(anticipa.expiringQuotaTarget(active: activaHolgada, all: [activaHolgada, caduca], now: ahora) == "b")
}

@Test func sinActivarNoSeAdelanta() {
    let caduca = cuenta("b", fiveHour: 0, sevenDay: 60, semanaEn: 10)
    #expect(politica.expiringQuotaTarget(active: activaHolgada, all: [caduca], now: ahora) == nil)
}

@Test func noSeAdelantaPorPocoMargenNiPorUnReinicioLejano() {
    let pocoMargen = cuenta("b", fiveHour: 0, sevenDay: 88, semanaEn: 10)
    let lejana = cuenta("c", fiveHour: 0, sevenDay: 10, semanaEn: 30)
    #expect(anticipa.expiringQuotaTarget(active: activaHolgada, all: [pocoMargen, lejana], now: ahora) == nil)
}

@Test func noSeAdelantaSiLaActivaCaducaAntesOCasiALaVez() {
    let caduca = cuenta("b", fiveHour: 0, sevenDay: 30, semanaEn: 10)
    let activaAntes = cuenta("a", fiveHour: 30, sevenDay: 40, semanaEn: 8)
    let activaCasiIgual = cuenta("a", fiveHour: 30, sevenDay: 40, semanaEn: 14)
    #expect(anticipa.expiringQuotaTarget(active: activaAntes, all: [caduca], now: ahora) == nil)
    #expect(anticipa.expiringQuotaTarget(active: activaCasiIgual, all: [caduca], now: ahora) == nil)
}

@Test func noSeAdelantaAUnaCuentaSinMargenDeCincoHorasOEnSuLimite() {
    let sinCincoHoras = cuenta("b", fiveHour: 88, sevenDay: 30, semanaEn: 10)
    let conFable = AutoSwitchPolicy(considersFable: true, anticipatesExpiringQuota: true)
    let fableAgotado = cuenta("c", fiveHour: 0, sevenDay: 30, semanaEn: 10, opus: 97, fableEn: 10)
    #expect(anticipa.expiringQuotaTarget(active: activaHolgada, all: [sinCincoHoras], now: ahora) == nil)
    #expect(conFable.expiringQuotaTarget(active: activaHolgada, all: [fableAgotado], now: ahora) == nil)
}

@Test func noSeAdelantaAUnaSemanaQueNoSeInforma() {
    // Team: no se sabe cuánto le queda, así que no se puede afirmar que
    // vaya a perderse nada.
    let team = cuenta("b", fiveHour: 0, sevenDay: nil, opus: 0, fableEn: 10, semanaNoInformada: true)
    #expect(anticipa.expiringQuotaTarget(active: activaHolgada, all: [team], now: ahora) == nil)
}

@Test func conLaActivaEnUnLimiteMandaElCambioOrdinario() {
    let caduca = cuenta("b", fiveHour: 0, sevenDay: 30, semanaEn: 10)
    #expect(anticipa.expiringQuotaTarget(active: agotada, all: [caduca], now: ahora) == nil)
    #expect(anticipa.decision(active: agotada, all: [caduca], now: ahora) == "b")
}

@Test func entreVariasQueCaducanSeEligeLaPrimera() {
    let antes = cuenta("b", fiveHour: 20, sevenDay: 50, semanaEn: 4)
    let despues = cuenta("c", fiveHour: 0, sevenDay: 20, semanaEn: 20)
    #expect(anticipa.expiringQuotaTarget(active: activaHolgada, all: [despues, antes], now: ahora) == "b")
}
