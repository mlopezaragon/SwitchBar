import Foundation
import Testing
@testable import SwitchBarCore

@Test
func laPreferenciaDeFableSobreviveAlReinicio() throws {
    let suiteName = "SwitchBar-preferences-\(UUID().uuidString)"
    let firstDefaults = try #require(
        UserDefaults(suiteName: suiteName)
    )
    firstDefaults.removePersistentDomain(forName: suiteName)
    defer {
        firstDefaults.removePersistentDomain(forName: suiteName)
    }

    let firstLaunch = AppPreferences(defaults: firstDefaults)
    #expect(firstLaunch.useFableForAutoSwitch == false)
    firstLaunch.useFableForAutoSwitch = true
    firstLaunch.fableTriggerThreshold = 97
    firstLaunch.lastObservedAccountUuid = "cuenta-a"

    let reopenedDefaults = try #require(
        UserDefaults(suiteName: suiteName)
    )
    let reopened = AppPreferences(defaults: reopenedDefaults)

    #expect(reopened.useFableForAutoSwitch == true)
    #expect(reopened.fableTriggerThreshold == 97)
    #expect(reopened.lastObservedAccountUuid == "cuenta-a")
}

@Test
func adelantarseAlCupoQueCaducaEstaActivadoYSeRecuerdaLaEleccionManual() throws {
    let suiteName = "SwitchBar-preferences-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = AppPreferences(defaults: defaults)
    #expect(first.anticipateExpiringQuota == true)
    #expect(first.manuallyChosenProfileID == nil)
    first.anticipateExpiringQuota = false
    first.manuallyChosenProfileID = "cuenta-a/org-1"

    let reopened = AppPreferences(
        defaults: try #require(UserDefaults(suiteName: suiteName))
    )
    #expect(reopened.anticipateExpiringQuota == false)
    #expect(reopened.manuallyChosenProfileID == "cuenta-a/org-1")
    reopened.manuallyChosenProfileID = nil
    #expect(reopened.manuallyChosenProfileID == nil)

    #expect(reopened.leftByUserTimestamps.isEmpty)
    reopened.leftByUserTimestamps = ["cuenta-b": 1_800_000_000]
    let again = AppPreferences(
        defaults: try #require(UserDefaults(suiteName: suiteName))
    )
    #expect(again.leftByUserTimestamps == ["cuenta-b": 1_800_000_000])
}
