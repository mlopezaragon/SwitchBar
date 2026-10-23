import CryptoKit
import Foundation

// MARK: - Errores del núcleo

public enum CoreError: Error, Equatable {
    case malformedJSON(String)
    case missingField(String)
}

extension CoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedJSON(let detail):
            L10n.tr("core.error.malformed_json", detail)
        case .missingField(let field):
            L10n.tr("core.error.missing_field", field)
        }
    }
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
    /// El servidor informa de límites semanales para esta cuenta, pero no
    /// del general. Ocurre en Team, cuyo plan sí tiene límite semanal según
    /// Anthropic: no es que no exista, es que su consumo no se puede ver. La
    /// interfaz lo dice en lugar de mostrar «—», y el cambio automático no
    /// puede reaccionar a ese límite.
    public var weeklyLimitUnreported: Bool

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, sevenDayOpus: UsageWindow?, fetchedAt: Date,
                weeklyLimitUnreported: Bool = false) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.fetchedAt = fetchedAt
        self.weeklyLimitUnreported = weeklyLimitUnreported
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
            fetchedAt: fetchedAt,
            weeklyLimitUnreported: weeklyLimitUnreported
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
            throw CoreError.malformedJSON(
                L10n.tr("core.error.usage_response_object")
            )
        }
        var byKind: [String: UsageWindow] = [:]
        var reportsWeeklyLimits = false
        if let limits = dict["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let kind = limit["kind"] as? String,
                      let percent = (limit["percent"] as? NSNumber)?.doubleValue else { continue }
                if kind.hasPrefix("weekly") { reportsWeeklyLimits = true }
                let resetsAt = (limit["resets_at"] as? String).flatMap(ISO8601.parse)
                let window = UsageWindow(utilization: percent, resetsAt: resetsAt)
                // Puede haber varios límites del mismo kind (p. ej. un
                // weekly_scoped por modelo): conservar el más alto, que es lo
                // conservador para la política de cambio.
                if let existing = byKind[kind], existing.utilization >= percent { continue }
                byKind[kind] = window
            }
        }
        let sevenDay = byKind["weekly_all"] ?? UsageWindow.from(dict["seven_day"])
        return UsageSnapshot(
            fiveHour: byKind["session"] ?? UsageWindow.from(dict["five_hour"]),
            sevenDay: sevenDay,
            sevenDayOpus: byKind["weekly_scoped"] ?? UsageWindow.from(dict["seven_day_opus"]),
            fetchedAt: fetchedAt,
            // Con otro límite semanal en la lista (el de Fable), la ausencia
            // del general no es una ventana aún sin abrir: no se informa.
            weeklyLimitUnreported: sevenDay == nil && reportsWeeklyLimits
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
            throw CoreError.malformedJSON(
                L10n.tr("core.error.oauth_credentials_object")
            )
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
            throw CoreError.malformedJSON(
                L10n.tr("core.error.raw_json_corrupt")
            )
        }
        return dict
    }

    /// Devuelve una copia con los tokens renovados, preservando el resto de campos.
    ///
    /// Un refresh token rotado no hereda la caducidad del anterior: si el
    /// servidor no indica la nueva se elimina, porque conservarla marcaría
    /// como caducada una sesión que sigue viva.
    public func updating(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Int?,
        refreshTokenExpiresAt: Int? = nil
    ) throws -> OAuthCredentials {
        var dict = try asDictionary()
        dict["accessToken"] = accessToken
        if let refreshToken, refreshToken != self.refreshToken {
            dict["refreshToken"] = refreshToken
            dict.removeValue(forKey: "refreshTokenExpiresAt")
        }
        if let refreshTokenExpiresAt {
            dict["refreshTokenExpiresAt"] = refreshTokenExpiresAt
        }
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
            throw CoreError.malformedJSON(
                L10n.tr("core.error.oauth_account_object")
            )
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
            throw CoreError.malformedJSON(
                L10n.tr("core.error.raw_json_corrupt")
            )
        }
        return dict
    }
}

// MARK: - Plan de la cuenta

/// Plan de Claude al que pertenece una cuenta.
public enum AccountPlan: String, Sendable, Equatable, CaseIterable {
    case pro, max, team, enterprise

    /// Team y Enterprise son cuentas de una organización; Pro y Max, personales.
    public var isOrganization: Bool {
        self == .team || self == .enterprise
    }

    /// Nombre comercial del plan, que Anthropic no traduce.
    public var displayName: String {
        rawValue.capitalized
    }

    /// Acepta tanto `organizationType` (`claude_team`) como `subscriptionType`
    /// (`team`). Un valor desconocido no se asimila a ningún plan.
    init?(rawType: String?) {
        guard var type = rawType?.lowercased() else { return nil }
        if type.hasPrefix("claude_") {
            type = String(type.dropFirst("claude_".count))
        }
        self.init(rawValue: type)
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
    /// Huella (SHA-256) del refresh token guardado. Permite comprobar a qué
    /// perfil pertenecen unas credenciales sin volver a leer el Llavero, que
    /// es lo que dispara los diálogos de autorización del sistema.
    public var refreshTokenFingerprint: String?
    /// Topes personales para cuentas compartidas (porcentaje 0–100 del límite
    /// real que este usuario se permite consumir); nil = cuenta no compartida.
    public var sharedFiveHourCap: Double?
    public var sharedWeeklyCap: Double?

    public var id: String { accountUuid }

    /// Plan de la cuenta. La fuente es `organizationType` del bloque de
    /// identidad: en las cuentas Team el Llavero deja `subscriptionType`
    /// vacío, así que ese campo solo sirve de respaldo.
    public var plan: AccountPlan? {
        AccountPlan(rawType: identityField("organizationType"))
            ?? AccountPlan(rawType: subscriptionType)
    }

    /// Nombre de la organización. En las cuentas personales es uno genérico
    /// («…'s Organization») que no aporta nada al usuario.
    public var organizationName: String? {
        identityField("organizationName")
    }

    private func identityField(_ key: String) -> String? {
        let dict = try? JSONSerialization.jsonObject(with: identityJSON) as? [String: Any]
        guard let value = dict?[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    public init(identity: AccountIdentity, subscriptionType: String?, needsLogin: Bool = false,
                refreshTokenFingerprint: String? = nil) {
        self.accountUuid = identity.accountUuid
        self.emailAddress = identity.emailAddress
        self.displayName = identity.displayName
        self.subscriptionType = subscriptionType
        self.needsLogin = needsLogin
        self.identityJSON = identity.rawJSON
        self.refreshTokenFingerprint = refreshTokenFingerprint
    }

    /// Huella estable de un refresh token (no reversible).
    public static func fingerprint(of refreshToken: String) -> String {
        Data(SHA256.hash(data: Data(refreshToken.utf8))).map { String(format: "%02x", $0) }.joined()
    }

    public func identity() throws -> AccountIdentity {
        try AccountIdentity(oauthAccountJSON: identityJSON)
    }
}
