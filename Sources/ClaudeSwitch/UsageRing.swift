import SwiftUI
import ClaudeSwitchCore

/// Anillo de progreso grande para la ventana de detalle.
struct UsageRing: View {
    let label: String
    let window: UsageWindow?

    private var fraction: Double {
        guard let u = window?.utilization else { return 0 }
        return min(max(u / 100, 0), 1)
    }

    private var ringColor: Color {
        guard let u = window?.utilization else { return .secondary }
        if u >= 90 { return .red }
        if u >= 75 { return .orange }
        return .accentColor
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: fraction)
                Text(window.map { "\(Int($0.utilization.rounded())) %" } ?? "—")
                    .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .frame(width: 68, height: 68)

            VStack(spacing: 2) {
                Text(label)
                    .font(.caption.weight(.medium))
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 96)
    }

    private var resetText: String {
        guard let date = window?.resetsAt else { return " " }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.unitsStyle = .short
        return "resetea " + f.localizedString(for: date, relativeTo: Date())
    }
}
