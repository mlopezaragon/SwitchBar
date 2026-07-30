import Foundation
import Testing
@testable import ClaudeSwitchCore

/// El camino `/usr/bin/security` solo puede tocar la entrada de Claude Code
/// y la entrada efímera de diagnóstico. Los perfiles privados usan SecItem.
/// otra —la app de escritorio de Claude, navegadores, correo…— está fuera de
/// su alcance por construcción.
@Test func soloSePermitenLasEntradasPropiasYLaDeClaudeCode() throws {
    let permitidas = [
        ClaudeCodeStore.credentialsService,
        "ClaudeSwitch-selftest"
    ]
    for servicio in permitidas {
        #expect(SecurityCLIKeychain.allowedServices.contains(servicio))
    }

    let ajenas = [
        "Claude", "Claude.app", "claude.ai", "Anthropic",
        "Chrome Safe Storage", "iCloud", "com.apple.account", "Slack",
        "ClaudeSwitch-credentials", "ClaudeSwitch-profile-abc"
    ]
    let keychain = SecurityCLIKeychain()
    for servicio in ajenas {
        #expect(!SecurityCLIKeychain.allowedServices.contains(servicio))
        // Escribir en una entrada ajena falla siempre, sin llegar al sistema.
        #expect(throws: KeychainError.self) {
            try keychain.writeString("x", service: servicio)
        }
        #expect(throws: KeychainError.self) {
            try keychain.delete(service: servicio)
        }
        // Leer una entrada ajena devuelve nil sin consultar al Llavero.
        #expect(try keychain.readString(service: servicio) == nil)
    }
}

@Test func escrituraCortaNoExponeTokenNiAmpliaLaACL() {
    let secret = "sk-secretisimo-123"
    let invocation = SecurityCLIKeychain.writeInvocation(
        value: secret,
        service: ClaudeCodeStore.credentialsService,
        account: "usuario"
    )
    #expect(invocation.arguments == ["-i"])
    #expect(!invocation.arguments.joined().contains(secret))
    #expect(!invocation.input.contains(secret))
    #expect(!invocation.input.contains(" -A"))
    #expect(!invocation.input.contains(" -w"))
    #expect(invocation.input.contains(" -X "))
    #expect(
        invocation.input.contains(
            Data(secret.utf8).map { String(format: "%02x", $0) }.joined()
        )
    )
}

@Test func escrituraLargaUsaElFallbackOficialSinTruncar() {
    let value = String(repeating: "dato-seguro-", count: 300)
    let invocation = SecurityCLIKeychain.writeInvocation(
        value: value,
        service: ClaudeCodeStore.credentialsService,
        account: "usuario"
    )
    let expectedHex = Data(value.utf8)
        .map { String(format: "%02x", $0) }
        .joined()

    #expect(invocation.input.isEmpty)
    #expect(invocation.arguments.first == "add-generic-password")
    #expect(invocation.arguments.contains("-U"))
    #expect(invocation.arguments.contains("-X"))
    #expect(invocation.arguments.last == expectedHex)
    #expect(!invocation.arguments.contains("-A"))
    #expect(!invocation.arguments.contains("-w"))
}
