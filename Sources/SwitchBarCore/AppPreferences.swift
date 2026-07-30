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
        static let pollIntervalSeconds = "pollIntervalSeconds"
        static let lastObservedAccountUuid = "lastObservedAccountUuid"
        static let usageRateLimitedUntilByAccount =
            "usageRateLimitedUntilByAccount"
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

    public var usageCooldownTimestamps: [String: TimeInterval] {
        get {
            let raw = defaults.dictionary(
                forKey: Key.usageRateLimitedUntilByAccount
            ) ?? [:]
            return raw.reduce(into: [:]) { result, entry in
                guard let value = entry.value as? NSNumber else { return }
                result[entry.key] = value.doubleValue
            }
        }
        set {
            defaults.set(
                newValue,
                forKey: Key.usageRateLimitedUntilByAccount
            )
        }
    }
}
