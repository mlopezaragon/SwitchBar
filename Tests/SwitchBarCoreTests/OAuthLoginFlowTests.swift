import CryptoKit
import Foundation
import Testing
@testable import SwitchBarCore

@Test
func laUrlDeAutorizacionLlevaElRetoPkceYElEstado() throws {
    let flow = OAuthLoginFlow(verifier: "verificador-de-prueba", state: "estado-1")
    let components = try #require(
        URLComponents(url: flow.authorizationURL, resolvingAgainstBaseURL: false)
    )
    func item(_ name: String) -> String? {
        components.queryItems?.first { $0.name == name }?.value
    }
    #expect(components.host == "claude.com")
    #expect(components.path == "/cai/oauth/authorize")
    #expect(item("client_id") == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
    #expect(item("response_type") == "code")
    #expect(item("code_challenge_method") == "S256")
    #expect(item("state") == "estado-1")
    #expect(
        item("redirect_uri") == "https://platform.claude.com/oauth/code/callback"
    )

    // El reto es el SHA-256 del verificador en base64url, sin relleno.
    let expected = Data(SHA256.hash(data: Data("verificador-de-prueba".utf8)))
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    #expect(item("code_challenge") == expected)
    // El verificador jamás viaja en la URL.
    #expect(!flow.authorizationURL.absoluteString.contains("verificador-de-prueba"))
}

@Test
func cadaLoginUsaUnVerificadorDistinto() {
    #expect(OAuthLoginFlow().verifier != OAuthLoginFlow().verifier)
    #expect(OAuthLoginFlow().state != OAuthLoginFlow().state)
}

@Test
func elCodigoPegadoSeLimpiaYSeValidaContraElEstado() {
    let flow = OAuthLoginFlow(verifier: "v", state: "estado-1")
    #expect(flow.normalizedCode(from: "  abc123  ") == "abc123")
    #expect(flow.normalizedCode(from: "abc123#estado-1") == "abc123")
    // Un código de otro intento no se acepta: canjearlo fallaría y, peor,
    // podría pertenecer a otra cuenta.
    #expect(flow.normalizedCode(from: "abc123#estado-2") == nil)
    #expect(flow.normalizedCode(from: "   ") == nil)
    #expect(flow.normalizedCode(from: "#estado-1") == nil)
}

@Test
func elPerfilAnidadoConSnakeCaseSeTraduceAlBloqueDeClaudeCode() throws {
    let json = Data("""
    {
      "account": {
        "uuid": "cuenta-1",
        "email_address": "persona@example.com",
        "display_name": "Persona",
        "billing_type": "subscription"
      },
      "organization": {
        "uuid": "org-1",
        "name": "Equipo",
        "organization_type": "team",
        "role": "admin"
      }
    }
    """.utf8)

    let identity = try AnthropicAPI.identity(fromProfile: json)
    #expect(identity.accountUuid == "cuenta-1")
    #expect(identity.emailAddress == "persona@example.com")
    #expect(identity.displayName == "Persona")

    let block = try identity.asDictionary()
    #expect(block["organizationUuid"] as? String == "org-1")
    #expect(block["organizationName"] as? String == "Equipo")
    #expect(block["organizationRole"] as? String == "admin")
    #expect(block["billingType"] as? String == "subscription")
}

@Test
func elPerfilPlanoConCamelCaseTambienSeEntiende() throws {
    let json = Data("""
    {"accountUuid":"cuenta-2","emailAddress":"otra@example.com"}
    """.utf8)
    let identity = try AnthropicAPI.identity(fromProfile: json)
    #expect(identity.accountUuid == "cuenta-2")
    #expect(identity.emailAddress == "otra@example.com")
}

@Test
func unPerfilSinCorreoOSinIdentificadorSeRechaza() {
    // Sin estos dos campos no se puede crear un perfil, y adivinarlos
    // guardaría credenciales bajo una identidad equivocada.
    #expect(throws: AnthropicAPIError.malformedResponse) {
        _ = try AnthropicAPI.identity(
            fromProfile: Data(#"{"account":{"uuid":"solo-uuid"}}"#.utf8)
        )
    }
    #expect(throws: AnthropicAPIError.malformedResponse) {
        _ = try AnthropicAPI.identity(fromProfile: Data("no es json".utf8))
    }
}
