import Darwin
import Foundation

/// Averigua si hay alguna sesión de Claude Code viva en este equipo.
///
/// SwitchBar nunca rota el token de la cuenta activa mientras alguien la esté
/// usando: una terminal abierta guarda su refresh token en memoria y rotarlo
/// la dejaría fuera. Pero cuando no hay ninguna sesión viva, ese cuidado deja
/// de tener sentido y solo consigue que la cuenta activa se quede sin poder
/// actualizar su uso hasta que el usuario vuelva a abrir Claude Code.
///
/// La comprobación mira la ruta real del ejecutable de cada proceso del
/// sistema. Claude Code se instala como un binario propio bajo
/// `~/.local/share/claude/versions/…`, y los envoltorios (`~/.local/bin/claude`,
/// `ClaudeCode.app/Contents/MacOS/claude`) son enlaces que resuelven a esa
/// misma ruta, así que basta con reconocerla.
///
/// Limitación conocida: una instalación antigua vía npm corre dentro de `node`
/// y no se distingue de cualquier otro proceso de Node sin leer argumentos.
/// Se considera que cualquier Node puede usar Claude Code: es preferible
/// aplazar una renovación a invalidar una sesión viva.
public struct ClaudeCodeProcessProbe: Sendable {
    public init() {}

    /// `true` si algún proceso vivo parece ser Claude Code.
    ///
    /// Ante la duda devuelve `true`: no poder mirar la tabla de procesos no es
    /// una prueba de que no haya nadie, y equivocarse hacia el lado prudente
    /// solo cuesta unos datos de uso algo más viejos.
    public func isClaudeCodeRunning() -> Bool {
        guard let pids = livePids() else { return true }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in pids where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = String(
                decoding: buffer.prefix(Int(length)),
                as: UTF8.self
            )
            if Self.looksLikeClaudeCode(path) || Self.isAmbiguousRuntime(path) { return true }
        }
        return false
    }

    /// Reconoce la ruta del ejecutable de una sesión de Claude Code.
    ///
    /// El nombre se compara respetando mayúsculas a propósito: la app de
    /// escritorio de Anthropic es `…/Claude.app/Contents/MacOS/Claude`, no
    /// toca el Llavero de Claude Code y no debe contar como sesión viva.
    static func looksLikeClaudeCode(_ path: String) -> Bool {
        if path.contains("/.local/share/claude/") { return true }
        if path.contains("/claude/versions/") { return true }
        if path.contains("claude-code") { return true }
        return (path as NSString).lastPathComponent == "claude"
    }

    static func isAmbiguousRuntime(_ path: String) -> Bool {
        ["node", "nodejs", "bun"].contains((path as NSString).lastPathComponent)
    }

    /// Identificadores de todos los procesos del sistema, o `nil` si el núcleo
    /// no deja consultarlos.
    private func livePids() -> [pid_t]? {
        let probe = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard probe > 0 else { return nil }
        // Holgura extra: entre la medida y la lectura pueden haber arrancado
        // procesos nuevos, y un hueco justo truncaría la lista en silencio.
        var pids = [pid_t](
            repeating: 0,
            count: Int(probe) / MemoryLayout<pid_t>.size + 128
        )
        let written = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.size)
        )
        guard written > 0 else { return nil }
        return Array(pids.prefix(Int(written) / MemoryLayout<pid_t>.size))
    }
}
