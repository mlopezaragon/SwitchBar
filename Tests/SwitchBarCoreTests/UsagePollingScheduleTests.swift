import Foundation
import Testing
@testable import SwitchBarCore

private let pollingEpoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test func activeAccountIsCheckedWithinAMinuteWithManyAccounts() {
    var schedule = UsagePollingSchedule()
    let accounts = ["active"] + (0..<20).map { "standby-\($0)" }
    var checks: [String: [Int]] = [:]
    for second in stride(from: 0, through: 1_800, by: 5) {
        let now = pollingEpoch.addingTimeInterval(Double(second))
        if let target = schedule.nextAccount(
            accounts: accounts, active: "active", snapshots: [:], blocked: [],
            activeInterval: 30, inactiveInterval: 300, now: now
        ) {
            checks[target, default: []].append(second)
            schedule.recordAttempt(target, now: now)
        }
    }
    let activeChecks = checks["active"] ?? []
    #expect(activeChecks.first == 0)
    #expect(zip(activeChecks, activeChecks.dropFirst()).allSatisfy { $1 - $0 <= 60 })
    // Even repeated failures of every request must not starve standby accounts.
    #expect(accounts.allSatisfy { checks[$0]?.isEmpty == false })
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

@Test func nearLimitUsesShorterIntervalEvenWithLongPreference() {
    #expect(UsagePollingSchedule.activeInterval(configured: 600, nearLimit: true) == 30)
    #expect(UsagePollingSchedule.activeInterval(configured: 600, nearLimit: false) == 60)
    #expect(UsagePollingSchedule.activeInterval(configured: 0, nearLimit: false) == 30)
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

@Test func npmAndBunRuntimesCannotBeAssumedSafeForTokenRotation() {
    #expect(ClaudeCodeProcessProbe.isAmbiguousRuntime("/opt/homebrew/bin/node"))
    #expect(ClaudeCodeProcessProbe.isAmbiguousRuntime("/usr/local/bin/bun"))
    #expect(!ClaudeCodeProcessProbe.isAmbiguousRuntime("/bin/zsh"))
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
