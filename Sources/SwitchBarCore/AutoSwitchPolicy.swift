import Foundation

/// Estado de uso de una cuenta para la política de cambio automático.
public struct AccountUsageState: Sendable {
    public var id: String
    public var usage: UsageSnapshot?
    public var needsLogin: Bool

    public init(id: String, usage: UsageSnapshot?, needsLogin: Bool) {
        self.id = id
        self.usage = usage
        self.needsLogin = needsLogin
    }
}

/// Motivo por el que una cuenta no puede recibir el cambio automático.
///
/// Distinguirlos importa: «no tiene margen» y «no se ha podido comprobar»
/// son situaciones muy distintas y merecen avisos distintos.
public enum CandidateRejection: Sendable, Equatable {
    /// Su sesión caducó: hace falta volver a iniciar sesión.
    case needsLogin
    /// Sin datos de uso vigentes; no se puede afirmar nada sobre su margen.
    case noUsageData
    /// Algún cupo relevante está en su umbral o por encima.
    case atLimit
}

/// Política pura (sin efectos) del cambio automático.
///
/// Disparo: la ventana de 5 h o la semana general alcanzan su umbral. Fable
/// participa únicamente cuando `considersFable` está activado.
/// Candidatas: cuentas con sesión válida, datos de uso, y las ventanas
/// relevantes por debajo de sus respectivos umbrales. Una cuenta en su umbral
/// nunca es destino, por mucho cupo que le vaya a caducar.
/// Elección, por este orden:
/// 1. Las que tienen margen útil (`minimumUsefulRoom`) en todas sus ventanas
///    van antes que las que obligarían a cambiar otra vez a los pocos minutos.
/// 2. La que antes reinicia su semana. Lo que no se gasta antes del reinicio
///    se pierde; las que reinician más tarde conservan su cupo para después.
///    Reinicios separados por menos de `deadlineTolerance` cuentan como uno.
/// 3. Menor uso de 5 h.
/// 4. Mayor margen ponderado de los cupos semanales que estén habilitados.
public struct AutoSwitchPolicy: Sendable {
    public var triggerThreshold: Double
    public var weeklyThreshold: Double
    public var fableThreshold: Double
    public var considersFable: Bool
    /// Cambiar sin esperar a un límite cuando otra cuenta está a punto de
    /// perder su cupo semanal. Ver `expiringQuotaTarget`.
    public var anticipatesExpiringQuota: Bool

    /// Puntos hasta el umbral por debajo de los cuales una cuenta solo sirve
    /// de último recurso: se gastarían en minutos y habría que volver a cambiar.
    public static let minimumUsefulRoom: Double = 5
    /// Dos reinicios semanales así de próximos valen lo mismo: entre ellos
    /// decide el margen, que ahorra cambios.
    public static let deadlineTolerance: TimeInterval = 6 * 3_600
    /// Cuánto antes del reinicio semanal se considera que un cupo sin gastar
    /// corre peligro de perderse.
    public static let expiringHorizon: TimeInterval = 24 * 3_600
    /// Margen semanal mínimo que justifica adelantarse a un límite.
    public static let expiringMinimumRoom: Double = 10

    public init(
        triggerThreshold: Double = 90,
        weeklyThreshold: Double = 95,
        fableThreshold: Double = 95,
        considersFable: Bool = false,
        anticipatesExpiringQuota: Bool = false
    ) {
        self.triggerThreshold = triggerThreshold
        self.weeklyThreshold = weeklyThreshold
        self.fableThreshold = fableThreshold
        self.considersFable = considersFable
        self.anticipatesExpiringQuota = anticipatesExpiringQuota
    }

    public func shouldSwitch(active: AccountUsageState) -> Bool {
        guard let usage = active.usage else { return false }
        if let fiveHour = usage.fiveHour,
           fiveHour.utilization >= triggerThreshold {
            return true
        }
        if let weekly = usage.sevenDay,
           weekly.utilization >= weeklyThreshold {
            return true
        }
        if considersFable,
           let fable = usage.sevenDayOpus,
           fable.utilization >= fableThreshold {
            return true
        }
        return false
    }

    /// Por qué se descarta esta cuenta, o `nil` si sirve como destino.
    ///
    /// Una instantánea vigente sin ventana de 5 h describe una cuenta sin
    /// sesión abierta (o cuya ventana ya se reinició): su consumo de 5 h es
    /// cero, no un dato desconocido, así que no la descalifica.
    public func rejection(for account: AccountUsageState) -> CandidateRejection? {
        if account.needsLogin { return .needsLogin }
        guard let usage = account.usage else { return .noUsageData }
        if fiveHourUtilization(account) >= triggerThreshold { return .atLimit }
        if let sevenDay = usage.sevenDay,
           sevenDay.utilization >= weeklyThreshold {
            return .atLimit
        }
        if considersFable,
           let opus = usage.sevenDayOpus,
           opus.utilization >= fableThreshold {
            return .atLimit
        }
        return nil
    }

