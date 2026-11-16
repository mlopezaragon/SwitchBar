import Foundation
import Testing
@testable import SwitchBarCore

// MARK: - Precios

@Test func identificadoresDeModeloSeNormalizan() {
    #expect(ModelPricing.canonicalID("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
    #expect(ModelPricing.canonicalID("us.anthropic.claude-opus-4-8-v1:0") == "claude-opus-4-8")
    #expect(ModelPricing.canonicalID("claude-opus-4-5@20251101") == "claude-opus-4-5")
    #expect(ModelPricing.canonicalID("claude-opus-5-5[1m]") == "claude-opus-5-5")
    #expect(ModelPricing.canonicalID("Claude-Sonnet-5-5") == "claude-sonnet-5-5")
}

@Test func nombresCortosDeModelo() {
    #expect(ModelPricing.displayName("claude-opus-5-5") == "Opus 5.5")
    #expect(ModelPricing.displayName("claude-fable-5-2") == "Fable 5.2")
    #expect(ModelPricing.displayName("claude-haiku-4-5-20251001") == "Haiku 4.5")
    #expect(ModelPricing.displayName("claude-opus-5") == "Opus 5")
    #expect(ModelPricing.displayName("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
}

@Test func elCosteSigueLosPreciosDelAPI() throws {
    // Opus 5.5: 4 $ entrada, 20 $ salida, 0,20 $ lectura de caché;
    // escritura 5 $ (5 min) y 8 $ (1 h) por millón.
    let counts = TokenCounts(
        input: 1_000_000, output: 1_000_000,
        cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000,
        cacheRead: 1_000_000
    )
    let cost = try #require(ModelPricing.cost(of: counts, model: "claude-opus-5-5"))
    #expect(abs(cost - (4 + 20 + 5 + 8 + 0.20)) < 1e-9)

    // Coincide con lo que Claude Code apuntó para una sesión real: 0,7642216 $
    // (su caché era de 1 h).
    let session = TokenCounts(input: 14, output: 9_078, cacheWrite1h: 59_931, cacheRead: 515_788)
    let sessionCost = try #require(ModelPricing.cost(of: session, model: "claude-opus-5-5"))
    #expect(abs(sessionCost - 0.7642216) < 0.000_001)
}

@Test func tarifasEspecialesYModelosDesconocidos() throws {
    let million = TokenCounts(input: 1_000_000)
    #expect(ModelPricing.cost(of: million, model: "claude-haiku-5-5") == 0.10)
    #expect(ModelPricing.cost(of: million, model: "claude-haiku-5-5", variant: .promptOver100K) == 0.50)
    #expect(ModelPricing.cost(of: million, model: "claude-opus-5-5", variant: .fast) == 8)
    #expect(ModelPricing.cost(of: million, model: "claude-fable-5-2") == 8)
    #expect(ModelPricing.cost(of: million, model: "claude-desconocido-9") == nil)
    let searches = TokenCounts(webSearches: 100)
    #expect(abs(try #require(ModelPricing.cost(of: searches, model: "claude-opus-5-5")) - 1) < 1e-9)
}

// MARK: - Días y fechas

@Test func diasCivilesIdaYVuelta() {
    for day: Int32 in [-1, 0, 1, 11_000, 20_773, 30_000] {
        let c = LocalDay.civil(day)
        #expect(LocalDay.number(year: c.year, month: c.month, day: c.day) == day)
        #expect(LocalDay.parse(LocalDay.string(day)) == day)
    }
    #expect(LocalDay.string(0) == "1970-01-01")
    #expect(LocalDay.parse("2026-11-16") == LocalDay.number(year: 2026, month: 11, day: 16))
}

