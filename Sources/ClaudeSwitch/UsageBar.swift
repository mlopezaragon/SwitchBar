import SwiftUI
import ClaudeSwitchCore

/// Barra fina de uso con etiqueta, porcentaje y reseteo relativo.
struct UsageBar: View {
    let label: String
    let window: UsageWindow?

    private var fraction: Double {
        guard let u = window?.utilization else { return 0 }
        return min(max(u / 100, 0), 1)
    }

    private var fillColor: Color {
        guard let u = window?.utilization else { return .secondary }
        if u >= 90 { return .red }
        if u >= 75 { return .orange }
        return .accentColor
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(4, geo.size.width * fraction))
                        .opacity(window == nil ? 0 : 1)
                }
            }
            .frame(height: 4)

            Text(window.map { "\(Int($0.utilization.rounded())) %" } ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(window == nil ? .tertiary : .primary)
                .frame(width: 42, alignment: .trailing)

            Text(resetText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .trailing)
                .lineLimit(1)
        }
    }

    private var resetText: String {
        guard let date = window?.resetsAt else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
