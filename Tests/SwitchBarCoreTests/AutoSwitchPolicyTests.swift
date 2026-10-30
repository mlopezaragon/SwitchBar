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
        ]
    )
    #expect(decision == "b")
}

@Test func unaTeamVaAntesQueUnaSemanaQueSeVaAPerder() {
    // La Max se reinicia en 4 h con el 75 % de su semana por gastar, pero
    // las Team van siempre antes: su ventana vuelve a llenarse sin gastar
    // semana.
    let team = cuenta("b", fiveHour: 0, sevenDay: nil, opus: 0, fableEn: 3, semanaNoInformada: true)
    let max = cuenta("c", fiveHour: 0, sevenDay: 20, semanaEn: 4)
    #expect(politica.urgency(max, now: ahora) == .weekAtRisk)
    #expect(politica.decision(active: agotada, all: [team, max], now: ahora) == "b")
    // Sin Team con margen, la semana que se va a perder va antes que la que
    // puede esperar.
    let reserva = cuenta("d", fiveHour: 0, sevenDay: 20, semanaEn: 100)
    #expect(politica.decision(active: agotada, all: [reserva, max], now: ahora) == "c")
}

@Test func elMismoReinicioSeDesempataPorElUsoDeCincoHoras() {
    let decision = politica.decision(
        active: agotada,
        all: [
            cuenta("b", fiveHour: 40, sevenDay: 50, semanaEn: 24),
            cuenta("c", fiveHour: 10, sevenDay: 50, semanaEn: 24)
        ]
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
        ]
    )
    #expect(decision == "c")
}

@Test func unaCuentaCasiEnElUmbralSoloEsUltimoRecurso() {
    // b caduca antes, pero con 3 puntos de margen habría que volver a
    // cambiar enseguida.
    let apretada = cuenta("b", fiveHour: 10, sevenDay: 92, semanaEn: 12)
    let holgada = cuenta("c", fiveHour: 20, sevenDay: 30, semanaEn: 140)
    #expect(politica.decision(active: agotada, all: [apretada, holgada]) == "c")
    #expect(politica.decision(active: agotada, all: [apretada]) == "b")
}

@Test func laCuentaQueYaAlcanzoSuLimiteNuncaSeElige() {
    // Por mucho que caduque en una hora, una semana al 96 % ya pasó el
    // umbral del 95 %.
    let decision = politica.decision(
        active: agotada,
        all: [
            cuenta("b", fiveHour: 0, sevenDay: 96, semanaEn: 1),
            cuenta("c", fiveHour: 50, sevenDay: 20, semanaEn: 150)
        ]
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
        all: [escalada, cuenta("c", fiveHour: 0, sevenDay: 20, semanaEn: 150)]
    )
    #expect(decision == "c")
}

@Test func unaTeamVaAntesQueUnaMaxCuyaSemanaNoCorrePeligro() {
    // La semana de la Max puede esperar: se guarda para cuando haga falta.
    // Que el reinicio de Fable de la Team llegue después no cuenta: lo que
    // limita a la Team es su ventana de 5 h.
    let team = cuenta("b", fiveHour: 30, sevenDay: nil, opus: 0, fableEn: 200, semanaNoInformada: true)
    let max = cuenta("c", fiveHour: 0, sevenDay: 20, semanaEn: 100)
    #expect(politica.decision(active: agotada, all: [max, team], now: ahora) == "b")
}

// MARK: - Gestión autónoma

private let autonoma = AutoSwitchPolicy(anticipatesExpiringQuota: true)
private let activaHolgada = cuenta("a", fiveHour: 30, sevenDay: 40, semanaEn: 100)

@Test func cambiaSinEsperarALaCuentaQueCaducaAntes() {
    let caduca = cuenta("b", fiveHour: 0, sevenDay: 60, semanaEn: 10)
    #expect(autonoma.expiringQuotaTarget(active: activaHolgada, all: [activaHolgada, caduca], now: ahora) == "b")
}

@Test func sinActivarNoSeAdelanta() {
    let caduca = cuenta("b", fiveHour: 0, sevenDay: 60, semanaEn: 10)
    #expect(politica.expiringQuotaTarget(active: activaHolgada, all: [caduca], now: ahora) == nil)
}

@Test func enModoAutonomoUnaMaxCedeAnteUnaTeamConMargen() {
    let max = cuenta("a", fiveHour: 20, sevenDay: 50, semanaEn: 100)
    let team = cuenta("b", fiveHour: 0, sevenDay: nil, opus: 0, fableEn: 150, semanaNoInformada: true)
    #expect(autonoma.expiringQuotaTarget(active: max, all: [max, team], now: ahora) == "b")
    // Y desde la Team no se vuelve a la Max mientras la Team tenga margen.
    #expect(autonoma.expiringQuotaTarget(active: team, all: [max, team], now: ahora) == nil)
}

