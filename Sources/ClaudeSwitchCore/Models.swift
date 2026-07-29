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
        conFracciones.date(from: s) ?? sinFracciones.date(from: s)
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

    /// Interpreta la respuesta de `GET /api/oauth/usage`.
    public static func parse(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoreError.malformedJSON("respuesta de uso no es un objeto JSON")
        }
        return UsageSnapshot(
            fiveHour: UsageWindow.from(dict["five_hour"]),
            sevenDay: UsageWindow.from(dict["seven_day"]),
            sevenDayOpus: UsageWindow.from(dict["seven_day_opus"]),
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
