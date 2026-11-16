import Foundation

/// Circunstancias de un mensaje que cambian su precio por token.
public struct UsageVariant: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Modo rápido de Claude Code (`/fast`).
    public static let fast = UsageVariant(rawValue: 1 << 0)
    /// Prompt (entrada + caché) de más de 100 000 tokens.
    public static let promptOver100K = UsageVariant(rawValue: 1 << 1)
    /// Prompt de más de 200 000 tokens.
    public static let promptOver200K = UsageVariant(rawValue: 1 << 2)

    init(promptTokens: Int64, fast: Bool) {
        var variant: UsageVariant = []
        if fast { variant.insert(.fast) }
        if promptTokens > 100_000 { variant.insert(.promptOver100K) }
        if promptTokens > 200_000 { variant.insert(.promptOver200K) }
        self = variant
    }
}

/// Tokens de uno o varios mensajes, separados como los factura el API.
public struct TokenCounts: Sendable, Equatable {
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheWrite5m: Int64 = 0
    public var cacheWrite1h: Int64 = 0
    public var cacheRead: Int64 = 0
    public var webSearches: Int64 = 0
    /// Respuestas del modelo (mensajes únicos).
    public var messages: Int64 = 0

    public init(
        input: Int64 = 0, output: Int64 = 0,
        cacheWrite5m: Int64 = 0, cacheWrite1h: Int64 = 0,
        cacheRead: Int64 = 0, webSearches: Int64 = 0, messages: Int64 = 0
    ) {
        self.input = input
        self.output = output
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.webSearches = webSearches
        self.messages = messages
    }

    public var cacheWrite: Int64 { cacheWrite5m + cacheWrite1h }
    /// Todos los tokens, caché incluida.
    public var total: Int64 { input + output + cacheWrite + cacheRead }
    public var isEmpty: Bool { messages == 0 && total == 0 }

    public mutating func add(_ other: TokenCounts) {
        input += other.input
        output += other.output
        cacheWrite5m += other.cacheWrite5m
        cacheWrite1h += other.cacheWrite1h
        cacheRead += other.cacheRead
        webSearches += other.webSearches
        messages += other.messages
    }
}

/// Día natural en la zona horaria del Mac, contado desde el 1-1-1970.
public enum LocalDay {
    public static func number(epoch: Double, timeZone: TimeZone = .current) -> Int32 {
        let offset = Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: epoch)))
        return Int32(((epoch + offset) / 86_400).rounded(.down))
    }

    public static func number(of date: Date, timeZone: TimeZone = .current) -> Int32 {
        number(epoch: date.timeIntervalSince1970, timeZone: timeZone)
    }

    /// Año, mes y día del calendario civil (algoritmo de Howard Hinnant).
    public static func civil(_ day: Int32) -> (year: Int, month: Int, day: Int) {
        let z = Int(day) + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    public static func number(year: Int, month: Int, day: Int) -> Int32 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month > 2 ? month - 3 : month + 9
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return Int32(era * 146_097 + doe - 719_468)
    }

    public static func string(_ day: Int32) -> String {
        let c = civil(day)
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }

    public static func parse(_ text: String) -> Int32? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return number(year: parts[0], month: parts[1], day: parts[2])
    }

    /// Mediodía de ese día en la zona del Mac, para dar formato a la fecha.
    public static func date(_ day: Int32, calendar: Calendar = .current) -> Date {
        let c = civil(day)
        let components = DateComponents(year: c.year, month: c.month, day: c.day, hour: 12)
        return calendar.date(from: components)
            ?? Date(timeIntervalSince1970: Double(day) * 86_400 + 43_200)
    }
}

/// Agrupa el uso por día, cuenta, modelo y tarifa.
public struct UsageBucketKey: Hashable, Sendable {
    public var day: Int32
    /// `ProfileID` de la cuenta, o cadena vacía si la sesión no dice cuál.
    public var account: String
    public var model: String
    public var variant: UsageVariant

    public init(day: Int32, account: String, model: String, variant: UsageVariant) {
        self.day = day
        self.account = account
        self.model = model
        self.variant = variant
    }
}

/// Registro acumulado del uso de Claude Code en este Mac.
///
/// Claude Code borra sus transcripciones a los 30 días; este registro
/// conserva los totales por día para que el histórico no se pierda con ellas.
/// Además de los totales guarda lo justo para seguir leyendo sin contar dos
/// veces: hasta dónde se leyó cada fichero, la cuenta de cada sesión y las
/// claves de los mensajes recientes.
public struct TokenUsageLedger: Sendable, Equatable {
    struct FileProgress: Sendable, Equatable {
        var offset: UInt64
        var inode: UInt64
    }

    struct SessionOwner: Sendable, Equatable {
        var account: String
        var lastSeenDay: Int32
    }

    /// Días de claves que se conservan para reconocer copias de un mensaje.
    /// Claude Code copia mensajes al bifurcar un subagente o al reanudar una
    /// sesión; la copia conserva la fecha del original. Un mensaje nuevo
    /// siempre llega con fecha posterior a la última lectura, así que basta
    /// con recordar unos días: lo anterior a esa ventana ya se contó.
    static let keyRetentionDays: Int32 = 7
    static let ownerRetentionDays: Int32 = 45

