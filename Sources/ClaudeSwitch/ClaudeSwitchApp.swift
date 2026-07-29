import SwiftUI

@main
struct ClaudeSwitchApp: App {
    var body: some Scene {
        MenuBarExtra("ClaudeSwitch", systemImage: "person.2.circle") {
            Text("ClaudeSwitch")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
