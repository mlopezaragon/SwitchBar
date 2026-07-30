import Foundation
import Testing
@testable import SwitchBarCore

private struct SecretBearingError: LocalizedError {
    let errorDescription: String?
}

@Test
func erroresDelLlaveroNuncaMuestranLaSalidaDelComando() throws {
    let secret = String(repeating: "ab", count: 300)
    let error = KeychainError.commandFailed(1)
    let visible = try #require(error.errorDescription)

    #expect(!visible.contains(secret))
    #expect(!visible.contains("unknown command"))
    #expect(visible.count < 300)
}

@Test
func laUltimaBarreraOcultaTokensYMensajesDesmesurados() {
    let hex = String(repeating: "c6", count: 120)
    let visible = UserFacingError.describe(
        SecretBearingError(
            errorDescription: "Falló el comando \(hex)"
        )
    )
    #expect(!visible.contains(hex))

    let bearer = UserFacingError.sanitize(
        "Authorization: Bearer abcdefghijklmnopqrstuvwxyz"
    )
    #expect(!bearer.contains("abcdefghijklmnopqrstuvwxyz"))

    let huge = UserFacingError.sanitize(
        String(repeating: "x", count: 600)
    )
    #expect(huge.count < 300)
}