@Test func enModoAutonomoSeVuelveALaTeamEnCuantoRecuperaMargen() {
    // La Max se reinicia en 4 h con media semana por gastar; aun así, una
    // Team con margen va antes, y desde ella no se vuelve a la Max.
    let max = cuenta("a", fiveHour: 20, sevenDay: 50, semanaEn: 4)
    let team = cuenta("b", fiveHour: 0, sevenDay: nil, opus: 0, fableEn: 3, semanaNoInformada: true)
    #expect(autonoma.expiringQuotaTarget(active: max, all: [max, team], now: ahora) == "b")
    #expect(autonoma.expiringQuotaTarget(active: team, all: [max, team], now: ahora) == nil)
    // Una Team todavía en su umbral no saca a nadie de la Max.
    let agotadaTeam = cuenta("c", fiveHour: 92, sevenDay: nil, opus: 0, fableEn: 3, semanaNoInformada: true)
    #expect(autonoma.expiringQuotaTarget(active: max, all: [max, agotadaTeam], now: ahora) == nil)
}

@Test func noSeAdelantaPorUnReinicioCasiSimultaneo() {
    let caduca = cuenta("b", fiveHour: 0, sevenDay: 30, semanaEn: 10)
    let activaAntes = cuenta("a", fiveHour: 30, sevenDay: 40, semanaEn: 8)
    let activaCasiIgual = cuenta("a", fiveHour: 30, sevenDay: 40, semanaEn: 10.25)
    #expect(autonoma.expiringQuotaTarget(active: activaAntes, all: [caduca], now: ahora) == nil)
    #expect(autonoma.expiringQuotaTarget(active: activaCasiIgual, all: [caduca], now: ahora) == nil)
}

@Test func noSeAdelantaAUnaCuentaConPocoMargen() {
    // Con 10 puntos de margen se gastaría enseguida: no compensa moverse.
    let pocoMargenSemanal = cuenta("b", fiveHour: 0, sevenDay: 85, semanaEn: 10)
    let pocoMargenCincoHoras = cuenta("c", fiveHour: 80, sevenDay: 30, semanaEn: 10)
    #expect(
        autonoma.expiringQuotaTarget(
            active: activaHolgada, all: [pocoMargenSemanal, pocoMargenCincoHoras], now: ahora
        ) == nil
    )
}

@Test func noSeAdelantaAUnaCuentaEnSuLimite() {
    let conFable = AutoSwitchPolicy(considersFable: true, anticipatesExpiringQuota: true)
    let fableAgotado = cuenta("c", fiveHour: 0, sevenDay: 30, semanaEn: 10, opus: 97, fableEn: 10)
    let semanaAgotada = cuenta("d", fiveHour: 0, sevenDay: 96, semanaEn: 2)
    #expect(conFable.expiringQuotaTarget(active: activaHolgada, all: [fableAgotado, semanaAgotada], now: ahora) == nil)
}

@Test func unaActivaSinSemanaEmpezadaCedeAnteCualquierCupoQueCaduque() {
    let activa = cuenta("a", fiveHour: 10, sevenDay: 0)
    let caduca = cuenta("b", fiveHour: 0, sevenDay: 50, semanaEn: 150)
    #expect(autonoma.expiringQuotaTarget(active: activa, all: [caduca], now: ahora) == "b")
}

@Test func conLaActivaEnUnLimiteMandaElCambioOrdinario() {
    let caduca = cuenta("b", fiveHour: 0, sevenDay: 30, semanaEn: 10)
    #expect(autonoma.expiringQuotaTarget(active: agotada, all: [caduca], now: ahora) == nil)
    #expect(autonoma.decision(active: agotada, all: [caduca]) == "b")
}

@Test func entreVariasQueCaducanSeEligeLaPrimera() {
    let antes = cuenta("b", fiveHour: 20, sevenDay: 50, semanaEn: 4)
    let despues = cuenta("c", fiveHour: 0, sevenDay: 20, semanaEn: 20)
    #expect(autonoma.expiringQuotaTarget(active: activaHolgada, all: [despues, antes], now: ahora) == "b")
}

@Test func unaCuentaQueElUsuarioAbandonoQuedaParaElFinal() {
    var abandonada = cuenta("b", fiveHour: 0, sevenDay: nil, opus: 0, fableEn: 3, semanaNoInformada: true)
    abandonada.leftByUser = true
    let otra = cuenta("c", fiveHour: 0, sevenDay: 20, semanaEn: 100)
    // El modo autónomo no vuelve a ella por su cuenta...
    #expect(autonoma.expiringQuotaTarget(active: activaHolgada, all: [abandonada, otra], now: ahora) == nil)
    // ...al cambiar por un límite va detrás de las demás...
    #expect(politica.decision(active: agotada, all: [abandonada, otra]) == "c")
    // ...y solo se usa si no queda otra.
    #expect(politica.decision(active: agotada, all: [abandonada]) == "b")
}

// MARK: - Ritmo de uso

private let conRitmo = AutoSwitchPolicy(switchesByPace: true)

/// Duraciones calculadas con coma flotante: un segundo de margen.
private func cerca(_ valor: TimeInterval?, _ esperado: TimeInterval) -> Bool {
    valor.map { abs($0 - esperado) < 1 } ?? false
}