@Test func marcasDeTiempoDeClaudeCode() throws {
    let epoch = try #require(Timestamp.epoch("2026-11-16T22:32:07.530Z"))
    let reference = ISO8601DateFormatter().date(from: "2026-11-16T22:32:07Z")!.timeIntervalSince1970
    #expect(abs(epoch - reference - 0.53) < 0.001)
    #expect(Timestamp.epoch("2026-11-16T22:32:07Z") == reference)
    #expect(Timestamp.epoch("2026-11-16T23:32:07+01:00") == reference)
    #expect(Timestamp.epoch("ayer") == nil)
}

@Test func elDiaSeCuentaEnLaZonaDelMac() throws {
    let madrid = try #require(TimeZone(identifier: "Europe/Madrid"))
    let epoch = try #require(Timestamp.epoch("2026-11-16T23:30:00Z"))
    #expect(LocalDay.string(LocalDay.number(epoch: epoch, timeZone: madrid)) == "2026-11-17")
    #expect(LocalDay.string(LocalDay.number(epoch: epoch, timeZone: .gmt)) == "2026-11-16")
}

// MARK: - Lectura de transcripciones

private let opus = "claude-opus-5-5"
private let accountA = "aaaaaaaa-0000-0000-0000-000000000001"
private let orgA = "orga0000-0000-0000-0000-000000000001"
private let accountB = "bbbbbbbb-0000-0000-0000-000000000002"
private let orgB = "orgb0000-0000-0000-0000-000000000002"
private let profileA = ProfileID.make(accountUuid: accountA, organizationUuid: orgA)
private let profileB = ProfileID.make(accountUuid: accountB, organizationUuid: orgB)

private func owner(_ session: String, account: String, org: String) -> String {
    #"{"type":"session-owner","accountUuid":"\#(account)","organizationUuid":"\#(org)","sessionId":"\#(session)"}"#
}

private func assistant(
    _ id: String, session: String, at timestamp: String,
    model: String = opus, input: Int = 10, output: Int = 20,
    cacheRead: Int = 1_000, cacheWrite: Int = 100, oneHour: Int = 0,
    block: String = "text"
) -> String {
    #"{"parentUuid":"p","isSidechain":false,"message":{"model":"\#(model)","id":"msg_\#(id)","type":"message","role":"assistant","content":[{"type":"\#(block)","text":"el \"usage\":{ de un texto no cuenta"}],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cacheWrite),"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output),"cache_creation":{"ephemeral_1h_input_tokens":\#(oneHour),"ephemeral_5m_input_tokens":\#(cacheWrite - oneHour)},"server_tool_use":{"web_search_requests":0},"speed":"standard"}},"requestId":"req_\#(id)","type":"assistant","timestamp":"\#(timestamp)","sessionId":"\#(session)"}"#
}

private func user(_ text: String, session: String) -> String {
    #"{"parentUuid":"p","message":{"role":"user","content":"\#(text)"},"type":"user","sessionId":"\#(session)","toolUseResult":"{\"usage\":{\"input_tokens\":999}}"}"#
}

private final class Fixture {
    let root: URL
    let support: URL

    init() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchbar-tokens-\(UUID().uuidString)")
        root = base.appendingPathComponent("projects")
        support = base.appendingPathComponent("support")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    var scanner: TranscriptScanner { TranscriptScanner(root: root, timeZone: .gmt) }

    func write(_ path: String, _ lines: [String], trailingNewline: Bool = true) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try Data(text.utf8).write(to: url)
    }

    func append(_ path: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent(path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
}

private func date(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text)!
}

private func report(_ ledger: TokenUsageLedger, account: String? = nil) -> TokenUsageReport {
    TokenUsageReport(ledger: ledger, days: nil, account: account)
}

