import SwiftUI
import ClaudeSwitchCore

/// Tarjeta de una cuenta en el panel: estado, correo, barras de uso y cambio con un clic.
struct AccountCardView: View {
    let profile: AccountProfile
    let usage: UsageSnapshot?
    let isActive: Bool
    let onSwitch: () -> Void

    @State private var hovering = false

    private var statusColor: Color {
        if profile.needsLogin { return .orange }
        return isActive ? .green : Color.secondary.opacity(0.5)
    }

    var body: some View {
        Button(action: { if !isActive && !profile.needsLogin { onSwitch() } }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(profile.emailAddress)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if isActive {
                        Text("Activa")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                            .foregroundStyle(.green)
                    } else if profile.needsLogin {
                        Text("Requiere sesión")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                            .foregroundStyle(.orange)
                    } else if hovering {
                        Text("Cambiar")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 5) {
                    UsageBar(label: "5 horas", window: usage?.fiveHour, cap: profile.sharedFiveHourCap)
                    UsageBar(label: "Semana", window: usage?.sevenDay, cap: profile.sharedWeeklyCap)
                    UsageBar(label: "Fable", window: usage?.sevenDayOpus, cap: profile.sharedWeeklyCap)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovering && !isActive ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isActive ? Color.green.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
