import Foundation

/// One shared admission gate for timers, panel refreshes and switch checks.
/// Failed requests consume a slot too; cached data never hides a failed attempt.
public struct UsagePollingSchedule: Sendable {
    public static let minimumSpacing: TimeInterval = 30
    public private(set) var lastAttemptByAccount: [String: Date] = [:]
    private var lastAccount: String?
    private var lastAttempt: Date?

    public init() {}

    public func canStart(now: Date) -> Bool {
        lastAttempt.map { now.timeIntervalSince($0) >= Self.minimumSpacing } ?? true
    }

    public mutating func recordAttempt(_ account: String, now: Date) {
        lastAttempt = now
        lastAccount = account
        lastAttemptByAccount[account] = now
    }

    public mutating func forgetAttempt(for account: String) {
        lastAttemptByAccount[account] = nil
    }

    public static func activeInterval(configured: TimeInterval, nearLimit: Bool) -> TimeInterval {
        nearLimit ? 30 : min(60, max(30, configured))
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
        let due = accounts.filter {
            !blocked.contains($0) && now.timeIntervalSince(lastCheck($0)) >=
                ($0 == active ? activeInterval : inactiveInterval)
        }
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
