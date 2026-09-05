import SwiftUI
import SwitchBarCore

/// Panel desplegable de la barra de menús.
struct MenuPanelView: View {
    @Bindable var state: AppState

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

            ForEach(state.profilesList) { profile in
                AccountCardView(
                    profile: profile,
                    usage: state.usageByAccount[profile.accountUuid],
                    isActive: profile.accountUuid == state.activeAccountUuid,
                    isUsageStale: state.isUsageStale(
                        for: profile.accountUuid
                    ),
                    isRenewalBlocked: state.isRenewalBlocked(
                        for: profile.accountUuid
                    ),
                    suggestsReconnect: state.suggestsReconnect(
                        for: profile.accountUuid
                    ),
                    onSwitch: { state.switchTo(profile.accountUuid) },
                    onReconnect: {
                        DetailWindowController.shared.show()
                        state.beginReconnect(profile)
                    }
                )
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
        .onAppear {
            state.refreshIfStale()
        }
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