/// Cuenta con su ventana de 5 h reiniciándose en `cincoEn` horas (si la hay)
/// y el ritmo al que se gastaría si se usara ahora.
private func medida(
    _ uuid: String,
    fiveHour: Double? = 0,
    cincoEn: Double? = nil,
    sevenDay: Double? = nil,
    semanaEn: Double? = nil,
    opus: Double? = nil,
    fableEn: Double? = nil,
    ritmo: Double? = nil,
    ritmoAlto: Double? = nil,
    semanaPorPunto: Double? = nil
) -> AccountUsageState {
    let snapshot = UsageSnapshot(
        fiveHour: fiveHour.map { UsageWindow(utilization: $0, resetsAt: cincoEn.map(horas)) },
        sevenDay: sevenDay.map { UsageWindow(utilization: $0, resetsAt: semanaEn.map(horas)) },
        sevenDayOpus: opus.map { UsageWindow(utilization: $0, resetsAt: fableEn.map(horas)) },
        fetchedAt: ahora,
        weeklyLimitUnreported: sevenDay == nil
    )
    return AccountUsageState(
        id: uuid,
        usage: snapshot,
        needsLogin: false,
        fiveHourPace: ritmo,
        fiveHourPaceUpper: ritmoAlto,
        weeklyPerFiveHour: semanaPorPunto
    )
}

@Test func alRitmoActualCambiaAntesDeQueLaSesionSeCorte() {
    // Al 75 % gastando 90 puntos/h: se agotaría en menos de 17 minutos.
    let deprisa = medida("a", fiveHour: 75, cincoEn: 3, ritmoAlto: 90)
    #expect(conRitmo.shouldSwitch(active: deprisa))
    #expect(conRitmo.paceRequiresSwitch(deprisa))
    #expect(!conRitmo.reachedThreshold(deprisa))
    // Sin la opción, manda solo el umbral.
    #expect(!politica.shouldSwitch(active: deprisa))
}

@Test func gastandoDespacioNoSeCambiaAntesDeTiempo() {
    // Al 85 % gastando 20 puntos/h quedan 45 minutos: aún no hace falta.
    let despacio = medida("a", fiveHour: 85, cincoEn: 3, ritmoAlto: 20)
    #expect(!conRitmo.shouldSwitch(active: despacio))
    // El umbral configurado sigue mandando aunque el ritmo sea lento.
    let enUmbral = medida("a", fiveHour: 91, cincoEn: 3, ritmoAlto: 1)
    #expect(conRitmo.shouldSwitch(active: enUmbral))
}

@Test func unaRafagaNoSacaDeUnaCuentaCasiVacia() {
    // Al 40 % no se cambia por ritmo, por rápido que se gaste ahora.
    let rafaga = medida("a", fiveHour: 40, cincoEn: 4, ritmoAlto: 400)
    #expect(!conRitmo.shouldSwitch(active: rafaga))
}

@Test func laAutonomiaCuentaConElReinicioDeLaVentana() {
    // 40 puntos a 30 por hora: 80 minutos.
    let sinReinicioCercano = medida("b", fiveHour: 60, cincoEn: 4, ritmo: 30)
    #expect(cerca(conRitmo.runway(sinReinicioCercano, now: ahora), 80 * 60))
    // Se reinicia en 30 minutos, antes de agotarse: sigue con una ventana
    // nueva, que a 30 por hora dura 200 minutos.
    let reiniciaPronto = medida("c", fiveHour: 60, cincoEn: 0.5, ritmo: 30)
    #expect(cerca(conRitmo.runway(reiniciaPronto, now: ahora), 230 * 60))
    // Tan despacio que ninguna ventana llegaría a agotarse.
    let lenta = medida("d", fiveHour: 60, cincoEn: 0.5, ritmo: 10)
    #expect(conRitmo.runway(lenta, now: ahora) == AutoSwitchPolicy.runwayHorizon)
    // Sin la opción o sin ritmo no se estima.
    #expect(politica.runway(sinReinicioCercano, now: ahora) == nil)
    #expect(conRitmo.runway(medida("e", fiveHour: 10), now: ahora) == nil)
}

@Test func enMaxLaSemanaTambienLimitaLaAutonomia() {
    // 10 puntos de semana a 0,1 por punto de 5 h y 50 puntos/h: 2 horas,
    // aunque la ventana de 5 h esté vacía.
    let max = medida("b", fiveHour: 0, sevenDay: 90, semanaEn: 48, ritmo: 50, semanaPorPunto: 0.1)
    #expect(cerca(conRitmo.runway(max, now: ahora), 2 * 3_600))
}

