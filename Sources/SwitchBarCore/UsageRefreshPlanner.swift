import Foundation

/// Reparte las consultas de uso a lo largo del intervalo configurado.
///
/// Consultar todas las cuentas en una ráfaga provoca que el endpoint privado
/// de uso acepte la primera y limite las siguientes. Este planificador devuelve
/// una sola cuenta por turno, comienza por la activa y recorre el resto de
/// forma circular, saltándose las que estén en período de espera.
public struct UsageRefreshPlanner: Sendable {
    public private(set) var cursor: String?

    public init(cursor: String? = nil) {
        self.cursor = cursor
    }

    public mutating func nextAccount(
        accountUuids: [String],
        activeAccountUuid: String?,
        blockedAccountUuids: Set<String>
    ) -> String? {
        var ordered: [String] = []
        if let activeAccountUuid,
           accountUuids.contains(activeAccountUuid) {
            ordered.append(activeAccountUuid)
        }
        for accountUuid in accountUuids
        where !ordered.contains(accountUuid) {
            ordered.append(accountUuid)
        }
        guard !ordered.isEmpty else { return nil }

        let start: Int
        if let cursor,
           let index = ordered.firstIndex(of: cursor) {
            start = (index + 1) % ordered.count
        } else {
            start = 0
        }

        for offset in 0..<ordered.count {
            let candidate = ordered[(start + offset) % ordered.count]
            guard !blockedAccountUuids.contains(candidate) else {
                continue
            }
            cursor = candidate
            return candidate
        }
        return nil
    }

    /// Separación entre peticiones para que todas las cuentas completen una
    /// vuelta aproximadamente dentro del intervalo elegido, nunca en ráfaga.
    public static func spacing(
        fullCycleInterval: TimeInterval,
        accountCount: Int
    ) -> TimeInterval {
        let cycle = max(60, fullCycleInterval)
        return max(30, cycle / Double(max(1, accountCount)))
    }

    public mutating func recordRefresh(of accountUuid: String) {
        cursor = accountUuid
    }

    /// Deshace el avance del turno cuando la consulta no llegó a hacerse por
    /// una causa ajena a la cuenta elegida. Sin esto, quien coincide con otra
    /// consulta pierde el turno entero y tarda una vuelta más en actualizarse.
    public mutating func rewind(to previousCursor: String?) {
        cursor = previousCursor
    }
}
