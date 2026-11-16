import Foundation

/// Registro de uso guardado junto a `usage-history.json`, con sus mismos
/// permisos 0600.
///
/// - `token-usage.json`: totales por día, cuenta y modelo (el histórico, que
///   sobrevive al borrado de transcripciones de Claude Code), hasta dónde se
///   leyó cada fichero y la cuenta de cada sesión reciente.
/// - `token-usage-keys.bin`: claves de los mensajes de los últimos días, en
///   binario porque son cientos de miles de números.
public final class TokenUsageStore: @unchecked Sendable {
    static let formatVersion = 1
    private let fileURL: URL
    private let keysURL: URL
    private let lock = NSLock()

    public init(directoryURL: URL) {
        self.fileURL = directoryURL.appendingPathComponent("token-usage.json")
        self.keysURL = directoryURL.appendingPathComponent("token-usage-keys.bin")
    }

    public convenience init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        // Nombre histórico del proyecto: ver ProfileStore.vaultService.
        self.init(directoryURL: support.appendingPathComponent("ClaudeSwitch"))
    }

    // MARK: Formato

    private struct Stored: Codable {
        var version: Int
        var lastScanAt: Double?
        var keysCoverFrom: Double?
        /// `[día, cuenta, modelo, variante, entrada, salida, caché 5 min,
        /// caché 1 h, caché leída, búsquedas, mensajes]`.
        var buckets: [Row]
        /// Ruta relativa → `[byte leído, inodo]`.
        var files: [String: [UInt64]]
        /// Sesión → `[cuenta, último día visto]`.
        var owners: [String: [String]]
    }

    private struct Row: Codable {
        var key: UsageBucketKey
        var counts: TokenCounts

        init(key: UsageBucketKey, counts: TokenCounts) {
            self.key = key
            self.counts = counts
        }

        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            let day = try row.decode(String.self)
            guard let number = LocalDay.parse(day) else {
                throw DecodingError.dataCorruptedError(in: row, debugDescription: "día")
            }
            key = UsageBucketKey(
                day: number,
                account: try row.decode(String.self),
                model: try row.decode(String.self),
                variant: UsageVariant(rawValue: try row.decode(UInt8.self))
            )
            counts = TokenCounts(
                input: try row.decode(Int64.self),
                output: try row.decode(Int64.self),
                cacheWrite5m: try row.decode(Int64.self),
                cacheWrite1h: try row.decode(Int64.self),
                cacheRead: try row.decode(Int64.self),
                webSearches: try row.decode(Int64.self),
                messages: try row.decode(Int64.self)
            )
        }

        func encode(to encoder: Encoder) throws {
            var row = encoder.unkeyedContainer()
            try row.encode(LocalDay.string(key.day))
            try row.encode(key.account)
            try row.encode(key.model)
            try row.encode(key.variant.rawValue)
            try row.encode(counts.input)
            try row.encode(counts.output)
            try row.encode(counts.cacheWrite5m)
            try row.encode(counts.cacheWrite1h)
            try row.encode(counts.cacheRead)
            try row.encode(counts.webSearches)
            try row.encode(counts.messages)
        }
    }

    // MARK: Carga y guardado

    /// Un fichero ilegible o de otra versión equivale a no tener registro: se
    /// vuelve a leer todo lo que quede en disco.
    public func load() -> TokenUsageLedger {
        lock.lock(); defer { lock.unlock() }
        var ledger = TokenUsageLedger()
        guard let data = try? SecureFileIO.readIfPresent(fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == Self.formatVersion else { return ledger }
        for row in stored.buckets {
            ledger.add(row.counts, to: row.key)
        }
        for (path, values) in stored.files where values.count == 2 {
            ledger.files[path] = .init(offset: values[0], inode: values[1])
        }
        for (session, values) in stored.owners where values.count == 2 {
            if let day = LocalDay.parse(values[1]) {
                ledger.sessionOwners[session] = .init(account: values[0], lastSeenDay: day)
            }
        }
        ledger.lastScanAt = stored.lastScanAt.map(Date.init(timeIntervalSince1970:))
        ledger.keysCoverFrom = stored.keysCoverFrom
        guard let keys = try? SecureFileIO.readIfPresent(keysURL),
              let seen = Self.decodeKeys(keys) else {
            // Sin las claves no se pueden reconocer copias recientes: se
            // vuelven a aceptar solo los mensajes posteriores a la última
            // lectura, que no pueden estar contados.
            if let lastScanAt = ledger.lastScanAt?.timeIntervalSince1970 {
                ledger.keysCoverFrom = max(ledger.keysCoverFrom ?? lastScanAt, lastScanAt)
            }
            return ledger
        }
        ledger.seenKeys = seen
        return ledger
    }

    public func save(_ ledger: TokenUsageLedger) throws {
        lock.lock(); defer { lock.unlock() }
        let stored = Stored(
            version: Self.formatVersion,
            lastScanAt: ledger.lastScanAt?.timeIntervalSince1970,
            keysCoverFrom: ledger.keysCoverFrom,
            buckets: ledger.buckets
                .sorted { ($0.key.day, $0.key.account, $0.key.model) < ($1.key.day, $1.key.account, $1.key.model) }
                .map { Row(key: $0.key, counts: $0.value) },
            files: ledger.files.mapValues { [$0.offset, $0.inode] },
            owners: ledger.sessionOwners.mapValues { [$0.account, LocalDay.string($0.lastSeenDay)] }
        )
        // Las claves primero: si falla el registro principal, unas claves de
        // más solo hacen descartar copias que de todos modos no se contarían.
        try SecureFileIO.writeAtomically(Self.encodeKeys(ledger.seenKeys), to: keysURL)
        let data = try JSONEncoder().encode(stored)
        try SecureFileIO.writeAtomically(data, to: fileURL)
    }

    /// Por día: `día (Int32) · cuántas (UInt32) · claves (UInt64)…`, todo en
    /// little-endian.
    static func encodeKeys(_ keys: [Int32: Set<UInt64>]) -> Data {
        var data = Data()
        data.reserveCapacity(keys.values.reduce(0) { $0 + $1.count } * 8 + keys.count * 8)
        for (day, set) in keys.sorted(by: { $0.key < $1.key }) {
            withUnsafeBytes(of: day.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(set.count).littleEndian) { data.append(contentsOf: $0) }
            for key in set {
                withUnsafeBytes(of: key.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    static func decodeKeys(_ data: Data) -> [Int32: Set<UInt64>]? {
        var result: [Int32: Set<UInt64>] = [:]
        let ok = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            func take<T: FixedWidthInteger>(_: T.Type) -> T? {
                guard offset + MemoryLayout<T>.size <= raw.count else { return nil }
                let value = raw.loadUnaligned(fromByteOffset: offset, as: T.self)
                offset += MemoryLayout<T>.size
                return T(littleEndian: value)
            }
            while offset < raw.count {
                guard let day = take(Int32.self), let count = take(UInt32.self),
                      offset + Int(count) * 8 <= raw.count else { return false }
                var set = Set<UInt64>(minimumCapacity: Int(count))
                for _ in 0..<count {
                    guard let key = take(UInt64.self) else { return false }
                    set.insert(key)
                }
                result[day] = set
            }
            return true
        }
        return ok ? result : nil
    }
}
