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

private let respuestaConLimits = """
{
  "five_hour": {"utilization": 78, "resets_at": "2026-07-29T14:09:59.230834+00:00"},
  "seven_day": {"utilization": 66, "resets_at": "2026-08-03T02:59:59.230899+00:00"},
  "seven_day_opus": null,
  "limits": [
    {"kind": "session", "group": "session", "percent": 78, "severity": "warning", "resets_at": "2026-07-29T14:09:59.230834+00:00", "is_active": true},
    {"kind": "weekly_all", "group": "weekly", "percent": 66, "severity": "normal", "resets_at": "2026-08-03T02:59:59.230899+00:00", "is_active": false},
    {"kind": "weekly_scoped", "group": "weekly", "percent": 5, "severity": "normal", "resets_at": "2026-08-03T03:00:00.231174+00:00", "is_active": false}
  ]
}
""".data(using: .utf8)!

@Test func prefiereElArrayLimitsYParseaMicrosegundos() throws {
    let s = try UsageSnapshot.parse(respuestaConLimits, fetchedAt: Date())
    #expect(s.fiveHour?.utilization == 78)
    // weekly_scoped es el límite de Opus/Fable aunque seven_day_opus sea null.
    #expect(s.sevenDayOpus?.utilization == 5)
    // Las fechas con microsegundos y desfase +00:00 se parsean igualmente.
    #expect(s.fiveHour?.resetsAt != nil)
    #expect(s.sevenDayOpus?.resetsAt != nil)
}

@Test func variosWeeklyScopedConservaElMasAlto() throws {
    let json = Data("""
    {"limits": [
      {"kind": "session", "percent": 10, "resets_at": "2026-07-29T18:00:00Z"},
      {"kind": "weekly_scoped", "percent": 30, "resets_at": "2026-08-03T07:00:00Z"},
      {"kind": "weekly_scoped", "percent": 70, "resets_at": "2026-08-03T07:00:00Z"}
    ]}
    """.utf8)
    let s = try UsageSnapshot.parse(json, fetchedAt: Date())
    #expect(s.sevenDayOpus?.utilization == 70)
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

@Test func reescalaAlTopePersonalDeCuentaCompartida() throws {
    let s = UsageSnapshot(
        fiveHour: UsageWindow(utilization: 54, resetsAt: nil),
        sevenDay: UsageWindow(utilization: 30, resetsAt: nil),
        sevenDayOpus: UsageWindow(utilization: 66, resetsAt: nil),
        fetchedAt: Date()
    )
    let escalado = s.scaledToPersonalCaps(fiveHourCap: 60, weeklyCap: 60)
    // 54 % real con tope del 60 % = 90 % propio.
    #expect(escalado.fiveHour?.utilization == 90)
    #expect(escalado.sevenDay?.utilization == 50)
    // El tope semanal se aplica también a Fable/Opus, saturando en 100.
    #expect(escalado.sevenDayOpus?.utilization == 100)
    // Sin topes, no cambia nada.
    let intacto = s.scaledToPersonalCaps(fiveHourCap: nil, weeklyCap: nil)
    #expect(intacto.fiveHour?.utilization == 54)
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
