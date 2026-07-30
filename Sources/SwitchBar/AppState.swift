import SwiftUI
import SwitchBarCore

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
    private let statusAPI: AnthropicStatusAPI
    private let preferences: AppPreferences
    private let usageCache: UsageSnapshotCache

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
    /// Explica una pausa del endpoint de uso sin mezclarla con errores locales.
    /// Persiste al abrir/cerrar el panel y se retira al recuperarse las cuentas.
    private(set) var usageRefreshNotice: String?
    private(set) var anthropicStatus: AnthropicStatusSnapshot?
    private(set) var anthropicStatusUnavailable = false
    private(set) var isCheckingAnthropicStatus = false

    // MARK: Ajustes persistidos

    var autoSwitchEnabled: Bool {
        didSet { preferences.autoSwitchEnabled = autoSwitchEnabled }
    }
    var triggerThreshold: Double {
        didSet { preferences.triggerThreshold = triggerThreshold }
    }
    var weeklyTriggerThreshold: Double {
        didSet { preferences.weeklyTriggerThreshold = weeklyTriggerThreshold }
    }
    var fableTriggerThreshold: Double {
        didSet { preferences.fableTriggerThreshold = fableTriggerThreshold }
    }
    var useFableForAutoSwitch: Bool {
        didSet { preferences.useFableForAutoSwitch = useFableForAutoSwitch }
    }
    var pollIntervalSeconds: Double {
        didSet { preferences.pollIntervalSeconds = pollIntervalSeconds }
    }

    private var pollTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var identityWatchTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    /// Anthropic puede limitar un token concreto. El descanso se guarda por
    /// cuenta para que una sola sesión no congele la actualización de todas.
    private var rateLimitedUntilByAccount: [String: Date] = [:]
    private var usageRefreshPlanner = UsageRefreshPlanner()
    private var usageIssueByAccount: [String: UsageIssue] = [:]
    private var identityTracker = ActiveIdentityTracker()
    /// Permite detectar también un `/login` de la misma cuenta, donde el UUID
    /// no cambia pero Claude Code reescribe su identidad y rota credenciales.
    private var lastObservedIdentityWrite: Date?
    /// Última cuenta que activó SwitchBar. Sirve para distinguir un cambio
    /// hecho por la app de un `/login` manual del usuario en la terminal.
    private var lastSwitchByApp: String?
    /// Evita que dos clics o un cambio manual y uno automático se solapen.
    private var isSwitchingAccount = false
    /// Instante del último login manual detectado. El cambio automático se
    /// mantiene en pausa un rato después para no pisar la elección del usuario.
    private(set) var manualLoginAt: Date?
    private let manualLoginGracePeriod: TimeInterval = 15 * 60

    // MARK: Ciclo de vida

    init(store: ClaudeCodeStore = ClaudeCodeStore(),
         profiles: ProfileStore = ProfileStore(),
         api: AnthropicAPI = AnthropicAPI(),
         statusAPI: AnthropicStatusAPI = AnthropicStatusAPI(),
         preferences: AppPreferences = AppPreferences(),
         usageCache: UsageSnapshotCache = UsageSnapshotCache()) {
        self.store = store
        self.profiles = profiles
        self.preferences = preferences
        self.usageCache = usageCache
        self.engine = SwitchEngine(store: store, profiles: profiles)
        self.api = api
        self.statusAPI = statusAPI
        self.autoSwitchEnabled = preferences.autoSwitchEnabled
        self.triggerThreshold = preferences.triggerThreshold
        self.weeklyTriggerThreshold = preferences.weeklyTriggerThreshold
        self.fableTriggerThreshold = preferences.fableTriggerThreshold
        // Fable es un cupo independiente: agotarlo no impide seguir usando
        // otros modelos con el cupo general. Solo participa si el usuario lo
        // activa expresamente.
        self.useFableForAutoSwitch = preferences.useFableForAutoSwitch
        self.pollIntervalSeconds = preferences.pollIntervalSeconds
        self.rateLimitedUntilByAccount = Self.loadUsageCooldowns(
            from: preferences
        )
        // El estado local se carga fuera del hilo principal. El único Llavero
        // que se consulta al arrancar es el almacén privado de SwitchBar,
        // con interacción desactivada; nunca se toca la sesión activa de
        // Claude Code durante el arranque.
        Task {
            await migrateLegacyStorage()
            await reloadLocalState()
            await restoreCachedUsage()
            startStatusPolling()
            startPolling()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAfterResume()
            }
        }
        startIdentityWatcher()
    }

    /// Vigila `~/.claude.json` para reflejar un cambio real de cuenta hecho
    /// mediante `/login`. Las reescrituras ordinarias del fichero con la misma
    /// identidad se ignoran; un token renovado para esa misma cuenta se recoge
    /// al consultar el uso. SwitchBar nunca renueva tokens por su cuenta.
    private func startIdentityWatcher() {
        identityWatchTask?.cancel()
        let store = self.store
        let engine = self.engine
        identityWatchTask = Task { [weak self] in
            guard let self else { return }
            self.lastObservedIdentityWrite = await self.offMain {
                store.identityModificationDate()
            }
            let initialIdentity = await self.offMain {
                try? store.readActiveIdentity()
            }
            let initialAccountUuid = initialIdentity?.accountUuid
            let previouslyObserved =
                self.preferences.lastObservedAccountUuid
            self.identityTracker = ActiveIdentityTracker(
                accountUuid: initialAccountUuid
            )
            if let previouslyObserved,
               let initialAccountUuid,
               previouslyObserved != initialAccountUuid {
                // La identidad cambió mientras SwitchBar estaba cerrado:
                // esta sí es una elección externa que conviene respetar.
                self.manualLoginAt = Date()
            }
            self.preferences.lastObservedAccountUuid = initialAccountUuid
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                let modified = await self.offMain {
                    store.identityModificationDate()
                }
                guard modified != self.lastObservedIdentityWrite else {
                    continue
                }
                self.lastObservedIdentityWrite = modified
                let identity = await self.offMain {
                    try? store.readActiveIdentity()
                }
                guard let identity else { continue }

                let change = self.identityTracker.observe(
                    accountUuid: identity.accountUuid,
                    expectedAppAccountUuid: self.lastSwitchByApp
                )
                if change == .unchanged {
                    // Claude Code reescribe este fichero por otros motivos.
                    // No renovar la pausa ni volver a consultar el uso.
                    if identity.accountUuid == self.lastSwitchByApp {
                        self.lastSwitchByApp = nil
                    }
                    continue
                }
                self.lastSwitchByApp = nil
                self.preferences.lastObservedAccountUuid =
                    identity.accountUuid
                if change == .manual {
                    self.manualLoginAt = Date()
                    self.infoMessage = nil
                    // Claude Code termina de confirmar el Llavero alrededor
                    // de la escritura de ~/.claude.json. Un breve margen evita
                    // capturar el par a medio actualizar.
                    try? await Task.sleep(for: .milliseconds(750))
                    if self.profilesList.contains(where: {
                        $0.accountUuid == identity.accountUuid
                    }) {
                        let result = await self.offMain {
                            Result { try engine.syncActiveIntoProfile() }
                        }
                        switch result {
                        case .success:
                            self.clearUsageCooldown(
                                for: identity.accountUuid
                            )
                        case .failure(let error):
                            self.lastError =
                                L10n.tr(
                                    "state.login_sync_failed",
                                    self.describe(error)
                                )
                        }
                    }
                }
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
                guard let self else { return }
                await self.refreshNextScheduledAccount()
                var spacing = UsageRefreshPlanner.spacing(
                    fullCycleInterval: self.pollIntervalSeconds,
                    accountCount: self.availableUsageAccountCount
                )
                // Mientras alguna cuenta siga sin datos (primer arranque o
                // cuenta recién añadida), la vuelta se acelera al máximo que
                // tolera el servidor. Simultáneas no: el endpoint detecta la
                // ráfaga, acepta la primera y castiga al resto con una pausa
                // de un minuto o más, que es el resultado contrario al buscado.
                if self.hasAccountsAwaitingFreshSnapshot {
                    spacing = min(spacing, 5)
                }
                try? await Task.sleep(for: .seconds(spacing))
            }
        }
    }

    /// Alguna cuenta utilizable (con sesión y sin pausa del servidor) sigue
    /// sin datos o con datos demasiado viejos para decidir: ocurre en el
    /// primer arranque, al añadir una cuenta y al volver de un apagado largo
    /// con la caché restaurada. El umbral coincide con el que la política
    /// automática considera «vigente».
    private var hasAccountsAwaitingFreshSnapshot: Bool {
        let now = Date()
        let maxAge = max(2 * pollIntervalSeconds, 600)
        return profilesList.contains { profile in
            guard !profile.needsLogin else { return false }
            if let snapshot = usageByAccount[profile.accountUuid],
               now.timeIntervalSince(snapshot.fetchedAt) < maxAge {
                return false
            }
            return rateLimitedUntilByAccount[profile.accountUuid]
                .map { $0 <= now } ?? true
        }
    }

    /// Rellena el panel con la última instantánea guardada de cada cuenta,
    /// sin esperar a la red. Las consultas posteriores las van sustituyendo.
    private func restoreCachedUsage() async {
        let usageCache = self.usageCache
        let cached = await offMain { usageCache.load() }
        guard !cached.isEmpty else { return }
        for (account, snapshot) in cached
        where usageByAccount[account] == nil {
            usageByAccount[account] = snapshot
        }
        if let activeAccountUuid,
           let restored = usageByAccount[activeAccountUuid] {
            lastRefreshAt = restored.fetchedAt
        }
    }

    /// Guarda la caché en disco sin bloquear el hilo principal. Un fallo de
    /// escritura solo pierde la comodidad del arranque, nunca datos reales.
    private func persistUsageCache() {
        let usageCache = self.usageCache
        let snapshots = usageByAccount
        Task.detached(priority: .utility) {
            try? usageCache.save(snapshots)
        }
    }

    /// La página pública es muy ligera. Durante una incidencia se consulta
    /// cada minuto para que la recuperación aparezca pronto; en estado normal,
    /// cada tres minutos.
    private func startStatusPolling() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAnthropicStatus()
                let disrupted =
                    self.anthropicStatus?.relevantHealth.isDisrupted ?? true
                try? await Task.sleep(
                    for: .seconds(disrupted ? 60 : 180)
                )
            }
        }
    }

    func refreshAnthropicStatus() async {
        if isCheckingAnthropicStatus { return }
        isCheckingAnthropicStatus = true
        defer { isCheckingAnthropicStatus = false }
        do {
            anthropicStatus = try await statusAPI.fetch()
            anthropicStatusUnavailable = false
        } catch {
            // Conservar el último estado conocido, pero dejar claro que no se
            // pudo actualizar. No confundir una red local sin conexión con una
            // caída confirmada de Anthropic.
            anthropicStatusUnavailable = true
        }
    }

    /// Refresco al abrir el panel, con un mínimo de 30 s entre rondas.
    func refreshIfStale() {
        Task {
            await reloadLocalState()
            if let activeAccountUuid,
               let last = usageByAccount[activeAccountUuid]?.fetchedAt,
               Date().timeIntervalSince(last) < 30 {
                return
            }
            await refreshAll()
        }
    }

    /// Al volver del reposo o reactivar la app se comprueba el uso de
    /// inmediato si los datos no son recientes. El panel no tiene que estar
    /// abierto para que el sondeo periódico y el cambio automático funcionen.
    func refreshAfterResume() {
        refreshIfStale()
    }

    // MARK: Estado local (sin red)

    private struct LocalSnapshot: Sendable {
        var profiles: [AccountProfile]
        var activeAccountUuid: String?
        var canUndo: Bool
        var activeUnsaved: AccountIdentity?
    }

    private struct LocalLoadOutcome: Sendable {
        var snapshot: LocalSnapshot?
        var errorMessage: String?
    }

    private func migrateLegacyStorage() async {
        let profiles = self.profiles
        let outcome = await offMain { () -> String? in
            do {
                _ = try profiles.migrateLegacyFileIfNeeded()
                return nil
            } catch {
                return UserFacingError.describe(error)
            }
        }
        if let outcome {
            lastError = L10n.tr(
                "state.legacy_migration_failed",
                outcome
            )
        }
    }

    private func reloadLocalState() async {
        let store = self.store
        let profiles = self.profiles
        let engine = self.engine
        let outcome = await offMain { () -> LocalLoadOutcome in
            do {
                var list = try profiles.loadProfiles()
                let identity = try store.readActiveIdentity()
                let unsaved = identity.flatMap { id in
                    list.contains { $0.accountUuid == id.accountUuid } ? nil : id
                }
                // La cuenta en uso siempre la primera; el resto por correo.
                let activeUuid = identity?.accountUuid
                list.sort { a, b in
                    if (a.accountUuid == activeUuid)
                        != (b.accountUuid == activeUuid) {
                        return a.accountUuid == activeUuid
                    }
                    return a.emailAddress.localizedCaseInsensitiveCompare(
                        b.emailAddress
                    ) == .orderedAscending
                }
                return LocalLoadOutcome(
                    snapshot: LocalSnapshot(
                        profiles: list,
                        activeAccountUuid: identity?.accountUuid,
                        canUndo: engine.canUndo,
                        activeUnsaved: unsaved
                    ),
                    errorMessage: nil
                )
            } catch {
                return LocalLoadOutcome(
                    snapshot: nil,
                    errorMessage: UserFacingError.describe(error)
                )
            }
        }
        guard let snapshot = outcome.snapshot else {
            if let message = outcome.errorMessage {
                lastError =
                    L10n.tr("state.local_read_failed", message)
            }
            return
        }
        profilesList = snapshot.profiles
        activeAccountUuid = snapshot.activeAccountUuid
        canUndo = snapshot.canUndo
        activeUnsaved = snapshot.activeUnsaved
    }

    // MARK: Refresco de red

    private enum UsageRefreshOutcome {
        case updated
        case unchanged
        case waitingForSession
        case rateLimited(until: Date)
        case failed(UsageRefreshFailure)
    }

    private enum UsageRefreshFailure {
        case server(Int)
        case connection
    }

    private enum UsageIssue {
        case waitingForSession
        case server(Int)
        case connection
    }

    /// El botón y los eventos de ciclo de vida actualizan únicamente la cuenta
    /// activa. El resto se reparte mediante `refreshNextScheduledAccount` para
    /// no enviar una ráfaga de peticiones. Solo el botón fuerza la consulta
    /// aunque los datos sean muy recientes; los eventos automáticos la omiten
    /// para no encadenar peticiones que acaben en una pausa del servidor.
    func refreshAll(force: Bool = false) async {
        await refreshAnthropicStatus()
        await reloadLocalState()
        guard let activeAccountUuid else {
            usageRefreshNotice = nil
            return
        }
        await refreshUsageAccount(activeAccountUuid, force: force)
    }

    private var availableUsageAccountCount: Int {
        let now = Date()
        return max(
            1,
            profilesList.filter { profile in
                guard !profile.needsLogin else { return false }
                return rateLimitedUntilByAccount[profile.accountUuid]
                    .map { $0 <= now } ?? true
            }.count
        )
    }

    private func refreshNextScheduledAccount() async {
        await reloadLocalState()
        let now = Date()
        clearExpiredUsageCooldowns(now: now)
        let refreshable = profilesList.filter { !$0.needsLogin }
        let blocked: Set<String> = Set(
            refreshable.compactMap { profile in
                guard let until =
                        rateLimitedUntilByAccount[profile.accountUuid],
                      until > now else {
                    return nil
                }
                return profile.accountUuid
            }
        )
        guard let target = usageRefreshPlanner.nextAccount(
            accountUuids: refreshable.map(\.accountUuid),
            activeAccountUuid: activeAccountUuid,
            blockedAccountUuids: blocked
        ) else {
            updateActiveUsageNotice()
            return
        }
        await refreshUsageAccount(target)
    }

    private func refreshUsageAccount(
        _ accountUuid: String,
        force: Bool = false
    ) async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await reloadLocalState()
        // Aquí no se toca la entrada del Llavero de Claude Code: el uso se
        // consulta con las credenciales propias de cada perfil. La sesión
        // oficial solo se lee al cambiar o capturar una cuenta.

        let now = Date()
        clearExpiredUsageCooldowns(now: now)
        guard let profile = profilesList.first(where: {
            $0.accountUuid == accountUuid && !$0.needsLogin
        }) else {
            updateActiveUsageNotice()
            return
        }
        if let until = rateLimitedUntilByAccount[accountUuid],
           until > now {
            updateActiveUsageNotice()
            return
        }

        usageRefreshPlanner.recordRefresh(of: accountUuid)
        // Tras un cambio de cuenta coinciden varios disparadores (vigilante de
        // identidad, apertura del panel y sondeo). Un dato muy reciente no se
        // vuelve a pedir: encadenar peticiones provoca la pausa del servidor.
        if !force,
           let fetchedAt = usageByAccount[accountUuid]?.fetchedAt,
           now.timeIntervalSince(fetchedAt) < 30 {
            updateActiveUsageNotice()
            return
        }
        switch await refreshUsage(for: profile) {
        case .updated:
            rateLimitedUntilByAccount[accountUuid] = nil
            usageIssueByAccount[accountUuid] = nil
            if accountUuid == activeAccountUuid {
                lastRefreshAt = Date()
            }
            persistUsageCache()
        case .rateLimited(let until):
            rateLimitedUntilByAccount[accountUuid] = until
            usageIssueByAccount[accountUuid] = nil
        case .waitingForSession:
            usageIssueByAccount[accountUuid] = .waitingForSession
        case .failed(.server(let code)):
            usageIssueByAccount[accountUuid] = .server(code)
        case .failed(.connection):
            usageIssueByAccount[accountUuid] = .connection
        case .unchanged:
            usageIssueByAccount[accountUuid] = nil
        }
        persistUsageCooldowns()
        await reloadLocalState()
        updateActiveUsageNotice()
        await runAutoSwitchIfNeeded()
    }

    private func clearExpiredUsageCooldowns(now: Date) {
        let expired = rateLimitedUntilByAccount.compactMap {
            $0.value <= now ? $0.key : nil
        }
        guard !expired.isEmpty else { return }
        for accountUuid in expired {
            rateLimitedUntilByAccount[accountUuid] = nil
        }
        persistUsageCooldowns()
    }

    private func refreshUsage(
        for profile: AccountProfile
    ) async -> UsageRefreshOutcome {
        do {
            guard var creds = try await credentials(for: profile.accountUuid) else {
                markNeedsLogin(profile.accountUuid, true)
                return .unchanged
            }
            if creds.isRefreshTokenExpired() {
                markNeedsLogin(profile.accountUuid, true)
                return .unchanged
            }
            // La cuenta activa es propiedad de Claude Code: su token se
            // recoge del Llavero oficial cuando Claude Code lo renueva.
            // Las cuentas inactivas no tienen ninguna terminal detrás, así
            // que su sesión del almacén privado se renueva aquí mismo con el
            // flujo OAuth estándar; sin esto quedarían sin datos («—») en
            // cuanto caducara su access token.
            if creds.isAccessTokenExpired() {
                switch await renewedCredentials(
                    for: profile,
                    previousAccessToken: creds.accessToken,
                    current: creds
                ) {
                case .success(let renewed):
                    creds = renewed
                case .failure(let outcome):
                    return outcome
                }
            }
            do {
                usageByAccount[profile.accountUuid] = try await api.fetchUsage(
                    accessToken: creds.accessToken
                )
                return .updated
            } catch AnthropicAPIError.httpError(401) {
                // El servidor rechazó un token que parecía vigente: renovar la
                // sesión una única vez y reintentar.
                switch await renewedCredentials(
                    for: profile,
                    previousAccessToken: creds.accessToken,
                    current: creds
                ) {
                case .success(let renewed):
                    usageByAccount[profile.accountUuid] =
                        try await api.fetchUsage(
                            accessToken: renewed.accessToken
                        )
                    return .updated
                case .failure(let outcome):
                    return outcome
                }
            }
        } catch AnthropicAPIError.rateLimited(let retryAfter) {
            // Respetar la espera indicada por Anthropic. Sin cabecera se usa
            // un descanso prudente de 10 minutos; se acota para evitar tanto
            // bucles agresivos como bloqueos absurdamente largos.
            let delay = min(max(retryAfter ?? 600, 60), 3_600)
            return .rateLimited(
                until: Date().addingTimeInterval(delay)
            )
        } catch AnthropicAPIError.httpError(let code) where code >= 500 {
            return .failed(.server(code))
        } catch {
            return .failed(.connection)
        }
    }

    private enum CredentialRenewal {
        case success(OAuthCredentials)
        case failure(UsageRefreshOutcome)
    }

    /// Obtiene credenciales vigentes para una consulta de uso.
    ///
    /// - Cuenta activa: se recoge la sesión que Claude Code ya renovó en su
    ///   Llavero oficial. SwitchBar nunca rota el token de la sesión
    ///   activa, porque una terminal abierta quedaría invalidada.
    /// - Cuenta inactiva: ninguna terminal la está usando (su entrada del
    ///   Llavero oficial fue sustituida al cambiar), así que su sesión del
    ///   almacén privado se renueva con el flujo OAuth estándar y el token
    ///   rotado se guarda en ese mismo almacén.
    private func renewedCredentials(
        for profile: AccountProfile,
        previousAccessToken: String,
        current creds: OAuthCredentials
    ) async -> CredentialRenewal {
        if profile.accountUuid == activeAccountUuid {
            guard let synchronized = await synchronizeActiveCredentials(
                for: profile,
                previousAccessToken: previousAccessToken
            ) else {
                return .failure(.waitingForSession)
            }
            return .success(synchronized)
        }
        do {
            let refreshed = try await api.refreshAccessToken(
                refreshToken: creds.refreshToken
            )
            let expiresAt = refreshed.expiresIn.map {
                Int(Date().addingTimeInterval($0)
                    .timeIntervalSince1970 * 1000)
            }
            let updated = try creds.updating(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                expiresAt: expiresAt
            )
            let profiles = self.profiles
            let accountUuid = profile.accountUuid
            try await offMain {
                Result {
                    try profiles.updateCredentials(
                        updated,
                        for: accountUuid
                    )
                }
            }.get()
            return .success(updated)
        } catch AnthropicAPIError.invalidGrant {
            markNeedsLogin(profile.accountUuid, true)
            return .failure(.unchanged)
        } catch AnthropicAPIError.rateLimited(let retryAfter) {
            let delay = min(max(retryAfter ?? 600, 60), 3_600)
            return .failure(
                .rateLimited(until: Date().addingTimeInterval(delay))
            )
        } catch AnthropicAPIError.httpError(let code) where code >= 500 {
            return .failure(.failed(.server(code)))
        } catch {
            return .failure(.failed(.connection))
        }
    }

    /// Recoge únicamente una credencial que Claude Code ya haya renovado para
    /// la cuenta activa. No escribe en la sesión oficial ni llama al endpoint
    /// OAuth, así que las terminales abiertas y `/login` siguen siendo los
    /// propietarios del ciclo de autenticación.
    private func synchronizeActiveCredentials(
        for profile: AccountProfile,
        previousAccessToken: String
    ) async -> OAuthCredentials? {
        guard profile.accountUuid == activeAccountUuid else { return nil }
        let engine = self.engine
        let result = await offMain {
            Result { try engine.syncActiveIntoProfile() }
        }
        guard case .success = result,
              let synchronized = try? await credentials(
                for: profile.accountUuid
              ),
              synchronized.accessToken != previousAccessToken,
              !synchronized.isAccessTokenExpired() else {
            return nil
        }
        clearUsageCooldown(for: profile.accountUuid)
        return synchronized
    }

    /// Los problemas de cuentas inactivas quedan reflejados por la antigüedad
    /// de sus datos, sin convertirlos en una alerta global. El aviso naranja
    /// solo aparece si la cuenta que el usuario está utilizando necesita
    /// esperar o renovar su sesión.
    private func updateActiveUsageNotice() {
        guard let activeAccountUuid,
              let profile = profilesList.first(where: {
                $0.accountUuid == activeAccountUuid
              }) else {
            usageRefreshNotice = nil
            return
        }
        if let until = rateLimitedUntilByAccount[activeAccountUuid],
           until > Date() {
            let minutes = max(
                1,
                Int(ceil(until.timeIntervalSinceNow / 60))
            )
            usageRefreshNotice = L10n.tr(
                "usage.cooldown.active",
                minutes
            )
            return
        }
        switch usageIssueByAccount[activeAccountUuid] {
        case .waitingForSession:
            usageRefreshNotice = L10n.tr(
                "usage.refresh.session_waiting",
                profile.emailAddress
            )
        case .server(let code):
            usageRefreshNotice =
                anthropicStatus?.relevantHealth.isDisrupted == true
                ? nil
                : L10n.tr("usage.refresh.server_error", code)
        case .connection:
            usageRefreshNotice =
                anthropicStatus?.relevantHealth.isDisrupted == true
                ? nil
                : L10n.tr("usage.refresh.connection_error")
        case nil:
            usageRefreshNotice = nil
        }
    }

    private static func loadUsageCooldowns(
        from preferences: AppPreferences
    ) -> [String: Date] {
        let now = Date()
        let raw = preferences.usageCooldownTimestamps
        return raw.reduce(into: [:]) { result, entry in
            let date = Date(timeIntervalSince1970: entry.value)
            if date > now {
                result[entry.key] = date
            }
        }
    }

    private func persistUsageCooldowns() {
        let now = Date()
        rateLimitedUntilByAccount = rateLimitedUntilByAccount.filter {
            $0.value > now
        }
        let raw = rateLimitedUntilByAccount.mapValues(
            \.timeIntervalSince1970
        )
        preferences.usageCooldownTimestamps = raw
    }

    private func clearUsageCooldown(for accountUuid: String) {
        let removedCooldown = rateLimitedUntilByAccount.removeValue(
            forKey: accountUuid
        ) != nil
        usageIssueByAccount[accountUuid] = nil
        if removedCooldown {
            persistUsageCooldowns()
        }
        if accountUuid == activeAccountUuid {
            updateActiveUsageNotice()
        }
    }

    /// Credenciales para consultar el uso.
    ///
    /// Se usan siempre las del almacén privado de SwitchBar. El refresco
    /// periódico nunca consulta ni modifica "Claude Code-credentials".
    private func credentials(for accountUuid: String) async throws -> OAuthCredentials? {
        let profiles = self.profiles
        return try await offMain { Result { try profiles.credentials(for: accountUuid) } }.get()
    }

    private func markNeedsLogin(_ accountUuid: String, _ flag: Bool) {
        let profiles = self.profiles
        Task {
            let result = await offMain {
                Result { try profiles.markNeedsLogin(accountUuid, flag) }
            }
            if case .failure(let error) = result {
                lastError =
                    L10n.tr("state.profile_update_failed", describe(error))
            }
        }
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
        guard !isSwitchingAccount else { return }
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
        let policy = AutoSwitchPolicy(
            triggerThreshold: triggerThreshold,
            weeklyThreshold: weeklyTriggerThreshold,
            fableThreshold: fableTriggerThreshold,
            considersFable: useFableForAutoSwitch
        )
        let triggerDescription = autoSwitchTriggerDescription(activeState)
        guard let target = policy.decision(active: activeState, all: states) else {
            if policy.shouldSwitch(active: activeState) {
                Notifier.notify(
                    title: L10n.tr("auto_switch.no_available.title"),
                    body: L10n.tr(
                        "auto_switch.no_available.body",
                        nextResetText(states: states)
                    )
                )
            }
            return
        }
        let engine = self.engine
        isSwitchingAccount = true
        defer { isSwitchingAccount = false }
        lastSwitchByApp = target
        let result: Result<AccountIdentity, Error> = await offMain {
            Result { try engine.switchTo(target) }
        }
        switch result {
        case .success(let identity):
            preferences.lastObservedAccountUuid = identity.accountUuid
            await reloadLocalState()
            lastRefreshAt = usageByAccount[target]?.fetchedAt
            updateActiveUsageNotice()
            let pct = usageByAccount[target]?.fiveHour.map { Int($0.utilization) } ?? 0
            Notifier.notify(
                title: L10n.tr(
                    "auto_switch.changed.title",
                    identity.emailAddress
                ),
                body: L10n.tr(
                    "auto_switch.changed.body",
                    triggerDescription,
                    pct
                )
            )
        case .failure(let error):
            if lastSwitchByApp == target {
                lastSwitchByApp = nil
            }
            lastError = L10n.tr("auto_switch.error", describe(error))
        }
    }

    private func autoSwitchTriggerDescription(
        _ active: AccountUsageState
    ) -> String {
        guard let usage = active.usage else {
            return L10n.tr("auto_switch.trigger.generic")
        }
        if useFableForAutoSwitch,
           let fable = usage.sevenDayOpus,
           fable.utilization >= fableTriggerThreshold {
            return L10n.tr(
                "auto_switch.trigger.fable",
                Int(fable.utilization)
            )
        }
        if let weekly = usage.sevenDay,
           weekly.utilization >= weeklyTriggerThreshold {
            return L10n.tr(
                "auto_switch.trigger.weekly",
                Int(weekly.utilization)
            )
        }
        if let fiveHour = usage.fiveHour {
            return L10n.tr(
                "auto_switch.trigger.five_hour",
                Int(fiveHour.utilization)
            )
        }
        return L10n.tr("auto_switch.trigger.generic")
    }

    private func nextResetText(states: [AccountUsageState]) -> String {
        let resets = states.flatMap { state in
            var accountResets = [
                state.usage?.fiveHour?.resetsAt,
                state.usage?.sevenDay?.resetsAt
            ]
            if useFableForAutoSwitch {
                accountResets.append(state.usage?.sevenDayOpus?.resetsAt)
            }
            return accountResets.compactMap { $0 }
        }.sorted()
        guard let next = resets.first else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = L10n.locale
        return L10n.tr(
            "auto_switch.next_reset",
            f.localizedString(for: next, relativeTo: Date())
        )
    }

    // MARK: Acciones del usuario

    func switchTo(_ accountUuid: String) {
        guard !isSwitchingAccount else { return }
        isSwitchingAccount = true
        let engine = self.engine
        lastError = nil
        infoMessage = nil
        lastSwitchByApp = accountUuid
        Task {
            defer { isSwitchingAccount = false }
            let result: Result<(AccountIdentity, Bool), Error> = await offMain {
                Result {
                    do {
                        return (try engine.switchTo(accountUuid), false)
                    } catch let error as CoreError {
                        guard case .malformedJSON = error else {
                            throw error
                        }
                        return (
                            try engine.repairAndSwitchTo(accountUuid),
                            true
                        )
                    } catch SwitchError.inconsistentActiveState {
                        return (
                            try engine.repairAndSwitchTo(accountUuid),
                            true
                        )
                    }
                }
            }
            if case .failure = result,
               lastSwitchByApp == accountUuid {
                lastSwitchByApp = nil
            }
            await reloadLocalState()
            lastRefreshAt = activeAccountUuid.flatMap {
                usageByAccount[$0]?.fetchedAt
            }
            updateActiveUsageNotice()
            switch result {
            case .success(let outcome):
                preferences.lastObservedAccountUuid =
                    outcome.0.accountUuid
                infoMessage = outcome.1
                    ? L10n.tr(
                        "state.session_repaired",
                        outcome.0.emailAddress
                    )
                    : L10n.tr(
                        "state.account_switched",
                        outcome.0.emailAddress
                    )
            case .failure(SwitchError.profileNeedsLogin):
                lastError = L10n.tr("state.account_needs_login")
            case .failure(let error):
                lastError = L10n.tr(
                    "state.account_switch_failed",
                    describe(error)
                )
            }
        }
    }

    func captureActive() {
        guard !isSwitchingAccount else { return }
        let engine = self.engine
        lastError = nil
        infoMessage = nil
        Task {
            let result: Result<AccountProfile, Error> = await offMain {
                Result { try engine.captureActiveAsProfile() }
            }
            await reloadLocalState()
            switch result {
            case .success(let profile):
                infoMessage = L10n.tr(
                    "state.account_saved",
                    profile.emailAddress
                )
                await refreshAll()
            case .failure(let error):
                lastError = L10n.tr(
                    "state.account_save_failed",
                    describe(error)
                )
            }
        }
    }

    func undo() {
        guard !isSwitchingAccount else { return }
        isSwitchingAccount = true
        let engine = self.engine
        lastError = nil
        infoMessage = nil
        Task {
            defer { isSwitchingAccount = false }
            let result: Result<AccountIdentity, Error> = await offMain {
                Result { try engine.undoLastSwitch() }
            }
            await reloadLocalState()
            lastRefreshAt = activeAccountUuid.flatMap {
                usageByAccount[$0]?.fetchedAt
            }
            updateActiveUsageNotice()
            switch result {
            case .success(let identity):
                lastSwitchByApp = identity.accountUuid
                preferences.lastObservedAccountUuid =
                    identity.accountUuid
                infoMessage = L10n.tr(
                    "state.undo_success",
                    identity.emailAddress
                )
            case .failure(let error):
                lastError = L10n.tr("state.undo_failed", describe(error))
            }
        }
    }

    // MARK: Alta mediante el login oficial de Claude Code

    var addAccountVisible = false
    private(set) var reconnectingProfile: AccountProfile?
    private(set) var addAccountError: String?
    private(set) var addAccountBusy = false

    func beginAddAccount() {
        reconnectingProfile = nil
        addAccountError = nil
        addAccountVisible = true
    }

    func beginReconnect(_ profile: AccountProfile) {
        reconnectingProfile = profile
        addAccountError = nil
        addAccountVisible = true
    }

    /// Copia el comando oficial y abre Terminal. No usa AppleScript ni
    /// automatización de teclado, evitando otra clase de permisos del sistema.
    func prepareOfficialLogin() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            "claude auth login --claudeai",
            forType: .string
        )
        if let terminal = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Terminal"
        ) {
            NSWorkspace.shared.open(terminal)
        }
    }

    /// Tras completar el login en la terminal, captura exactamente el par
    /// identidad/credenciales que Claude Code dejó activo.
    func completeAddAccount() async {
        addAccountBusy = true
        addAccountError = nil
        defer { addAccountBusy = false }
        let engine = self.engine
        let target = reconnectingProfile
        let result = await offMain {
            Result {
                try engine.captureActiveAsProfile(
                    expectedAccountUuid: target?.accountUuid
                )
            }
        }
        switch result {
        case .success(let saved):
            reconnectingProfile = nil
            addAccountVisible = false
            infoMessage = target == nil
                ? L10n.tr("state.account_added", saved.emailAddress)
                : L10n.tr("state.account_reconnected", saved.emailAddress)
            await reloadLocalState()
            Task { await refreshAll() }
        case .failure(SwitchError.unexpectedActiveAccount(_, _)):
            if let target {
                addAccountError =
                    L10n.tr(
                        "state.unexpected_reconnect_account",
                        target.emailAddress
                    )
            } else {
                addAccountError =
                    L10n.tr("state.account_changed_while_saving")
            }
        case .failure(let error):
            addAccountError = L10n.tr(
                "state.enrollment_failed",
                describe(error)
            )
        }
    }

    func cancelAddAccount() {
        reconnectingProfile = nil
        addAccountVisible = false
        addAccountError = nil
    }

    func openAnthropicStatusPage() {
        NSWorkspace.shared.open(
            URL(string: "https://status.claude.com")!
        )
    }

    func setSharedCaps(fiveHour: Double?, weekly: Double?, for accountUuid: String) {
        let profiles = self.profiles
        Task {
            let result = await offMain {
                Result {
                    try profiles.setSharedCaps(
                        fiveHour: fiveHour,
                        weekly: weekly,
                        for: accountUuid
                    )
                }
            }
            await reloadLocalState()
            if case .failure(let error) = result {
                lastError = L10n.tr(
                    "state.shared_caps_failed",
                    describe(error)
                )
            }
        }
    }

    func removeProfile(_ accountUuid: String) {
        let profiles = self.profiles
        clearUsageCooldown(for: accountUuid)
        Task {
            let ok = await offMain { (try? profiles.removeProfile(accountUuid)) != nil }
            usageByAccount[accountUuid] = nil
            persistUsageCache()
            await reloadLocalState()
            if !ok {
                lastError = L10n.tr("state.profile_delete_failed")
            }
        }
    }

    private func describe(_ error: Error) -> String {
        UserFacingError.describe(error)
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
