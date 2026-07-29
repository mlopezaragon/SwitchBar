# Plan de implementación de ClaudeSwitch

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App nativa de barra de menús (macOS 26) que muestra el uso de 3 cuentas de Claude Code y cambia la cuenta activa manual o automáticamente.

**Architecture:** SwiftPM con dos targets (ClaudeSwitchCore librería testeable + ClaudeSwitch ejecutable SwiftUI), patrón de construcción de la app Eco (build-app.sh + Makefile). Secretos solo en el Llavero; estado observable con @Observable; sondeo del endpoint OAuth de uso cada 180 s.

**Tech Stack:** Swift 6 (modo lenguaje 5 si hace falta por concurrencia), SwiftUI MenuBarExtra, Security.framework, UserNotifications, ServiceManagement.

## Global Constraints

- macOS 26 (Tahoe) como plataforma mínima; API `glassEffect` disponible.
- Todos los textos visibles en español correcto (tildes, eñes); sin emojis.
- Secretos jamás en ficheros de texto plano; solo Llavero.
- Al escribir en `Claude Code-credentials` se reemplaza **solo** la clave `claudeAiOauth`; el resto del JSON (p. ej. `mcpOAuth.*`) se preserva intacto.
- Cabeceras del endpoint de uso: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: claude-code/2.0.0`, `Content-Type: application/json`.
- Sondeo mínimo 180 s por cuenta; retroceso exponencial ante 429.

---

### Task 1: Andamiaje del proyecto

**Files:**
- Create: `Package.swift`, `Makefile`, `scripts/build-app.sh`, `Resources/Info.plist`, `.gitignore`
- Create: `Sources/ClaudeSwitchCore/Placeholder.swift`, `Sources/ClaudeSwitch/ClaudeSwitchApp.swift` (MenuBarExtra mínimo), `Tests/ClaudeSwitchCoreTests/SmokeTests.swift`

**Interfaces:**
- Produces: proyecto que compila con `swift build` y pasa `swift test`; `make app` genera `ClaudeSwitch.app` con `LSUIElement=true`, identificador `com.mlopara.ClaudeSwitch`.

- [ ] Package.swift con targets ClaudeSwitchCore (lib), ClaudeSwitch (exec, depende de Core), ClaudeSwitchCoreTests.
- [ ] Info.plist: CFBundleIdentifier com.mlopara.ClaudeSwitch, LSUIElement true, CFBundleName ClaudeSwitch, NSHumanReadableCopyright.
- [ ] build-app.sh y Makefile calcados del patrón Eco (identidad "ClaudeSwitch Self-Signed" con caída a ad-hoc).
- [ ] `swift build` y `swift test` en verde. Commit.

### Task 2: Modelos y parsing del JSON de uso

**Files:**
- Create: `Sources/ClaudeSwitchCore/Models.swift`
- Test: `Tests/ClaudeSwitchCoreTests/UsageParsingTests.swift`

**Interfaces:**
- Produces:
  - `struct UsageWindow: Codable, Sendable { var utilization: Double; var resetsAt: Date? }`
  - `struct UsageSnapshot: Codable, Sendable { var fiveHour: UsageWindow?; var sevenDay: UsageWindow?; var sevenDayOpus: UsageWindow?; var fetchedAt: Date }` con `static func parse(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot` (claves snake_case: five_hour, seven_day, seven_day_opus; resets_at ISO8601 con fracciones opcionales).
  - `struct OAuthCredentials: Codable, Sendable` (accessToken, refreshToken, expiresAt ms, refreshTokenExpiresAt?, scopes [String], subscriptionType?, rateLimitTier?) con `var isAccessTokenExpired: Bool` (margen 60 s).
  - `struct AccountIdentity: Codable, Sendable` — espejo del bloque `oauthAccount` de `~/.claude.json` (accountUuid, emailAddress, displayName?, organizationUuid?, resto se preserva como JSON crudo).
  - `struct AccountProfile: Codable, Identifiable, Sendable { var id: String {accountUuid}; identidad + estado (needsLogin: Bool) }`

- [ ] Test con JSON real del endpoint (incluye seven_day_opus null y no null, resets_at con y sin fracciones) → parse correcto.
- [ ] Test de `isAccessTokenExpired`.
- [ ] Implementación mínima; tests en verde; commit.

### Task 3: KeychainService y ClaudeCodeStore

**Files:**
- Create: `Sources/ClaudeSwitchCore/KeychainService.swift`, `Sources/ClaudeSwitchCore/ClaudeCodeStore.swift`
- Test: `Tests/ClaudeSwitchCoreTests/ClaudeCodeStoreTests.swift`

**Interfaces:**
- Produces:
  - `protocol KeychainStoring { func readString(service: String) throws -> String?; func writeString(_ value: String, service: String) throws; func delete(service: String) throws }` + `final class KeychainService: KeychainStoring` (SecItem genp, cuenta = NSUserName()). Para `Claude Code-credentials` la búsqueda es solo por servicio.
  - `struct ClaudeCodeStore` con init inyectable `(keychain: KeychainStoring, claudeJsonURL: URL)`:
    - `func readActiveCredentials() throws -> OAuthCredentials?` (parsea la clave `claudeAiOauth` del JSON del Llavero)
    - `func writeActiveCredentials(_ c: OAuthCredentials) throws` — relee el JSON del Llavero, reemplaza solo `claudeAiOauth` (como diccionario genérico) y reescribe. Si no existe la entrada, crea `{"claudeAiOauth": ...}`.
    - `func readActiveIdentity() throws -> AccountIdentity?` / `func writeActiveIdentity(_ i: AccountIdentity) throws` — sobre `oauthAccount` de `~/.claude.json`, preservando el resto del fichero (leer como `[String: Any]` con JSONSerialization, sustituir esa clave, reescribir).

- [ ] Test (con keychain falso en memoria y claude.json temporal): escribir credenciales preserva claves `mcpOAuth.*` byte a byte en contenido (comparar diccionarios).
- [ ] Test: writeActiveIdentity preserva las demás claves de claude.json (p. ej. `projects`, `history`).
- [ ] Implementación; tests en verde; commit.

### Task 4: ProfileStore

**Files:**
- Create: `Sources/ClaudeSwitchCore/ProfileStore.swift`
- Test: `Tests/ClaudeSwitchCoreTests/ProfileStoreTests.swift`

**Interfaces:**
- Produces: `final class ProfileStore` con init `(keychain: KeychainStoring, directoryURL: URL)`:
  - `func loadProfiles() -> [AccountProfile]` / `func saveProfile(identity: AccountIdentity, credentials: OAuthCredentials) throws` (metadatos en `profiles.json`, secretos en servicio `ClaudeSwitch-profile-<accountUuid>`)
  - `func credentials(for accountUuid: String) throws -> OAuthCredentials?`
  - `func updateCredentials(_ c: OAuthCredentials, for accountUuid: String) throws`
  - `func markNeedsLogin(_ accountUuid: String, _ flag: Bool)`
  - `func removeProfile(_ accountUuid: String) throws`

- [ ] Tests de ida y vuelta con keychain falso y directorio temporal; commit.

### Task 5: TokenRefresher y UsageClient

**Files:**
- Create: `Sources/ClaudeSwitchCore/AnthropicAPI.swift`
- Test: `Tests/ClaudeSwitchCoreTests/AnthropicAPITests.swift` (parsing de respuestas; sin red real)

**Interfaces:**
- Produces:
  - `struct TokenRefreshResponse: Codable` (access_token, refresh_token?, expires_in)
  - `final class AnthropicAPI` con init `(session: URLSession = .shared)`:
    - `func refresh(_ creds: OAuthCredentials) async throws -> OAuthCredentials` — POST `https://console.anthropic.com/v1/oauth/token` body JSON `{grant_type: "refresh_token", refresh_token, client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e"}`; ante 4xx/error de red intenta `https://platform.claude.com/v1/oauth/token`; si ambos fallan con 400/401 lanza `AnthropicAPIError.refreshTokenInvalid`.
    - `func fetchUsage(accessToken: String) async throws -> UsageSnapshot` — GET endpoint de uso con las cabeceras de Global Constraints; 429 → `AnthropicAPIError.rateLimited`.

- [ ] Tests de decodificación de TokenRefreshResponse y de mapeo de errores; commit.

### Task 6: SwitchEngine

**Files:**
- Create: `Sources/ClaudeSwitchCore/SwitchEngine.swift`
- Test: `Tests/ClaudeSwitchCoreTests/SwitchEngineTests.swift`

**Interfaces:**
- Consumes: ClaudeCodeStore, ProfileStore.
- Produces: `final class SwitchEngine` init `(store: ClaudeCodeStore, profiles: ProfileStore)`:
  - `func activeAccountUuid() -> String?` (de la identidad activa)
  - `@discardableResult func switchTo(_ accountUuid: String) throws -> AccountIdentity` — 1) vuelca credenciales+identidad activas a su perfil si existe (o error `unknownActiveAccount` si la activa no tiene perfil: se ignora y continúa), 2) escribe credenciales+identidad del perfil destino, 3) guarda `lastSwitch = (from, to)` en UserDefaults para deshacer.
  - `func captureActiveAsProfile() throws -> AccountProfile` (alta de cuentas)
  - `func undoLastSwitch() throws -> AccountIdentity?`

