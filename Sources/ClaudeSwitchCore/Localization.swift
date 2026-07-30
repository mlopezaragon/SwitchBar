import Foundation

/// Único punto de acceso a los textos visibles de ClaudeSwitch.
///
/// La app empaquetada incluye los catálogos en su bundle principal y SwiftPM
/// los incluye también en el bundle de recursos del módulo. Así la misma
/// traducción funciona instalada, con `swift run` y en las pruebas.
public enum L10n {
    public static var locale: Locale {
        let code = activeBundle.preferredLocalizations.first
            ?? Bundle.main.preferredLocalizations.first
            ?? "es"
        return Locale(identifier: code)
    }

    public static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        let format = localizedFormat(for: key)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: arguments)
    }

    private static var activeBundle: Bundle {
        let main = Bundle.main
        if main.localizations.contains(where: { $0 == "es" || $0 == "en" }) {
            return main
        }
        return Bundle.module
    }

    private static func localizedFormat(for key: String) -> String {
        let mainValue = Bundle.main.localizedString(
            forKey: key,
            value: nil,
            table: nil
        )
        if mainValue != key { return mainValue }
        return Bundle.module.localizedString(
            forKey: key,
            value: key,
            table: nil
        )
    }
}
