import Foundation
import os

/// Registro de diagnóstico de las consultas de uso.
///
/// Cuando una cuenta deja de actualizarse, el panel solo puede decir que sus
/// datos son viejos; el motivo (una pausa del servidor, un token que no se
/// renueva, un código HTTP inesperado) se pierde. Aquí queda anotado en el
/// registro unificado del sistema, visible con:
///
///     log stream --predicate 'subsystem == "com.mlopara.ClaudeSwitch"'
///
/// El resultado de cada consulta queda anotado siempre; el reparto de turnos,
/// mucho más ruidoso, solo aparece añadiendo `--debug` a ese comando.
///
/// No se registran secretos ni correos: solo el principio del identificador
/// de la cuenta, que basta para seguir el rastro de una en concreto.
public enum Diagnostics {
    public static let usage = Logger(
        subsystem: "com.mlopara.ClaudeSwitch",
        category: "usage"
    )

    /// Identificador corto y no reversible a un correo, apto para el registro.
    /// Con organización añade su principio: la misma cuenta puede estar en
    /// una personal y en la de un equipo.
    public static func tag(_ profileID: String) -> String {
        let parts = profileID.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return String(profileID.prefix(8)) }
        return "\(parts[0].prefix(8))/\(parts[1].prefix(4))"
    }
}
