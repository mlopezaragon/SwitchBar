import Foundation
import Testing
@testable import SwitchBarCore

private let ahora = Date(timeIntervalSince1970: 1_800_000_000)

private func horas(_ h: Double) -> Date {
    ahora.addingTimeInterval(h * 3_600)
}

private func cuenta(
    _ uuid: String,
    fiveHour: Double? = 0,
    cincoEn: Double? = nil,
    sevenDay: Double? = nil,
    semanaEn: Double? = nil,
    ritmo: Double?,
    semanaPorPunto: Double? = nil
) -> AccountUsageState {
    AccountUsageState(
        id: uuid,
        usage: UsageSnapshot(
            fiveHour: fiveHour.map { UsageWindow(utilization: $0, resetsAt: cincoEn.map(horas)) },
            sevenDay: sevenDay.map { UsageWindow(utilization: $0, resetsAt: semanaEn.map(horas)) },
            sevenDayOpus: nil,
            fetchedAt: ahora,
            weeklyLimitUnreported: sevenDay == nil
        ),
        needsLogin: false,
        fiveHourPace: ritmo,
        weeklyPerFiveHour: semanaPorPunto
    )
}

private let politica = AutoSwitchPolicy(switchesByPace: true)

private func prevision(_ cuentas: [AccountUsageState], activa: String = "a") -> CoverageForecast? {
    CoveragePlanner.forecast(
        activeID: activa, states: cuentas, policy: politica, basis: .currentPace, now: ahora
    )
}

@Test func conCuentasDeSobraNoSeAcabaElCupo() throws {
    // 20 puntos/h: ninguna ventana de 5 h llega a agotarse.
    let resultado = try #require(prevision([
        cuenta("a", fiveHour: 50, cincoEn: 2, ritmo: 20),
        cuenta("b", ritmo: 20)
    ]))
    #expect(resultado.runsOutAt == nil)
    #expect(resultado.basis == .currentPace)
}

@Test func avisaDeCuandoSeAcabaYDeCuandoVuelve() throws {
    // a: 60 puntos libres a 60/h → 1 h. b: 100 a 60/h → 1 h 40 más.
    // La ventana de a se reinicia a las 4 h: hasta entonces no hay cupo.
    let resultado = try #require(prevision([
        cuenta("a", fiveHour: 40, cincoEn: 4, ritmo: 60),
        cuenta("b", ritmo: 60)
    ]))
    let seAcaba = try #require(resultado.runsOutAt)
    let vuelve = try #require(resultado.resumesAt)
    #expect(abs(seAcaba.timeIntervalSince(horas(2 + 40.0 / 60))) <= 120)
    #expect(abs(vuelve.timeIntervalSince(horas(4))) <= 120)
}

@Test func unaCuentaSinRitmoConocidoNoCuenta() throws {
    let resultado = try #require(prevision([
        cuenta("a", fiveHour: 40, cincoEn: 4, ritmo: 60),
        cuenta("b", ritmo: nil)
    ]))
    let seAcaba = try #require(resultado.runsOutAt)
    #expect(abs(seAcaba.timeIntervalSince(horas(1))) <= 120)
}

@Test func sinRitmoEnLaActivaNoHayPrevision() {
    #expect(prevision([cuenta("a", ritmo: nil), cuenta("b", ritmo: 30)]) == nil)
}

@Test func laSemanaDeMaxTambienSeAgota() throws {
    // 5 puntos de semana a 0,1 por punto de 5 h: 50 puntos de 5 h, menos de
    // una hora a 60/h, aunque la ventana de 5 h esté vacía.
    let resultado = try #require(prevision([
        cuenta("a", fiveHour: 0, sevenDay: 95, semanaEn: 100, ritmo: 60, semanaPorPunto: 0.1)
    ]))
    let seAcaba = try #require(resultado.runsOutAt)
    #expect(abs(seAcaba.timeIntervalSince(horas(50.0 / 60))) <= 120)
    #expect(resultado.resumesAt == nil)
}

@Test func unaUltraVerificadaGastaSoloSuSemana() throws {
    // La activa está agotada hasta dentro de 6 horas. La Ultra, al 90 % de
    // su semana a 5 puntos por hora, aguanta 2 horas hasta el 100 %.
    let ultra = AccountUsageState(
        id: "u",
        usage: UsageSnapshot(
            fiveHour: nil,
            sevenDay: UsageWindow(utilization: 90, resetsAt: horas(100)),
            sevenDayOpus: nil,
            fetchedAt: ahora,
            fiveHourLimitRemoved: true
        ),
        needsLogin: false,
        weeklyPace: 5
    )
    let forecast = try #require(prevision([cuenta("a", fiveHour: 100, cincoEn: 6, ritmo: 20), ultra]))
    let runsOut = try #require(forecast.runsOutAt)
    #expect(abs(runsOut.timeIntervalSince(horas(2))) <= 120)
    let resumes = try #require(forecast.resumesAt)
    #expect(abs(resumes.timeIntervalSince(horas(6))) <= 120)
    // Sin ritmo semanal no se puede simular: la previsión prefiere quedarse corta.
    var sinRitmo = ultra
    sinRitmo.weeklyPace = nil
    let corta = try #require(prevision([cuenta("a", fiveHour: 100, cincoEn: 6, ritmo: 20), sinRitmo]))
    #expect(corta.runsOutAt == ahora)
}
