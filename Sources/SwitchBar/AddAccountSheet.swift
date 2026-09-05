import SwiftUI
import SwitchBarCore

/// Alta de cuenta. El camino principal ocurre dentro de la app: se abre la
/// pantalla oficial de Anthropic en el navegador y se pega el código que
/// esta muestra. El flujo por terminal se conserva como alternativa, porque
/// es el que Claude Code documenta y el que sigue funcionando si Anthropic
/// cambia algo del canje.
struct AddAccountSheet: View {
    @Bindable var state: AppState
    @State private var showsTerminalPath = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))

            Text(introduction)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            directPath

            if showsTerminalPath {
                Divider()
                terminalPath
            }

            if let error = state.addAccountError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(showsTerminalPath
                       ? L10n.tr("add_account.hide_terminal_path")
                       : L10n.tr("add_account.show_terminal_path")) {
                    showsTerminalPath.toggle()
                }
                .buttonStyle(.link)
                Spacer()
                Button(L10n.tr("add_account.cancel")) {
                    state.cancelAddAccount()
                }
            }
        }
        .padding(22)
        .frame(width: 520)
        .disabled(state.addAccountBusy)
        .interactiveDismissDisabled(state.addAccountBusy)
    }

    /// Paso 1: abrir el navegador. Paso 2: pegar el código y guardar.
    @ViewBuilder
    private var directPath: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                state.startInAppLogin()
            } label: {
                Label(
                    state.loginFlow == nil
                        ? L10n.tr("add_account.open_sign_in")
                        : L10n.tr("add_account.reopen_sign_in"),
                    systemImage: "safari"
                )
            }
            .controlSize(.large)
            .keyboardShortcut(state.loginFlow == nil ? .defaultAction : nil)

            Text(L10n.tr("add_account.private_window_hint"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if state.loginFlow != nil {
                Text(L10n.tr("add_account.paste_code_label"))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    TextField(
                        L10n.tr("add_account.paste_code_placeholder"),
                        text: $state.pastedLoginCode
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { save() }

                    if state.addAccountBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L10n.tr("add_account.save")) { save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(state.pastedLoginCode
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty)
                    }
                }
            }
        }
    }

    /// Camino alternativo: el login oficial desde la terminal, tal y como
    /// funcionaba antes.
    @ViewBuilder
    private var terminalPath: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("add_account.terminal_path_title"))
                .font(.callout.weight(.medium))

            Text("claude auth login --claudeai")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                )

            VStack(alignment: .leading, spacing: 6) {
                Label(firstTerminalStep, systemImage: "1.circle")
                Label(
                    L10n.tr("add_account.step.slash_login"),
                    systemImage: "2.circle"
                )
                Label(
                    L10n.tr("add_account.step.return"),
                    systemImage: "3.circle"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(L10n.tr("add_account.copy_and_open_terminal")) {
                    state.prepareOfficialLogin()
                }
                Spacer()
                if state.addAccountBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L10n.tr("add_account.finish_and_save")) {
                        Task { await state.completeAddAccount() }
                    }
                }
            }
        }
    }

    private func save() {
        Task { await state.completeInAppLogin() }
    }

    /// Al reconectar, lo que importa es elegir la cuenta correcta; al dar de
    /// alta una nueva, ejecutar el comando.
    private var firstTerminalStep: String {
        if let profile = state.reconnectingProfile {
            return L10n.tr("add_account.step.choose", profile.emailAddress)
        }
        return L10n.tr("add_account.step.command")
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
}
