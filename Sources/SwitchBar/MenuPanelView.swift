import SwiftUI
import SwitchBarCore

/// Panel desplegable de la barra de menús.
struct MenuPanelView: View {
    @Bindable var state: AppState
    /// Altura real de las tarjetas, para que el panel se ajuste a ellas
    /// mientras quepan y se desplace cuando no.
    @State private var cardsHeight: CGFloat = 0
    /// Altura real del panel, para ajustar la ventana cuando encoge.
    @State private var panelHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            AnthropicStatusBanner(
                snapshot: state.anthropicStatus,
                unavailable: state.anthropicStatusUnavailable,
                checking: state.isCheckingAnthropicStatus,
                compact: true,
                openOfficialPage: state.openAnthropicStatusPage
            )

            if let unsaved = state.activeUnsaved {
                unsavedBanner(unsaved)
            }

            if state.profilesList.isEmpty && state.activeUnsaved == nil {
                emptyState
            }

            if !state.profilesList.isEmpty {
                accountCards
            }

            Button {
                DetailWindowController.shared.show()
                state.beginAddAccount()
            } label: {
                Label(L10n.tr("account.add"), systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if let message = state.infoMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let notice = state.autoSwitchMonitoringNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notice = state.usageRefreshNotice {
                Label(notice, systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = state.lastError {
                Label {
                    Text(error)
                        .lineLimit(4)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            panelHeight = $0
        }
        .background(PanelWindowFitter(height: panelHeight))
        .onAppear {
            state.refreshIfStale()
        }
    }

    /// Las tarjetas se desplazan en vez de crecer sin fin. El panel no tiene
    /// más espacio que la pantalla: con seis o siete cuentas, las últimas
    /// tarjetas y el botón de añadir quedaban fuera de su borde, como si
    /// hubiera un límite de cuentas.
    private var accountCards: some View {
        let next = state.nextAutoSwitchTarget
        return ScrollView {
            VStack(spacing: 10) {
                ForEach(state.profilesList) { profile in
                    AccountCardView(
                        profile: profile,
                        usage: state.usageByAccount[profile.id],
                        isActive: profile.id == state.activeProfileID,
                        isUsageStale: state.isUsageStale(
                            for: profile.id
                        ),
                        isRenewalBlocked: state.isRenewalBlocked(
                            for: profile.id
                        ),
                        suggestsReconnect: state.suggestsReconnect(
                            for: profile.id
                        ),
                        isNextAutoSwitch: profile.id == next,
                        onSwitch: { state.switchTo(profile.id) },
                        onReconnect: {
                            DetailWindowController.shared.show()
                            state.beginReconnect(profile)
                        }
                    )
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                cardsHeight = $0
            }
        }
        .frame(height: min(cardsHeight, maxCardsHeight))
    }

    /// Espacio para las tarjetas: la pantalla menos lo que ocupan la
    /// cabecera, los avisos y el pie del panel.
    private var maxCardsHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, visible - 320)
    }

    private var header: some View {
        HStack {
            Text("SwitchBar")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if state.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else if let last = state.lastRefreshAt {
                Text(ResetFormatter.since(last))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Button {
                Task { await state.refreshAll(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.tr("usage.refresh_now"))
        }
    }

    private func unsavedBanner(_ identity: AccountIdentity) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("account.unsaved"))
                    .font(.caption.weight(.semibold))
                Text(identity.emailAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.tr("account.save")) { state.captureActive() }
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.08)))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(L10n.tr("account.empty.title"))
                .font(.callout.weight(.medium))
            Text(L10n.tr("account.empty.explanation"))
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
                Text(L10n.tr("auto_switch.label"))
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Spacer()

            if state.canUndo {
                Button(L10n.tr("action.undo")) { state.undo() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                DetailWindowController.shared.show()
            } label: {
                Image(systemName: "rectangle.expand.diagonal")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.tr("action.open_details"))

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.tr("action.quit"))
        }
    }

}

/// Encoge la ventana del panel hasta la altura del contenido. La ventana de
/// MenuBarExtra crece cuando aparece un aviso, pero no vuelve a encoger
/// cuando desaparece (el binario se enlaza con el SDK de macOS 14 y el
/// sistema mantiene ese comportamiento antiguo): el panel quedaba centrado
/// en una ventana más alta, con franjas vacías arriba y abajo.
private struct PanelWindowFitter: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> FitterView {
        FitterView()
    }

    func updateNSView(_ view: FitterView, context: Context) {
        view.height = height
        view.fitWindow()
    }

    final class FitterView: NSView {
        var height: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            fitWindow()
        }

        /// Solo encoge: crecer ya lo hace SwiftUI. El borde superior no se
        /// mueve, para que el panel siga pegado a la barra de menús.
        func fitWindow() {
            guard let window, height > 0 else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            guard content.height > height + 0.5 else { return }
            let fitted = NSRect(
                x: content.minX,
                y: content.maxY - height,
                width: content.width,
                height: height
            )
            window.setFrame(window.frameRect(forContentRect: fitted), display: true)
        }
    }
}
