import SwiftUI

@main
struct ClaudeSwitchApp: App {
    @State private var state = AppState()

    init() {
        Notifier.requestPermission()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView(state: state)
        } label: {
            MenuBarIcon(fraction: state.activeFiveHourFraction)
        }
        .menuBarExtraStyle(.window)

        Window("ClaudeSwitch", id: "detalle") {
            DetailView(state: state)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 640, height: 560)
    }
}

/// Icono de la barra: anillo con el uso de 5 h de la cuenta activa.
struct MenuBarIcon: View {
    var fraction: Double?

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.25), lineWidth: 1.8)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(.primary, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .fill(.primary)
                    .frame(width: 3, height: 3)
            }
        }
        .frame(width: 15, height: 15)
        .padding(.horizontal, 2)
    }
}
