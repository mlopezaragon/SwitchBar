import SwiftUI
import ClaudeSwitchCore

/// Barra fina de uso con etiqueta, porcentaje y reseteo relativo.
struct UsageBar: View {
    let label: String
    let window: UsageWindow?
    /// Tope personal (0–100) en cuentas compartidas; dibuja una marca en la barra.
    var cap: Double? = nil

    private var fraction: Double {
        guard let u = window?.utilization else { return 0 }
        return min(max(u / 100, 0), 1)
    }

    /// Utilización relativa al tope personal (si lo hay) para elegir el color.
    private var effectiveUtilization: Double? {
        guard let u = window?.utilization else { return nil }
        guard let cap, cap > 0, cap < 100 else { return u }
        return min(100, u / cap * 100)
    }

    private var fillColor: Color {
        guard let u = effectiveUtilization else { return .secondary }
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
                    if let cap, cap > 0, cap < 100 {
                        Rectangle()
                            .fill(.secondary)
                            .frame(width: 1.5, height: 8)
                            .offset(x: geo.size.width * cap / 100)
                            .help("Tope personal: \(Int(cap)) %")
                    }
                }
            }
            .frame(height: 4)

            Text(window.map { "\(Int($0.utilization.rounded())) %" } ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(window == nil ? .tertiary : .primary)
                .frame(width: 38, alignment: .trailing)

            Text(ResetFormatter.compact(window?.resetsAt))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
                .lineLimit(1)
                .help(ResetFormatter.absolute(window?.resetsAt))
        }
    }
}
