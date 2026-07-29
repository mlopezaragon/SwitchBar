import SwiftUI
import ClaudeSwitchCore

/// Estado observable de la app: perfiles, uso por cuenta, cuenta activa,
/// ajustes y acciones (cambiar, capturar, deshacer, refrescar).
@MainActor
@Observable
final class AppState {
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
    private var rateLimitedUntil: Date?

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
        reloadLocalState()
        startPolling()
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
        reloadLocalState()
        if let last = lastRefreshAt, Date().timeIntervalSince(last) < 30 { return }
        Task { await refreshAll() }
    }

    // MARK: Estado local (sin red)

    private func reloadLocalState() {
        profilesList = profiles.loadProfiles()
        activeAccountUuid = engine.activeAccountUuid()
        canUndo = engine.canUndo
        if let identity = try? store.readActiveIdentity(),
           !profilesList.contains(where: { $0.accountUuid == identity.accountUuid }) {
            activeUnsaved = identity
        } else {
            activeUnsaved = nil
        }
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
        reloadLocalState()
        try? engine.syncActiveIntoProfile()

        for profile in profilesList where !profile.needsLogin {
            await refreshUsage(for: profile)
        }
        reloadLocalState()
        await runAutoSwitchIfNeeded()
    }

    private func refreshUsage(for profile: AccountProfile) async {
        let isActive = profile.accountUuid == activeAccountUuid
        do {
            guard var creds = try credentialsPreferringActive(for: profile.accountUuid) else {
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
    private func credentialsPreferringActive(for accountUuid: String) throws -> OAuthCredentials? {
        if accountUuid == activeAccountUuid, let active = try store.readActiveCredentials() {
            return active
        }
        return try profiles.credentials(for: accountUuid)
    }

    /// Renueva y persiste en el perfil. Solo para cuentas NO activas: la
    /// renovación rota el refresh token, y perder el nuevo sería fatal, así
    /// que la persistencia se reintenta antes de rendirse.
    private func refreshCredentials(_ creds: OAuthCredentials, for accountUuid: String) async throws -> OAuthCredentials {
        let renewed = try await api.refresh(creds)
        do {
            try profiles.updateCredentials(renewed, for: accountUuid)
        } catch {
            try? await Task.sleep(for: .milliseconds(300))
            try profiles.updateCredentials(renewed, for: accountUuid)
        }
        profiles.markNeedsLogin(accountUuid, false)
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
        do {
            let identity = try engine.switchTo(target)
            reloadLocalState()
            let pct = usageByAccount[target]?.fiveHour.map { Int($0.utilization) } ?? 0
            Notifier.notify(
                title: "Cambiado a \(identity.emailAddress)",
                body: "Ventana de 5 h al \(pct) %. Las sesiones abiertas siguen con la cuenta anterior."
            )
        } catch {
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
        do {
            let identity = try engine.switchTo(accountUuid)
            reloadLocalState()
            infoMessage = "Ahora \(identity.emailAddress) es la cuenta activa. Las sesiones de Claude Code abiertas siguen con la anterior hasta reiniciarlas."
        } catch SwitchError.profileNeedsLogin {
            lastError = "Esa cuenta necesita iniciar sesión de nuevo en Claude Code"
        } catch {
            lastError = "No se pudo cambiar de cuenta: \(describe(error))"
        }
    }

    func captureActive() {
        do {
            let profile = try engine.captureActiveAsProfile()
            reloadLocalState()
            infoMessage = "Cuenta \(profile.emailAddress) guardada."
            Task { await refreshAll() }
        } catch {
            lastError = "No se pudo guardar la cuenta activa: \(describe(error))"
        }
    }

    func undo() {
        do {
            let identity = try engine.undoLastSwitch()
            reloadLocalState()
            infoMessage = "De vuelta en \(identity.emailAddress)."
        } catch {
            lastError = "No se pudo deshacer: \(describe(error))"
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
            let profile = try profiles.saveProfile(identity: identity, credentials: creds)
            addAccountSession = nil
            addAccountVisible = false
            infoMessage = "Cuenta \(profile.emailAddress) añadida."
            reloadLocalState()
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
        profiles.setSharedCaps(fiveHour: fiveHour, weekly: weekly, for: accountUuid)
        reloadLocalState()
    }

    func removeProfile(_ accountUuid: String) {
        do {
            try profiles.removeProfile(accountUuid)
            usageByAccount[accountUuid] = nil
            reloadLocalState()
        } catch {
            lastError = "No se pudo eliminar el perfil: \(describe(error))"
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
