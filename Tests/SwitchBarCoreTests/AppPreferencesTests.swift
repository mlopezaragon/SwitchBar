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
