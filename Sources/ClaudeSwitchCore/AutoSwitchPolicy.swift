import Foundation

/// Estado de uso de una cuenta para la política de cambio automático.
public struct AccountUsageState: Sendable {
    public var accountUuid: String
    public var usage: UsageSnapshot?
    public var needsLogin: Bool

    public init(accountUuid: String, usage: UsageSnapshot?, needsLogin: Bool) {
        self.accountUuid = accountUuid
        self.usage = usage
        self.needsLogin = needsLogin
    }
}

/// Política pura (sin efectos) del cambio automático.
///
/// Disparo: la ventana de 5 h o la semana general alcanzan su umbral. Fable
/// participa únicamente cuando `considersFable` está activado.
/// Candidatas: cuentas con sesión válida, datos de uso, y las ventanas
/// relevantes por debajo de sus respectivos umbrales.
/// Elección: menor uso de 5 h; desempate por mayor margen ponderado
/// de los cupos que estén habilitados.
public struct AutoSwitchPolicy: Sendable {
    public var triggerThreshold: Double
    public var weeklyThreshold: Double
    public var fableThreshold: Double
    public var considersFable: Bool

    public init(
        triggerThreshold: Double = 90,
        weeklyThreshold: Double = 95,
        fableThreshold: Double = 95,
        considersFable: Bool = false
    ) {
        self.triggerThreshold = triggerThreshold
        self.weeklyThreshold = weeklyThreshold
        self.fableThreshold = fableThreshold
        self.considersFable = considersFable
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

    public func isCandidate(_ account: AccountUsageState) -> Bool {
        guard !account.needsLogin, let usage = account.usage, let fiveHour = usage.fiveHour else { return false }
        if fiveHour.utilization >= triggerThreshold { return false }
        if let sevenDay = usage.sevenDay,
           sevenDay.utilization >= weeklyThreshold {
            return false
        }
        if considersFable,
           let opus = usage.sevenDayOpus,
           opus.utilization >= fableThreshold {
            return false
        }
        return true
    }

    func weeklyMargin(_ account: AccountUsageState) -> Double {
        let sevenDay = account.usage?.sevenDay?.utilization ?? 0
        guard considersFable else {
            return 100 - sevenDay
        }
        let opus = account.usage?.sevenDayOpus?.utilization ?? 0
        return 0.6 * (100 - sevenDay) + 0.4 * (100 - opus)
    }

    /// La mejor cuenta a la que cambiar, o nil si ninguna candidata sirve.
    public func bestCandidate(active: AccountUsageState, others: [AccountUsageState]) -> String? {
        let candidates = others.filter { $0.accountUuid != active.accountUuid && isCandidate($0) }
        guard !candidates.isEmpty else { return nil }
        let best = candidates.min { a, b in
            let fa = a.usage!.fiveHour!.utilization
            let fb = b.usage!.fiveHour!.utilization
            if fa != fb { return fa < fb }
            return weeklyMargin(a) > weeklyMargin(b)
        }
        return best?.accountUuid
    }

    /// Decisión completa: a qué cuenta cambiar dada la situación actual, o nil.
    public func decision(active: AccountUsageState, all: [AccountUsageState]) -> String? {
        guard shouldSwitch(active: active) else { return nil }
        return bestCandidate(active: active, others: all)
    }
}