@Test func unaVentanaSinAbrirSeEstrenaAntesQueGastarOtraQuePuedeEsperar() {
    // b ya tiene la ventana abierta y se reinicia en 2 h: da tiempo a
    // gastarla. Las 5 h de c no empiezan a contar hasta que se usa.
    let abierta = medida("b", fiveHour: 30, cincoEn: 2, opus: 0, fableEn: 70)
    let sinEstrenar = medida("c", fiveHour: nil, opus: 0, fableEn: 20)
    #expect(politica.decision(active: agotada, all: [sinEstrenar, abierta], now: ahora) == "c")
    // Si su reinicio está tan cerca que su margen se perdería, va antes.
    let apurada = medida("b", fiveHour: 30, cincoEn: 0.75, opus: 0, fableEn: 70)
    #expect(politica.decision(active: agotada, all: [sinEstrenar, apurada], now: ahora) == "b")
    // Sin margen útil en esa ventana, no hay nada que rescatar; y en Team
    // la semana de Fable no cuenta como cupo que caduca.
    let casiLlena = medida("d", fiveHour: 86, cincoEn: 2, opus: 0, fableEn: 70)
    #expect(politica.expiryDeadline(casiLlena, now: ahora) == nil)
}

@Test func lasVentanasAbiertasSeGastanPorOrdenDeReinicio() {
    let antes = medida("b", fiveHour: 50, cincoEn: 1, opus: 0, fableEn: 100)
    let despues = medida("c", fiveHour: 10, cincoEn: 4, opus: 0, fableEn: 30)
    #expect(politica.decision(active: agotada, all: [despues, antes], now: ahora) == "b")
}

@Test func unaVentanaTeamAbiertaVaAntesQueUnaSemanaInminente() {
    let semanaInminente = medida("b", fiveHour: nil, sevenDay: 40, semanaEn: 1)
    let ventanaAbierta = medida("c", fiveHour: 20, cincoEn: 3, opus: 0, fableEn: 90)
    #expect(politica.decision(active: agotada, all: [ventanaAbierta, semanaInminente], now: ahora) == "c")
    #expect(politica.decision(active: agotada, all: [semanaInminente], now: ahora) == "b")
}

@Test func unDestinoQueSeAgotariaEnMinutosEsUltimoRecurso() {
    // b caduca antes, pero al ritmo medido aguantaría 20 minutos.
    let corta = medida("b", fiveHour: 80, cincoEn: 0.25, opus: 0, fableEn: 10, ritmo: 60)
    let larga = medida("c", fiveHour: 0, opus: 0, fableEn: 90, ritmo: 60)
    #expect(conRitmo.decision(active: agotada, all: [corta, larga], now: ahora) == "c")
    #expect(conRitmo.decision(active: agotada, all: [corta], now: ahora) == "b")
    // Sin la opción, el orden es el de siempre.
    #expect(politica.decision(active: agotada, all: [corta, larga], now: ahora) == "b")
}

@Test func aIgualDeCaducidadGanaLaQueMasAguanta() {
    let menos = medida("b", fiveHour: nil, opus: 0, fableEn: 50, ritmo: 60)
    let mas = medida("c", fiveHour: nil, opus: 0, fableEn: 50, ritmo: 20)
    #expect(conRitmo.decision(active: agotada, all: [menos, mas], now: ahora) == "c")
}

@Test func noSeAdelantaAUnaCuentaQueAguantariaPoco() {
    let autonomaConRitmo = AutoSwitchPolicy(anticipatesExpiringQuota: true, switchesByPace: true)
    let activa = medida("a", fiveHour: 20, cincoEn: 4, sevenDay: 40, semanaEn: 100, ritmo: 30)
    // Su semana caduca antes, pero a 120 puntos/h su ventana duraría 25 minutos.
    let corta = medida("b", fiveHour: 50, cincoEn: 4, sevenDay: 30, semanaEn: 10, ritmo: 120)
    #expect(autonomaConRitmo.expiringQuotaTarget(active: activa, all: [activa, corta], now: ahora) == nil)
    let holgada = medida("c", fiveHour: 0, sevenDay: 30, semanaEn: 10, ritmo: 30)
    #expect(autonomaConRitmo.expiringQuotaTarget(active: activa, all: [activa, corta, holgada], now: ahora) == "c")
}

// MARK: - Cuentas sin límite semanal a la vista

@Test func primeroLoQueCaducaDespuesTeamYLasMaxAlFinal() {
    let teamApurada = medida("a2", fiveHour: 40, cincoEn: 0.5)
    let teamAbierta = medida("b", fiveHour: 40, cincoEn: 3)
    let teamSinAbrir = medida("c", fiveHour: nil)
    let maxHolgada = medida("d", fiveHour: 0, sevenDay: 20, semanaEn: 100, ritmo: 20, semanaPorPunto: 0.25)
    #expect(politica.urgency(teamApurada, now: ahora) == .expiring)
    #expect(politica.urgency(teamSinAbrir, now: ahora) == .renewable)
    #expect(politica.urgency(teamAbierta, now: ahora) == .open)
    #expect(politica.urgency(maxHolgada, now: ahora) == .reserve)
    let todas = [maxHolgada, teamAbierta, teamSinAbrir, teamApurada]
    #expect(politica.decision(active: agotada, all: todas, now: ahora) == "a2")
    #expect(politica.decision(active: agotada, all: [maxHolgada, teamAbierta, teamSinAbrir], now: ahora) == "c")
    #expect(politica.decision(active: agotada, all: [maxHolgada, teamAbierta], now: ahora) == "b")
    #expect(politica.decision(active: agotada, all: [maxHolgada], now: ahora) == "d")
}

