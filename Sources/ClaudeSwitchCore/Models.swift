import Foundation

// MARK: - Errores del núcleo

public enum CoreError: Error, Equatable {
    case malformedJSON(String)
    case missingField(String)
}

// MARK: - Fechas ISO 8601 (con y sin fracciones de segundo)

enum ISO8601 {
    nonisolated(unsafe) private static let conFracciones: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let sinFracciones: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String) -> Date? {
        if let d = conFracciones.date(from: s) ?? sinFracciones.date(from: s) { return d }
        // El endpoint de uso emite microsegundos (p. ej. ".230834+00:00"),
        // que el formateador estricto no acepta: eliminar la parte fraccional.
        let sinFraccion = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return sinFracciones.date(from: sinFraccion)
    }
}

// MARK: - Ventanas de uso

public struct UsageWindow: Sendable, Equatable {
    /// Porcentaje usado, 0–100.
    public var utilization: Double
    public var resetsAt: Date?

    public init(utilization: Double, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    static func from(_ any: Any?) -> UsageWindow? {
        guard let dict = any as? [String: Any] else { return nil }
        guard let utilization = (dict["utilization"] as? NSNumber)?.doubleValue else { return nil }
        let resetsAt = (dict["resets_at"] as? String).flatMap(ISO8601.parse)
        return UsageWindow(utilization: utilization, resetsAt: resetsAt)
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    public var fiveHour: UsageWindow?
    public var sevenDay: UsageWindow?
    public var sevenDayOpus: UsageWindow?
    public var fetchedAt: Date

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, sevenDayOpus: UsageWindow?, fetchedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.fetchedAt = fetchedAt
    }

    /// Reescala las ventanas a un tope personal (cuentas compartidas): con un
    /// tope del 60 %, haber consumido el 54 % real equivale al 90 % "propio".
    /// El tope semanal se aplica también a la ventana de Fable/Opus.
    public func scaledToPersonalCaps(fiveHourCap: Double?, weeklyCap: Double?) -> UsageSnapshot {
        func scale(_ w: UsageWindow?, cap: Double?) -> UsageWindow? {
            guard let w else { return nil }
            guard let cap, cap > 0, cap < 100 else { return w }
            return UsageWindow(utilization: min(100, w.utilization / cap * 100), resetsAt: w.resetsAt)
        }
        return UsageSnapshot(
            fiveHour: scale(fiveHour, cap: fiveHourCap),
            sevenDay: scale(sevenDay, cap: weeklyCap),
            sevenDayOpus: scale(sevenDayOpus, cap: weeklyCap),
            fetchedAt: fetchedAt
        )
    }

    /// Interpreta la respuesta de `GET /api/oauth/usage`.
    ///
    /// La fuente preferida es el array `limits` (kinds `session`, `weekly_all`
    /// y `weekly_scoped` — este último es el límite semanal de Opus/Fable);
    /// si falta, se cae a las claves clásicas `five_hour`/`seven_day`/
    /// `seven_day_opus`.
    public static func parse(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoreError.malformedJSON("respuesta de uso no es un objeto JSON")
        }
        var byKind: [String: UsageWindow] = [:]
        if let limits = dict["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let kind = limit["kind"] as? String,
                      let percent = (limit["percent"] as? NSNumber)?.doubleValue else { continue }
                let resetsAt = (limit["resets_at"] as? String).flatMap(ISO8601.parse)
                let window = UsageWindow(utilization: percent, resetsAt: resetsAt)
                // Puede haber varios límites del mismo kind (p. ej. un
                // weekly_scoped por modelo): conservar el más alto, que es lo
                // conservador para la política de cambio.
                if let existing = byKind[kind], existing.utilization >= percent { continue }
                byKind[kind] = window
            }
        }
        return UsageSnapshot(
            fiveHour: byKind["session"] ?? UsageWindow.from(dict["five_hour"]),
            sevenDay: byKind["weekly_all"] ?? UsageWindow.from(dict["seven_day"]),
            sevenDayOpus: byKind["weekly_scoped"] ?? UsageWindow.from(dict["seven_day_opus"]),
            fetchedAt: fetchedAt
        )
    }
}

// MARK: - Credenciales OAuth (clave `claudeAiOauth` del Llavero)

