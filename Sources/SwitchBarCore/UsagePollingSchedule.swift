import Foundation

/// One shared admission gate for timers, panel refreshes and switch checks.
/// Failed requests consume a slot too; cached data never hides a failed attempt.
public struct UsagePollingSchedule: Sendable {
    public static let minimumSpacing: TimeInterval = 30
    /// Una cuenta en reposo con un cupo agotado no puede consumir más hasta
    /// su reinicio. Aun así se mira de vez en cuando, por si Anthropic lo
    /// adelanta (los reinicios de límite que concede a algunas cuentas).
    public static let saturatedRecheckInterval: TimeInterval = 3_600
    public private(set) var lastAttemptByAccount: [String: Date] = [:]
    public private(set) var budget = UsageRequestBudget()
    private var lastAccount: String?
    private var lastAttempt: Date?

    public init() {}

    public func canStart(now: Date) -> Bool {
        lastAttempt.map { now.timeIntervalSince($0) >= Self.minimumSpacing } ?? true
    }

    /// Cuánto falta para que el espaciado permita otra consulta.
    public func delayBeforeStart(now: Date) -> TimeInterval {
        lastAttempt.map { max(0, Self.minimumSpacing - now.timeIntervalSince($0)) } ?? 0
    }

    public func hasBudget(for account: String, now: Date) -> Bool {
        budget.canSpend(account, now: now)
    }

    public mutating func recordAttempt(_ account: String, now: Date) {
        lastAttempt = now
        lastAccount = account
        lastAttemptByAccount[account] = now
    }

    /// Solo gasta cupo una consulta que llegó a enviarse: esperar a que Claude
    /// Code renueve la sesión o encontrar la renovación aparcada no pregunta
    /// nada al endpoint de uso.
    public mutating func recordUsageRequest(_ account: String, now: Date) {
        budget.spend(account, now: now)
    }

    public mutating func recordUsageRateLimit(_ account: String, now: Date) {
        budget.drain(account, now: now)
    }

    public mutating func forgetAttempt(for account: String) {
        lastAttemptByAccount[account] = nil
    }

    /// Ritmo de la cuenta activa. Por debajo de lo que el cupo del servidor
    /// recupera, salvo cerca de un umbral del cambio automático: ahí se acepta
    /// gastar el margen acumulado para cambiar a tiempo, y el cupo estimado
    /// impide que esa ráfaga acabe en una pausa.
    public static func activeInterval(nearLimit: Bool) -> TimeInterval {
        nearLimit ? 60 : UsageRequestBudget.refillInterval
    }

    /// Hasta cuándo una cuenta no puede consumir porque tiene agotada la
    /// ventana de 5 horas o la semanal, o `nil` si puede. Fable no cuenta:
    /// agotarlo solo impide usar ese modelo.
    public static func saturatedUntil(_ snapshot: UsageSnapshot?, now: Date) -> Date? {
        guard let snapshot else { return nil }
        // Un minuto de margen: justo en el reinicio el servidor aún puede
        // devolver el porcentaje anterior.
        return [snapshot.fiveHour, snapshot.sevenDay]
            .compactMap { $0 }
            .filter { $0.utilization >= 100 }
            .compactMap { $0.resetsAt?.addingTimeInterval(60) }
            .filter { $0 > now }
            .max()
    }

    /// Prioritize the active account whenever due, but give overdue standby
    /// accounts every other slot so a failure cannot starve all alternatives.
    public func nextAccount(
        accounts: [String], active: String?, snapshots: [String: UsageSnapshot],
        blocked: Set<String>, activeInterval: TimeInterval,
        inactiveInterval: TimeInterval, prioritized: Set<String> = [], now: Date
    ) -> String? {
        guard canStart(now: now) else { return nil }
        func lastCheck(_ account: String) -> Date {
            max(lastAttemptByAccount[account] ?? .distantPast,
                snapshots[account]?.fetchedAt ?? .distantPast)
        }
        func isDue(_ account: String) -> Bool {
            guard !blocked.contains(account), budget.canSpend(account, now: now) else {
                return false
            }
            let elapsed = now.timeIntervalSince(lastCheck(account))
            if account == active { return elapsed >= activeInterval }
            guard elapsed >= inactiveInterval else { return false }
            // Agotada y en reposo: su uso no puede cambiar hasta el reinicio.
            return Self.saturatedUntil(snapshots[account], now: now) == nil
                || elapsed >= Self.saturatedRecheckInterval
        }
        let due = accounts.filter(isDue)
        let standby = due.filter { $0 != active }.min {
            if prioritized.contains($0) != prioritized.contains($1) {
                return prioritized.contains($0)
            }
            return lastCheck($0) < lastCheck($1)
        }
        if let active, due.contains(active), lastAccount != active || standby == nil {
            return active
        }
        return standby ?? due.first
    }
}

public enum UsageRetryPolicy {
    /// Retry-After is a minimum requested by the server, never a ceiling.
    /// Without one, retry usage after 1, 2, 4... minutes (at most 15).
    /// Token renewal has a separate, deliberately much slower policy.
    public static func delay(retryAfter: TimeInterval?, streak: Int, renewal: Bool) -> TimeInterval {
        if let retryAfter, retryAfter.isFinite, retryAfter > 0 {
            return max(30, retryAfter)
        }
        let exponent = Double(min(10, max(1, streak) - 1))
        if renewal {
            return streak >= 3 ? 43_200 : min(21_600, 7_200 * pow(2, exponent))
        }
        return min(900, 60 * pow(2, exponent))
    }
}
