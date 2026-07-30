import CryptoKit
import Foundation

/// Autorización OAuth con PKCE, el mismo flujo que ejecuta `claude auth
/// login --claudeai`.
///
/// Permite dar de alta una cuenta desde la propia app: se abre el navegador
/// en la pantalla oficial de Anthropic y el usuario pega el código que esta
/// le muestra. El destino de la redirección pertenece al cliente oficial y
/// no se puede cambiar, así que el pegado del código es inevitable; lo que
/// se evita es tener que abrir una terminal y ejecutar comandos.
public struct OAuthLoginFlow: Sendable {
    /// Verificador PKCE de esta sesión de login. Nunca sale de la app: solo
    /// viaja su hash al canjear el código.
    public let verifier: String
    /// Valor opaco que liga la respuesta del navegador con esta petición.
    public let state: String

    public init() {
        self.verifier = Self.randomURLSafeString()
        self.state = Self.randomURLSafeString()
    }

    /// Inicializador para pruebas reproducibles.
    public init(verifier: String, state: String) {
        self.verifier = verifier
        self.state = state
    }

    static let authorizeEndpoint = "https://claude.com/cai/oauth/authorize"
    static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    public static let scopes = [
        "org:create_api_key",
        "user:profile",
        "user:inference",
        "user:sessions:claude_code",
        "user:mcp_servers",
        "user:file_upload"
    ]

    /// Página oficial de inicio de sesión para esta petición.
    public var authorizationURL: URL {
        var components = URLComponents(string: Self.authorizeEndpoint)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: AnthropicAPI.oauthClientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    /// Limpia lo que el usuario pega. El navegador muestra el código solo o
    /// como `código#estado`, y a veces se copia con espacios alrededor.
    /// Devuelve nil si el estado viene y no es el de esta petición: eso
    /// significa que el código pertenece a otro intento de login.
    public func normalizedCode(from pasted: String) -> String? {
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Sin `omittingEmptySubsequences: false`, un texto como «#estado»
        // dejaría el estado en la posición del código y se canjearía basura.
        let parts = trimmed.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let code = String(parts[0]).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !code.isEmpty else { return nil }
        if parts.count == 2 {
            let returnedState = String(parts[1]).trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard returnedState == state else { return nil }
        }
        return code
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomURLSafeString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }
}
