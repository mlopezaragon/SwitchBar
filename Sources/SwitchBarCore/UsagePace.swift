import Foundation

/// Ritmo de gasto de la ventana de 5 h en este momento.
public struct PaceEstimate: Sendable, Equatable {
    /// Puntos de la ventana de 5 h por hora.
    public var pointsPerHour: Double
    /// Cota alta: el servidor redondea el uso a puntos enteros, así que entre
    /// dos lecturas puede haberse gastado casi un punto más de lo que se ve.
    /// Es la que se usa para no llegar tarde a un límite.
    public var upperPointsPerHour: Double
    /// Tiempo cubierto por las lecturas que se han usado.
    public var span: TimeInterval
}

/// Ritmo habitual de una cuenta (o de un plan) cuando se está usando.
public struct TypicalPace: Sendable, Equatable {
    /// Puntos de la ventana de 5 h por hora de uso.
    public var pointsPerHour: Double
    /// Tiempo de uso medido para calcularlo.
    public var measured: TimeInterval
    /// Puntos de la semana general que cuesta cada punto de 5 h, en las
    /// cuentas que informan de ambas (Max). `nil` si no hay medida.
    public var weeklyPerFiveHour: Double?
}

/// Medición del ritmo a partir del historial de lecturas.
///
/// El mismo trabajo gasta más puntos en un plan con menos cupo: los puntos
/// por hora de cada cuenta reflejan a la vez cuánto trabaja el usuario y
/// cuánto da el plan. Comparar el ritmo habitual de dos planes estima cuánto
/// rinde cada uno, que Anthropic no publica.
public enum UsagePace {
    /// Lecturas que cuentan para el ritmo actual.
    public static let currentWindow: TimeInterval = 30 * 60
    /// Por debajo, dos lecturas no dicen nada fiable de un ritmo.
    public static let minimumCurrentSpan: TimeInterval = 8 * 60
    /// Con un gasto grande, un par de minutos ya dan un ritmo fiable: el
    /// redondeo del servidor (un punto) apenas pesa. Una ventana de Team con
    /// varias sesiones se agota en diez minutos y no da tiempo a esperar ocho.
    public static let minimumFastSpan: TimeInterval = 2 * 60
    public static let minimumFastPoints: Double = 10
    /// Un ritmo habitual medido durante menos tiempo no se usa.
    public static let minimumTypicalMeasure: TimeInterval = 20 * 60
    /// Entre dos lecturas más separadas no se sabe qué pasó.
    static let maximumGap: TimeInterval = 20 * 60
    /// Una pausa así de larga cierra un tramo de uso.
    static let idleBreak: TimeInterval = 15 * 60
    static let minimumRunSpan: TimeInterval = 10 * 60
    static let minimumRunPoints: Double = 2
    /// Lo que puede variar la hora de reinicio de una misma ventana.
    static let resetTolerance: TimeInterval = 5 * 60
    /// El servidor redondea hacia abajo la hora de reinicio de la ventana de
    /// 5 h (a la decena de minutos): la apertura que se deduce de ella puede
    /// caer unos minutos antes de la real, incluso antes de la lectura previa.
    static let resetRounding: TimeInterval = 30 * 60

    /// Ritmo de la última media hora dentro de la ventana de 5 h actual, o
    /// `nil` si no hay lecturas suficientes y recientes.
    public static func current(_ samples: [UsageSample], now: Date) -> PaceEstimate? {
        guard let last = samples.last,
              now.timeIntervalSince(last.at) <= idleBreak else { return nil }
        let horizon = now.addingTimeInterval(-currentWindow)
        var points = 0.0
        var earliest = last
        for (older, newer) in zip(samples.dropLast().reversed(), samples.reversed()) {
            guard older.at >= horizon, let delta = fiveHourDelta(from: older, to: newer) else {
                break
            }
            points += delta
            earliest = older
        }
        let span = last.at.timeIntervalSince(earliest.at)
        guard span >= minimumCurrentSpan
                || (span >= minimumFastSpan && points >= minimumFastPoints)
        else { return nil }
        return PaceEstimate(
            pointsPerHour: points / span * 3_600,
            upperPointsPerHour: (points + 1) / span * 3_600,
            span: span
        )
    }

