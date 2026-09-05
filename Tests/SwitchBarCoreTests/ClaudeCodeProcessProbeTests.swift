import Testing
@testable import SwitchBarCore

@Test
func elBinarioDeClaudeCodeSeReconoce() {
    // Ruta real del ejecutable: los envoltorios (`~/.local/bin/claude`,
    // `ClaudeCode.app/Contents/MacOS/claude`) resuelven todos a esta.
    #expect(
        ClaudeCodeProcessProbe.looksLikeClaudeCode(
            "/Users/alguien/.local/share/claude/versions/2.1.220"
        )
    )
    #expect(
        ClaudeCodeProcessProbe.looksLikeClaudeCode(
            "/opt/homebrew/bin/claude"
        )
    )
    #expect(
        ClaudeCodeProcessProbe.looksLikeClaudeCode(
            "/Users/alguien/node_modules/@anthropic-ai/claude-code/cli.js"
        )
    )
}

@Test
func laAppDeEscritorioNoCuentaComoSesionDeClaudeCode() {
    // Claude para escritorio no toca el Llavero de Claude Code: confundirla
    // con una terminal abierta bloquearía la renovación de la cuenta activa
    // durante todo el tiempo que la app esté abierta.
    #expect(
        !ClaudeCodeProcessProbe.looksLikeClaudeCode(
            "/Applications/Claude.app/Contents/MacOS/Claude"
        )
    )
    #expect(
        !ClaudeCodeProcessProbe.looksLikeClaudeCode(
            "/usr/bin/login"
        )
    )
    #expect(!ClaudeCodeProcessProbe.looksLikeClaudeCode("/bin/zsh"))
}
