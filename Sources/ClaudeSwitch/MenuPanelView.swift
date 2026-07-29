import SwiftUI
import ClaudeSwitchCore

/// Panel desplegable de la barra de menús.
struct MenuPanelView: View {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let unsaved = state.activeUnsaved {
                unsavedBanner(unsaved)
            }

            if state.profilesList.isEmpty && state.activeUnsaved == nil {
                emptyState
            }

            Button {
                openWindow(id: "detalle")
                NSApp.activate(ignoringOtherApps: true)
                state.beginAddAccount()
            } label: {
                Label("Añadir cuenta", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            ForEach(state.profilesList) { profile in
                AccountCardView(
                    profile: profile,
                    usage: state.usageByAccount[profile.accountUuid],
                    isActive: profile.accountUuid == state.activeAccountUuid,
                    onSwitch: { state.switchTo(profile.accountUuid) }
                )
            }

            if let message = state.infoMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = state.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
        .onAppear {
            state.clearMessages()
            state.refreshIfStale()
        }
    }

    private var header: some View {
        HStack {
            Text("ClaudeSwitch")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if state.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else if let last = state.lastRefreshAt {
                Text(relative(last))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Button {
                Task { await state.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Actualizar ahora")
        }
    }

    private func unsavedBanner(_ identity: AccountIdentity) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cuenta activa sin guardar")
                    .font(.caption.weight(.semibold))
                Text(identity.emailAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Guardar") { state.captureActive() }
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.08)))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Sin cuentas guardadas")
                .font(.callout.weight(.medium))
            Text("Inicia sesión en Claude Code con cada cuenta y pulsa «Guardar» cuando aparezca aquí.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $state.autoSwitchEnabled) {
                Text("Cambio automático")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Spacer()

            if state.canUndo {
                Button("Deshacer") { state.undo() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                openWindow(id: "detalle")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "rectangle.expand.diagonal")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Abrir detalle y ajustes")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Salir de ClaudeSwitch")
        }
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