@Test func cuentaCadaRespuestaUnaVezYConSuCuenta() throws {
    let fixture = Fixture()
    try fixture.write("proyecto/s1.jsonl", [
        #"{"type":"mode","mode":"normal","sessionId":"s1"}"#,
        owner("s1", account: accountA, org: orgA),
        user("hola", session: "s1"),
        // Una respuesta con dos bloques se escribe en dos líneas iguales.
        assistant("1", session: "s1", at: "2026-11-16T10:00:00.000Z", block: "thinking"),
        assistant("1", session: "s1", at: "2026-11-16T10:00:01.000Z", block: "text"),
        assistant("2", session: "s1", at: "2026-11-16T10:05:00.000Z", cacheWrite: 300, oneHour: 200)
    ])
    var ledger = TokenUsageLedger()
    let changed = fixture.scanner.scan(into: &ledger, now: date("2026-11-16T12:00:00Z"))
    #expect(changed)

    let total = report(ledger).total.counts
    #expect(total.messages == 2)
    #expect(total.input == 20)
    #expect(total.output == 40)
    #expect(total.cacheRead == 2_000)
    #expect(total.cacheWrite5m == 200)
    #expect(total.cacheWrite1h == 200)
    #expect(report(ledger).byAccount.map(\.id) == [profileA])
    #expect(ledger.sessionOwners["s1"]?.account == profileA)
}

@Test func losSubagentesHeredanLaCuentaYNoDuplicanLasCopias() throws {
    let fixture = Fixture()
    try fixture.write("proyecto/s1.jsonl", [
        owner("s1", account: accountA, org: orgA),
        assistant("1", session: "s1", at: "2026-11-16T10:00:00.000Z"),
        assistant("2", session: "s1", at: "2026-11-16T10:01:00.000Z")
    ])
    // Un subagente bifurcado copia la conversación y añade lo suyo.
    try fixture.write("proyecto/s1/subagents/agent-x.jsonl", [
        assistant("1", session: "s1", at: "2026-11-16T10:00:00.000Z"),
        assistant("2", session: "s1", at: "2026-11-16T10:01:00.000Z"),
        assistant("3", session: "s1", at: "2026-11-16T10:02:00.000Z", model: "claude-sonnet-5-5")
    ])
    // Una sesión sin línea de cuenta (Claude Code anterior a la 2.1.310).
    try fixture.write("otro/s2.jsonl", [
        assistant("4", session: "s2", at: "2026-11-15T09:00:00.000Z")
    ])
    var ledger = TokenUsageLedger()
    fixture.scanner.scan(into: &ledger, now: date("2026-11-16T12:00:00Z"))

    let all = report(ledger)
    #expect(all.total.counts.messages == 4)
    #expect(report(ledger, account: profileA).total.counts.messages == 3)
    #expect(report(ledger, account: "").total.counts.messages == 1)
    #expect(Set(all.byModel.map(\.id)) == ["claude-opus-5-5", "claude-sonnet-5-5"])
    #expect(all.byDay.map { LocalDay.string($0.day) } == ["2026-11-16", "2026-11-15"])
}

@Test func laLecturaEsIncrementalYEsperaALineasCompletas() throws {
    let fixture = Fixture()
    try fixture.write("p/s1.jsonl", [
        owner("s1", account: accountA, org: orgA),
        assistant("1", session: "s1", at: "2026-11-16T10:00:00.000Z")
    ])
    var ledger = TokenUsageLedger()
    let scanner = fixture.scanner
    scanner.scan(into: &ledger, now: date("2026-11-16T10:01:00Z"))
    #expect(report(ledger).total.counts.messages == 1)

    // Nada nuevo: no hay que guardar.
    #expect(!scanner.scan(into: &ledger, now: date("2026-11-16T10:02:00Z")))

    // Una línea a medio escribir no se cuenta hasta que se completa.
    let next = assistant("2", session: "s1", at: "2026-11-16T10:05:00.000Z")
    let cut = next.index(next.startIndex, offsetBy: next.count / 2)
    try fixture.append("p/s1.jsonl", String(next[..<cut]))
    scanner.scan(into: &ledger, now: date("2026-11-16T10:06:00Z"))
    #expect(report(ledger).total.counts.messages == 1)

    try fixture.append("p/s1.jsonl", String(next[cut...]) + "\n")
    scanner.scan(into: &ledger, now: date("2026-11-16T10:07:00Z"))
    #expect(report(ledger).total.counts.messages == 2)
    #expect(report(ledger, account: profileA).total.counts.messages == 2)
}

