import Foundation

/// Hasta cuándo alcanza el cupo de todas las cuentas si se sigue trabajando.
public struct CoverageForecast: Sendable, Equatable {
    public enum Basis: Sendable, Equatable {
        /// Ritmo medido ahora mismo en la cuenta activa.
        case currentPace
        /// Ritmo habitual de cada cuenta: ahora no se está usando.
        case typicalPace
    }

    /// Momento en que ninguna cuenta tendría cupo, o `nil` si no ocurre
    /// dentro de `horizon`.
    public var runsOutAt: Date?
    /// Cuándo volvería a haber cupo tras quedarse sin él, si se sabe dentro
    /// del horizonte.
    public var resumesAt: Date?
    public var horizon: TimeInterval
    public var basis: Basis
}

/// Simulación del uso continuo de las cuentas, minuto a minuto.
///
/// Supone que se trabaja sin parar al ritmo indicado, que una sesión sigue
/// con su cuenta hasta agotarla (como hace Claude Code) y que entonces
/// continúa en la que elegiría el cambio automático. Las ventanas de 5 h se
/// reinician a su hora y se abren al volver a usarse. Las cuentas sin ritmo
/// conocido o sin datos no cuentan: la previsión prefiere quedarse corta.
public enum CoveragePlanner {
    public static let horizon: TimeInterval = 12 * 3_600
    static let step: TimeInterval = 60
    static let fiveHourWindow: TimeInterval = 5 * 3_600

    private struct Simulated {
        var state: AccountUsageState
        var fiveHour: Double
        var fiveHourResetsAt: Date?
        var sevenDay: Double?
        var sevenDayResetsAt: Date?

        init(_ state: AccountUsageState) {
            self.state = state
            fiveHour = state.usage?.fiveHour?.utilization ?? 0
            fiveHourResetsAt = state.usage?.fiveHour?.resetsAt
            sevenDay = state.usage?.sevenDay?.utilization
            sevenDayResetsAt = state.usage?.sevenDay?.resetsAt
        }

        var exhausted: Bool {
            fiveHour >= 100 || (sevenDay.map { $0 >= 100 } ?? false)
        }

        mutating func advance(to now: Date) {
            if let reset = fiveHourResetsAt, reset <= now {
                fiveHour = 0
                fiveHourResetsAt = nil
            }
            if let reset = sevenDayResetsAt, reset <= now {
                sevenDay = sevenDay.map { _ in 0 }
                sevenDayResetsAt = nil
            }
        }

        mutating func consume(for interval: TimeInterval, startingAt now: Date) {
            guard let pace = state.fiveHourPace, pace > 0 else { return }
            if fiveHourResetsAt == nil {
                fiveHourResetsAt = now.addingTimeInterval(CoveragePlanner.fiveHourWindow)
            }
            let points = pace * interval / 3_600
            fiveHour += points
            if let ratio = state.weeklyPerFiveHour, let weekly = sevenDay {
                sevenDay = weekly + points * ratio
            }
        }

        /// La cuenta tal y como la vería la política en ese instante.
        func snapshot(at now: Date) -> AccountUsageState {
            guard let usage = state.usage else { return state }
            var copy = state
            let opus = usage.sevenDayOpus.flatMap { window in
                window.resetsAt.map { $0 <= now } ?? false ? nil : window
            }
            copy.usage = UsageSnapshot(
                fiveHour: fiveHourResetsAt == nil && fiveHour == 0
                    ? nil
                    : UsageWindow(utilization: fiveHour, resetsAt: fiveHourResetsAt),
                sevenDay: sevenDay.map { UsageWindow(utilization: $0, resetsAt: sevenDayResetsAt) },
                sevenDayOpus: opus,
                fetchedAt: now,
                weeklyLimitUnreported: usage.weeklyLimitUnreported
            )
            return copy
        }
    }

    public static func forecast(
        activeID: String,
        states: [AccountUsageState],
        policy: AutoSwitchPolicy,
        basis: CoverageForecast.Basis,
        now: Date = Date(),
        horizon: TimeInterval = CoveragePlanner.horizon
    ) -> CoverageForecast? {
        var accounts = states
            .filter { $0.usage != nil && !$0.needsLogin && ($0.fiveHourPace ?? 0) > 0 }
            .map(Simulated.init)
        guard let start = accounts.firstIndex(where: { $0.state.id == activeID }) else {
            return nil
        }
        var current: Int? = start
        var runsOutAt: Date?
        var t = now
        let end = now.addingTimeInterval(horizon)
        while t < end {
            for index in accounts.indices { accounts[index].advance(to: t) }
            if current == nil || accounts[current!].exhausted {
                current = nextAccount(after: current, in: accounts, policy: policy, at: t)
            }
            guard let index = current else {
                if runsOutAt == nil { runsOutAt = t }
                t = t.addingTimeInterval(step)
                continue
            }
            if runsOutAt != nil {
                return CoverageForecast(runsOutAt: runsOutAt, resumesAt: t, horizon: horizon, basis: basis)
            }
            accounts[index].consume(for: step, startingAt: t)
            t = t.addingTimeInterval(step)
        }
        return CoverageForecast(runsOutAt: runsOutAt, resumesAt: nil, horizon: horizon, basis: basis)
    }

    private static func nextAccount(
        after current: Int?,
        in accounts: [Simulated],
        policy: AutoSwitchPolicy,
        at now: Date
    ) -> Int? {
        let snapshots = accounts.map { $0.snapshot(at: now) }
        let active = current.map { snapshots[$0] }
            ?? AccountUsageState(id: "", usage: nil, needsLogin: false)
        let available = snapshots.indices
            .filter { !accounts[$0].exhausted }
            .map { snapshots[$0] }
        guard let id = policy.bestCandidate(active: active, others: available, now: now) else {
            return nil
        }
        return accounts.firstIndex { $0.state.id == id }
    }
}