@Test func unaVentanaTeamSinAbrirSeAbreEnCuantoEstaDisponible() {
    // El caso del 30 de octubre de 2026: backend con su ventana abierta
    // hasta dentro de 4 h y mlopara recién reiniciada. Las 5 h de mlopara no
    // empiezan a contar hasta que se usa: va primero, y backend después,
    // antes de su reinicio.
    let backend = medida("b", fiveHour: 40, cincoEn: 4, opus: 0, fableEn: 100, ritmo: 85)
    let mlopara = medida("m", fiveHour: 0, opus: 0, fableEn: 150, ritmo: 85)
    #expect(conRitmo.urgency(backend, now: ahora) == .open)
    #expect(conRitmo.urgency(mlopara, now: ahora) == .renewable)
    #expect(conRitmo.decision(active: agotada, all: [backend, mlopara], now: ahora) == "m")
    // El modo autónomo deja la ventana abierta que puede esperar para
    // estrenar la otra...
    let autonomaConRitmo = AutoSwitchPolicy(anticipatesExpiringQuota: true, switchesByPace: true)
    #expect(autonomaConRitmo.expiringQuotaTarget(active: backend, all: [backend, mlopara], now: ahora) == "m")
    // ...y, ya abiertas las dos, no salta de una a otra mientras den tiempo
    // a gastarse.
    let mloparaAbierta = medida("m", fiveHour: 10, cincoEn: 4.9, opus: 0, fableEn: 150, ritmo: 85)
    #expect(autonomaConRitmo.expiringQuotaTarget(active: mloparaAbierta, all: [backend, mloparaAbierta], now: ahora) == nil)
    // Cuando el margen de backend ya no daría tiempo a gastarse, vuelve a ella.
    let backendApurada = medida("b", fiveHour: 40, cincoEn: 0.5, opus: 0, fableEn: 100, ritmo: 85)
    #expect(conRitmo.urgency(backendApurada, now: ahora) == .expiring)
    #expect(autonomaConRitmo.expiringQuotaTarget(active: mloparaAbierta, all: [backendApurada, mloparaAbierta], now: ahora) == "b")
}

@Test func unaSemanaSeDaPorPerdidaSiNoDaTiempoAGastarla() {
    // 55 puntos de semana a 0,25 por punto de 5 h y 20 puntos/h: 11 horas
    // de trabajo, que trabajando la mitad del tiempo piden 22 horas.
    let lejos = medida("a", fiveHour: 0, sevenDay: 40, semanaEn: 30, ritmo: 20, semanaPorPunto: 0.25)
    let cerca = medida("b", fiveHour: 0, sevenDay: 40, semanaEn: 20, ritmo: 20, semanaPorPunto: 0.25)
    #expect(!politica.weeklyQuotaAtRisk(lejos, now: ahora))
    #expect(politica.weeklyQuotaAtRisk(cerca, now: ahora))
    // Gastar más deprisa no ayuda: la ventana de 5 h no da más de un cupo
    // entero cada cinco horas.
    let deprisa = medida("c", fiveHour: 0, sevenDay: 40, semanaEn: 30, ritmo: 80, semanaPorPunto: 0.25)
    #expect(!politica.weeklyQuotaAtRisk(deprisa, now: ahora))
    // Sin medir lo que cuesta la semana, solo cuenta el último día.
    #expect(politica.weeklyQuotaAtRisk(medida("d", fiveHour: 0, sevenDay: 40, semanaEn: 23), now: ahora))
    #expect(!politica.weeklyQuotaAtRisk(medida("e", fiveHour: 0, sevenDay: 40, semanaEn: 25), now: ahora))
    // Sin margen no hay nada que perder.
    #expect(!politica.weeklyQuotaAtRisk(medida("f", fiveHour: 0, sevenDay: 92, semanaEn: 5), now: ahora))
}

@Test func enModoAutonomoSeAprovechaLaVentanaAbiertaQueAntesCaduca() {
    let activa = medida("a", fiveHour: 30, cincoEn: 4)
    let caducaAntes = medida("b", fiveHour: 40, cincoEn: 1)
    #expect(autonoma.expiringQuotaTarget(active: activa, all: [activa, caducaAntes], now: ahora) == "b")
    #expect(autonoma.expiringQuotaTarget(active: caducaAntes, all: [activa, caducaAntes], now: ahora) == nil)
    // Una Team sin abrir sí saca de una ventana abierta que puede esperar:
    // sus 5 h no empiezan a contar hasta que se usa.
    #expect(autonoma.expiringQuotaTarget(active: activa, all: [medida("c", fiveHour: nil)], now: ahora) == "c")
    // Pero no de una cuyo margen se perdería.
    #expect(autonoma.expiringQuotaTarget(active: caducaAntes, all: [medida("c", fiveHour: nil)], now: ahora) == nil)
}

