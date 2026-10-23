import Foundation

/// Estado de uso de una cuenta para la política de cambio automático.
public struct AccountUsageState: Sendable {
    public var id: String
    public var usage: UsageSnapshot?
    public var needsLogin: Bool
    /// El usuario salió a mano de esta cuenta y aún no ha llegado su reinicio
    /// semanal. Puede saber algo que la app no ve, como el límite semanal de
    /// Team, que Anthropic no informa: la cuenta queda para el final y el
    /// modo autónomo no vuelve a ella por su cuenta.
    public var leftByUser: Bool

    public init(id: String, usage: UsageSnapshot?, needsLogin: Bool, leftByUser: Bool = false) {
        self.id = id
        self.usage = usage
        self.needsLogin = needsLogin
        self.leftByUser = leftByUser
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
/// 0. Las que el usuario no ha abandonado a mano (`leftByUser`) van antes.
/// 1. Las que tienen margen útil (`minimumUsefulRoom`) en todas sus ventanas
///    van antes que las que obligarían a cambiar otra vez a los pocos minutos.
/// 2. La que antes reinicia su semana, aunque sea por minutos. Lo que no se
///    gasta antes del reinicio se pierde; las que reinician más tarde
///    conservan su cupo para después.
/// 3. Menor uso de 5 h.
/// 4. Mayor margen ponderado de los cupos semanales que estén habilitados.
public struct AutoSwitchPolicy: Sendable {
    public var triggerThreshold: Double
    public var weeklyThreshold: Double
    public var fableThreshold: Double
    public var considersFable: Bool
    /// Gestión autónoma: cambiar sin esperar a un límite a la cuenta cuyo
    /// cupo semanal caduca antes. Ver `expiringQuotaTarget`.
    public var anticipatesExpiringQuota: Bool

    /// Puntos hasta el umbral por debajo de los cuales una cuenta solo sirve
    /// de último recurso: se gastarían en minutos y habría que volver a cambiar.
    public static let minimumUsefulRoom: Double = 5
    /// Cuánto antes debe caducar el cupo de otra cuenta para cambiar a ella
    /// sin esperar a un límite. Por debajo, el cambio no aprovecha nada.
    public static let anticipationMargin: TimeInterval = 30 * 60
    /// Margen mínimo, en todas sus ventanas informadas, de la cuenta a la que
    /// se adelanta el cambio. Con menos se gastaría enseguida y habría que
    /// volver a cambiar, solo para regresar en su siguiente ventana de 5 h.
    public static let anticipationMinimumRoom: Double = 15

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

    /// Clave de orden de una candidata: menor es mejor. Una semana sin fecha
    /// de reinicio va la última: su cupo no caduca.
    private func rank(
        _ account: AccountUsageState
    ) -> (Int, Int, Double, Double, Double) {
        let left = account.leftByUser ? 1 : 0
        let cramped = usefulRoom(account) < Self.minimumUsefulRoom ? 1 : 0
        let deadline = account.usage.flatMap(weeklyDeadline)?.timeIntervalSince1970 ?? .infinity
        return (left, cramped, deadline, fiveHourUtilization(account), -weeklyMargin(account))
    }

    /// La mejor cuenta a la que cambiar, o nil si ninguna candidata sirve.
    public func bestCandidate(
        active: AccountUsageState,
        others: [AccountUsageState]
    ) -> String? {
        let candidates = others.filter { $0.id != active.id && isCandidate($0) }
        return candidates.min { rank($0) < rank($1) }?.id
    }

    /// Decisión completa: a qué cuenta cambiar dada la situación actual, o nil.
    public func decision(
        active: AccountUsageState,
        all: [AccountUsageState]
    ) -> String? {
        guard shouldSwitch(active: active) else { return nil }
        return bestCandidate(active: active, others: all)
    }

    /// Cuenta a la que conviene cambiar aunque la activa no esté en ningún
    /// límite, o nil.
    ///
    /// Mantiene activa la cuenta cuyo cupo semanal caduca antes: si otra con
    /// margen holgado (`anticipationMinimumRoom`) se reinicia al menos
    /// `anticipationMargin` antes que la activa, gastar primero el suyo no
    /// cuesta nada y la activa conserva el propio para después. Los umbrales
    /// se respetan igual que en cualquier cambio. En Team, cuya semana general
    /// no se informa, cuentan las ventanas que sí se informan y el reinicio
    /// de Fable.
    public func expiringQuotaTarget(
        active: AccountUsageState,
        all: [AccountUsageState],
        now: Date = Date()
    ) -> String? {
        guard anticipatesExpiringQuota,
              let activeUsage = active.usage,
              !shouldSwitch(active: active) else { return nil }
        let activeDeadline = weeklyDeadline(activeUsage)
        let expiringFirst = all.filter { account in
            guard account.id != active.id,
                  !account.leftByUser,
                  isCandidate(account),
                  usefulRoom(account) >= Self.anticipationMinimumRoom,
                  let deadline = account.usage.flatMap(weeklyDeadline),
                  deadline > now
            else { return false }
            guard let activeDeadline else { return true }
            return deadline.addingTimeInterval(Self.anticipationMargin) <= activeDeadline
        }
        return bestCandidate(active: active, others: expiringFirst)
    }
}
