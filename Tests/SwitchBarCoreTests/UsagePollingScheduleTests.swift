import Foundation
import Testing
@testable import SwitchBarCore

private let pollingEpoch = Date(timeIntervalSince1970: 1_800_000_000)

/// Simulates the timer: every five seconds, whatever account is due is
/// queried, and every query reaches the server.
private func simulate(
    _ schedule: inout UsagePollingSchedule, accounts: [String], active: String,
    activeInterval: TimeInterval, snapshots: [String: UsageSnapshot] = [:],
    from start: Int = 0, seconds: Int
) -> [String: [Int]] {
    var checks: [String: [Int]] = [:]
    for second in stride(from: start, through: start + seconds, by: 5) {
        let now = pollingEpoch.addingTimeInterval(Double(second))
        if let target = schedule.nextAccount(
            accounts: accounts, active: active, snapshots: snapshots, blocked: [],
            activeInterval: activeInterval, inactiveInterval: 300, now: now
        ) {
            checks[target, default: []].append(second)
            schedule.recordAttempt(target, now: now)
            schedule.recordUsageRequest(target, now: now)
        }
    }
    return checks
}

@Test func activeAccountKeepsAPaceItsServerQuotaSustainsWithManyAccounts() {
    var schedule = UsagePollingSchedule()
    let accounts = ["active"] + (0..<20).map { "standby-\($0)" }
    let checks = simulate(
        &schedule, accounts: accounts, active: "active",
        activeInterval: UsagePollingSchedule.activeInterval(nearLimit: false), seconds: 7_200
    )
    let activeChecks = checks["active"] ?? []
    #expect(activeChecks.first == 0)
    // One query per refill period, plus at most one spacing slot of delay:
    // never faster than the server recovers, never left behind.
    #expect(zip(activeChecks, activeChecks.dropFirst()).allSatisfy {
        (150...180).contains($1 - $0)
    })
    // Even repeated failures of every request must not starve standby accounts.
    #expect(accounts.allSatisfy { checks[$0]?.isEmpty == false })
}

@Test func aBurstNearALimitCannotDrainTheServerQuota() {
    var schedule = UsagePollingSchedule()
    let checks = simulate(
        &schedule, accounts: ["active"], active: "active",
        activeInterval: UsagePollingSchedule.activeInterval(nearLimit: true), seconds: 3_600
    )["active"] ?? []
    // The saved-up margin allows a short burst at the faster pace...
    #expect(checks.prefix(5) == [0, 60, 120, 180, 240])
    // ...after which queries settle at the recovery rate: a minute-by-minute
    // pace used to empty the real quota within half an hour.
    let lastHalf = checks.filter { $0 >= 1_800 }
    #expect(lastHalf.count <= 1_800 / 150 + 1)
    #expect(checks.count <= Int(UsageRequestBudget.capacity) + 3_600 / 150 + 1)
}

@Test func aRateLimitEmptiesTheEstimatedQuota() {
    var schedule = UsagePollingSchedule()
    schedule.recordAttempt("a", now: pollingEpoch)
    schedule.recordUsageRateLimit("a", now: pollingEpoch)
    #expect(!schedule.hasBudget(for: "a", now: pollingEpoch.addingTimeInterval(149)))
    #expect(schedule.nextAccount(
        accounts: ["a"], active: "a", snapshots: [:], blocked: [],
        activeInterval: 60, inactiveInterval: 300, now: pollingEpoch.addingTimeInterval(120)
    ) == nil)
    #expect(schedule.nextAccount(
        accounts: ["a"], active: "a", snapshots: [:], blocked: [],
        activeInterval: 60, inactiveInterval: 300, now: pollingEpoch.addingTimeInterval(150)
    ) == "a")
    // Other accounts keep their own quota.
    #expect(schedule.hasBudget(for: "b", now: pollingEpoch))
}

@Test func requestsThatNeverReachTheServerDoNotSpendQuota() {
    var budget = UsageRequestBudget()
    #expect(budget.available("a", now: pollingEpoch) == UsageRequestBudget.capacity)
    for _ in 0..<Int(UsageRequestBudget.capacity) { budget.spend("a", now: pollingEpoch) }
    #expect(!budget.canSpend("a", now: pollingEpoch))
    #expect(budget.canSpend("a", now: pollingEpoch.addingTimeInterval(150)))
    #expect(budget.available("a", now: pollingEpoch.addingTimeInterval(100_000)) == UsageRequestBudget.capacity)

    // Waiting for Claude Code or for a parked renewal only records an attempt.
    var schedule = UsagePollingSchedule()
    for second in stride(from: 0, to: 600, by: 30) {
        schedule.recordAttempt("a", now: pollingEpoch.addingTimeInterval(Double(second)))
    }
    #expect(schedule.budget.available("a", now: pollingEpoch.addingTimeInterval(600)) == UsageRequestBudget.capacity)
}

