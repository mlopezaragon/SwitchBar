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
/// Disparo: la ventana de 5 h de la cuenta activa alcanza `triggerThreshold`.
/// Candidatas: cuentas con sesión válida, datos de uso, y las ventanas
/// semanales (total y de Opus/Fable) por debajo de `weeklyCeiling`.
/// Elección: menor uso de 5 h; desempate por mayor margen ponderado
/// 0,6·(100−semanal) + 0,4·(100−opus).
public struct AutoSwitchPolicy: Sendable {
    public var triggerThreshold: Double
    public var weeklyCeiling: Double

    public init(triggerThreshold: Double = 90, weeklyCeiling: Double = 95) {
        self.triggerThreshold = triggerThreshold
        self.weeklyCeiling = weeklyCeiling
    }

    public func shouldSwitch(active: AccountUsageState) -> Bool {
        guard let fiveHour = active.usage?.fiveHour else { return false }
        return fiveHour.utilization >= triggerThreshold
    }

    public func isCandidate(_ account: AccountUsageState) -> Bool {
        guard !account.needsLogin, let usage = account.usage, let fiveHour = usage.fiveHour else { return false }
        if fiveHour.utilization >= triggerThreshold { return false }
        if let sevenDay = usage.sevenDay, sevenDay.utilization >= weeklyCeiling { return false }
        if let opus = usage.sevenDayOpus, opus.utilization >= weeklyCeiling { return false }
        return true
    }

    func weeklyMargin(_ account: AccountUsageState) -> Double {
        let sevenDay = account.usage?.sevenDay?.utilization ?? 0
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
