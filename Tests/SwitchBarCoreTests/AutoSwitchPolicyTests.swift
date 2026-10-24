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

@Test func unaHoraDeDiferenciaEnElReinicioYaDecide() {
    // El caso del usuario: una Team al 0 % que se reinicia en 3 h frente a
    // otra cuenta que se reinicia en 4 h. Gana la de 3 h.
    let team = cuenta("b", fiveHour: 0, sevenDay: nil, opus: 0, fableEn: 3, semanaNoInformada: true)
    let otra = cuenta("c", fiveHour: 0, sevenDay: 20, semanaEn: 4)
    #expect(politica.decision(active: agotada, all: [otra, team]) == "b")
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

@Test func enTeamElReinicioDeFableEstimaElDeLaSemana() {
    let team = cuenta("b", fiveHour: 30, sevenDay: nil, opus: 0, fableEn: 20, semanaNoInformada: true)
    let max = cuenta("c", fiveHour: 0, sevenDay: 20, semanaEn: 100)
    #expect(politica.decision(active: agotada, all: [team, max]) == "b")
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

@Test func enModoAutonomoTresHorasGananACuatro() {
    // Activa: se reinicia en 4 h. Una Team al 0 % se reinicia en 3 h.
    let activa = cuenta("a", fiveHour: 20, sevenDay: 50, semanaEn: 4)
    let team = cuenta("b", fiveHour: 0, sevenDay: nil, opus: 0, fableEn: 3, semanaNoInformada: true)
    #expect(autonoma.expiringQuotaTarget(active: activa, all: [activa, team], now: ahora) == "b")
    // Y desde la Team no se vuelve a la de 4 h mientras la Team aguante.
    #expect(autonoma.expiringQuotaTarget(active: team, all: [activa, team], now: ahora) == nil)
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

@Test func unaVentanaAbiertaConMargenSeGastaAntesQueEstrenarOtra() {
    // b ya tiene la ventana abierta y se reinicia en 2 h; c está sin
    // estrenar y su semana (Fable en Team) se reinicia antes que la de b.
    let abierta = medida("b", fiveHour: 30, cincoEn: 2, opus: 0, fableEn: 70)
    let sinEstrenar = medida("c", fiveHour: nil, opus: 0, fableEn: 20)
    #expect(politica.decision(active: agotada, all: [sinEstrenar, abierta], now: ahora) == "b")
    // Sin margen útil en esa ventana, no hay nada que rescatar.
    let casiLlena = medida("d", fiveHour: 86, cincoEn: 2, opus: 0, fableEn: 70)
    #expect(politica.expiryDeadline(casiLlena, now: ahora) == horas(70))
}

@Test func lasVentanasAbiertasSeGastanPorOrdenDeReinicio() {
    let antes = medida("b", fiveHour: 50, cincoEn: 1, opus: 0, fableEn: 100)
    let despues = medida("c", fiveHour: 10, cincoEn: 4, opus: 0, fableEn: 30)
    #expect(politica.decision(active: agotada, all: [despues, antes], now: ahora) == "b")
}

@Test func unaSemanaQueCaducaAntesQueLaVentanaManda() {
    let semanaInminente = medida("b", fiveHour: nil, sevenDay: 40, semanaEn: 1)
    let ventanaAbierta = medida("c", fiveHour: 20, cincoEn: 3, opus: 0, fableEn: 90)
    #expect(politica.decision(active: agotada, all: [ventanaAbierta, semanaInminente], now: ahora) == "b")
}

@Test func unDestinoQueSeAgotariaEnMinutosEsUltimoRecurso() {
    // b caduca antes, pero al ritmo medido aguantaría 20 minutos.
    let corta = medida("b", fiveHour: 80, cincoEn: 3, opus: 0, fableEn: 10, ritmo: 60)
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
