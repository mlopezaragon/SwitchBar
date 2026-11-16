import Darwin
import Foundation

/// Lee las transcripciones de Claude Code (`~/.claude/projects/**/*.jsonl`)
/// y suma al registro el uso de cada respuesta del modelo.
///
/// Solo se interpretan dos tipos de línea, y solo los campos de uso: las
/// respuestas (`assistant`, con `message.usage`) y la línea `session-owner`
/// que Claude Code escribe desde la 2.1.310 con la cuenta de la sesión. El
/// contenido de las conversaciones nunca se guarda ni sale del Mac.
///
/// La lectura es incremental: de cada fichero se recuerda hasta qué byte se
/// leyó, de modo que tras la primera pasada (decenas de GB) cada vuelta solo
/// lee lo que se ha añadido desde la anterior.
public final class TranscriptScanner: @unchecked Sendable {
    public struct Progress: Sendable, Equatable {
        public var bytesRead: Int64
        public var bytesTotal: Int64

        public var fraction: Double {
            bytesTotal > 0 ? min(1, Double(bytesRead) / Double(bytesTotal)) : 1
        }
    }

    let root: URL
    private let timeZone: TimeZone

    public init(root: URL = TranscriptScanner.defaultRoot, timeZone: TimeZone = .current) {
        self.root = root
        self.timeZone = timeZone
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    // MARK: Lectura

    private struct Candidate {
        var relativePath: String
        var size: UInt64
        var inode: UInt64
        var modified: Double
        var nested: Bool
    }

    /// Recorre las transcripciones y añade al registro lo nuevo. Devuelve si
    /// había algo que leer (si no, no hace falta volver a guardar el registro).
    ///
    /// Primero las sesiones y después los subagentes: un subagente hereda la
    /// cuenta de su sesión y, si la bifurca, copia sus mensajes; leyendo antes
    /// la sesión, el original se cuenta con la cuenta correcta y la copia se
    /// reconoce como tal.
    @discardableResult
    public func scan(
        into ledger: inout TokenUsageLedger,
        now: Date = Date(),
        progress: ((Progress) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) -> Bool {
        let candidates = enumerate()
        var pending: [Candidate] = []
        var total: Int64 = 0
        for candidate in candidates {
            let known = ledger.files[candidate.relativePath]
            let start = known.map { $0.inode == candidate.inode && $0.offset <= candidate.size ? $0.offset : 0 } ?? 0
            if start < candidate.size {
                pending.append(candidate)
                total += Int64(candidate.size - start)
            }
        }
        pending.sort {
            if $0.nested != $1.nested { return !$0.nested }
            return $0.modified < $1.modified
        }

        let reader = LineReader()
        var processor = LineProcessor(timeZone: timeZone, today: LocalDay.number(of: now, timeZone: timeZone))
        var done: Int64 = 0
        var lastReport: Int64 = 0
        progress?(Progress(bytesRead: 0, bytesTotal: total))
        for candidate in pending {
            if isCancelled() { return false }
            let known = ledger.files[candidate.relativePath]
            var start: UInt64 = 0
            if let known, known.inode == candidate.inode, known.offset <= candidate.size {
                start = known.offset
            }
            let path = root.appendingPathComponent(candidate.relativePath).path
            let end = reader.read(path: path, from: start) { line in
                processor.process(line, ledger: &ledger)
            }
            ledger.files[candidate.relativePath] = .init(offset: end, inode: candidate.inode)
            done += Int64(candidate.size > start ? candidate.size - start : 0)
            if done - lastReport > 64 << 20 {
                lastReport = done
                progress?(Progress(bytesRead: done, bytesTotal: total))
            }
        }
        if isCancelled() { return false }
        progress?(Progress(bytesRead: total, bytesTotal: total))
        let filesBefore = ledger.files.count
        ledger.finishScan(
            at: now,
            existingFiles: Set(candidates.map(\.relativePath)),
            timeZone: timeZone
        )
        return !pending.isEmpty || ledger.files.count != filesBefore
    }

    private func enumerate() -> [Candidate] {
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var result: [Candidate] = []
        while let relative = enumerator.nextObject() as? String {
            guard relative.hasSuffix(".jsonl") else { continue }
            var info = stat()
            guard lstat(base + relative, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            // Proyecto/sesión.jsonl en el primer nivel; el resto son
            // subagentes y flujos de trabajo dentro de la carpeta de su sesión.
            let depth = relative.utf8.reduce(0) { $1 == UInt8(ascii: "/") ? $0 + 1 : $0 }
            result.append(Candidate(
                relativePath: relative,
                size: UInt64(info.st_size),
                inode: UInt64(info.st_ino),
                modified: Double(info.st_mtimespec.tv_sec),
                nested: depth > 1
            ))
        }
        return result
    }
}

// MARK: - Lectura por líneas

/// Lee un fichero desde un desplazamiento y entrega cada línea completa. Una
/// línea a medio escribir al final se deja para la próxima vuelta.
final class LineReader {
    private var buffer: UnsafeMutableRawPointer
    private var capacity: Int

    init(capacity: Int = 4 << 20) {
        self.capacity = capacity
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    }

    deinit { buffer.deallocate() }

    /// Devuelve el desplazamiento justo después de la última línea completa.
    func read(path: String, from offset: UInt64, line: (UnsafeRawBufferPointer) -> Void) -> UInt64 {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return offset }
        defer { close(descriptor) }
        var consumed = offset
        var filled = 0
        var position = off_t(offset)
        while true {
            if filled == capacity { grow() }
            let count = pread(descriptor, buffer + filled, capacity - filled, position)
            if count <= 0 { break }
            position += off_t(count)
            filled += count
            var start = 0
            while start < filled,
                  let newline = memchr(buffer + start, 0x0A, filled - start) {
                let end = buffer.distance(to: newline)
                if end > start {
                    line(UnsafeRawBufferPointer(start: buffer + start, count: end - start))
                }
                start = end + 1
            }
            if start > 0 {
                if start < filled { memmove(buffer, buffer + start, filled - start) }
                filled -= start
                consumed += UInt64(start)
            }
        }
        return consumed
    }

    private func grow() {
        let larger = UnsafeMutableRawPointer.allocate(byteCount: capacity * 2, alignment: 16)
        larger.copyMemory(from: buffer, byteCount: capacity)
        buffer.deallocate()
        buffer = larger
        capacity *= 2
    }
}

// MARK: - Interpretación de líneas

struct LineProcessor {
    private static let usageMarker = Array(#""usage":{"#.utf8)
    private static let ownerMarker = Array(#""type":"session-owner""#.utf8)

    private let decoder = JSONDecoder()
    private let timeZone: TimeZone
    private let today: Int32

    init(timeZone: TimeZone, today: Int32) {
        self.timeZone = timeZone
        self.today = today
    }

    /// Las marcas se buscan en los bytes crudos: dentro de un texto JSON las
    /// comillas van escapadas, así que no hay coincidencias falsas con el
    /// contenido de las conversaciones.
    mutating func process(_ line: UnsafeRawBufferPointer, ledger: inout TokenUsageLedger) {
        if Self.contains(line, Self.usageMarker) {
            guard let entry = decode(AssistantLine.self, line) else { return }
            record(entry, ledger: &ledger)
        } else if line.count < 4_096, Self.contains(line, Self.ownerMarker) {
            guard let owner = decode(OwnerLine.self, line),
                  owner.type == "session-owner",
                  let session = owner.sessionId,
                  let account = owner.accountUuid, !account.isEmpty else { return }
            ledger.sessionOwners[session] = .init(
                account: ProfileID.make(accountUuid: account, organizationUuid: owner.organizationUuid),
                lastSeenDay: today
            )
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ line: UnsafeRawBufferPointer) -> T? {
        guard let base = line.baseAddress else { return nil }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: line.count, deallocator: .none)
        return try? decoder.decode(type, from: data)
    }

    private func record(_ entry: AssistantLine, ledger: inout TokenUsageLedger) {
        guard entry.type == "assistant",
              let message = entry.message,
              let usage = message.usage,
              let model = message.model, !model.isEmpty,
              !model.hasPrefix("<"),
              let epoch = entry.timestamp.flatMap(Timestamp.epoch) else { return }
        // Más antiguo que las claves que se conservan: es la copia de un
        // mensaje que ya se contó al leerlo por primera vez.
        if let cover = ledger.keysCoverFrom, epoch < cover { return }
        let day = LocalDay.number(epoch: epoch, timeZone: timeZone)
        if let key = Self.messageKey(id: message.id, request: entry.requestId),
           !ledger.markSeen(key, day: day) {
            return
        }

        let input = Int64(max(0, usage.input_tokens ?? 0))
        let cacheRead = Int64(max(0, usage.cache_read_input_tokens ?? 0))
        let cacheWrite = Int64(max(0, usage.cache_creation_input_tokens ?? 0))
        let oneHour = min(cacheWrite, Int64(max(0, usage.cache_creation?.ephemeral_1h_input_tokens ?? 0)))
        var counts = TokenCounts()
        counts.input = input
        counts.output = Int64(max(0, usage.output_tokens ?? 0))
        counts.cacheRead = cacheRead
        // Sin desglose, la escritura es la de 5 minutos (la predeterminada).
        counts.cacheWrite1h = oneHour
        counts.cacheWrite5m = cacheWrite - oneHour
        counts.webSearches = Int64(max(0, usage.server_tool_use?.web_search_requests ?? 0))
        counts.messages = 1

        let account = entry.sessionId.flatMap { ledger.sessionOwners[$0]?.account } ?? ""
        let variant = UsageVariant(promptTokens: input + cacheRead + cacheWrite, fast: usage.speed == "fast")
        ledger.add(counts, to: UsageBucketKey(day: day, account: account, model: model, variant: variant))
    }

    /// Una respuesta se escribe en varias líneas (una por bloque) con el mismo
    /// mensaje y la misma petición, y puede reaparecer copiada en otro fichero.
    static func messageKey(id: String?, request: String?) -> UInt64? {
        guard id != nil || request != nil else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (id ?? "").utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        hash = (hash ^ 0x3A) &* 0x100_0000_01b3
        for byte in (request ?? "").utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }

    static func contains(_ haystack: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = haystack.baseAddress, haystack.count >= needle.count else { return false }
        return needle.withUnsafeBytes { pattern in
            memmem(base, haystack.count, pattern.baseAddress, pattern.count) != nil
        }
    }

    // Solo los campos necesarios: el resto de cada línea ni se conserva.
    struct AssistantLine: Decodable {
        var type: String?
        var sessionId: String?
        var timestamp: String?
        var requestId: String?
        var message: Message?

        struct Message: Decodable {
            var id: String?
            var model: String?
            var usage: Usage?
        }

        struct Usage: Decodable {
            var input_tokens: Int?
            var output_tokens: Int?
            var cache_creation_input_tokens: Int?
            var cache_read_input_tokens: Int?
            var cache_creation: CacheCreation?
            var server_tool_use: ServerToolUse?
            var speed: String?
        }

        struct CacheCreation: Decodable {
            var ephemeral_1h_input_tokens: Int?
        }

        struct ServerToolUse: Decodable {
            var web_search_requests: Int?
        }
    }

    struct OwnerLine: Decodable {
        var type: String?
        var sessionId: String?
        var accountUuid: String?
        var organizationUuid: String?
    }
}

/// Marcas de tiempo ISO 8601 de Claude Code (`2026-11-16T22:32:07.530Z`).
enum Timestamp {
    static func epoch(_ text: String) -> Double? {
        let bytes = Array(text.utf8)
        func number(_ from: Int, _ count: Int) -> Int? {
            guard from + count <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[from..<(from + count)] {
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }
        if bytes.count >= 20, bytes[4] == 45, bytes[7] == 45, bytes[10] == 84,
           bytes.last == 90,
           let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
           let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2) {
            var fraction = 0.0
            if bytes.count > 21, bytes[19] == 46 {
                var scale = 0.1
                for byte in bytes[20..<(bytes.count - 1)] {
                    guard byte >= 48, byte <= 57 else { break }
                    fraction += Double(byte - 48) * scale
                    scale /= 10
                }
            }
            let days = Double(LocalDay.number(year: year, month: month, day: day))
            return days * 86_400 + Double(hour * 3_600 + minute * 60 + second) + fraction
        }
        // Otros formatos (con zona horaria explícita): raros, sin prisa.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)?.timeIntervalSince1970
    }
}