@Test func anExhaustedStandbyAccountWaitsForItsResetInsteadOfPolling() {
    let reset = pollingEpoch.addingTimeInterval(7_200)
    let exhausted = UsageSnapshot(
        fiveHour: UsageWindow(utilization: 20, resetsAt: pollingEpoch.addingTimeInterval(3_000)),
        sevenDay: UsageWindow(utilization: 100, resetsAt: reset),
        sevenDayOpus: nil, fetchedAt: pollingEpoch
    )
    #expect(UsagePollingSchedule.saturatedUntil(exhausted, now: pollingEpoch) == reset.addingTimeInterval(60))
    // Fable alone does not stop the account from consuming.
    let fableOnly = UsageSnapshot(
        fiveHour: nil, sevenDay: UsageWindow(utilization: 40, resetsAt: reset),
        sevenDayOpus: UsageWindow(utilization: 100, resetsAt: reset), fetchedAt: pollingEpoch
    )
    #expect(UsagePollingSchedule.saturatedUntil(fableOnly, now: pollingEpoch) == nil)

    var schedule = UsagePollingSchedule()
    let early = simulate(
        &schedule, accounts: ["active", "full", "free"], active: "active",
        activeInterval: 150, snapshots: ["full": exhausted], seconds: 3_500
    )
    // The free standby account follows its interval; the exhausted one waits.
    #expect((early["free"]?.count ?? 0) >= 10)
    #expect(early["full"] == nil)
    // An hourly look covers an early reset, and right after the real reset
    // the account is checked again.
    let later = simulate(
        &schedule, accounts: ["active", "full", "free"], active: "active",
        activeInterval: 150, snapshots: ["full": exhausted], from: 3_505, seconds: 200
    )
    #expect(later["full"]?.count == 1)
    #expect(UsagePollingSchedule.saturatedUntil(exhausted, now: reset.addingTimeInterval(61)) == nil)
}

@Test func manualRefreshCannotCreateABurstOrStealTheNextSlot() {
    var schedule = UsagePollingSchedule()
    schedule.recordAttempt("active", now: pollingEpoch)
    for second in 0..<30 {
        #expect(!schedule.canStart(now: pollingEpoch.addingTimeInterval(Double(second))))
    }
    #expect(schedule.canStart(now: pollingEpoch.addingTimeInterval(30)))
    #expect(schedule.lastAttemptByAccount["standby"] == nil)
}

@Test func cooldownOfActiveAccountDoesNotBlockOthers() {
    var schedule = UsagePollingSchedule()
    for second in stride(from: 0, through: 90, by: 30) {
        let now = pollingEpoch.addingTimeInterval(Double(second))
        let target = schedule.nextAccount(
            accounts: ["a", "b", "c"], active: "a", snapshots: [:], blocked: ["a"],
            activeInterval: 30, inactiveInterval: 300, now: now
        )
        #expect(target != "a")
        if let target { schedule.recordAttempt(target, now: now) }
    }
    #expect(schedule.lastAttemptByAccount["b"] != nil)
    #expect(schedule.lastAttemptByAccount["c"] != nil)
    #expect(schedule.nextAccount(
        accounts: ["a", "b", "c"], active: "a", snapshots: [:], blocked: [],
        activeInterval: 30, inactiveInterval: 300, now: pollingEpoch.addingTimeInterval(120)
    ) == "a")
}

@Test func restoredSnapshotsAndFailedAttemptsHaveIndependentFreshness() {
    var schedule = UsagePollingSchedule()
    let snapshots = ["a": UsageSnapshot(fiveHour: nil, sevenDay: nil, sevenDayOpus: nil, fetchedAt: pollingEpoch)]
    #expect(schedule.nextAccount(
        accounts: ["a"], active: "a", snapshots: snapshots, blocked: [],
        activeInterval: 60, inactiveInterval: 300, now: pollingEpoch.addingTimeInterval(30)
    ) == nil)
    schedule.recordAttempt("a", now: pollingEpoch.addingTimeInterval(60))
    #expect(schedule.nextAccount(
        accounts: ["a"], active: "a", snapshots: snapshots, blocked: [],
        activeInterval: 60, inactiveInterval: 300, now: pollingEpoch.addingTimeInterval(90)
    ) == nil)
    #expect(schedule.nextAccount(
        accounts: ["a"], active: "a", snapshots: snapshots, blocked: [],
        activeInterval: 60, inactiveInterval: 300, now: pollingEpoch.addingTimeInterval(120)
    ) == "a")
}