// MARK: - Sin margen en ninguna cuenta

@Test func sinMargenEnNingunaSeEsperaEnLaPrimeraQueSeRecupera() {
    let activa = medida("a", fiveHour: 95, cincoEn: 4)
    let pronto = medida("b", fiveHour: 100, cincoEn: 0.5)
    let despues = medida("c", fiveHour: 92, cincoEn: 1)
    #expect(politica.decision(active: activa, all: [activa, pronto, despues], now: ahora) == nil)
    #expect(politica.recoveryTarget(active: activa, all: [activa, despues, pronto], now: ahora) == "b")
    // Si alguna tiene margen, manda el cambio ordinario.
    let libre = medida("d", fiveHour: 10, cincoEn: 2)
    #expect(politica.recoveryTarget(active: activa, all: [pronto, libre], now: ahora) == nil)
    // Mientras la activa no tenga que cambiar, no se toca.
    let holgada = medida("e", fiveHour: 50, cincoEn: 4)
    #expect(politica.recoveryTarget(active: holgada, all: [pronto], now: ahora) == nil)
}

@Test func porRitmoNoSeEsperaEnUnaCuentaAgotada() {
    // Aún al 75 %, pero a 90 puntos/h se agota en menos de 20 minutos. Desde
    // b, agotada, el cambio ordinario volvería enseguida a a: se sigue en a
    // hasta su umbral, y entonces sí se espera en b.
    let deprisa = medida("a", fiveHour: 75, cincoEn: 4, ritmoAlto: 90)
    let pronto = medida("b", fiveHour: 100, cincoEn: 0.25)
    #expect(conRitmo.recoveryTarget(active: deprisa, all: [deprisa, pronto], now: ahora) == nil)
    let enUmbral = medida("a", fiveHour: 90, cincoEn: 4, ritmoAlto: 90)
    #expect(conRitmo.recoveryTarget(active: enUmbral, all: [enUmbral, pronto], now: ahora) == "b")
}

@Test func unaActivaSinSemanaEsperaEnUnaQueVuelvaAntes() {
    let activa = medida("a", fiveHour: 10, cincoEn: 3, sevenDay: 97, semanaEn: 50)
    let team = medida("b", fiveHour: 100, cincoEn: 1)
    #expect(politica.recoveryTarget(active: activa, all: [activa, team], now: ahora) == "b")
}

@Test func nuncaSeEsperaEnUnaCuentaConTopePersonal() {
    let activa = medida("a", fiveHour: 95, cincoEn: 4)
    var compartida = medida("b", fiveHour: 100, cincoEn: 0.5)
    compartida.hasPersonalCap = true
    let propia = medida("c", fiveHour: 92, cincoEn: 1)
    #expect(politica.recoveryTarget(active: activa, all: [compartida, propia], now: ahora) == "c")
    #expect(politica.recoveryTarget(active: activa, all: [compartida], now: ahora) == nil)
}

@Test func soloSeEsperaEnCuentasQueBloqueaSuVentanaDeCincoHoras() {
    let activa = medida("a", fiveHour: 95, cincoEn: 4)
    // Su ventana se reinicia enseguida, pero su semana está agotada.
    let semanaAgotada = medida("b", fiveHour: 95, cincoEn: 0.5, sevenDay: 97, semanaEn: 50)
    #expect(politica.recoveryTarget(active: activa, all: [semanaAgotada], now: ahora) == nil)
    var abandonada = medida("c", fiveHour: 100, cincoEn: 0.5)
    abandonada.leftByUser = true
    #expect(politica.recoveryTarget(active: activa, all: [abandonada], now: ahora) == nil)
}

@Test func noSeCambiaParaEsperarCasiLoMismo() {
    let activa = medida("a", fiveHour: 95, cincoEn: 1)
    let casiIgual = medida("b", fiveHour: 100, cincoEn: 0.9)
    #expect(politica.recoveryTarget(active: activa, all: [casiIgual], now: ahora) == nil)
}

@Test func conUmbralDel86UnaTeamQueVuelaCambiaEnCuantoSeMideSuRitmo() {
    // 59 % gastando 480 puntos/h: se agotaría en cinco minutos.
    let politica86 = AutoSwitchPolicy(triggerThreshold: 86, switchesByPace: true)
    #expect(politica86.shouldSwitch(active: medida("a", fiveHour: 59, cincoEn: 4.8, ritmoAlto: 480)))
    // Al 86 % cambia siempre, con ritmo o sin él.
    let sinRitmo = AutoSwitchPolicy(triggerThreshold: 86)
    #expect(sinRitmo.shouldSwitch(active: medida("b", fiveHour: 86, cincoEn: 4)))
    #expect(!sinRitmo.shouldSwitch(active: medida("c", fiveHour: 85, cincoEn: 4)))
}

