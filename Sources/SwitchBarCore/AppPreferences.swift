import Foundation

/// Preferencias propias de SwitchBar.
///
/// Se usa un dominio estable y explícito para que la configuración sea la
/// misma al abrir la copia instalada, otra copia firmada o una ejecución de
/// desarrollo. Depender de `UserDefaults.standard` hacía que una ejecución
/// sin el bundle definitivo pudiera leer otro dominio.
public final class AppPreferences: @unchecked Sendable {
    /// Dominio histórico (ClaudeSwitch): cambiarlo descartaría los ajustes de
    /// instalaciones previas. El nombre es invisible para el usuario.
    public static let suiteName = "com.mlopara.ClaudeSwitch"

    private enum Key {
        static let autoSwitchEnabled = "autoSwitchEnabled"
        static let triggerThreshold = "triggerThreshold"
        static let weeklyTriggerThreshold = "weeklyTriggerThreshold"
        static let fableTriggerThreshold = "fableTriggerThreshold"
        static let useFableForAutoSwitch = "useFableForAutoSwitch"
        static let anticipateExpiringQuota = "anticipateExpiringQuota"
        static let switchByPace = "switchByPace"
        static let manuallyChosenProfileID = "manuallyChosenProfileID"
        static let leftByUserUntil = "leftByUserUntilByProfile"
        static let pollIntervalSeconds = "pollIntervalSeconds"
        static let lastObservedAccountUuid = "lastObservedAccountUuid"
        static let usageRateLimitedUntilByAccount =
            "usageRateLimitedUntilByAccount"
        static let renewalBlockedAccounts = "renewalBlockedAccounts"
        static let renewalBlockedUntilByAccount =
            "renewalBlockedUntilByAccount"
        static let renewalBlockReset = "renewalBlockResetGeneration"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: Self.suiteName)
            ?? .standard
    }

    public var autoSwitchEnabled: Bool {
        get { defaults.bool(forKey: Key.autoSwitchEnabled) }
        set { defaults.set(newValue, forKey: Key.autoSwitchEnabled) }
    }

    public var triggerThreshold: Double {
        get {
            defaults.object(forKey: Key.triggerThreshold) as? Double ?? 90
        }
        set { defaults.set(newValue, forKey: Key.triggerThreshold) }
    }

    public var weeklyTriggerThreshold: Double {
        get {
            defaults.object(
                forKey: Key.weeklyTriggerThreshold
            ) as? Double ?? 95
        }
        set {
            defaults.set(newValue, forKey: Key.weeklyTriggerThreshold)
        }
    }

    public var fableTriggerThreshold: Double {
        get {
            defaults.object(
                forKey: Key.fableTriggerThreshold
            ) as? Double ?? 95
        }
        set {
            defaults.set(newValue, forKey: Key.fableTriggerThreshold)
        }
    }

    public var useFableForAutoSwitch: Bool {
        get {
            defaults.object(
                forKey: Key.useFableForAutoSwitch
            ) as? Bool ?? false
        }
        set {
            defaults.set(newValue, forKey: Key.useFableForAutoSwitch)
        }
    }

    /// Cambiar antes de llegar a un límite para gastar el cupo semanal que
    /// otra cuenta va a perder en su reinicio. Activado por omisión: solo
    /// cambia de cuenta cuando ese cupo se perdería sin remedio.
    public var anticipateExpiringQuota: Bool {
        get {
            defaults.object(
                forKey: Key.anticipateExpiringQuota
            ) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: Key.anticipateExpiringQuota)
        }
    }

    /// Usar el ritmo de uso medido: cambiar antes si la cuenta activa se va a
    /// agotar enseguida y no elegir destinos que durarían minutos. Activado
    /// por omisión; sin medidas suficientes se comporta como sin él.
    public var switchByPace: Bool {
        get { defaults.object(forKey: Key.switchByPace) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.switchByPace) }
    }

    /// Perfil que el usuario eligió a mano (clic, deshacer o `/login`). El
    /// cambio automático solo lo abandona al llegar a un límite. Se guarda en
    /// disco para que un reinicio de la app no olvide esa elección.
    public var manuallyChosenProfileID: String? {
        get { defaults.string(forKey: Key.manuallyChosenProfileID) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.manuallyChosenProfileID)
            } else {
                defaults.removeObject(forKey: Key.manuallyChosenProfileID)
            }
        }
    }

    /// Cuentas de las que el usuario salió a mano, con la fecha hasta la que
    /// el cambio automático las deja para el final (su reinicio semanal).
    public var leftByUserTimestamps: [String: TimeInterval] {
        get { timestamps(forKey: Key.leftByUserUntil) }
        set { defaults.set(newValue, forKey: Key.leftByUserUntil) }
    }

    public var pollIntervalSeconds: Double {
        get {
            defaults.object(
                forKey: Key.pollIntervalSeconds
            ) as? Double ?? 180
        }
        set { defaults.set(newValue, forKey: Key.pollIntervalSeconds) }
    }

    public var lastObservedAccountUuid: String? {
        get { defaults.string(forKey: Key.lastObservedAccountUuid) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.lastObservedAccountUuid)
            } else {
                defaults.removeObject(forKey: Key.lastObservedAccountUuid)
            }
        }
    }

    /// Cuentas cuya sesión no se ha podido renovar por un límite del servidor.
    ///
    /// Se guarda en disco porque la salida es una acción del usuario
    /// (reconectar la cuenta) y el aviso tiene que seguir ahí después de
    /// reiniciar la app; si no, el problema vuelve a parecer invisible.
    public var renewalBlockedAccounts: Set<String> {
        get {
            Set(
                defaults.array(
                    forKey: Key.renewalBlockedAccounts
                ) as? [String] ?? []
            )
        }
        set {
            defaults.set(
                Array(newValue).sorted(),
                forKey: Key.renewalBlockedAccounts
            )
        }
    }

    public var usageCooldownTimestamps: [String: TimeInterval] {
        get { timestamps(forKey: Key.usageRateLimitedUntilByAccount) }
        set {
            defaults.set(
                newValue,
                forKey: Key.usageRateLimitedUntilByAccount
            )
        }
    }

    /// Pausas del endpoint de renovación de sesiones. Se guardan aparte de las
    /// del endpoint de uso porque solo una de las dos impide leer los datos:
    /// mezclarlas dejaba la app sin uso que mostrar tras cada reinicio.
    public var renewalCooldownTimestamps: [String: TimeInterval] {
        get { timestamps(forKey: Key.renewalBlockedUntilByAccount) }
        set {
            defaults.set(
                newValue,
                forKey: Key.renewalBlockedUntilByAccount
            )
        }
    }

    /// Generación de la limpieza de bloqueos ya aplicada en este equipo.
    ///
    /// Las versiones anteriores dejaban a una cuenta dando vueltas contra el
    /// endpoint de renovación hasta acumular un castigo de medio día, y ese
    /// castigo sobrevivía a la actualización. Subir la generación en el código
    /// borra una única vez los bloqueos heredados para que la lógica corregida
    /// no arranque penalizada por los errores de la anterior.
    public var renewalBlockResetGeneration: Int {
        get { defaults.integer(forKey: Key.renewalBlockReset) }
        set { defaults.set(newValue, forKey: Key.renewalBlockReset) }
    }

    private func timestamps(forKey key: String) -> [String: TimeInterval] {
        let raw = defaults.dictionary(forKey: key) ?? [:]
        return raw.reduce(into: [:]) { result, entry in
            guard let value = entry.value as? NSNumber else { return }
            result[entry.key] = value.doubleValue
        }
    }
}