- [ ] Tests con dobles: cambio conserva tokens renovados del perfil origen; deshacer vuelve a la cuenta anterior; captura crea perfil. Commit.

### Task 7: AutoSwitchPolicy

**Files:**
- Create: `Sources/ClaudeSwitchCore/AutoSwitchPolicy.swift`
- Test: `Tests/ClaudeSwitchCoreTests/AutoSwitchPolicyTests.swift`

**Interfaces:**
- Produces:
  - `struct AccountUsageState { var accountUuid: String; var usage: UsageSnapshot?; var needsLogin: Bool }`
  - `struct AutoSwitchPolicy { var triggerThreshold: Double = 90; var weeklyCeiling: Double = 95;`
    `func shouldSwitch(active: AccountUsageState) -> Bool;`
    `func bestCandidate(active: AccountUsageState, others: [AccountUsageState]) -> String?` — descarta needsLogin, sin datos, seven_day ≥ ceiling, seven_day_opus ≥ ceiling; ordena por menor five_hour, desempate por mayor margen ponderado 0,6·(100−seven_day) + 0,4·(100−seven_day_opus, o 100 si null); devuelve nil si nadie mejora a la activa o no hay candidatas. `}`

- [ ] Tests de todas las ramas (sin candidatas, empates, opus null, activa por debajo del umbral). Commit.