@Test func unaSesionQueCambiaDeCuentaReparteSuUso() throws {
    let fixture = Fixture()
    try fixture.write("p/s1.jsonl", [
        owner("s1", account: accountA, org: orgA),
        assistant("1", session: "s1", at: "2026-11-16T10:00:00.000Z"),
        owner("s1", account: accountB, org: orgB),
        assistant("2", session: "s1", at: "2026-11-16T11:00:00.000Z")
    ])
    var ledger = TokenUsageLedger()
    fixture.scanner.scan(into: &ledger, now: date("2026-11-16T12:00:00Z"))
    #expect(report(ledger, account: profileA).total.counts.messages == 1)
    #expect(report(ledger, account: profileB).total.counts.messages == 1)
}

@Test func elHistoricoSobreviveAlBorradoYReconoceCopiasAntiguas() throws {
    let fixture = Fixture()
    try fixture.write("p/viejo.jsonl", [
        owner("viejo", account: accountA, org: orgA),
        assistant("1", session: "viejo", at: "2026-10-01T10:00:00.000Z")
    ])
    var ledger = TokenUsageLedger()
    let scanner = fixture.scanner
    scanner.scan(into: &ledger, now: date("2026-10-01T12:00:00Z"))

    // Claude Code borra la transcripción a los 30 días: el total se queda.
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("p/viejo.jsonl"))
    scanner.scan(into: &ledger, now: date("2026-11-16T09:00:00Z"))
    #expect(report(ledger).total.counts.messages == 1)
    #expect(ledger.files.isEmpty)
    // Solo se guardan las claves de los últimos días.
    #expect(ledger.seenKeys.keys.allSatisfy { $0 >= LocalDay.parse("2026-11-09")! })

    // Reanudar aquella sesión copia sus mensajes a otro fichero: ya contados.
    try fixture.write("p/reanudada.jsonl", [
        owner("reanudada", account: accountB, org: orgB),
        assistant("1", session: "reanudada", at: "2026-10-01T10:00:00.000Z"),
        assistant("9", session: "reanudada", at: "2026-11-16T10:00:00.000Z")
    ])
    scanner.scan(into: &ledger, now: date("2026-11-16T10:30:00Z"))
    #expect(report(ledger).total.counts.messages == 2)
    #expect(report(ledger, account: profileA).total.counts.messages == 1)
    #expect(report(ledger, account: profileB).total.counts.messages == 1)
}

@Test func unFicheroSustituidoSeReleeSinContarDosVeces() throws {
    let fixture = Fixture()
    let lines = [
        owner("s1", account: accountA, org: orgA),
        assistant("1", session: "s1", at: "2026-11-16T10:00:00.000Z"),
        assistant("2", session: "s1", at: "2026-11-16T10:01:00.000Z")
    ]
    try fixture.write("p/s1.jsonl", lines)
    var ledger = TokenUsageLedger()
    let scanner = fixture.scanner
    scanner.scan(into: &ledger, now: date("2026-11-16T10:02:00Z"))

    // Mismo nombre, otro fichero (otro inodo) y más corto que lo ya leído.
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("p/s1.jsonl"))
    try fixture.write("p/s1.jsonl", [
        owner("s1", account: accountA, org: orgA),
        assistant("3", session: "s1", at: "2026-11-16T10:03:00.000Z")
    ] + Array(lines.dropFirst()))
    scanner.scan(into: &ledger, now: date("2026-11-16T10:04:00Z"))
    #expect(report(ledger).total.counts.messages == 3)
}

