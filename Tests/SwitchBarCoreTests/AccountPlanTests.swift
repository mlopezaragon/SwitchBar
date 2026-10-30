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
    #expect(AccountPlan.allCases.map(\.displayName) == ["Pro", "Max", "Ultra", "Team", "Enterprise"])
}

@Test func elNivelDeLimitesSeparaMaxDeUltra() throws {
    // Forma real tras el cambio de nombre del 30 de octubre de 2026: el
    // servidor sigue diciendo `claude_max` y solo el nivel los distingue.
    let ultra = try perfil("""
    {"accountUuid": "u1", "emailAddress": "a@a.com", "organizationType": "claude_max",
     "organizationRateLimitTier": "default_claude_max_20x"}
    """, subscriptionType: "max")
    #expect(ultra.plan == .ultra)
    #expect(ultra.plan?.isOrganization == false)
    #expect(ultra.planLabel == "Ultra")

    let max = try perfil("""
    {"accountUuid": "u2", "emailAddress": "b@b.com", "organizationType": "claude_max",
     "organizationRateLimitTier": "default_claude_max_5x"}
    """, subscriptionType: "max")
    #expect(max.plan == .max)

    // Sin nivel no se puede saber: se queda en Max.
    let sinNivel = try perfil("""
    {"accountUuid": "u3", "emailAddress": "c@c.com", "organizationType": "claude_max"}
    """)
    #expect(sinNivel.plan == .max)

    // El nivel personal de un asiento Team no lo convierte en otro plan.
    let team = try perfil("""
    {"accountUuid": "u4", "emailAddress": "d@d.com", "organizationType": "claude_team",
     "organizationRateLimitTier": "default_raven", "userRateLimitTier": "default_claude_max_5x"}
    """)
    #expect(team.plan == .team)
}

@Test func seAceptaUnTipoQueYaDigaUltra() throws {
    let porTipo = try perfil("""
    {"accountUuid": "u1", "emailAddress": "a@a.com", "organizationType": "claude_ultra"}
    """)
    #expect(porTipo.plan == .ultra)

    let porLlavero = try perfil("""
    {"accountUuid": "u2", "emailAddress": "b@b.com"}
    """, subscriptionType: "ultra")
    #expect(porLlavero.plan == .ultra)

    let porNivel = try perfil("""
    {"accountUuid": "u3", "emailAddress": "c@c.com", "organizationType": "claude_max",
     "organizationRateLimitTier": "default_claude_ultra"}
    """)
    #expect(porNivel.plan == .ultra)
}

@Test func elNivelDelEndpointDePerfilLlegaAlPerfilGuardado() throws {
    let json = Data("""
    {
      "account": {"uuid": "cuenta-1", "email_address": "persona@example.com"},
      "organization": {"uuid": "org-1", "organization_type": "claude_max",
                       "rate_limit_tier": "default_claude_max_20x"}
    }
    """.utf8)
    let profile = AccountProfile(
        identity: try AnthropicAPI.identity(fromProfile: json),
        subscriptionType: "max"
    )
    #expect(profile.plan == .ultra)
}
