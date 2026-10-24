import Foundation
import Testing
@testable import SwitchBarCore

private let inicio = Date(timeIntervalSince1970: 1_800_000_000)

private func minuto(_ m: Double) -> Date {
    inicio.addingTimeInterval(m * 60)
}

/// Ventana de 5 h que se reinicia a las 4 h de `inicio`.
private let reinicio = minuto(240)

private func lectura(
    _ m: Double,
    _ cincoHoras: Double?,
    reinicio: Date? = reinicio,
    semana: Double? = nil,
    semanaEn: Date? = nil
) -> UsageSample {
    UsageSample(
        at: minuto(m),
        fiveHour: cincoHoras,
        fiveHourResetsAt: cincoHoras == nil ? nil : reinicio,
        sevenDay: semana,
        sevenDayResetsAt: semanaEn
    )
}

// MARK: - Historial

private func instantanea(_ m: Double, _ cincoHoras: Double) -> UsageSnapshot {
    UsageSnapshot(
        fiveHour: UsageWindow(utilization: cincoHoras, resetsAt: reinicio),
        sevenDay: nil,
        sevenDayOpus: nil,
        fetchedAt: minuto(m)
    )
}

@Test func elHistorialNoRepiteLecturasIdenticasSalvoDeVezEnCuando() {
    var historial = UsageHistory()
    let guardadas = [
        historial.record(instantanea(0, 10), for: "a"),
        historial.record(instantanea(2.5, 10), for: "a"),
        historial.record(instantanea(5, 11), for: "a"),
        // Sin cambios durante diez minutos: se guarda una para saber que estuvo parada.
        historial.record(instantanea(15, 11), for: "a"),
        // Una lectura que no es más reciente se descarta.
        historial.record(instantanea(15, 12), for: "a")
    ]
    #expect(guardadas == [true, false, true, true, false])
    #expect(historial.samples(for: "a").map(\.fiveHour) == [10, 11, 11])
}

@Test func elHistorialOlvidaLoDeHaceMasDeUnaSemana() {
    var historial = UsageHistory()
    historial.record(instantanea(0, 10), for: "a")
    historial.record(instantanea(60 * 24 * 6, 20), for: "a")
    historial.record(instantanea(0, 5), for: "b")
    historial.prune(now: minuto(60 * 24 * 7 + 1), keeping: ["a", "b"])
    #expect(historial.samples(for: "a").map(\.fiveHour) == [20])
    #expect(historial.samples(for: "b").isEmpty)

    historial.prune(now: minuto(60 * 24 * 7 + 1), keeping: [])
    #expect(historial.samplesByAccount.isEmpty)
}