@Test func elRegistroSeGuardaYSeRecuperaEntero() throws {
    let fixture = Fixture()
    try fixture.write("p/s1.jsonl", [
        owner("s1", account: accountA, org: orgA),
        assistant("1", session: "s1", at: "2026-11-15T10:00:00.000Z"),
        assistant("2", session: "s1", at: "2026-11-16T10:00:00.000Z", model: "claude-fable-5-2", input: 200_000)
    ])
    var ledger = TokenUsageLedger()
    let scanner = fixture.scanner
    scanner.scan(into: &ledger, now: date("2026-11-16T12:00:00Z"))

    let store = TokenUsageStore(directoryURL: fixture.support)
    try store.save(ledger)
    var restored = store.load()
    #expect(restored == ledger)

    // Tras reiniciar sigue leyendo donde lo dejó, sin repetir nada.
    try fixture.append("p/s1.jsonl", assistant("3", session: "s1", at: "2026-11-16T12:30:00.000Z") + "\n")
    scanner.scan(into: &restored, now: date("2026-11-16T13:00:00Z"))
    #expect(report(restored).total.counts.messages == 3)
    #expect(report(restored, account: profileA).total.counts.messages == 3)

    // El prompt de más de 200 000 tokens queda marcado para su tarifa.
    #expect(ledger.buckets.keys.contains { $0.variant.contains(.promptOver200K) })
}

@Test func sinLasClavesSoloSeAceptaLoPosteriorALaUltimaLectura() throws {
    let fixture = Fixture()
    try fixture.write("p/s1.jsonl", [
        owner("s1", account: accountA, org: orgA),
        assistant("1", session: "s1", at: "2026-11-16T10:00:00.000Z")
    ])
    var ledger = TokenUsageLedger()
    let scanner = fixture.scanner
    scanner.scan(into: &ledger, now: date("2026-11-16T10:30:00Z"))
    let store = TokenUsageStore(directoryURL: fixture.support)
    try store.save(ledger)
    try FileManager.default.removeItem(at: fixture.support.appendingPathComponent("token-usage-keys.bin"))

    var restored = store.load()
    try fixture.write("p/s1/subagents/agent-y.jsonl", [
        assistant("1", session: "s1", at: "2026-11-16T10:00:00.000Z"),
        assistant("5", session: "s1", at: "2026-11-16T10:45:00.000Z")
    ])
    scanner.scan(into: &restored, now: date("2026-11-16T11:00:00Z"))
    #expect(report(restored).total.counts.messages == 2)
}

@Test func elInformeFiltraPorDiasYOrdenaPorCoste() throws {
    var ledger = TokenUsageLedger()
    let day = LocalDay.parse("2026-11-16")!
    ledger.add(TokenCounts(input: 1_000_000, messages: 1), to: UsageBucketKey(day: day, account: profileA, model: opus, variant: []))
    ledger.add(TokenCounts(input: 1_000_000, messages: 1), to: UsageBucketKey(day: day - 1, account: profileB, model: "claude-fable-5-2", variant: []))
    ledger.add(TokenCounts(input: 500, messages: 1), to: UsageBucketKey(day: day, account: profileB, model: "claude-raro-1", variant: []))

    let today = TokenUsageReport(ledger: ledger, days: day...day, account: nil)
    #expect(today.total.counts.messages == 2)
    #expect(today.total.cost == 4)
    #expect(today.total.unpricedTokens == 500)

    let all = TokenUsageReport(ledger: ledger, days: nil, account: nil)
    #expect(all.byModel.first?.id == "claude-fable-5-2")
    #expect(all.byAccount.first?.id == profileB)
    #expect(all.byDay.first?.day == day)
    #expect(all.byDay.first?.byModel[opus]?.cost == 4)
}

@Test func lasClavesBinariasResistenDatosCorruptos() {
    let keys: [Int32: Set<UInt64>] = [20_000: [1, 2, 3], 20_001: [UInt64.max]]
    let data = TokenUsageStore.encodeKeys(keys)
    #expect(TokenUsageStore.decodeKeys(data) == keys)
    #expect(TokenUsageStore.decodeKeys(data.prefix(data.count - 3)) == nil)
}