    /// Ritmo habitual de una cuenta: solo los tramos en que se estaba usando.
    public static func typical(_ samples: [UsageSample]) -> TypicalPace? {
        typical(pooling: [samples])
    }

    /// Ritmo habitual de varias cuentas juntas, por ejemplo las de un plan.
    public static func typical(pooling accounts: [[UsageSample]]) -> TypicalPace? {
        var points = 0.0
        var measured: TimeInterval = 0
        var weeklyPoints = 0.0
        var weeklyBase = 0.0
        for samples in accounts {
            for run in runs(samples) {
                points += run.points
                measured += run.duration
                weeklyPoints += run.weeklyPoints
                weeklyBase += run.weeklyBase
            }
        }
        guard measured >= minimumTypicalMeasure, points > 0 else { return nil }
        return TypicalPace(
            pointsPerHour: points / measured * 3_600,
            measured: measured,
            weeklyPerFiveHour: weeklyBase >= 10 ? weeklyPoints / weeklyBase : nil
        )
    }

    struct Run: Equatable {
        var points = 0.0
        var duration: TimeInterval = 0
        /// Puntos semanales gastados mientras la ventana de 5 h sumaba
        /// `weeklyBase` puntos, en los tramos que informan de ambas.
        var weeklyPoints = 0.0
        var weeklyBase = 0.0
    }

    /// Tramos de uso: lecturas seguidas dentro de una misma ventana, con
    /// consumo y sin pausas largas. Las pausas cortas cuentan como parte del
    /// trabajo; la final no.
    static func runs(_ samples: [UsageSample]) -> [Run] {
        var result: [Run] = []
        var current = Run()
        var idle: TimeInterval = 0
        func close() {
            if current.duration >= minimumRunSpan, current.points >= minimumRunPoints {
                result.append(current)
            }
            current = Run()
            idle = 0
        }
        for (older, newer) in zip(samples, samples.dropFirst()) {
            let gap = newer.at.timeIntervalSince(older.at)
            guard gap > 0, gap <= maximumGap,
                  let delta = fiveHourDelta(from: older, to: newer) else {
                close()
                continue
            }
            if delta <= 0 {
                idle += gap
                if idle > idleBreak { close() }
                continue
            }
            current.points += delta
            current.duration += idle + gap
            idle = 0
            if let weeklyDelta = weeklyDelta(from: older, to: newer) {
                current.weeklyPoints += weeklyDelta
                current.weeklyBase += delta
            }
        }
        close()
        return result
    }

    /// Puntos de 5 h gastados entre dos lecturas, o `nil` si entre ellas
    /// terminó una ventana y no se puede saber.
    static func fiveHourDelta(from older: UsageSample, to newer: UsageSample) -> Double? {
        switch (older.fiveHourResetsAt, newer.fiveHourResetsAt) {
        case (nil, nil):
            // Sin hora de reinicio en ninguna de las dos: normalmente no hay
            // ventana abierta y no se ha gastado nada.
            let delta = (newer.fiveHour ?? 0) - (older.fiveHour ?? 0)
            return delta >= 0 ? delta : nil
        case (nil, let reset?):
            // La ventana se abrió entre las dos lecturas.
            guard reset.addingTimeInterval(-5 * 3_600) >= older.at.addingTimeInterval(-resetRounding) else {
                return nil
            }
            return newer.fiveHour ?? 0
        case let (old?, new?):
            guard abs(old.timeIntervalSince(new)) <= resetTolerance else { return nil }
            let delta = (newer.fiveHour ?? 0) - (older.fiveHour ?? 0)
            // Un descenso es un reinicio concedido por Anthropic.
            return delta >= 0 ? delta : nil
        case (_?, nil):
            return nil
        }
    }