@Test func conMuchaCargaUnaTeamSigueYendoAntesQueUnaMax() {
    // Varias sesiones a la vez: 340 puntos/h en Team y 72 en Max. La Team
    // nueva solo dará unos diez minutos antes de que el ritmo la deje, pero
    // gastar la semana de la Max sería peor.
    let team = medida("b", fiveHour: nil, ritmo: 340)
    let max = medida("c", fiveHour: 0, sevenDay: 30, semanaEn: 100, ritmo: 72, semanaPorPunto: 0.25)
    #expect(conRitmo.serviceTime(team, now: ahora).map { abs($0 - 60 / 340 * 3_600) < 1 } == true)
    #expect(conRitmo.decision(active: agotada, all: [max, team], now: ahora) == "b")
    let autonomaConRitmo = AutoSwitchPolicy(anticipatesExpiringQuota: true, switchesByPace: true)
    let activaMax = medida("a", fiveHour: 20, cincoEn: 4, sevenDay: 30, semanaEn: 100, ritmo: 72, semanaPorPunto: 0.25)
    #expect(autonomaConRitmo.expiringQuotaTarget(active: activaMax, all: [activaMax, team], now: ahora) == "b")
}

// MARK: - Cambio por ritmo sin ida y vuelta

private let umbral95ConRitmo = AutoSwitchPolicy(triggerThreshold: 95, switchesByPace: true)

@Test func porRitmoSeCambiaAUnaCuentaQueAguanta() {
    let deprisa = medida("a", fiveHour: 75, cincoEn: 4, ritmo: 85, ritmoAlto: 90)
    let nueva = medida("b", fiveHour: nil, ritmo: 60)
    #expect(conRitmo.decision(active: deprisa, all: [deprisa, nueva], now: ahora) == "b")
}

@Test func dosTeamsQueSeGastanALaVezNoSePasanElTurno() {
    // 30/10/2026: backend al 94 % y mlopara al 80 %, las dos gastándose por
    // sus sesiones abiertas. Cada una, activa, se agotaba en minutos y el
    // ritmo la cambiaba por la otra, que también: un cambio por sondeo.
    let backend = medida("backend", fiveHour: 94, cincoEn: 3.5, ritmo: 40, ritmoAlto: 40)
    let mlopara = medida("mlopara", fiveHour: 80, cincoEn: 4.5, ritmo: 200, ritmoAlto: 200)
    #expect(umbral95ConRitmo.paceRequiresSwitch(backend))
    #expect(umbral95ConRitmo.paceRequiresSwitch(mlopara))
    // A un punto del umbral, backend no sirve para dejar mlopara por ritmo,
    // ni mlopara, que se gasta a 200 puntos/h, para dejar backend.
    #expect(umbral95ConRitmo.decision(active: mlopara, all: [mlopara, backend], now: ahora) == nil)
    #expect(umbral95ConRitmo.decision(active: backend, all: [backend, mlopara], now: ahora) == nil)
    #expect(umbral95ConRitmo.recoveryTarget(active: mlopara, all: [mlopara, backend], now: ahora) == nil)
    // Si mlopara no se estuviera gastando, sí convendría.
    let mloparaParada = medida("mlopara", fiveHour: 80, cincoEn: 4.5, ritmo: 30)
    #expect(umbral95ConRitmo.decision(active: backend, all: [backend, mloparaParada], now: ahora) == "mlopara")
    // En su umbral, backend se deja igualmente, aunque sea por un último recurso.
    let backendEnUmbral = medida("backend", fiveHour: 95, cincoEn: 3.5, ritmo: 40, ritmoAlto: 40)
    #expect(umbral95ConRitmo.decision(active: backendEnUmbral, all: [backendEnUmbral, mlopara], now: ahora) == "mlopara")
    // Y desde mlopara ya no hay vuelta: backend está en su umbral.
    #expect(umbral95ConRitmo.decision(active: mlopara, all: [mlopara, backendEnUmbral], now: ahora) == nil)
}

@Test func porRitmoUnUltimoRecursoNoSeAceptaPeroSiHayOtraMejorSeElige() {
    let deprisa = medida("a", fiveHour: 75, cincoEn: 4, ritmoAlto: 90)
    let casiLlena = medida("b", fiveHour: 88, cincoEn: 0.5, ritmo: 30)
    let holgada = medida("c", fiveHour: 10, cincoEn: 4, ritmo: 30)
    #expect(!conRitmo.accepts(casiLlena, from: deprisa, now: ahora))
    #expect(conRitmo.accepts(holgada, from: deprisa, now: ahora))
    #expect(conRitmo.decision(active: deprisa, all: [deprisa, casiLlena, holgada], now: ahora) == "c")
    #expect(conRitmo.decision(active: deprisa, all: [deprisa, casiLlena], now: ahora) == nil)
}

// MARK: - Ultra verificada: sin ventana de 5 h

/// Cuenta sin límite de 5 h: solo su semana y el ritmo al que la gasta.
private func ultraVerificada(
    _ uuid: String,
    sevenDay: Double,
    semanaEn: Double,
    ritmoSemanal: Double? = nil
) -> AccountUsageState {
    AccountUsageState(
        id: uuid,
        usage: UsageSnapshot(
            fiveHour: nil,
            sevenDay: UsageWindow(utilization: sevenDay, resetsAt: horas(semanaEn)),
            sevenDayOpus: nil,
            fetchedAt: ahora,
            fiveHourLimitRemoved: true
        ),
        needsLogin: false,
        weeklyPace: ritmoSemanal
    )
}

