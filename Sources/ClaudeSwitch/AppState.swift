import SwiftUI
import ClaudeSwitchCore

/// Estado observable de la app: perfiles, uso por cuenta, cuenta activa,
/// ajustes y acciones (cambiar, capturar, deshacer, refrescar).
@MainActor
@Observable
final class AppState {
    /// Instancia única: el delegado de la app y la ventana de detalle
    /// (gestionada con AppKit) necesitan el mismo estado que el panel.
    static let shared = AppState()

    private let store: ClaudeCodeStore
    private let profiles: ProfileStore
    private let engine: SwitchEngine
    private let api: AnthropicAPI

    // MARK: Estado observable

    private(set) var profilesList: [AccountProfile] = []
    private(set) var usageByAccount: [String: UsageSnapshot] = [:]
    private(set) var activeAccountUuid: String?
    /// Cuenta activa en Claude Code que aún no tiene perfil guardado.
    private(set) var activeUnsaved: AccountIdentity?
    private(set) var lastError: String?
    /// Aviso informativo tras un cambio (sesiones abiertas, etc.).
    private(set) var infoMessage: String?
    private(set) var canUndo = false
    private(set) var isRefreshing = false
    private(set) var lastRefreshAt: Date?

    // MARK: Ajustes persistidos

    var autoSwitchEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSwitchEnabled, forKey: "autoSwitchEnabled") }
    }
    var triggerThreshold: Double {
        didSet { UserDefaults.standard.set(triggerThreshold, forKey: "triggerThreshold") }
    }
    var pollIntervalSeconds: Double {
        didSet { UserDefaults.standard.set(pollIntervalSeconds, forKey: "pollIntervalSeconds") }
    }

    private var pollTask: Task<Void, Never>?
    private var identityWatchTask: Task<Void, Never>?
    private var rateLimitedUntil: Date?
    /// Última cuenta que activó ClaudeSwitch. Sirve para distinguir un cambio
    /// hecho por la app de un `/login` manual del usuario en la terminal.
    private var lastSwitchByApp: String?
    /// Credenciales de la cuenta activa cacheadas para no releer el Llavero
    /// (cada lectura puede abrir un diálogo de autorización del sistema).
    private var cachedActiveCredentials: (uuid: String, credentials: OAuthCredentials)?
    /// Hay que volcar la sesión activa a su perfil en el próximo refresco
    /// (se marca al detectar un cambio de cuenta, no en cada ronda).
    private var pendingSyncOfActive = true
    /// Instante del último login manual detectado. El cambio automático se
    /// mantiene en pausa un rato después para no pisar la elección del usuario.
    private(set) var manualLoginAt: Date?
    private let manualLoginGracePeriod: TimeInterval = 15 * 60

    // MARK: Ciclo de vida

    init(store: ClaudeCodeStore = ClaudeCodeStore(),
         profiles: ProfileStore = ProfileStore(),
         api: AnthropicAPI = AnthropicAPI()) {
        self.store = store
        self.profiles = profiles
        self.engine = SwitchEngine(store: store, profiles: profiles)
        self.api = api
        let d = UserDefaults.standard
        self.autoSwitchEnabled = d.bool(forKey: "autoSwitchEnabled")
        self.triggerThreshold = d.object(forKey: "triggerThreshold") as? Double ?? 90
        self.pollIntervalSeconds = d.object(forKey: "pollIntervalSeconds") as? Double ?? 180
        // El estado local se carga fuera del hilo principal: leer el Llavero
        // puede quedarse esperando un diálogo de autorización del sistema y
        // congelaría toda la interfaz.
        Task { await reloadLocalState() }
        startPolling()
        startIdentityWatcher()
    }

    /// Vigila `~/.claude.json` cada pocos segundos (solo lectura de fichero,
    /// sin tocar el Llavero) para reflejar al instante un `/login` hecho por
    /// el usuario en la terminal.
    private func startIdentityWatcher() {
        identityWatchTask?.cancel()
        let store = self.store
        identityWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                let uuid = await self.offMain { (try? store.readActiveIdentity())?.accountUuid }
                guard let uuid, uuid != self.activeAccountUuid else { continue }
                // Cambió la cuenta activa. Si no fue la app, es un login manual.
                if uuid != self.lastSwitchByApp {
                    self.manualLoginAt = Date()
                    self.infoMessage = nil
                }
                self.cachedActiveCredentials = nil
                self.pendingSyncOfActive = true
                await self.reloadLocalState()
                await self.refreshAll()
            }
        }
    }

    /// El cambio automático está en pausa tras un login manual reciente.
    var autoSwitchPausedByManualLogin: Bool {
        guard let manualLoginAt else { return false }
        return Date().timeIntervalSince(manualLoginAt) < manualLoginGracePeriod
    }

    /// Ejecuta trabajo que toca Llavero o disco fuera del hilo principal.
    private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                let interval = self?.pollIntervalSeconds ?? 180
                try? await Task.sleep(for: .seconds(max(60, interval)))
            }
        }
    }

    /// Refresco al abrir el panel, con un mínimo de 30 s entre rondas.
    func refreshIfStale() {
        Task {
            await reloadLocalState()
            if let last = lastRefreshAt, Date().timeIntervalSince(last) < 30 { return }
            await refreshAll()
        }
    }

    // MARK: Estado local (sin red)

    private struct LocalSnapshot: Sendable {
        var profiles: [AccountProfile]
        var activeAccountUuid: String?
        var canUndo: Bool
        var activeUnsaved: AccountIdentity?
    }

    private func reloadLocalState() async {
        let store = self.store
        let profiles = self.profiles
        let engine = self.engine
        let snapshot = await offMain { () -> LocalSnapshot in
            let list = profiles.loadProfiles()
            let identity = try? store.readActiveIdentity()
            let unsaved = identity.flatMap { id in
                list.contains { $0.accountUuid == id.accountUuid } ? nil : id
            }
            return LocalSnapshot(
                profiles: list,
                activeAccountUuid: identity?.accountUuid ?? engine.activeAccountUuid(),
                canUndo: engine.canUndo,
                activeUnsaved: unsaved
            )
        }
        profilesList = snapshot.profiles
        activeAccountUuid = snapshot.activeAccountUuid
        canUndo = snapshot.canUndo
        activeUnsaved = snapshot.activeUnsaved
    }

    // MARK: Refresco de red

    func refreshAll() async {
        if isRefreshing { return }
        if let until = rateLimitedUntil, Date() < until { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshAt = Date()
        }
        lastError = nil
        await reloadLocalState()
        // El volcado de la sesión activa a su perfil lee el Llavero de Claude
        // Code, así que solo se hace cuando la cuenta activa ha cambiado (o
        // tras un cambio propio), no en cada ronda de refresco.
        if pendingSyncOfActive {
            pendingSyncOfActive = false
            let engine = self.engine
            _ = await offMain { try? engine.syncActiveIntoProfile() }
            await reloadLocalState()
        }

        for profile in profilesList where !profile.needsLogin {
            await refreshUsage(for: profile)
        }
        await reloadLocalState()
        await runAutoSwitchIfNeeded()
    }

    private func refreshUsage(for profile: AccountProfile) async {
        let isActive = profile.accountUuid == activeAccountUuid
        do {
            guard var creds = try await credentialsPreferringActive(for: profile.accountUuid) else {
                profiles.markNeedsLogin(profile.accountUuid, true)
                return
            }
            if creds.isRefreshTokenExpired() {
                profiles.markNeedsLogin(profile.accountUuid, true)
                return
            }
            if creds.isAccessTokenExpired() {
                // La cuenta activa la renueva Claude Code: renovarla aquí
                // competiría por rotar el mismo refresh token y podría
                // desconectar la CLI. Se muestra el último dato conocido.
                guard !isActive else { return }
                creds = try await refreshCredentials(creds, for: profile.accountUuid)
            }
            do {
                usageByAccount[profile.accountUuid] = try await api.fetchUsage(accessToken: creds.accessToken)
            } catch AnthropicAPIError.httpError(401) {
                guard !isActive else { return }
                // Token rechazado pese a no constar caducado: renovar y reintentar una vez.
                creds = try await refreshCredentials(creds, for: profile.accountUuid)
                usageByAccount[profile.accountUuid] = try await api.fetchUsage(accessToken: creds.accessToken)
            }
        } catch AnthropicAPIError.refreshTokenInvalid {
            profiles.markNeedsLogin(profile.accountUuid, true)
        } catch AnthropicAPIError.rateLimited {
            rateLimitedUntil = Date().addingTimeInterval(600)
            lastError = "Límite de peticiones alcanzado; se reintentará en unos minutos"
        } catch {
            lastError = "No se pudo consultar el uso (¿sin conexión?)"
        }
    }

    /// Para la cuenta activa, la fuente de verdad es el Llavero de Claude Code
    /// (la CLI renueva tokens por su cuenta); para el resto, el perfil.
    ///
    /// La entrada "Claude Code-credentials" la creó Claude Code, así que cada
    /// lectura puede provocar un diálogo de autorización del Llavero. Por eso
    /// se cachea en memoria y solo se relee cuando cambia la cuenta activa o
    /// cuando el token cacheado caduca (que es cuando la CLI lo habrá
    /// renovado): de decenas de lecturas por hora se pasa a una.
    private func credentialsPreferringActive(for accountUuid: String) async throws -> OAuthCredentials? {
        let store = self.store
        let profiles = self.profiles
        if accountUuid == activeAccountUuid {
            if let cached = cachedActiveCredentials,
               cached.uuid == accountUuid,
               !cached.credentials.isAccessTokenExpired() {
                return cached.credentials
            }
            let result: Result<OAuthCredentials?, Error> = await offMain {
                Result { try store.readActiveCredentials() }
            }
            if let active = try result.get() {
                cachedActiveCredentials = (accountUuid, active)
                return active
            }
        }
        return try await offMain { Result { try profiles.credentials(for: accountUuid) } }.get()
    }

    /// Renueva y persiste en el perfil. Solo para cuentas NO activas: la
    /// renovación rota el refresh token, y perder el nuevo sería fatal, así
    /// que la persistencia se reintenta antes de rendirse.
    private func refreshCredentials(_ creds: OAuthCredentials, for accountUuid: String) async throws -> OAuthCredentials {
        let renewed = try await api.refresh(creds)
        let profiles = self.profiles
        var persisted = await offMain { (try? profiles.updateCredentials(renewed, for: accountUuid)) != nil }
        if !persisted {
            try? await Task.sleep(for: .milliseconds(300))
            persisted = await offMain { (try? profiles.updateCredentials(renewed, for: accountUuid)) != nil }
        }
        guard persisted else { throw KeychainError.notUTF8 }
        _ = await offMain { profiles.markNeedsLogin(accountUuid, false) }
        return renewed
    }

    // MARK: Cambio automático

    /// Instantánea válida para tomar decisiones: descarta datos más viejos de
    /// dos intervalos de sondeo y ventanas cuyo reseteo ya pasó (su porcentaje
    /// ya no refleja la realidad).
    private func freshUsage(for accountUuid: String) -> UsageSnapshot? {
        guard var snapshot = usageByAccount[accountUuid] else { return nil }
        let maxAge = max(2 * pollIntervalSeconds, 600)
        guard Date().timeIntervalSince(snapshot.fetchedAt) < maxAge else { return nil }
        let now = Date()
        func vigente(_ w: UsageWindow?) -> UsageWindow? {
            guard let w else { return nil }
            if let reset = w.resetsAt, reset <= now { return nil }
            return w
        }
        snapshot.fiveHour = vigente(snapshot.fiveHour)
        snapshot.sevenDay = vigente(snapshot.sevenDay)
        snapshot.sevenDayOpus = vigente(snapshot.sevenDayOpus)
        return snapshot
    }

    private func runAutoSwitchIfNeeded() async {
        guard autoSwitchEnabled, let active = activeAccountUuid else { return }
        // Un login manual reciente manda: no se le cambia la cuenta al usuario
        // justo después de que la haya elegido a mano en la terminal.
        guard !autoSwitchPausedByManualLogin else { return }
        // Para la política, el uso de las cuentas compartidas se reescala a su
        // tope personal: así el cambio salta antes y deja margen a la otra persona.
        let states = profilesList.map { profile in
            AccountUsageState(
                accountUuid: profile.accountUuid,
                usage: freshUsage(for: profile.accountUuid)?
                    .scaledToPersonalCaps(fiveHourCap: profile.sharedFiveHourCap, weeklyCap: profile.sharedWeeklyCap),
                needsLogin: profile.needsLogin
            )
        }
        guard let activeState = states.first(where: { $0.accountUuid == active }) else { return }
        let policy = AutoSwitchPolicy(triggerThreshold: triggerThreshold)
        guard let target = policy.decision(active: activeState, all: states) else {
            if policy.shouldSwitch(active: activeState) {
                Notifier.notify(
                    title: "Sin cuentas con margen",
                    body: "Todas las cuentas están cerca de sus límites. \(nextResetText(states: states))"
                )
            }
            return
        }
        let engine = self.engine
        let result: Result<AccountIdentity, Error> = await offMain {
            Result { try engine.switchTo(target) }
        }
        switch result {
        case .success(let identity):
            lastSwitchByApp = target
            cachedActiveCredentials = nil
            await reloadLocalState()
            let pct = usageByAccount[target]?.fiveHour.map { Int($0.utilization) } ?? 0
            Notifier.notify(
                title: "Cambiado a \(identity.emailAddress)",
                body: "Ventana de 5 h al \(pct) %. Las sesiones abiertas siguen con la cuenta anterior."
            )
        case .failure(let error):
            lastError = "El cambio automático falló: \(describe(error))"
        }
    }

    private func nextResetText(states: [AccountUsageState]) -> String {
        let resets = states.compactMap { $0.usage?.fiveHour?.resetsAt }.sorted()
        guard let next = resets.first else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "es_ES")
        return "El primer reseteo llega \(f.localizedString(for: next, relativeTo: Date()))."
    }

    // MARK: Acciones del usuario

    func switchTo(_ accountUuid: String) {
        let engine = self.engine
        Task {
            let result: Result<AccountIdentity, Error> = await offMain {
                Result { try engine.switchTo(accountUuid) }
            }
            if case .success = result {
                lastSwitchByApp = accountUuid
                cachedActiveCredentials = nil
                pendingSyncOfActive = true
            }
            await reloadLocalState()
            switch result {
            case .success(let identity):
                infoMessage = "Ahora \(identity.emailAddress) es la cuenta activa. Las sesiones de Claude Code abiertas siguen con la anterior hasta reiniciarlas."
            case .failure(SwitchError.profileNeedsLogin):
                lastError = "Esa cuenta necesita iniciar sesión de nuevo: añádela otra vez con «Añadir cuenta»"
            case .failure(let error):
                lastError = "No se pudo cambiar de cuenta: \(describe(error))"
            }
        }
    }

    func captureActive() {
        let engine = self.engine
        Task {
            let result: Result<AccountProfile, Error> = await offMain {
                Result { try engine.captureActiveAsProfile() }
            }
            await reloadLocalState()
            switch result {
            case .success(let profile):
                infoMessage = "Cuenta \(profile.emailAddress) guardada."
                await refreshAll()
            case .failure(let error):
                lastError = "No se pudo guardar la cuenta activa: \(describe(error))"
            }
        }
    }

    func undo() {
        let engine = self.engine
        Task {
            let result: Result<AccountIdentity, Error> = await offMain {
                Result { try engine.undoLastSwitch() }
            }
            await reloadLocalState()
            switch result {
            case .success(let identity):
                infoMessage = "De vuelta en \(identity.emailAddress)."
            case .failure(let error):
                lastError = "No se pudo deshacer: \(describe(error))"
            }
        }
    }

    // MARK: Alta de cuenta desde la propia app (sin terminal)

    var addAccountVisible = false
    private(set) var addAccountSession: AnthropicAPI.LoginSession?
    private(set) var addAccountError: String?
    private(set) var addAccountBusy = false

    /// Abre el navegador con la página de autorización y muestra la hoja
    /// para pegar el código. No toca la sesión activa de Claude Code.
    func beginAddAccount() {
        let session = AnthropicAPI.makeLoginSession()
        addAccountSession = session
        addAccountError = nil
        addAccountVisible = true
        NSWorkspace.shared.open(session.url)
    }

    func reopenAddAccountPage() {
        guard let session = addAccountSession else { return }
        NSWorkspace.shared.open(session.url)
    }

    func completeAddAccount(code: String) async {
        guard let session = addAccountSession else { return }
        addAccountBusy = true
        addAccountError = nil
        defer { addAccountBusy = false }
        do {
            let (creds, identity) = try await api.exchangeAuthorizationCode(code, session: session)
            let profiles = self.profiles
            let saved: AccountProfile = try await offMain {
                Result { try profiles.saveProfile(identity: identity, credentials: creds) }
            }.get()
            addAccountSession = nil
            addAccountVisible = false
            infoMessage = "Cuenta \(saved.emailAddress) añadida."
            await reloadLocalState()
            Task { await refreshAll() }
        } catch AnthropicAPIError.invalidAuthorizationCode {
            addAccountError = "El código no es válido o ya se usó. Vuelve a abrir la página y pega el código nuevo."
        } catch {
            addAccountError = "No se pudo completar el alta: \(describe(error))"
        }
    }

    func cancelAddAccount() {
        addAccountSession = nil
        addAccountVisible = false
        addAccountError = nil
    }

    func setSharedCaps(fiveHour: Double?, weekly: Double?, for accountUuid: String) {
        let profiles = self.profiles
        Task {
            _ = await offMain { profiles.setSharedCaps(fiveHour: fiveHour, weekly: weekly, for: accountUuid) }
            await reloadLocalState()
        }
    }

    func removeProfile(_ accountUuid: String) {
        let profiles = self.profiles
        Task {
            let ok = await offMain { (try? profiles.removeProfile(accountUuid)) != nil }
            usageByAccount[accountUuid] = nil
            await reloadLocalState()
            if !ok { lastError = "No se pudo eliminar el perfil" }
        }
    }

    func clearMessages() {
        infoMessage = nil
        lastError = nil
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: Datos derivados para la interfaz

    var activeProfile: AccountProfile? {
        profilesList.first { $0.accountUuid == activeAccountUuid }
    }

    /// Uso de 5 h de la cuenta activa (0–1) para el icono de la barra.
    var activeFiveHourFraction: Double? {
        guard let uuid = activeAccountUuid,
              let u = usageByAccount[uuid]?.fiveHour?.utilization else { return nil }
        return min(max(u / 100, 0), 1)
    }
}