### Task 8: AppState y UsagePoller (integración observable)

**Files:**
- Create: `Sources/ClaudeSwitch/AppState.swift`

**Interfaces:**
- Consumes: todo lo anterior.
- Produces: `@MainActor @Observable final class AppState`:
  - propiedades: `profiles: [AccountProfile]`, `usageByAccount: [String: UsageSnapshot]`, `activeAccountUuid: String?`, `autoSwitchEnabled` (persistida), `triggerThreshold` (persistida), `lastError: String?`, `canUndo: Bool`, `activeUnsaved: AccountIdentity?` (cuenta activa sin perfil → botón "Guardar esta cuenta").
  - métodos: `func refreshAll() async` (refresca tokens caducados vía AnthropicAPI + ProfileStore.updateCredentials; consulta uso de todas; si autoSwitch y política lo dicta → ejecuta cambio y notifica), `func switchTo(_ uuid: String)`, `func captureActive()`, `func undo()`.
  - Temporizador cada 180 s + al abrir el panel (con mínimo 30 s entre rondas).

- [ ] Compila; integración manual ligera. Commit.

### Task 9: UI — panel de barra de menús

**Files:**
- Create: `Sources/ClaudeSwitch/MenuPanelView.swift`, `Sources/ClaudeSwitch/AccountCardView.swift`, `Sources/ClaudeSwitch/UsageBar.swift`, modify `ClaudeSwitchApp.swift`

**Interfaces:**
- Consumes: AppState.
- Produces: MenuBarExtra (.window) con icono plantilla (anillo según uso 5 h activo, dibujado con Canvas/Image renderer). Panel ~360 pt: cabecera pequeña, 3 tarjetas (AccountCardView: punto estado, email, insignia "Activa", 3 UsageBar finas con porcentaje y reseteo relativo), pie con interruptor "Cambio automático", "Deshacer", "Abrir detalle", "Salir". Materiales glass, tipografía SF, números tabulares.

- [ ] Compila y `make app && open` muestra el panel correcto. Commit.

### Task 10: UI — ventana de detalle y ajustes

**Files:**
- Create: `Sources/ClaudeSwitch/DetailWindow.swift`, `Sources/ClaudeSwitch/SettingsView.swift`, `Sources/ClaudeSwitch/UsageRing.swift`

**Interfaces:**
- Produces: `Window` con anillos grandes por cuenta (5 h, semanal, Fable/Opus), fechas de reseteo absolutas y relativas, y ajustes: umbral (slider 50–99), modo automático, intervalo, arranque al iniciar sesión (SMAppService.mainApp), gestión de perfiles (eliminar/recapturar).

- [ ] Compila y se ve correcta; commit.

### Task 11: Notificaciones y pulido

**Files:**
- Create: `Sources/ClaudeSwitch/Notifier.swift`; modify `AppState.swift`

- [ ] UNUserNotificationCenter: permiso al arrancar; notificación al cambio automático ("Cambiado a <email> — 5 h al N %") y al quedar todas agotadas.
- [ ] Aviso tras cambio manual en el propio panel: "Las sesiones abiertas siguen con la cuenta anterior hasta reiniciarlas".
- [ ] Commit.

### Task 12: Construcción final y prueba manual guiada

- [ ] `swift test` completo en verde; `make app`; arrancar; capturar la cuenta activa real como primer perfil; verificar uso real de esa cuenta contra `/usage` de Claude Code.
- [ ] Revisión de código por subagente (code-reviewer, modelo opus) y corrección de hallazgos.
- [ ] Commit final y resumen al usuario con instrucciones de alta de las otras 2 cuentas.