@Test func unaUltraVerificadaSoloSeAgotaPorSuSemana() {
    let ultra = ultraVerificada("u", sevenDay: 70, semanaEn: 100, ritmoSemanal: 5)
    #expect(!conRitmo.hasFiveHourLimit(ultra))
    #expect(conRitmo.hasFiveHourLimit(medida("m", fiveHour: 0)))
    #expect(conRitmo.isCandidate(ultra))
    #expect(!conRitmo.shouldSwitch(active: ultra))
    // 30 puntos hasta el 100 % a 5 por hora: 6 horas; el umbral semanal
    // (95 %) la deja a las 5.
    #expect(cerca(conRitmo.runway(ultra, now: ahora), 6 * 3_600))
    #expect(cerca(conRitmo.serviceTime(ultra, now: ahora), 5 * 3_600))
    // Si su semana se reinicia antes, sigue con una nueva.
    let reinicia = ultraVerificada("v", sevenDay: 70, semanaEn: 2, ritmoSemanal: 5)
    #expect(cerca(conRitmo.runway(reinicia, now: ahora), AutoSwitchPolicy.runwayHorizon))
    // En su umbral semanal dispara el cambio, y no es una cuenta en la que
    // esperar a que se recupere: no tiene ventana de 5 h que se reinicie.
    let llena = ultraVerificada("w", sevenDay: 96, semanaEn: 50)
    #expect(politica.shouldSwitch(active: llena))
    #expect(politica.fiveHourRecovery(llena, now: ahora) == nil)
}

@Test func laSemanaDeUnaUltraVerificadaSeMideSinElFrenoDeLaVentana() {
    // 55 puntos a 5 por hora: 11 horas de trabajo, 22 trabajando la mitad.
    #expect(!politica.weeklyQuotaAtRisk(ultraVerificada("a", sevenDay: 40, semanaEn: 30, ritmoSemanal: 5), now: ahora))
    #expect(politica.weeklyQuotaAtRisk(ultraVerificada("b", sevenDay: 40, semanaEn: 20, ritmoSemanal: 5), now: ahora))
    // Gastando más deprisa sí da tiempo: ya no hay ventana que lo impida.
    #expect(!politica.weeklyQuotaAtRisk(ultraVerificada("c", sevenDay: 40, semanaEn: 20, ritmoSemanal: 20), now: ahora))
    // Sin ritmo medido, solo el último día.
    #expect(politica.weeklyQuotaAtRisk(ultraVerificada("d", sevenDay: 40, semanaEn: 23), now: ahora))
    #expect(!politica.weeklyQuotaAtRisk(ultraVerificada("e", sevenDay: 40, semanaEn: 25), now: ahora))
}

@Test func unaUltraVerificadaSeGuardaParaCuandoHagaFalta() {
    let ultra = ultraVerificada("u", sevenDay: 30, semanaEn: 120, ritmoSemanal: 5)
    let team = medida("t", fiveHour: 20, cincoEn: 3)
    #expect(politica.urgency(ultra, now: ahora) == .reserve)
    #expect(politica.decision(active: agotada, all: [ultra, team], now: ahora) == "t")
    #expect(politica.decision(active: agotada, all: [ultra], now: ahora) == "u")
}

@Test func unaUltraVerificadaCedeEnCuantoUnaTeamVuelveATenerMargen() {
    // Todas las Team agotadas: se trabaja en la Ultra.
    let ultra = ultraVerificada("u", sevenDay: 30, semanaEn: 120, ritmoSemanal: 5)
    let teamAgotada = medida("t", fiveHour: 96, cincoEn: 0.5, opus: 0, fableEn: 90)
    #expect(conRitmo.decision(active: agotada, all: [ultra, teamAgotada], now: ahora) == "u")
    let autonomaConRitmo = AutoSwitchPolicy(anticipatesExpiringQuota: true, switchesByPace: true)
    #expect(autonomaConRitmo.expiringQuotaTarget(active: ultra, all: [ultra, teamAgotada], now: ahora) == nil)
    // Su ventana se reinicia: en cuanto vuelve a tener margen, se vuelve a ella.
    var teamRecuperada = medida("t", fiveHour: 0, opus: 0, fableEn: 90, ritmo: 85)
    teamRecuperada.weeklyPerFiveHour = nil
    #expect(autonomaConRitmo.expiringQuotaTarget(active: ultra, all: [ultra, teamRecuperada], now: ahora) == "t")
    // Salvo que al ritmo medido no durara ni unos minutos: entonces la Ultra,
    // que no tiene ventana de 5 h, aguanta mejor.
    let teamFugaz = medida("t", fiveHour: 0, opus: 0, fableEn: 90, ritmo: 1_500)
    #expect(autonomaConRitmo.expiringQuotaTarget(active: ultra, all: [ultra, teamFugaz], now: ahora) == nil)
}
