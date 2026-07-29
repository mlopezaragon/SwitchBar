import SwiftUI
import ServiceManagement
import ClaudeSwitchCore

/// Ventana de detalle: anillos de uso por cuenta y ajustes.
struct DetailView: View {
    @Bindable var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headline

                if let unsaved = state.activeUnsaved {
                    HStack {
                        Text("La cuenta activa \(unsaved.emailAddress) no está guardada todavía.")
                            .font(.callout)
                        Spacer()
                        Button("Guardar cuenta") { state.captureActive() }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.08)))
                }

                ForEach(state.profilesList) { profile in
                    accountSection(profile)
                }

                settingsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(.background)
        .onAppear { state.refreshIfStale() }
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ClaudeSwitch")
                .font(.system(size: 22, weight: .semibold))
            if let active = state.activeProfile {
                Text("Cuenta activa: \(active.emailAddress)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func accountSection(_ profile: AccountProfile) -> some View {
        let usage = state.usageByAccount[profile.accountUuid]
        let isActive = profile.accountUuid == state.activeAccountUuid
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Circle()
                    .fill(profile.needsLogin ? Color.orange : (isActive ? Color.green : Color.secondary.opacity(0.4)))
                    .frame(width: 8, height: 8)
                Text(profile.emailAddress)
                    .font(.system(size: 15, weight: .medium))
                if let plan = profile.subscriptionType {
                    Text(plan.capitalized)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Text("Activa")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Button("Cambiar a esta cuenta") { state.switchTo(profile.accountUuid) }
                        .controlSize(.small)
                        .disabled(profile.needsLogin)
                }
                Menu {
                    Button("Eliminar perfil", role: .destructive) { state.removeProfile(profile.accountUuid) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }

            if profile.needsLogin {
                Text("Requiere iniciar sesión de nuevo: entra en Claude Code con esta cuenta y guárdala otra vez.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 24) {
                UsageRing(label: "5 horas", window: usage?.fiveHour)
                UsageRing(label: "Semana", window: usage?.sevenDay)
                UsageRing(label: "Fable / Opus", window: usage?.sevenDayOpus)
                Spacer()
            }

            if let fetched = usage?.fetchedAt {
                Text("Datos de \(relative(fetched))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quinary))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isActive ? Color.green.opacity(0.3) : Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ajustes")
                .font(.system(size: 15, weight: .semibold))

            Toggle("Cambio automático de cuenta", isOn: $state.autoSwitchEnabled)
                .toggleStyle(.switch)

            HStack {
                Text("Cambiar cuando la ventana de 5 horas supere el \(Int(state.triggerThreshold)) %")
                    .font(.callout)
                Spacer()
                Slider(value: $state.triggerThreshold, in: 50...99, step: 1)
                    .frame(width: 180)
            }

            HStack {
                Text("Frecuencia de actualización")
                    .font(.callout)
                Spacer()
                Picker("", selection: $state.pollIntervalSeconds) {
                    Text("3 min").tag(180.0)
                    Text("5 min").tag(300.0)
                    Text("10 min").tag(600.0)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            LaunchAtLoginToggle()
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quinary))
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_ES")
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Interruptor de arranque al iniciar sesión (solo funciona empaquetada como .app).
private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("Abrir al iniciar sesión", isOn: $enabled)
            .toggleStyle(.switch)
            .onChange(of: enabled) {
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
    }
}
