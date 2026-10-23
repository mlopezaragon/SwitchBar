import Foundation

/// Un lote de restablecimientos de límite que Anthropic concede a una cuenta.
/// Cada restablecimiento devuelve a cero una ventana (la de 5 horas, la semana
/// o ambas) antes de su reinicio.
public struct LimitResetGrant: Sendable, Equatable {
    /// Qué ventana devuelve a cero.
    public enum Kind: String, Sendable, Equatable {
        /// La ventana de 5 horas.
        case session
        /// La semana.
        case weekly
        /// La ventana de 5 horas y la semana.
        case full
    }

    public var id: String
    /// Nombre que le da el servidor, en inglés. Solo se muestra si el tipo
    /// es uno que la app aún no conoce.
    public var label: String
    public var kind: Kind?
    public var resetsLeft: Int
    public var resetsTotal: Int
    /// Hasta cuándo se pueden usar; `nil` si el servidor no lo dice.
    public var endsAt: Date?
    /// Se puede gastar ahora mismo.
    public var usableNow: Bool
    /// Solo se puede gastar con la cuenta en un límite.
    public var useRequiresLimit: Bool
    public var paused: Bool

    public init(
        id: String,
        label: String = "",
        kind: Kind?,
        resetsLeft: Int,
        resetsTotal: Int,
        endsAt: Date? = nil,
        usableNow: Bool = false,
        useRequiresLimit: Bool = true,
        paused: Bool = false
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.resetsLeft = resetsLeft
        self.resetsTotal = resetsTotal
        self.endsAt = endsAt
        self.usableNow = usableNow
        self.useRequiresLimit = useRequiresLimit
        self.paused = paused
    }

    /// Ya no sirve: pasó su fecha límite.
    public func isExpired(now: Date) -> Bool {
        endsAt.map { $0 <= now } ?? false
    }
}

/// Restablecimientos de límite de una cuenta.
///
/// Llegan en el bloque `cedar_ember` de `GET /api/oauth/usage` al pedirlo con
/// `cedar_ember=1`, el mismo que lee el comando `/limit-reset` de Claude Code.
/// Anthropic no lo documenta: cualquier campo puede faltar o cambiar, así que
/// los lotes ilegibles se descartan y un bloque ilegible no estropea el resto
/// del uso.
public struct LimitResets: Sendable, Equatable {
    public var eligible: Bool
    public var grants: [LimitResetGrant]

    public init(eligible: Bool, grants: [LimitResetGrant]) {
        self.eligible = eligible
        self.grants = grants
    }

    /// Lotes que aún no han caducado.
    public func current(now: Date = Date()) -> [LimitResetGrant] {
        grants.filter { !$0.isExpired(now: now) }
    }

    public func resetsLeft(now: Date = Date()) -> Int {
        current(now: now).reduce(0) { $0 + $1.resetsLeft }
    }

    public func resetsTotal(now: Date = Date()) -> Int {
        current(now: now).reduce(0) { $0 + $1.resetsTotal }
    }

    /// Primera fecha límite entre los lotes a los que aún les quedan.
    public func nextExpiry(now: Date = Date()) -> Date? {
        current(now: now)
            .filter { $0.resetsLeft > 0 }
            .compactMap(\.endsAt)
            .min()
    }

    static func parse(_ any: Any?) -> LimitResets? {
        guard let dict = any as? [String: Any] else { return nil }
        let grants = (dict["grants"] as? [Any] ?? []).compactMap(grant)
        return LimitResets(
            eligible: dict["eligible"] as? Bool ?? false,
            grants: grants
        )
    }

    private static func grant(_ any: Any) -> LimitResetGrant? {
        guard let dict = any as? [String: Any],
              let id = dict["id"] as? String,
              let left = (dict["resets_left"] as? NSNumber)?.intValue,
              left >= 0 else { return nil }
        let total = (dict["resets_total"] as? NSNumber)?.intValue ?? left
        return LimitResetGrant(
            id: id,
            label: dict["label"] as? String ?? "",
            kind: (dict["type"] as? String).flatMap(LimitResetGrant.Kind.init),
            resetsLeft: left,
            resetsTotal: max(total, left),
            endsAt: (dict["ends_at"] as? String).flatMap(ISO8601.parse),
            usableNow: dict["usable_now"] as? Bool ?? false,
            useRequiresLimit: dict["use_requires_limit"] as? Bool ?? true,
            paused: dict["paused"] as? Bool ?? false
        )
    }
}
