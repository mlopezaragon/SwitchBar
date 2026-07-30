import Foundation

/// Última instantánea de uso conocida de cada cuenta, persistida en disco.
///
/// Los porcentajes de uso y sus horas de reinicio no son secretos: guardarlos
/// permite que el panel muestre todas las cuentas nada más arrancar, en lugar
/// de esperar a que la primera vuelta de consultas (espaciadas para respetar
/// al servidor) las rellene una a una. El fichero vive junto a
/// `profiles.json` con los mismos permisos 0600.
public final class UsageSnapshotCache: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(directoryURL: URL) {
        self.fileURL = directoryURL.appendingPathComponent("usage-cache.json")
    }

    public convenience init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        // Nombre histórico del proyecto: ver ProfileStore.vaultService.
        self.init(
            directoryURL: support.appendingPathComponent("ClaudeSwitch")
        )
    }

    /// Carga la caché descartando las ventanas cuyo reinicio ya pasó: su
    /// porcentaje ya no describe la realidad y mostrarlo induciría a error
    /// (y a la política automática, si los datos fueran recientes).
    public func load(now: Date = Date()) -> [String: UsageSnapshot] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? SecureFileIO.readIfPresent(fileURL),
              let dict = try? JSONSerialization.jsonObject(
                with: data
              ) as? [String: [String: Any]] else {
            return [:]
        }
        var result: [String: UsageSnapshot] = [:]
        for (account, raw) in dict {
            guard let fetchedAt = (raw["fetchedAt"] as? NSNumber)?.doubleValue
            else { continue }
            func window(_ key: String) -> UsageWindow? {
                guard let w = raw[key] as? [String: Any],
                      let utilization =
                        (w["utilization"] as? NSNumber)?.doubleValue else {
                    return nil
                }
                let resetsAt = (w["resetsAt"] as? NSNumber).map {
                    Date(timeIntervalSince1970: $0.doubleValue)
                }
                if let resetsAt, resetsAt <= now { return nil }
                return UsageWindow(
                    utilization: utilization,
                    resetsAt: resetsAt
                )
            }
            result[account] = UsageSnapshot(
                fiveHour: window("fiveHour"),
                sevenDay: window("sevenDay"),
                sevenDayOpus: window("sevenDayOpus"),
                fetchedAt: Date(timeIntervalSince1970: fetchedAt)
            )
        }
        return result
    }

    public func save(_ snapshots: [String: UsageSnapshot]) throws {
        lock.lock(); defer { lock.unlock() }
        var dict: [String: [String: Any]] = [:]
        for (account, snapshot) in snapshots {
            var raw: [String: Any] = [
                "fetchedAt": snapshot.fetchedAt.timeIntervalSince1970
            ]
            func encode(_ window: UsageWindow?) -> [String: Any]? {
                guard let window else { return nil }
                var w: [String: Any] = ["utilization": window.utilization]
                if let resetsAt = window.resetsAt {
                    w["resetsAt"] = resetsAt.timeIntervalSince1970
                }
                return w
            }
            raw["fiveHour"] = encode(snapshot.fiveHour)
            raw["sevenDay"] = encode(snapshot.sevenDay)
            raw["sevenDayOpus"] = encode(snapshot.sevenDayOpus)
            dict[account] = raw
        }
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.sortedKeys]
        )
        try SecureFileIO.writeAtomically(data, to: fileURL)
    }
}