    public internal(set) var buckets: [UsageBucketKey: TokenCounts] = [:]
    var files: [String: FileProgress] = [:]
    var sessionOwners: [String: SessionOwner] = [:]
    var seenKeys: [Int32: Set<UInt64>] = [:]
    /// Desde cuándo las claves están completas (segundos desde 1970). Antes de
    /// la primera lectura no hay límite: se cuenta todo lo que haya en disco.
    var keysCoverFrom: Double?
    public internal(set) var lastScanAt: Date?

    public init() {}

    public var hasScanned: Bool { lastScanAt != nil }

    /// Primer día con uso registrado.
    public var firstDay: Int32? { buckets.keys.map(\.day).min() }

    mutating func add(_ counts: TokenCounts, to key: UsageBucketKey) {
        buckets[key, default: TokenCounts()].add(counts)
    }

    /// Devuelve `false` si el mensaje ya estaba contado.
    mutating func markSeen(_ key: UInt64, day: Int32) -> Bool {
        seenKeys[day, default: []].insert(key).inserted
    }

    /// Cierra una lectura: olvida claves, sesiones y ficheros que ya no hacen
    /// falta y fija desde cuándo se puede seguir comprobando duplicados.
    mutating func finishScan(at now: Date, existingFiles: Set<String>, timeZone: TimeZone = .current) {
        let today = LocalDay.number(of: now, timeZone: timeZone)
        let firstKeyDay = today - Self.keyRetentionDays
        seenKeys = seenKeys.filter { $0.key >= firstKeyDay }
        sessionOwners = sessionOwners.filter { $0.value.lastSeenDay >= today - Self.ownerRetentionDays }
        files = files.filter { existingFiles.contains($0.key) }
        // Medianoche (local) del primer día con claves: las de ese día están todas.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let firstKeyDate = calendar.startOfDay(for: LocalDay.date(firstKeyDay, calendar: calendar))
        keysCoverFrom = max(keysCoverFrom ?? -Double.infinity, firstKeyDate.timeIntervalSince1970)
        lastScanAt = now
    }
}

// MARK: - Informe

/// Totales de un grupo (un modelo, una cuenta, un día) con su coste.
public struct UsageTotals: Sendable, Equatable {
    public var counts = TokenCounts()
    /// Coste equivalente en el API de lo que tiene precio conocido.
    public var cost: Double = 0
    /// Tokens de modelos sin precio conocido, que no suman al coste.
    public var unpricedTokens: Int64 = 0

    public init() {}

    mutating func add(_ counts: TokenCounts, cost: Double?) {
        self.counts.add(counts)
        if let cost {
            self.cost += cost
        } else {
            unpricedTokens += counts.total
        }
    }
}

/// Resumen del registro para un periodo y, opcionalmente, una sola cuenta.
public struct TokenUsageReport: Sendable {
    public struct Group: Sendable, Identifiable {
        public var id: String
        public var totals: UsageTotals
    }

    public struct Day: Sendable, Identifiable {
        public var day: Int32
        public var totals: UsageTotals
        /// Totales de ese día por modelo canónico.
        public var byModel: [String: UsageTotals]
        public var id: Int32 { day }
    }

    public var total = UsageTotals()
    /// Por modelo canónico (`claude-opus-5-5`), de mayor a menor coste.
    public var byModel: [Group] = []
    /// Por cuenta (`ProfileID`; vacío = sin atribuir), de mayor a menor coste.
    public var byAccount: [Group] = []
    /// Días del periodo con uso, del más reciente al más antiguo.
    public var byDay: [Day] = []

    /// - Parameters:
    ///   - days: días incluidos (ambos extremos); `nil` = todo el registro.
    ///   - account: solo esa cuenta; `nil` = todas.
    public init(ledger: TokenUsageLedger, days: ClosedRange<Int32>?, account: String?) {
        var models: [String: UsageTotals] = [:]
        var accounts: [String: UsageTotals] = [:]
        var daily: [Int32: (UsageTotals, [String: UsageTotals])] = [:]
        for (key, counts) in ledger.buckets {
            if let days, !days.contains(key.day) { continue }
            if let account, key.account != account { continue }
            let cost = ModelPricing.cost(of: counts, model: key.model, variant: key.variant)
            let model = ModelPricing.canonicalID(key.model)
            total.add(counts, cost: cost)
            models[model, default: UsageTotals()].add(counts, cost: cost)
            accounts[key.account, default: UsageTotals()].add(counts, cost: cost)
            var entry = daily[key.day] ?? (UsageTotals(), [:])
            entry.0.add(counts, cost: cost)
            entry.1[model, default: UsageTotals()].add(counts, cost: cost)
            daily[key.day] = entry
        }
        func ordered(_ groups: [String: UsageTotals]) -> [Group] {
            groups.map { Group(id: $0.key, totals: $0.value) }
                .sorted {
                    ($0.totals.cost, $0.totals.counts.total, $1.id)
                        > ($1.totals.cost, $1.totals.counts.total, $0.id)
                }
        }
        byModel = ordered(models)
        byAccount = ordered(accounts)
        byDay = daily.map { Day(day: $0.key, totals: $0.value.0, byModel: $0.value.1) }
            .sorted { $0.day > $1.day }
    }
}