    static func weeklyDelta(from older: UsageSample, to newer: UsageSample) -> Double? {
        guard let before = older.sevenDay, let after = newer.sevenDay,
              UsageSample.close(older.sevenDayResetsAt, newer.sevenDayResetsAt, tolerance: 3_600)
        else { return nil }
        let delta = after - before
        return delta >= 0 ? delta : nil
    }
}

/// Ritmo habitual medido de cada cuenta y de cada plan.
public struct PaceModel: Sendable, Equatable {
    public var byAccount: [String: TypicalPace]
    public var byPlan: [AccountPlan: TypicalPace]

    public init(byAccount: [String: TypicalPace] = [:], byPlan: [AccountPlan: TypicalPace] = [:]) {
        self.byAccount = byAccount
        self.byPlan = byPlan
    }

    /// `plans` asigna a cada cuenta su plan; las que no lo tienen solo
    /// cuentan para sí mismas.
    public init(history: UsageHistory, plans: [String: AccountPlan?]) {
        var byAccount: [String: TypicalPace] = [:]
        var samplesByPlan: [AccountPlan: [[UsageSample]]] = [:]
        for (account, plan) in plans {
            let samples = history.samples(for: account)
            if let typical = UsagePace.typical(samples) {
                byAccount[account] = typical
            }
            if let plan { samplesByPlan[plan, default: []].append(samples) }
        }
        self.init(
            byAccount: byAccount,
            byPlan: samplesByPlan.compactMapValues { UsagePace.typical(pooling: $0) }
        )
    }

    public func typical(for account: String, plan: AccountPlan?) -> TypicalPace? {
        byAccount[account] ?? plan.flatMap { byPlan[$0] }
    }
}

/// Qué ritmo cabe esperar de cada cuenta si se usara ahora.
///
/// Si se está trabajando, el ritmo medido en la activa dice con qué
/// intensidad: las demás cuentas se estiman con su ritmo habitual escalado
/// por esa intensidad. Si no, con su ritmo habitual. Una cuenta sin medidas
/// propias usa las de su plan y, a falta de ellas, se supone que rinde como
/// la activa.
public struct PaceContext: Sendable, Equatable {
    /// Por debajo de este ritmo la cuenta activa se considera parada.
    public static let workingPace: Double = 1
    static let intensityRange: ClosedRange<Double> = 0.25...4

    public var basis: CoverageForecast.Basis
    public var activeCurrent: PaceEstimate?
    /// Cuánto más (o menos) se trabaja ahora que de costumbre.
    public var intensity: Double
    /// Ritmo de la activa con el que se estiman las cuentas sin medidas.
    public var reference: Double?
    private let model: PaceModel

    public init(
        model: PaceModel,
        activeID: String?,
        activePlan: AccountPlan?,
        activeCurrent: PaceEstimate?
    ) {
        self.model = model
        self.activeCurrent = activeCurrent
        let typical = activeID.flatMap { model.typical(for: $0, plan: activePlan) }
        if let current = activeCurrent, current.pointsPerHour >= Self.workingPace {
            basis = .currentPace
            intensity = typical.map {
                min(max(current.pointsPerHour / $0.pointsPerHour, Self.intensityRange.lowerBound),
                    Self.intensityRange.upperBound)
            } ?? 1
            reference = current.pointsPerHour
        } else {
            basis = .typicalPace
            intensity = 1
            reference = typical?.pointsPerHour
        }
    }

    /// Puntos de 5 h por hora que gastaría la cuenta, o `nil` si no hay
    /// ninguna medida con la que estimarlo.
    public func expectedPace(for account: String, plan: AccountPlan?, isActive: Bool) -> Double? {
        if isActive, basis == .currentPace, let current = activeCurrent {
            return current.pointsPerHour
        }
        if let typical = model.typical(for: account, plan: plan) {
            return typical.pointsPerHour * intensity
        }
        return reference
    }

    public func weeklyPerFiveHour(for account: String, plan: AccountPlan?) -> Double? {
        model.byAccount[account]?.weeklyPerFiveHour
            ?? plan.flatMap { model.byPlan[$0]?.weeklyPerFiveHour }
    }
}