/// Vista tipada sobre el JSON crudo de `claudeAiOauth`. El JSON completo se
/// conserva byte a byte en `rawJSON` para no perder campos desconocidos al
/// reescribirlo en el Llavero.
public struct OAuthCredentials: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// Época en milisegundos.
    public var expiresAt: Int?
    /// Época en milisegundos; caducidad del propio refresh token.
    public var refreshTokenExpiresAt: Int?
    public var subscriptionType: String?
    public var rawJSON: Data

    public init(claudeAiOauthJSON data: Data) throws {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoreError.malformedJSON("claudeAiOauth no es un objeto JSON")
        }
        guard let access = dict["accessToken"] as? String else { throw CoreError.missingField("accessToken") }
        guard let refresh = dict["refreshToken"] as? String else { throw CoreError.missingField("refreshToken") }
        self.accessToken = access
        self.refreshToken = refresh
        self.expiresAt = (dict["expiresAt"] as? NSNumber)?.intValue
        self.refreshTokenExpiresAt = (dict["refreshTokenExpiresAt"] as? NSNumber)?.intValue
        self.subscriptionType = dict["subscriptionType"] as? String
        self.rawJSON = data
    }

    /// Diccionario del objeto `claudeAiOauth` tal cual está en `rawJSON`.
    public func asDictionary() throws -> [String: Any] {
        guard let dict = try? JSONSerialization.jsonObject(with: rawJSON) as? [String: Any] else {
            throw CoreError.malformedJSON("rawJSON corrupto")
        }
        return dict
    }

    /// Devuelve una copia con los tokens renovados, preservando el resto de campos.
    public func updating(accessToken: String, refreshToken: String?, expiresAt: Int?) throws -> OAuthCredentials {
        var dict = try asDictionary()
        dict["accessToken"] = accessToken
        if let refreshToken { dict["refreshToken"] = refreshToken }
        if let expiresAt { dict["expiresAt"] = expiresAt }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return try OAuthCredentials(claudeAiOauthJSON: data)
    }

    /// Caducado (o a punto: margen de 60 s). Sin `expiresAt` se asume caducado.
    public func isAccessTokenExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return true }
        let expiry = Date(timeIntervalSince1970: Double(expiresAt) / 1000)
        return now.addingTimeInterval(60) >= expiry
    }

    /// El refresh token en sí ha caducado: la cuenta necesita login por navegador.
    /// Sin dato se asume vigente (Claude Code no siempre lo incluye).
    public func isRefreshTokenExpired(now: Date = Date()) -> Bool {
        guard let refreshTokenExpiresAt else { return false }
        return now >= Date(timeIntervalSince1970: Double(refreshTokenExpiresAt) / 1000)
    }
}

// MARK: - Identidad de cuenta (bloque `oauthAccount` de ~/.claude.json)

public struct AccountIdentity: Sendable, Equatable {
    public var accountUuid: String
    public var emailAddress: String
    public var displayName: String?
    public var rawJSON: Data

    public init(oauthAccountJSON data: Data) throws {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoreError.malformedJSON("oauthAccount no es un objeto JSON")
        }
        guard let uuid = dict["accountUuid"] as? String else { throw CoreError.missingField("accountUuid") }
        guard let email = dict["emailAddress"] as? String else { throw CoreError.missingField("emailAddress") }
        self.accountUuid = uuid
        self.emailAddress = email
        self.displayName = dict["displayName"] as? String
        self.rawJSON = data
    }

    public func asDictionary() throws -> [String: Any] {
        guard let dict = try? JSONSerialization.jsonObject(with: rawJSON) as? [String: Any] else {
            throw CoreError.malformedJSON("rawJSON corrupto")
        }
        return dict
    }
}

// MARK: - Perfil guardado

public struct AccountProfile: Codable, Identifiable, Sendable, Equatable {
    public var accountUuid: String
    public var emailAddress: String
    public var displayName: String?
    public var subscriptionType: String?
    public var needsLogin: Bool
    /// JSON crudo del bloque `oauthAccount` (no contiene secretos).
    public var identityJSON: Data
    /// Topes personales para cuentas compartidas (porcentaje 0–100 del límite
    /// real que este usuario se permite consumir); nil = cuenta no compartida.
    public var sharedFiveHourCap: Double?
    public var sharedWeeklyCap: Double?

    public var id: String { accountUuid }

    public init(identity: AccountIdentity, subscriptionType: String?, needsLogin: Bool = false) {
        self.accountUuid = identity.accountUuid
        self.emailAddress = identity.emailAddress
        self.displayName = identity.displayName
        self.subscriptionType = subscriptionType
        self.needsLogin = needsLogin
        self.identityJSON = identity.rawJSON
    }

    public func identity() throws -> AccountIdentity {
        try AccountIdentity(oauthAccountJSON: identityJSON)
    }
}
