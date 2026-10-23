import Foundation
import Testing
@testable import SwitchBarCore

private func perfil(_ identidad: String, subscriptionType: String? = nil) throws -> AccountProfile {
    try AccountProfile(
        identity: AccountIdentity(oauthAccountJSON: Data(identidad.utf8)),
        subscriptionType: subscriptionType
    )
}

@Test func elTipoDeOrganizacionDistingueTeamDeLasCuentasPersonales() throws {
    // Forma real del bloque `oauthAccount`: en Team el Llavero no trae
    // `subscriptionType`, así que la única pista es `organizationType`.
    let team = try perfil("""
    {"accountUuid": "u1", "emailAddress": "a@empresa.com",
     "organizationType": "claude_team", "organizationName": "Empresa",
     "seatTier": "team_tier_1"}
    """)
    #expect(team.plan == .team)
    #expect(team.plan?.isOrganization == true)
    #expect(team.organizationName == "Empresa")

    // Mismo dominio corporativo, pero suscripción personal.
    let max = try perfil("""
    {"accountUuid": "u2", "emailAddress": "b@empresa.com",
     "organizationType": "claude_max",
     "organizationName": "b@empresa.com's Organization"}
    """, subscriptionType: "max")
    #expect(max.plan == .max)
    #expect(max.plan?.isOrganization == false)
}

@Test func elTipoDeOrganizacionPrevaleceSobreElDelLlavero() throws {
    let profile = try perfil("""
    {"accountUuid": "u1", "emailAddress": "a@a.com", "organizationType": "claude_enterprise"}
    """, subscriptionType: "max")
    #expect(profile.plan == .enterprise)
    #expect(profile.plan?.isOrganization == true)
}

@Test func sinTipoDeOrganizacionSeUsaElDelLlavero() throws {
    let profile = try perfil("""
    {"accountUuid": "u1", "emailAddress": "a@a.com"}
    """, subscriptionType: "pro")
    #expect(profile.plan == .pro)
    #expect(profile.organizationName == nil)
}

@Test func unPlanDesconocidoNoSeAsimilaANinguno() throws {
    let desconocido = try perfil("""
    {"accountUuid": "u1", "emailAddress": "a@a.com", "organizationType": "claude_free"}
    """)
    #expect(desconocido.plan == nil)

    let vacio = try perfil("""
    {"accountUuid": "u2", "emailAddress": "b@b.com", "organizationType": ""}
    """)
    #expect(vacio.plan == nil)
}

@Test func elPlanDelEndpointDePerfilLlegaAlPerfilGuardado() throws {
    let json = Data("""
    {
      "account": {"uuid": "cuenta-1", "email_address": "persona@example.com"},
      "organization": {"uuid": "org-1", "name": "Equipo", "organization_type": "claude_team"}
    }
    """.utf8)
    let profile = AccountProfile(
        identity: try AnthropicAPI.identity(fromProfile: json),
        subscriptionType: nil
    )
    #expect(profile.plan == .team)
    #expect(profile.organizationName == "Equipo")
}

@Test func losNombresDelPlanSonLosComerciales() {
    #expect(AccountPlan.allCases.map(\.displayName) == ["Pro", "Max", "Team", "Enterprise"])
}