    public func isCandidate(_ account: AccountUsageState) -> Bool {
        rejection(for: account) == nil
    }

    func fiveHourUtilization(_ account: AccountUsageState) -> Double {
        account.usage?.fiveHour?.utilization ?? 0
    }

    func weeklyMargin(_ account: AccountUsageState) -> Double {
        let sevenDay = account.usage?.sevenDay?.utilization ?? 0
        guard considersFable else {
            return 100 - sevenDay
        }
        let opus = account.usage?.sevenDayOpus?.utilization ?? 0
        return 0.6 * (100 - sevenDay) + 0.4 * (100 - opus)
    }

    /// Puntos que le quedan a la cuenta hasta el umbral más próximo de las
    /// ventanas que cuentan. Una semana no informada (Team) no se puede medir.
    func usefulRoom(_ account: AccountUsageState) -> Double {
        var room = triggerThreshold - fiveHourUtilization(account)
        if let sevenDay = account.usage?.sevenDay {
            room = min(room, weeklyThreshold - sevenDay.utilization)
        }
        if considersFable, let opus = account.usage?.sevenDayOpus {
            room = min(room, fableThreshold - opus.utilization)
        }
        return room
    }

    /// Cuándo caduca el cupo semanal de la cuenta.
    ///
    /// En las cuentas que informan de ambas, la semana general y la de Fable
    /// se reinician a la vez. Cuando falta la general (Team), la de Fable es
    /// la mejor estimación disponible. Sin ninguna, la semana aún no ha
    /// empezado y su cupo no caduca.
    public func weeklyDeadline(_ usage: UsageSnapshot) -> Date? {
        usage.sevenDay?.resetsAt ?? usage.sevenDayOpus?.resetsAt
    }

    /// Clave de orden de una candidata: menor es mejor.
    private func rank(
        _ account: AccountUsageState,
        now: Date
    ) -> (Int, Int, Double, Double) {
        let cramped = usefulRoom(account) < Self.minimumUsefulRoom ? 1 : 0
        let deadline = account.usage.flatMap(weeklyDeadline).map {
            Int(max(0, $0.timeIntervalSince(now)) / Self.deadlineTolerance)
        } ?? Int.max
        return (cramped, deadline, fiveHourUtilization(account), -weeklyMargin(account))
    }

    /// La mejor cuenta a la que cambiar, o nil si ninguna candidata sirve.
    public func bestCandidate(
        active: AccountUsageState,
        others: [AccountUsageState],
        now: Date = Date()
    ) -> String? {
        let candidates = others.filter { $0.id != active.id && isCandidate($0) }
        return candidates.min { rank($0, now: now) < rank($1, now: now) }?.id
    }

    /// Decisión completa: a qué cuenta cambiar dada la situación actual, o nil.
    public func decision(
        active: AccountUsageState,
        all: [AccountUsageState],
        now: Date = Date()
    ) -> String? {
        guard shouldSwitch(active: active) else { return nil }
        return bestCandidate(active: active, others: all, now: now)
    }

    /// Cuenta a la que conviene cambiar aunque la activa no esté en ningún
    /// límite, o nil.
    ///
    /// Una cuenta cuya semana se reinicia dentro de `expiringHorizon` y a la
    /// que aún le quedan `expiringMinimumRoom` puntos va a perder ese cupo si
    /// nadie lo usa. Si la activa se reinicia claramente más tarde, gastar
    /// antes el que caduca no cuesta nada: la activa conserva el suyo. Solo
    /// cuenta la semana general informada: sin ella no se sabe cuánto queda.
    public func expiringQuotaTarget(
        active: AccountUsageState,
        all: [AccountUsageState],
        now: Date = Date()
    ) -> String? {
        guard anticipatesExpiringQuota,
              let activeUsage = active.usage,
              !shouldSwitch(active: active) else { return nil }
        let activeDeadline = weeklyDeadline(activeUsage)
        let expiring = all.filter { account in
            guard account.id != active.id,
                  isCandidate(account),
                  usefulRoom(account) >= Self.minimumUsefulRoom,
                  let weekly = account.usage?.sevenDay,
                  let deadline = weekly.resetsAt,
                  deadline > now,
                  deadline.timeIntervalSince(now) <= Self.expiringHorizon,
                  weeklyThreshold - weekly.utilization >= Self.expiringMinimumRoom
            else { return false }
            guard let activeDeadline else { return true }
            return deadline.addingTimeInterval(Self.deadlineTolerance) < activeDeadline
        }
        return bestCandidate(active: active, others: expiring, now: now)
    }
}