@Test func elHistorialSobreviveAlReinicio() throws {
    let carpeta = FileManager.default.temporaryDirectory
        .appendingPathComponent("historial-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: carpeta) }
    let almacen = UsageHistoryStore(directoryURL: carpeta)
    var historial = UsageHistory()
    historial.record(instantanea(0, 10), for: "a")
    historial.record(
        UsageSnapshot(
            fiveHour: nil,
            sevenDay: UsageWindow(utilization: 40, resetsAt: minuto(3_000)),
            sevenDayOpus: nil,
            fetchedAt: minuto(5)
        ),
        for: "b"
    )
    try almacen.save(historial)
    let cargado = almacen.load(now: minuto(10))
    #expect(cargado == historial)

    let atributos = try FileManager.default.attributesOfItem(
        atPath: carpeta.appendingPathComponent("usage-history.json").path
    )
    #expect((atributos[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

// MARK: - Ritmo actual

@Test func elRitmoActualSaleDeLaUltimaMediaHora() throws {
    let lecturas = [
        lectura(0, 10), // fuera de la media hora
        lectura(20, 20),
        lectura(30, 25),
        lectura(40, 30),
        lectura(50, 35)
    ]
    let ritmo = try #require(UsagePace.current(lecturas, now: minuto(50)))
    // 15 puntos en 30 minutos.
    #expect(ritmo.pointsPerHour == 30)
    #expect(ritmo.upperPointsPerHour == 32)
    #expect(ritmo.span == 30 * 60)
}

@Test func sinLecturasSuficientesNoHayRitmoActual() {
    #expect(UsagePace.current([], now: inicio) == nil)
    #expect(UsagePace.current([lectura(0, 10), lectura(5, 12)], now: minuto(5)) == nil)
    // Datos viejos: no describen el ahora.
    #expect(UsagePace.current([lectura(0, 10), lectura(10, 15)], now: minuto(40)) == nil)
}

@Test func elRitmoActualNoMezclaDosVentanas() throws {
    let nuevaVentana = minuto(320)
    let lecturas = [
        lectura(10, 80),
        lectura(15, 90),
        // La ventana anterior terminó y empezó otra.
        lectura(20, 2, reinicio: nuevaVentana),
        lectura(30, 6, reinicio: nuevaVentana)
    ]
    let ritmo = try #require(UsagePace.current(lecturas, now: minuto(30)))
    #expect(ritmo.pointsPerHour == 24)
    #expect(ritmo.span == 10 * 60)
}

@Test func unaCuentaParadaTieneRitmoCero() throws {
    let lecturas = [lectura(0, 40), lectura(10, 40), lectura(20, 40)]
    let ritmo = try #require(UsagePace.current(lecturas, now: minuto(20)))
    #expect(ritmo.pointsPerHour == 0)
    #expect(ritmo.upperPointsPerHour == 3)
}

// MARK: - Ritmo habitual

@Test func elRitmoHabitualSoloCuentaLosTramosDeUso() throws {
    let lecturas = [
        lectura(0, 0),
        lectura(10, 5),
        lectura(20, 10),
        lectura(30, 15),
        // Una hora parada: no rebaja el ritmo.
        lectura(40, 15),
        lectura(50, 15),
        lectura(60, 15),
        lectura(70, 15),
        lectura(80, 15),
        lectura(90, 15),
        lectura(100, 20),
        lectura(110, 25)
    ]
    let ritmo = try #require(UsagePace.typical(lecturas))
    // 25 puntos en 50 minutos de uso.
    #expect(ritmo.pointsPerHour == 30)
    #expect(ritmo.measured == 50 * 60)
    #expect(ritmo.weeklyPerFiveHour == nil)
}

@Test func unaPausaCortaCuentaComoTrabajo() throws {
    let lecturas = [
        lectura(0, 0),
        lectura(10, 6),
        lectura(20, 6),
        lectura(30, 12)
    ]
    let ritmo = try #require(UsagePace.typical(lecturas))
    #expect(ritmo.pointsPerHour == 24)
    #expect(ritmo.measured == 30 * 60)
}

@Test func conPocoUsoMedidoNoHayRitmoHabitual() {
    #expect(UsagePace.typical([lectura(0, 0), lectura(10, 5)]) == nil)
}

@Test func elRitmoHabitualDeUnPlanJuntaSusCuentas() throws {
    let a = [lectura(0, 0), lectura(10, 5), lectura(15, 8)]
    let b = [lectura(0, 0), lectura(10, 4), lectura(15, 7)]
    #expect(UsagePace.typical(a) == nil)
    let plan = try #require(UsagePace.typical(pooling: [a, b]))
    #expect(plan.pointsPerHour == 30)
    #expect(plan.measured == 30 * 60)
}

@Test func enMaxSeMideCuantaSemanaCuestaCadaPuntoDeCincoHoras() throws {
    let semana = minuto(5_000)
    let lecturas = [
        lectura(0, 0, semana: 40, semanaEn: semana),
        lectura(10, 10, semana: 41, semanaEn: semana),
        lectura(20, 20, semana: 42, semanaEn: semana)
    ]
    let ritmo = try #require(UsagePace.typical(lecturas))
    #expect(ritmo.weeklyPerFiveHour == 0.1)
}

@Test func laVentanaQueSeAbreEntreDosLecturasCuenta() {
    let abierta = UsageSample(at: minuto(10), fiveHour: 4, fiveHourResetsAt: minuto(5 + 300))
    let cerrada = UsageSample(at: minuto(0), fiveHour: nil)
    #expect(UsagePace.fiveHourDelta(from: cerrada, to: abierta) == 4)
    // Una ventana que empezó antes de la lectura anterior no es nueva: falta información.
    let vieja = UsageSample(at: minuto(10), fiveHour: 30, fiveHourResetsAt: minuto(100))
    #expect(UsagePace.fiveHourDelta(from: cerrada, to: vieja) == nil)
}

// MARK: - Ritmo esperado de cada cuenta

private func habitual(_ puntosPorHora: Double, semanaPorPunto: Double? = nil) -> TypicalPace {
    TypicalPace(pointsPerHour: puntosPorHora, measured: 3_600, weeklyPerFiveHour: semanaPorPunto)
}

private func ahoraMismo(_ puntosPorHora: Double) -> PaceEstimate {
    PaceEstimate(pointsPerHour: puntosPorHora, upperPointsPerHour: puntosPorHora + 2, span: 1_800)
}

@Test func trabajandoElDobleDeLoHabitualTodasLasCuentasSeGastanAlDoble() {
    let modelo = PaceModel(
        byAccount: ["activa": habitual(30), "max": habitual(10)],
        byPlan: [.team: habitual(30), .max: habitual(10)]
    )
    let contexto = PaceContext(model: modelo, activeID: "activa", activePlan: .team, activeCurrent: ahoraMismo(60))
    #expect(contexto.basis == .currentPace)
    #expect(contexto.intensity == 2)
    #expect(contexto.expectedPace(for: "activa", plan: .team, isActive: true) == 60)
    #expect(contexto.expectedPace(for: "max", plan: .max, isActive: false) == 20)
    // Sin medidas propias: las de su plan.
    #expect(contexto.expectedPace(for: "otra-team", plan: .team, isActive: false) == 60)
}

@Test func sinTrabajarAhoraSeUsaElRitmoHabitual() {
    let modelo = PaceModel(byAccount: ["activa": habitual(30)], byPlan: [.max: habitual(12, semanaPorPunto: 0.1)])
    let contexto = PaceContext(model: modelo, activeID: "activa", activePlan: .team, activeCurrent: ahoraMismo(0))
    #expect(contexto.basis == .typicalPace)
    #expect(contexto.intensity == 1)
    #expect(contexto.expectedPace(for: "activa", plan: .team, isActive: true) == 30)
    #expect(contexto.expectedPace(for: "max", plan: .max, isActive: false) == 12)
    #expect(contexto.weeklyPerFiveHour(for: "max", plan: .max) == 0.1)
    // Sin plan ni medidas, se supone que rinde como la activa.
    #expect(contexto.expectedPace(for: "desconocida", plan: nil, isActive: false) == 30)
}

@Test func laIntensidadTieneUnLimite() {
    let modelo = PaceModel(byAccount: ["activa": habitual(10)])
    let rafaga = PaceContext(model: modelo, activeID: "activa", activePlan: nil, activeCurrent: ahoraMismo(200))
    #expect(rafaga.intensity == 4)
}

@Test func sinNingunaMedidaNoSeEstimaNada() {
    let contexto = PaceContext(model: PaceModel(), activeID: "activa", activePlan: .team, activeCurrent: nil)
    #expect(contexto.basis == .typicalPace)
    #expect(contexto.expectedPace(for: "activa", plan: .team, isActive: true) == nil)
    #expect(contexto.expectedPace(for: "otra", plan: .max, isActive: false) == nil)
}

@Test func elModeloAgrupaLasCuentasPorPlan() {
    var historial = UsageHistory()
    for (cuenta, puntos) in [("t1", [0.0, 5, 8]), ("t2", [0.0, 4, 7])] {
        for (i, valor) in puntos.enumerated() {
            historial.record(
                UsageSample(at: minuto([0, 10, 15][i]), fiveHour: valor, fiveHourResetsAt: reinicio),
                for: cuenta
            )
        }
    }
    let modelo = PaceModel(history: historial, plans: ["t1": .team, "t2": .team, "x": nil])
    #expect(modelo.byAccount.isEmpty, "cada una por separado tiene poco medido")
    #expect(modelo.byPlan[.team]?.pointsPerHour == 30)
    #expect(modelo.typical(for: "t1", plan: .team)?.pointsPerHour == 30)
}
