import Foundation
import Testing
@testable import ClaudeSwitchCore

private let respuestaCompleta = """
{
  "five_hour": {"utilization": 42, "resets_at": "2026-07-29T18:00:00.123456Z"},
  "seven_day": {"utilization": 61.5, "resets_at": "2026-08-03T07:00:00Z"},
  "seven_day_opus": {"utilization": 12, "resets_at": "2026-08-03T07:00:00Z"},
  "seven_day_sonnet": null,
  "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null}
}
""".data(using: .utf8)!

private let respuestaSinOpus = """
{
  "five_hour": {"utilization": 0, "resets_at": "2026-07-29T18:00:00Z"},
  "seven_day": {"utilization": 5, "resets_at": "2026-08-03T07:00:00Z"},
  "seven_day_opus": null
}
""".data(using: .utf8)!

@Test func parseaRespuestaCompletaDeUso() throws {
    let ahora = Date()
    let s = try UsageSnapshot.parse(respuestaCompleta, fetchedAt: ahora)
    #expect(s.fiveHour?.utilization == 42)
    #expect(s.fiveHour?.resetsAt != nil)
    #expect(s.sevenDay?.utilization == 61.5)
    #expect(s.sevenDayOpus?.utilization == 12)
    #expect(s.fetchedAt == ahora)
}

@Test func parseaRespuestaConOpusNulo() throws {
    let s = try UsageSnapshot.parse(respuestaSinOpus, fetchedAt: Date())
    #expect(s.fiveHour?.utilization == 0)
    #expect(s.sevenDayOpus == nil)
}

@Test func rechazaJSONInvalido() {
    #expect(throws: CoreError.self) {
        _ = try UsageSnapshot.parse(Data("[]".utf8), fetchedAt: Date())
    }
}

@Test func detectaCaducidadDelToken() throws {
    let ahora = Date(timeIntervalSince1970: 1_000_000)
    let json = """
    {"accessToken": "a", "refreshToken": "r", "expiresAt": \(Int(1_000_000_000 + 120_000)), "scopes": ["user:inference"], "subscriptionType": "max"}
    """.data(using: .utf8)!
    let creds = try OAuthCredentials(claudeAiOauthJSON: json)
    // Caduca en 120 s: con margen de 60 s aún vale.
    #expect(!creds.isAccessTokenExpired(now: ahora))
    // A 90 s de la caducidad ya no (margen 60 s)… y pasado el instante, tampoco.
    #expect(creds.isAccessTokenExpired(now: ahora.addingTimeInterval(61)))
    #expect(creds.isAccessTokenExpired(now: ahora.addingTimeInterval(300)))
}

@Test func actualizarTokensPreservaCamposDesconocidos() throws {
    let json = """
    {"accessToken": "a", "refreshToken": "r", "expiresAt": 1, "rateLimitTier": "max_20x", "campoRaro": {"x": 1}}
    """.data(using: .utf8)!
    let creds = try OAuthCredentials(claudeAiOauthJSON: json)
    let nuevas = try creds.updating(accessToken: "a2", refreshToken: "r2", expiresAt: 99)
    let dict = try nuevas.asDictionary()
    #expect(dict["accessToken"] as? String == "a2")
    #expect(dict["refreshToken"] as? String == "r2")
    #expect((dict["expiresAt"] as? NSNumber)?.intValue == 99)
    #expect(dict["rateLimitTier"] as? String == "max_20x")
    #expect((dict["campoRaro"] as? [String: Any])?["x"] as? Int == 1)
}
