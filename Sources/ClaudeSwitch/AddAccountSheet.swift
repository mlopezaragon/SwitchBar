import SwiftUI

/// Hoja de alta de cuenta: el navegador ya está abierto en la página de
/// autorización; aquí se pega el código que muestra tras iniciar sesión.
struct AddAccountSheet: View {
    @Bindable var state: AppState
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Añadir cuenta")
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Label("Se ha abierto claude.ai en tu navegador. Inicia sesión con la cuenta que quieras añadir (usa una ventana privada si el navegador ya tiene otra sesión abierta).", systemImage: "1.circle")
                Label("Autoriza el acceso y copia el código que aparece.", systemImage: "2.circle")
                Label("Pégalo aquí debajo.", systemImage: "3.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            TextField("Código de autorización", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($focused)
                .onSubmit { submit() }

            if let error = state.addAccountError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Volver a abrir la página") { state.reopenAddAccountPage() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar") { state.cancelAddAccount() }
                if state.addAccountBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Conectar cuenta") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear { focused = true }
    }

    private func submit() {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task { await state.completeAddAccount(code: value) }
    }
}