@Test func accountChangePrioritizesTheNewActiveAccount() {
    var schedule = UsagePollingSchedule()
    schedule.recordAttempt("a", now: pollingEpoch)
    #expect(schedule.nextAccount(
        accounts: ["a", "b", "c"], active: "c", snapshots: [:], blocked: [],
        activeInterval: 60, inactiveInterval: 300, now: pollingEpoch.addingTimeInterval(30)
    ) == "c")
}

@Test func activePaceMatchesWhatTheServerQuotaRecovers() {
    #expect(UsagePollingSchedule.activeInterval(nearLimit: false) == UsageRequestBudget.refillInterval)
    #expect(UsagePollingSchedule.activeInterval(nearLimit: true) == 60)
}

@Test func usageRetriesDoNotInheritTheHoursLongRenewalBackoff() {
    #expect(UsageRetryPolicy.delay(retryAfter: nil, streak: 1, renewal: false) == 60)
    #expect(UsageRetryPolicy.delay(retryAfter: nil, streak: 2, renewal: false) == 120)
    #expect(UsageRetryPolicy.delay(retryAfter: nil, streak: 3, renewal: false) == 240)
    #expect(UsageRetryPolicy.delay(retryAfter: nil, streak: Int.max, renewal: false) == 900)
    #expect(UsageRetryPolicy.delay(retryAfter: nil, streak: 1, renewal: true) == 7_200)
    #expect(UsageRetryPolicy.delay(retryAfter: nil, streak: 3, renewal: true) == 43_200)
}

@Test func serverRetryAfterIsNeitherMultipliedNorTruncated() {
    for renewal in [true, false] {
        #expect(UsageRetryPolicy.delay(retryAfter: 123, streak: 8, renewal: renewal) == 123)
        #expect(UsageRetryPolicy.delay(retryAfter: 86_400, streak: 1, renewal: renewal) == 86_400)
        #expect(UsageRetryPolicy.delay(retryAfter: 0, streak: 1, renewal: renewal) >= 60)
        #expect(UsageRetryPolicy.delay(retryAfter: .infinity, streak: 1, renewal: renewal).isFinite)
    }
}

@Test func newlyLinkedAccountGetsTheNextStandbySlotWithoutABurst() {
    var schedule = UsagePollingSchedule()
    schedule.recordAttempt("active", now: pollingEpoch)
    #expect(schedule.nextAccount(
        accounts: ["active", "old", "new"], active: "active", snapshots: [:], blocked: [],
        activeInterval: 60, inactiveInterval: 300, prioritized: ["new"], now: pollingEpoch.addingTimeInterval(5)
    ) == nil)
    #expect(schedule.nextAccount(
        accounts: ["active", "old", "new"], active: "active", snapshots: [:], blocked: [],
        activeInterval: 60, inactiveInterval: 300, prioritized: ["new"], now: pollingEpoch.addingTimeInterval(30)
    ) == "new")
}

@Test func theSpacingTellsHowLongUntilTheNextRequest() {
    var schedule = UsagePollingSchedule()
    #expect(schedule.delayBeforeStart(now: pollingEpoch) == 0)
    schedule.recordAttempt("a", now: pollingEpoch)
    #expect(schedule.delayBeforeStart(now: pollingEpoch.addingTimeInterval(10)) == 20)
    #expect(schedule.delayBeforeStart(now: pollingEpoch.addingTimeInterval(45)) == 0)
}

@Test func aStandbyWhoseWindowJustResetIsReadInTheNextFreeSlot() throws {
    // A Team account read at 95 % whose 5-hour window resets at 400 s. Its
    // regular interval would wait until 600 s; the automatic switch wants to
    // know right away that it has room again.
    let reset = pollingEpoch.addingTimeInterval(400)
    let team = UsageSnapshot(
        fiveHour: UsageWindow(utilization: 95, resetsAt: reset),
        sevenDay: nil, sevenDayOpus: nil, fetchedAt: pollingEpoch.addingTimeInterval(300)
    )
    var schedule = UsagePollingSchedule()
    schedule.recordAttempt("team", now: pollingEpoch.addingTimeInterval(300))
    let checks = simulate(
        &schedule, accounts: ["active", "team"], active: "active",
        activeInterval: 150, snapshots: ["team": team], from: 305, seconds: 290
    )
    let first = try #require(checks["team"]?.first)
    #expect((460...495).contains(first))
    // Only once: afterwards it follows its regular interval again.
    #expect(checks["team"]?.count == 1)
    #expect(UsagePollingSchedule.resetSinceLastCheck(team, lastCheck: reset, now: reset.addingTimeInterval(59)) == false)
    #expect(UsagePollingSchedule.resetSinceLastCheck(team, lastCheck: reset, now: reset.addingTimeInterval(60)))
    #expect(UsagePollingSchedule.resetSinceLastCheck(team, lastCheck: reset.addingTimeInterval(60), now: reset.addingTimeInterval(120)) == false)
}
