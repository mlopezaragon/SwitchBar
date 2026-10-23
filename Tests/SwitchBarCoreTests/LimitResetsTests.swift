import Foundation
import Testing
@testable import SwitchBarCore

/// Forma del bloque tal como la lee el comando `/limit-reset` de Claude Code.
private let respuestaConRestablecimientos = """
{
  "limits": [
    {"kind": "session", "group": "session", "percent": 100, "resets_at": "2026-10-24T02:00:00Z"}
  ],
  "cedar_ember": {
    "eligible": true,
    "at_limit": true,
    "grants": [
      {"id": "grant_a", "label": "Session reset", "resets_total": 2, "resets_left": 1,
       "starts_at": "2026-10-01T00:00:00Z", "ends_at": "2026-10-30T23:00:00Z",
       "clears": ["five_hour"], "paused": false, "usable_now": true,
       "use_requires_limit": true, "percent_used": {}, "blocking": [], "type": "session",
       "gives_back_weekly": false, "unavailable_reason": null},
      {"id": "grant_b", "label": "Full reset", "resets_total": 1, "resets_left": 1,
       "ends_at": "2026-11-15T23:00:00.123456+00:00", "type": "full", "usable_now": false},
      {"id": "grant_roto", "resets_total": 1},
      "no es un objeto"
    ],
    "next_grant_id": "grant_a",
    "cooldown_until": null
  }
}
""".data(using: .utf8)!

@Test func leeLosRestablecimientosDelBloqueCedarEmber() throws {
    let usage = try UsageSnapshot.parse(respuestaConRestablecimientos, fetchedAt: Date())
    let resets = try #require(usage.limitResets)
    let ahora = try #require(ISO8601.parse("2026-10-23T12:00:00Z"))
    #expect(resets.eligible)
    // Los lotes ilegibles se descartan sin estropear el resto.
    #expect(resets.grants.map(\.id) == ["grant_a", "grant_b"])
    #expect(resets.grants[0].kind == .session)
    #expect(resets.grants[0].usableNow)
    #expect(resets.grants[1].kind == .full)
    #expect(resets.grants[1].endsAt != nil)
    #expect(resets.resetsLeft(now: ahora) == 2)
    #expect(resets.resetsTotal(now: ahora) == 3)
    #expect(resets.nextExpiry(now: ahora) == ISO8601.parse("2026-10-30T23:00:00Z"))
    // El resto de la respuesta se sigue leyendo igual.
    #expect(usage.fiveHour?.utilization == 100)
}

@Test func sinBloqueNoHayRestablecimientos() throws {
    let usage = try UsageSnapshot.parse(
        Data(#"{"five_hour": {"utilization": 10}}"#.utf8),
        fetchedAt: Date()
    )
    #expect(usage.limitResets == nil)
}

@Test func unBloqueIlegibleNoEstropeaElUso() throws {
    let usage = try UsageSnapshot.parse(
        Data(#"{"five_hour": {"utilization": 10}, "cedar_ember": "roto"}"#.utf8),
        fetchedAt: Date()
    )
    #expect(usage.limitResets == nil)
    #expect(usage.fiveHour?.utilization == 10)
}

@Test func losLotesCaducadosNoCuentan() {
    let ahora = Date(timeIntervalSince1970: 1_800_000_000)
    let resets = LimitResets(eligible: true, grants: [
        LimitResetGrant(id: "viejo", kind: .weekly, resetsLeft: 1, resetsTotal: 1,
                        endsAt: ahora.addingTimeInterval(-60)),
        LimitResetGrant(id: "gastado", kind: .session, resetsLeft: 0, resetsTotal: 1,
                        endsAt: ahora.addingTimeInterval(3_600)),
        LimitResetGrant(id: "sin_fecha", kind: .session, resetsLeft: 1, resetsTotal: 2)
    ])
    #expect(resets.current(now: ahora).map(\.id) == ["gastado", "sin_fecha"])
    #expect(resets.resetsLeft(now: ahora) == 1)
    #expect(resets.resetsTotal(now: ahora) == 3)
    // Un lote ya gastado no marca la fecha límite.
    #expect(resets.nextExpiry(now: ahora) == nil)
}

@Test func laConsultaDeUsoPideLosRestablecimientos() throws {
    let components = try #require(
        URLComponents(url: AnthropicAPI.usageEndpoint, resolvingAgainstBaseURL: false)
    )
    #expect(components.path == "/api/oauth/usage")
    #expect(components.queryItems?.contains(URLQueryItem(name: "cedar_ember", value: "1")) == true)
}

@Test func laCacheConservaLosRestablecimientos() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("switchbar-resets-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fin = Date(timeIntervalSince1970: 1_900_000_000)
    let resets = LimitResets(eligible: true, grants: [
        LimitResetGrant(id: "g1", label: "Full reset", kind: .full, resetsLeft: 1, resetsTotal: 2,
                        endsAt: fin, usableNow: true, useRequiresLimit: false),
        LimitResetGrant(id: "g2", kind: nil, resetsLeft: 0, resetsTotal: 1, paused: true)
    ])
    let snapshot = UsageSnapshot(
        fiveHour: UsageWindow(utilization: 30, resetsAt: nil),
        sevenDay: nil,
        sevenDayOpus: nil,
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
        limitResets: resets
    )
    try UsageSnapshotCache(directoryURL: directory).save(["cuenta-a": snapshot])
    let restored = try #require(UsageSnapshotCache(directoryURL: directory).load()["cuenta-a"])
    #expect(restored.limitResets == resets)
}

@Test func elTopePersonalConservaLosRestablecimientos() {
    let resets = LimitResets(eligible: true, grants: [
        LimitResetGrant(id: "g", kind: .session, resetsLeft: 1, resetsTotal: 1)
    ])
    let snapshot = UsageSnapshot(
        fiveHour: UsageWindow(utilization: 30, resetsAt: nil),
        sevenDay: nil, sevenDayOpus: nil, fetchedAt: Date(), limitResets: resets
    )
    #expect(snapshot.scaledToPersonalCaps(fiveHourCap: 50, weeklyCap: 50).limitResets == resets)
}
