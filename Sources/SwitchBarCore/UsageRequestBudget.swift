import Foundation

/// Cupo estimado de consultas de uso de cada cuenta.
///
/// Anthropic no documenta el límite del endpoint de uso, pero el registro de
/// SwitchBar lo deja ver: es por cuenta, admite ráfagas de unas quince
/// consultas y se recupera a razón de una cada dos minutos, más o menos.
/// Consultar la cuenta activa cada minuto lo vaciaba en media hora, y a partir
/// de ahí una de cada dos peticiones acababa en 429; las cuentas consultadas
/// cada tres minutos no recibían ninguno. Claude Code consulta el mismo
/// endpoint contra el mismo cupo, así que la estimación se queda corta a
/// propósito: es preferible un dato algo menos reciente a una pausa del
/// servidor.
public struct UsageRequestBudget: Sendable, Equatable {
    /// Consultas que se pueden encadenar tras un rato sin preguntar.
    public static let capacity: Double = 6
    /// Tiempo que tarda en recuperarse una consulta.
    public static let refillInterval: TimeInterval = 150

    private var balance: [String: Double] = [:]
    private var updatedAt: [String: Date] = [:]

    public init() {}

    public func available(_ account: String, now: Date) -> Double {
        guard let stored = balance[account], let last = updatedAt[account] else {
            return Self.capacity
        }
        let recovered = max(0, now.timeIntervalSince(last)) / Self.refillInterval
        return min(Self.capacity, stored + recovered)
    }

    public func canSpend(_ account: String, now: Date) -> Bool {
        available(account, now: now) >= 1
    }

    public mutating func spend(_ account: String, now: Date) {
        balance[account] = max(0, available(account, now: now) - 1)
        updatedAt[account] = now
    }

    /// Un 429 demuestra que el cupo real está vacío, diga lo que diga la
    /// estimación.
    public mutating func drain(_ account: String, now: Date) {
        balance[account] = 0
        updatedAt[account] = now
    }
}
