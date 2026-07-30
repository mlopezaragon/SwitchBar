import Foundation

/// Convierte errores internos en texto apto para la interfaz.
///
/// La salida de herramientas del sistema puede incluir el comando completo
/// que falló. En el caso de `/usr/bin/security`, ese comando puede contener
/// credenciales codificadas en hexadecimal. La interfaz nunca debe mostrar
/// esa salida, ni siquiera si un error nuevo se propaga por accidente.
public enum UserFacingError {
    public static func describe(_ error: Error) -> String {
        guard let localized = error as? LocalizedError,
              let description = localized.errorDescription else {
            return L10n.tr("state.unexpected_error")
        }
        return sanitize(description)
    }

    public static func sanitize(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 500,
              !looksSensitive(trimmed) else {
            return L10n.tr("state.unexpected_error")
        }
        return trimmed
    }

    private static func looksSensitive(_ message: String) -> Bool {
        let patterns = [
            // Blobs que `security -X` recibe como hexadecimal.
            #"(?i)(?:^|[^0-9a-f])[0-9a-f]{64,}(?:$|[^0-9a-f])"#,
            // Cabeceras OAuth y campos de token serializados.
            #"(?i)\bbearer\s+\S+"#,
            #"(?i)(?:access|refresh|oauth)[-_a-z]*token\s*[:=]\s*[\"']?[A-Za-z0-9._~+/=-]{12,}"#
        ]
        return patterns.contains {
            message.range(of: $0, options: .regularExpression) != nil
        }
    }
}
