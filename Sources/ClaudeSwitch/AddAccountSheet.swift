import SwiftUI
import ClaudeSwitchCore

/// Vincula la sesión creada por el flujo oficial de Claude Code. La app no
/// implementa OAuth ni manipula códigos privados de Anthropic.
struct AddAccountSheet: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))

            Text(introduction)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                Label(
                    firstStep,
                    systemImage: "1.circle"
                )
                Label(
                    L10n.tr("add_account.step.slash_login"),
                    systemImage: "2.circle"
                )
                Label(
                    L10n.tr("add_account.step.return"),
                    systemImage: "3.circle"
                )
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Text("claude auth login --claudeai")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                )

            if let error = state.addAccountError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(L10n.tr("add_account.copy_and_open_terminal")) {
                    state.prepareOfficialLogin()
                }
                Spacer()
                Button(L10n.tr("add_account.cancel")) {
                    state.cancelAddAccount()
                }
                if state.addAccountBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(L10n.tr("add_account.finish_and_save")) {
                        Task { await state.completeAddAccount() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private var title: String {
        if state.reconnectingProfile != nil {
            return L10n.tr("add_account.title.reconnect")
        }
        return L10n.tr("add_account.title.add")
    }

    private var introduction: String {
        if let profile = state.reconnectingProfile {
            return L10n.tr(
                "add_account.introduction.reconnect",
                profile.emailAddress
            )
        }
        return L10n.tr("add_account.introduction.add")
    }

    private var firstStep: String {
        if let profile = state.reconnectingProfile {
            return L10n.tr("add_account.step.choose", profile.emailAddress)
        }
        return L10n.tr("add_account.step.command")
    }
}
