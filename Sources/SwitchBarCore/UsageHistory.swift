import Foundation

/// Lectura del uso de una cuenta en un instante. Es lo único que hace falta
/// para medir a qué ritmo se gasta: porcentajes y horas de reinicio, nada
/// secreto.
public struct UsageSample: Sendable, Equatable {
    public var at: Date
    /// Uso de la ventana de 5 h; `nil` si no hay ventana abierta.
    public var fiveHour: Double?
    public var fiveHourResetsAt: Date?
    public var sevenDay: Double?
    public var sevenDayResetsAt: Date?

    public init(
        at: Date,
        fiveHour: Double?,
        fiveHourResetsAt: Date? = nil,
        sevenDay: Double? = nil,
        sevenDayResetsAt: Date? = nil
    ) {
        self.at = at
        self.fiveHour = fiveHour
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDay = sevenDay
        self.sevenDayResetsAt = sevenDayResetsAt
    }

    public init(_ snapshot: UsageSnapshot) {
        self.init(
            at: snapshot.fetchedAt,
            fiveHour: snapshot.fiveHour?.utilization,
            fiveHourResetsAt: snapshot.fiveHour?.resetsAt,
            sevenDay: snapshot.sevenDay?.utilization,
            sevenDayResetsAt: snapshot.sevenDay?.resetsAt
        )
    }

    /// Mismos porcentajes y mismas ventanas. El servidor redondea la hora de
    /// reinicio de forma distinta entre consultas, así que se tolera un minuto.
    func sameReading(as other: UsageSample) -> Bool {
        fiveHour == other.fiveHour
            && sevenDay == other.sevenDay
            && Self.close(fiveHourResetsAt, other.fiveHourResetsAt, tolerance: 60)
            && Self.close(sevenDayResetsAt, other.sevenDayResetsAt, tolerance: 60)
    }

    static func close(_ a: Date?, _ b: Date?, tolerance: TimeInterval) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) <= tolerance
        default: return false
        }
    }
}

/// Lecturas recientes de cada cuenta, de las que sale su ritmo de gasto.
public struct UsageHistory: Sendable, Equatable {
    /// Una semana basta para conocer el ritmo habitual de cada plan.
    public static let retention: TimeInterval = 7 * 24 * 3_600
    /// Una lectura idéntica a la anterior no aporta nada, salvo de vez en
    /// cuando: así se sabe que la cuenta estuvo parada y no sin consultar.
    public static let idleHeartbeat: TimeInterval = 10 * 60
    /// Tope por cuenta, por si el sondeo se acelerara más de lo previsto.
    static let maximumSamplesPerAccount = 6_000

    public private(set) var samplesByAccount: [String: [UsageSample]]

    public init(samplesByAccount: [String: [UsageSample]] = [:]) {
        self.samplesByAccount = samplesByAccount.mapValues {
            $0.sorted { $0.at < $1.at }
        }
    }

    public func samples(for account: String) -> [UsageSample] {
        samplesByAccount[account] ?? []
    }

    /// Añade la lectura si aporta algo. Devuelve `true` si se guardó.
    @discardableResult
    public mutating func record(_ snapshot: UsageSnapshot, for account: String) -> Bool {
        record(UsageSample(snapshot), for: account)
    }

    @discardableResult
    public mutating func record(_ sample: UsageSample, for account: String) -> Bool {
        var list = samplesByAccount[account] ?? []
        if let last = list.last {
            guard sample.at > last.at else { return false }
            if last.sameReading(as: sample),
               sample.at.timeIntervalSince(last.at) < Self.idleHeartbeat {
                return false
            }
        }
        list.append(sample)
        if list.count > Self.maximumSamplesPerAccount {
            list.removeFirst(list.count - Self.maximumSamplesPerAccount)
        }
        samplesByAccount[account] = list
        return true
    }

    public mutating func prune(now: Date, keeping accounts: Set<String>? = nil) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        var pruned: [String: [UsageSample]] = [:]
        for (account, list) in samplesByAccount {
            if let accounts, !accounts.contains(account) { continue }
            let recent = list.filter { $0.at >= cutoff }
            if !recent.isEmpty { pruned[account] = recent }
        }
        samplesByAccount = pruned
    }
}

/// Historial de lecturas guardado en disco, junto a `usage-cache.json` y con
/// sus mismos permisos 0600. Sin él, el ritmo habitual de cada cuenta se
/// perdería en cada reinicio de la app.
public final class UsageHistoryStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(directoryURL: URL) {
        self.fileURL = directoryURL.appendingPathComponent("usage-history.json")
    }

    public convenience init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        // Nombre histórico del proyecto: ver ProfileStore.vaultService.
        self.init(directoryURL: support.appendingPathComponent("ClaudeSwitch"))
    }

    /// Formato compacto: por cuenta, filas `[t, u5, r5, u7, r7]` con las
    /// fechas en segundos y `null` donde no hay dato.
    public func load(now: Date = Date()) -> UsageHistory {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? SecureFileIO.readIfPresent(fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: [[Any]]]
        else { return UsageHistory() }
        func number(_ row: [Any], _ index: Int) -> Double? {
            guard index < row.count else { return nil }
            return (row[index] as? NSNumber)?.doubleValue
        }
        func date(_ row: [Any], _ index: Int) -> Date? {
            number(row, index).map { Date(timeIntervalSince1970: $0) }
        }
        var samples: [String: [UsageSample]] = [:]
        for (account, rows) in dict {
            samples[account] = rows.compactMap { row in
                guard let at = date(row, 0) else { return nil }
                return UsageSample(
                    at: at,
                    fiveHour: number(row, 1),
                    fiveHourResetsAt: date(row, 2),
                    sevenDay: number(row, 3),
                    sevenDayResetsAt: date(row, 4)
                )
            }
        }
        var history = UsageHistory(samplesByAccount: samples)
        history.prune(now: now)
        return history
    }

    public func save(_ history: UsageHistory) throws {
        lock.lock(); defer { lock.unlock() }
        func value(_ number: Double?) -> Any { number ?? NSNull() }
        func value(_ date: Date?) -> Any {
            date.map { $0.timeIntervalSince1970.rounded() } ?? NSNull()
        }
        var dict: [String: [[Any]]] = [:]
        for (account, list) in history.samplesByAccount {
            dict[account] = list.map {
                [
                    $0.at.timeIntervalSince1970.rounded(),
                    value($0.fiveHour),
                    value($0.fiveHourResetsAt),
                    value($0.sevenDay),
                    value($0.sevenDayResetsAt)
                ]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try SecureFileIO.writeAtomically(data, to: fileURL)
    }
}
