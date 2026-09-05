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
    private var monitoringDate = Date()
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
    /// Testigo de actividad que mantiene despierto el sondeo. Ver
    /// `beginBackgroundActivity()`.
    private var backgroundActivity: NSObjectProtocol?
    private var statusTask: Task<Void, Never>?
    private var identityWatchTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    /// Anthropic puede limitar un token concreto. El descanso se guarda por
    /// cuenta para que una sola sesión no congele la actualización de todas.
    /// Solo afecta a la consulta de uso.
    private var rateLimitedUntilByAccount: [String: Date] = [:]
    /// Descanso del endpoint de renovación de sesiones, que es un cupo aparte
    /// y mucho más severo. Nunca impide consultar el uso: mientras el token de
    /// acceso siga valiendo, o Claude Code lo haya renovado por su cuenta, los
    /// datos se pueden pedir igual. Confundir ambos descansos dejaba la app
    /// ciega justo cuando todavía podía ver.
    private var renewalBlockedUntilByAccount: [String: Date] = [:]
    /// Pausas encadenadas de cada cuenta, para alargar el descanso en vez de
    /// insistir con la misma cadencia contra un endpoint que ya está limitando.
    private var usageRateLimitStreakByAccount: [String: Int] = [:]
    /// Cuentas cuya sesión el servidor no deja renovar. Sobrevive a los
    /// reinicios: mientras dure, la única salida rápida es reconectarlas.
    private var renewalBlockedAccounts: Set<String> = []
    /// Se sube al corregir algo que dejaba bloqueos injustos guardados en
    /// disco. Ver `AppPreferences.renewalBlockResetGeneration`.
    private static let renewalBlockResetGeneration = 1
    /// Averigua si hay alguna terminal de Claude Code viva antes de tocar el
    /// token de la cuenta activa.
    private let claudeCodeProbe = ClaudeCodeProcessProbe()
    private var usagePollingSchedule = UsagePollingSchedule()
    private var pendingInitialUsageAccounts: Set<String> = []
    private var renewalRateLimitStreakByAccount: [String: Int] = [:]
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
    /// La evaluación automática puede consultar cuentas por su cuenta; sin
    /// este cerrojo esas consultas volverían a lanzar la evaluación.
    private var isEvaluatingAutoSwitch = false
    /// Último aviso de «no hay a dónde cambiar», con su motivo, para no
    /// repetirlo en cada vuelta del sondeo.
    private var lastNoCandidateNotice: (reason: NoCandidateReason, at: Date)?
    private let noCandidateNoticeInterval: TimeInterval = 30 * 60
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
        // Preserve server deadlines across restarts, even when Retry-After
        // exceeds the fallback retry policy.
        self.rateLimitedUntilByAccount = Self.loadCooldowns(
            preferences.usageCooldownTimestamps
        )
        self.renewalBlockedUntilByAccount = Self.loadCooldowns(
            preferences.renewalCooldownTimestamps
        )
        self.renewalBlockedAccounts = preferences.renewalBlockedAccounts
        // Herencia de una versión que insistía contra el endpoint de
        // renovación hasta dejar todas las cuentas castigadas medio día.
        // Con el reparto de turnos ya corregido, arrastrar ese castigo solo
        // alargaría un problema que ya no se puede reproducir.
        if preferences.renewalBlockResetGeneration < Self.renewalBlockResetGeneration {
            preferences.renewalBlockResetGeneration =
                Self.renewalBlockResetGeneration
            self.renewalBlockedUntilByAccount = [:]
            self.renewalBlockedAccounts = []
            preferences.renewalCooldownTimestamps = [:]
            preferences.renewalBlockedAccounts = []
        }
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

    /// Impide que macOS duerma la app (App Nap).
    ///
    /// SwitchBar vive en la barra de menús, sin ventanas: para el sistema es
    /// candidata perfecta a que le agrupen y pospongan los temporizadores. Con
    /// eso, el sondeo se paraba en cuanto el usuario dejaba de tocar el panel y
    /// las cuentas que no estaban activas se quedaban horas sin comprobar,
    /// hasta el punto de que el cambio automático ya no podía contar con ellas.
    /// Vigilar el uso es justo lo que se le pide a esta app, así que se declara
    /// como actividad en curso; el reposo del propio Mac se sigue permitiendo.
    private func beginBackgroundActivity() {
        guard backgroundActivity == nil else { return }
        backgroundActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Comprobar el uso de las cuentas"
        )
    }

    func startPolling() {
        pollTask?.cancel()
        beginBackgroundActivity()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNextScheduledAccount()
                // This is a local scheduling tick, not a network request.
                // Short sleeps also re-evaluate an expired cooldown promptly.
                await self.runAutoSwitchIfNeeded()
                self.monitoringDate = Date()
                self.updateActiveUsageNotice()
                try? await Task.sleep(for: .seconds(5))
            }
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
        lastRefreshAt = activeAccountUuid.flatMap { usageByAccount[$0]?.fetchedAt }
        canUndo = snapshot.canUndo
        activeUnsaved = snapshot.activeUnsaved
    }

    // MARK: Refresco de red

    private enum UsageRefreshOutcome {
        case updated
        case unchanged
        case waitingForSession
        case rateLimited(retryAfter: TimeInterval?, source: RateLimitSource)
        /// Su sesión hace falta renovarla, pero ese endpoint está aparcado.
        /// No se ha gastado ninguna petición.
        case renewalUnavailable
        case failed(UsageRefreshFailure)

        /// Texto para el registro de diagnóstico. Sin secretos.
        var logDescription: String {
            switch self {
            case .updated: "actualizada"
            case .unchanged: "sin cambios"
            case .renewalUnavailable: "renovación aparcada"
            case .waitingForSession: "esperando a que Claude Code renueve"
            case .rateLimited(_, let source):
                "pausa del servidor (\(source == .renewal ? "renovación" : "uso"))"
            case .failed(.server(let code)): "HTTP \(code)"
            case .failed(.connection(let detail)): "fallo: \(detail)"
            }
        }
    }

    /// De dónde viene una pausa impuesta por el servidor.
    ///
    /// Importa mucho: consultar el uso es barato y se puede reintentar pronto,
    /// pero renovar la sesión es una operación cara y rara. Insistir en la
    /// renovación cada pocos minutos es lo que mantiene castigada a la cuenta.
    private enum RateLimitSource {
        case usage
        case renewal
    }

    private enum UsageRefreshFailure {
        case server(Int)
        case connection(String)
    }

    private enum UsageIssue {
        case waitingForSession
        /// Anthropic está limitando la renovación de esta sesión. Esperar es
        /// obligado, pero el usuario puede resolverlo antes reconectándola.
        case renewalBlocked
        case server(Int)
        case connection
    }

    /// La sesión de esta cuenta no se puede renovar ahora mismo. Se dice en su
    /// tarjeta porque tiene arreglo a mano: volver a conectarla.
    func isRenewalBlocked(for accountUuid: String) -> Bool {
        renewalBlockedAccounts.contains(accountUuid)
    }

    /// Cuánto se tolera que una cuenta lleve sin datos antes de ofrecer la
    /// salida manual. Muy por encima del ciclo normal: si a la hora sigue sin
    /// actualizarse, ya no es un tropiezo pasajero.
    private let reconnectHintThreshold: TimeInterval = 3_600

    /// Conviene ofrecerle al usuario reconectar esta cuenta.
    ///
    /// Basta con que sus datos lleven mucho tiempo parados: da igual si fue un
    /// límite del servidor, una sesión que no se puede renovar o cualquier
    /// otra causa, porque la acción que lo resuelve es la misma. Esperar a
    /// tener el error concreto en la mano dejaba el botón escondido justo
    /// cuando más falta hace.
    func suggestsReconnect(for accountUuid: String) -> Bool {
        guard !profilesList.contains(where: {
            $0.accountUuid == accountUuid && $0.needsLogin
        }) else { return false }
        if renewalBlockedAccounts.contains(accountUuid) { return true }
        guard let snapshot = usageByAccount[accountUuid] else { return false }
        return Date().timeIntervalSince(snapshot.fetchedAt)
            >= reconnectHintThreshold
    }

    private func markRenewalBlocked(
        _ accountUuid: String,
        _ blocked: Bool
    ) {
        let changed = blocked
            ? renewalBlockedAccounts.insert(accountUuid).inserted
            : renewalBlockedAccounts.remove(accountUuid) != nil
        guard changed else { return }
        preferences.renewalBlockedAccounts = renewalBlockedAccounts
    }

    /// El botón y los eventos de ciclo de vida actualizan únicamente la cuenta
    /// activa. El resto se reparte mediante `refreshNextScheduledAccount` para
    /// no enviar una ráfaga de peticiones. Solo el botón fuerza la consulta
    /// aunque los datos sean muy recientes; los eventos automáticos la omiten
    /// para no encadenar peticiones que acaben en una pausa del servidor.
    func refreshAll(force: Bool = false) async {
        Task { await refreshAnthropicStatus() }
        await reloadLocalState()
        guard let activeAccountUuid else {
            usageRefreshNotice = nil
            return
        }
        await refreshUsageAccount(activeAccountUuid, force: force)
    }

    private var activeUsageInterval: TimeInterval {
        let usage = activeAccountUuid.flatMap { uuid in
            let profile = profilesList.first { $0.accountUuid == uuid }
            return usageByAccount[uuid]?.scaledToPersonalCaps(
                fiveHourCap: profile?.sharedFiveHourCap,
                weeklyCap: profile?.sharedWeeklyCap
            )
        }
        let nearLimit = (usage?.fiveHour?.utilization ?? 0) >= triggerThreshold - 15
            || (usage?.sevenDay?.utilization ?? 0) >= weeklyTriggerThreshold - 10
            || (useFableForAutoSwitch && (usage?.sevenDayOpus?.utilization ?? 0) >= fableTriggerThreshold - 10)
        return UsagePollingSchedule.activeInterval(
            configured: pollIntervalSeconds, nearLimit: nearLimit
        )
    }

    private func refreshNextScheduledAccount() async {
        await reloadLocalState()
        let now = Date()
        clearExpiredUsageCooldowns(now: now)
        clearExpiredRenewalBlocks(now: now)
        let refreshable = profilesList.filter { !$0.needsLogin }
        let blocked: Set<String> = Set(
            refreshable.compactMap { profile in
                if let until = rateLimitedUntilByAccount[profile.accountUuid],
                   until > now {
                    return profile.accountUuid
                }
                // Su token caducó y el endpoint de renovación está aparcado:
                // esta cuenta no puede conseguir nada hasta que el aparcado
                // expire. Sin esta salvedad su intento fallaba sin actualizar
                // la fecha del dato, así que el filtro de frescura no la
                // apartaba nunca y volvía a llevarse el turno cada vuelta,
                // dejando sin él a las cuentas que sí podían actualizarse.
                // Solo aplica a las inactivas: a la activa puede renovársela
                // Claude Code en cualquier momento.
                if profile.accountUuid != activeAccountUuid,
                   case .renewalBlocked = usageIssueByAccount[
                       profile.accountUuid
                   ],
                   let until = renewalBlockedUntilByAccount[
                       profile.accountUuid
                   ],
                   until > now {
                    return profile.accountUuid
                }
                return nil
            }
        )
        Diagnostics.usage.debug(
            "turno: \(refreshable.map { Diagnostics.tag($0.accountUuid) }.joined(separator: ","), privacy: .public) | en pausa: \(blocked.map(Diagnostics.tag).joined(separator: ","), privacy: .public)"
        )
        guard let target = usagePollingSchedule.nextAccount(
            accounts: refreshable.map(\.accountUuid),
            active: activeAccountUuid,
            snapshots: usageByAccount,
            blocked: blocked,
            activeInterval: activeUsageInterval,
            inactiveInterval: inactiveRefreshInterval,
            prioritized: pendingInitialUsageAccounts,
            now: now
        ) else {
            updateActiveUsageNotice()
            return
        }
        await refreshUsageAccount(target)
    }

    /// Resultado de un intento de consulta, desde el punto de vista de quien
    /// reparte los turnos.
    private enum UsageRefreshAttempt {
        /// Se consultó al servidor (con éxito o no).
        case attempted
        /// No tocaba: pausa del servidor, dato recién traído, perfil no apto.
        case skipped
        /// Coincidió con otra consulta en curso. No es culpa de la cuenta:
        /// su turno no debe darse por gastado.
        case busy
    }

    private func refreshUsageAccount(
        _ accountUuid: String,
        force: Bool = false
    ) async {
        guard await performUsageRefresh(accountUuid, force: force)
                == .attempted else {
            return
        }
        await runAutoSwitchIfNeeded()
    }

    /// Consulta el uso de una cuenta. Devuelve `true` si llegó a intentarse
    /// (había perfil, sin pausa del servidor y sin datos recién traídos); así
    /// quien llame sabe si tiene sentido volver a evaluar el cambio.
    ///
    /// No dispara el cambio automático por sí misma: es la propia evaluación
    /// la que puede pedir consultas de rescate y volvería a llamarse a sí
    /// misma sin fin.
    @discardableResult
    private func performUsageRefresh(
        _ accountUuid: String,
        force: Bool = false
    ) async -> UsageRefreshAttempt {
        if isRefreshing {
            Diagnostics.usage.debug(
                "\(Diagnostics.tag(accountUuid), privacy: .public) omitida: otra consulta en curso"
            )
            return .busy
        }
        isRefreshing = true
        defer { isRefreshing = false }
        await reloadLocalState()
        // Requests use the private profile. For the active account we may
        // first copy credentials already refreshed by Claude Code.

        let now = Date()
        clearExpiredUsageCooldowns(now: now)
        clearExpiredRenewalBlocks(now: now)
        guard let profile = profilesList.first(where: {
            $0.accountUuid == accountUuid && !$0.needsLogin
        }) else {
            Diagnostics.usage.debug(
                "\(Diagnostics.tag(accountUuid), privacy: .public) omitida: sin perfil utilizable"
            )
            updateActiveUsageNotice()
            return .skipped
        }
        if let until = rateLimitedUntilByAccount[accountUuid],
           until > now {
            Diagnostics.usage.debug(
                "\(Diagnostics.tag(accountUuid), privacy: .public) omitida: pausa del servidor \(Int(until.timeIntervalSinceNow)) s"
            )
            updateActiveUsageNotice()
            return .skipped
        }

        // Tras un cambio de cuenta coinciden varios disparadores (vigilante de
        // identidad, apertura del panel y sondeo). Un dato muy reciente no se
        // vuelve a pedir: encadenar peticiones provoca la pausa del servidor.
        if !force,
           let fetchedAt = usageByAccount[accountUuid]?.fetchedAt,
           now.timeIntervalSince(fetchedAt) < 30 {
            Diagnostics.usage.debug(
                "\(Diagnostics.tag(accountUuid), privacy: .public) omitida: dato de hace \(Int(now.timeIntervalSince(fetchedAt))) s"
            )
            updateActiveUsageNotice()
            return .skipped
        }
        // Manual refresh and switch rescue share the same gate as the timer.
        // Force bypasses freshness only, never server cooldowns or spacing.
        guard !Task.isCancelled, usagePollingSchedule.canStart(now: Date()) else {
            return .skipped
        }
        usagePollingSchedule.recordAttempt(accountUuid, now: Date())
        await adoptActiveCredentialsIfFresher(profile)
        let outcome = await refreshUsage(for: profile)
        pendingInitialUsageAccounts.remove(accountUuid)
        Diagnostics.usage.log(
            "\(Diagnostics.tag(accountUuid), privacy: .public) -> \(outcome.logDescription, privacy: .public)"
        )
        switch outcome {
        case .updated:
            rateLimitedUntilByAccount[accountUuid] = nil
            usageRateLimitStreakByAccount[accountUuid] = nil
            usageIssueByAccount[accountUuid] = nil
            markRenewalBlocked(accountUuid, false)
            if accountUuid == activeAccountUuid {
                lastRefreshAt = Date()
            }
            persistUsageCache()
        case .rateLimited(let retryAfter, let source):
            let renewal = source == .renewal
            let streak = (renewal
                ? renewalRateLimitStreakByAccount[accountUuid]
                : usageRateLimitStreakByAccount[accountUuid]) ?? 0
            if renewal {
                renewalRateLimitStreakByAccount[accountUuid] = streak + 1
            } else {
                usageRateLimitStreakByAccount[accountUuid] = streak + 1
            }
            let until = Date().addingTimeInterval(UsageRetryPolicy.delay(
                retryAfter: retryAfter, streak: streak + 1, renewal: renewal
            ))
            switch source {
            case .renewal:
                // Solo se aparcan las renovaciones. Consultar el uso sigue
                // permitido: en cuanto Claude Code renueve esa sesión por su
                // cuenta, los datos vuelven sin pedirle nada al endpoint
                // castigado.
                renewalBlockedUntilByAccount[accountUuid] = until
                usageIssueByAccount[accountUuid] = .renewalBlocked
                markRenewalBlocked(accountUuid, true)
            case .usage:
                rateLimitedUntilByAccount[accountUuid] = until
                usageIssueByAccount[accountUuid] = nil
            }
        case .renewalUnavailable:
            usageIssueByAccount[accountUuid] = .renewalBlocked
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
        return .attempted
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

    /// Retira el aviso «Sesión sin renovar» cuando su pausa ya ha vencido.
    ///
    /// Antes solo lo borraba una lectura de uso correcta, y una cuenta con la
    /// renovación aparcada nunca llegaba a tener una: el aviso se quedaba
    /// puesto en su tarjeta durante horas después de que el motivo hubiera
    /// desaparecido, invitando a reconectar una cuenta que ya no lo necesita.
    private func clearExpiredRenewalBlocks(now: Date) {
        let expired = renewalBlockedUntilByAccount.compactMap {
            $0.value <= now ? $0.key : nil
        }
        guard !expired.isEmpty else { return }
        for accountUuid in expired {
            renewalBlockedUntilByAccount[accountUuid] = nil
            markRenewalBlocked(accountUuid, false)
            if case .renewalBlocked = usageIssueByAccount[accountUuid] {
                usageIssueByAccount[accountUuid] = nil
            }
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
            // Inactive accounts may still belong to older terminals; renewal
            // also checks for running clients before rotating their tokens.
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
            Diagnostics.usage.log(
                "\(Diagnostics.tag(profile.accountUuid), privacy: .public) 429 al consultar el uso (retry-after: \(retryAfter.map { String(Int($0)) } ?? "ninguno", privacy: .public))"
            )
            return .rateLimited(retryAfter: retryAfter, source: .usage)
        } catch AnthropicAPIError.httpError(let code) {
            // Cualquier código inesperado, no solo los 5xx: un 403 tratado
            // como «fallo de conexión» dejaba a la cuenta reintentando en
            // silencio para siempre, sin que nadie supiera qué pasaba.
            return .failed(.server(code))
        } catch {
            return .failed(.connection(describe(error)))
        }
    }

    /// Se queda con la sesión que Claude Code acaba de renovar, mientras la
    /// cuenta sigue siendo la activa.
    ///
    /// Es la pieza que evita casi todas las renovaciones propias. Claude Code
    /// rota el token de la cuenta activa cada pocas horas y lo deja en su
    /// Llavero; copiarlo aquí no cuesta ni una petición. Antes solo se recogía
    /// cuando la copia de SwitchBar ya había caducado, y para entonces la
    /// cuenta solía haber dejado de ser la activa: solo quedaba pedirle al
    /// servidor una renovación, que es justo lo que Anthropic castiga.
    private func adoptActiveCredentialsIfFresher(
        _ profile: AccountProfile
    ) async {
        guard profile.accountUuid == activeAccountUuid else { return }
        let engine = self.engine
        _ = await offMain { try? engine.syncActiveIntoProfile() }
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
    /// - Cuenta inactiva: también puede seguir en uso en terminales anteriores.
    ///   Solo se renueva cuando no hay procesos que puedan usar Claude Code.
    private func renewedCredentials(
        for profile: AccountProfile,
        previousAccessToken: String,
        current creds: OAuthCredentials
    ) async -> CredentialRenewal {
        let isActive = profile.accountUuid == activeAccountUuid
        if isActive {
            if let synchronized = await synchronizeActiveCredentials(
                for: profile,
                previousAccessToken: previousAccessToken
            ) {
                return .success(synchronized)
            }
            return .failure(.waitingForSession)
        }
        if !isActive {
            let probe = claudeCodeProbe
            guard await offMain({ !probe.isClaudeCodeRunning() }) else {
                return .failure(.waitingForSession)
            }
        }
        // El endpoint de renovación está castigado para esta cuenta: pedirle
        // otra solo alargaría el castigo. Se informa sin gastar la petición.
        if let until = renewalBlockedUntilByAccount[profile.accountUuid],
           until > Date() {
            Diagnostics.usage.debug(
                "\(Diagnostics.tag(profile.accountUuid), privacy: .public) renovación aparcada \(Int(until.timeIntervalSinceNow)) s"
            )
            return .failure(.renewalUnavailable)
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
            let saved = try await offMain {
                Result {
                    try profiles.updateCredentials(
                        updated,
                        for: accountUuid,
                        expectedAccessToken: creds.accessToken
                    )
                }
            }.get()
            guard saved else { return .failure(.unchanged) }
            renewalRateLimitStreakByAccount[accountUuid] = nil
            return .success(updated)
        } catch AnthropicAPIError.invalidGrant {
            markNeedsLogin(profile.accountUuid, true)
            return .failure(.unchanged)
        } catch AnthropicAPIError.rateLimited(let retryAfter) {
            Diagnostics.usage.log(
                "\(Diagnostics.tag(profile.accountUuid), privacy: .public) 429 al renovar la sesión (retry-after: \(retryAfter.map { String(Int($0)) } ?? "ninguno", privacy: .public))"
            )
            return .failure(.rateLimited(retryAfter: retryAfter, source: .renewal))
        } catch AnthropicAPIError.httpError(let code) {
            return .failure(.failed(.server(code)))
        } catch {
            return .failure(.failed(.connection(describe(error))))
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
        case .renewalBlocked:
            usageRefreshNotice = L10n.tr(
                "usage.renewal_blocked",
                profile.emailAddress
            )
        case .waitingForSession:
            // Que Claude Code todavía no haya renovado su sesión no es una
            // avería: la cuenta se puede usar con normalidad y lo único que
            // se retrasa es la lectura del consumo. Poner un aviso naranja
            // encima de una cuenta marcada como «Activa» solo desconcierta,
            // así que se reserva para cuando los datos ya son viejos de
            // verdad y el usuario merece saber por qué no se mueven.
            usageRefreshNotice = isUsageStale(for: activeAccountUuid)
                ? L10n.tr(
                    "usage.refresh.session_waiting",
                    profile.emailAddress
                )
                : nil
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

    private static func loadCooldowns(
        _ raw: [String: TimeInterval],
        maximum: TimeInterval? = nil
    ) -> [String: Date] {
        let now = Date()
        return raw.reduce(into: [:]) { result, entry in
            let date = Date(timeIntervalSince1970: entry.value)
            guard date > now else { return }
            guard let maximum else {
                result[entry.key] = date
                return
            }
            result[entry.key] = min(date, now.addingTimeInterval(maximum))
        }
    }

    private func persistUsageCooldowns() {
        let now = Date()
        rateLimitedUntilByAccount = rateLimitedUntilByAccount.filter {
            $0.value > now
        }
        renewalBlockedUntilByAccount = renewalBlockedUntilByAccount.filter {
            $0.value > now
        }
        preferences.usageCooldownTimestamps =
            rateLimitedUntilByAccount.mapValues(\.timeIntervalSince1970)
        // Las pausas de renovación son largas (horas) y tienen que sobrevivir
        // a un reinicio: si se olvidaran, la app volvería a llamar a la puerta
        // en cada arranque y el castigo no se levantaría nunca.
        preferences.renewalCooldownTimestamps =
            renewalBlockedUntilByAccount.mapValues(\.timeIntervalSince1970)
    }

    private func clearUsageCooldown(for accountUuid: String) {
        rateLimitedUntilByAccount[accountUuid] = nil
        renewalBlockedUntilByAccount[accountUuid] = nil
        usageRateLimitStreakByAccount[accountUuid] = nil
        usageIssueByAccount[accountUuid] = nil
        markRenewalBlocked(accountUuid, false)
        renewalRateLimitStreakByAccount[accountUuid] = nil
        persistUsageCooldowns()
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

    /// Antigüedad a partir de la cual una instantánea deja de servir para
    /// decidir. Es también la que marca los datos como viejos en el panel:
    /// mostrar un 0 % de hace horas como si fuera de ahora induce a error.
    /// La activa caduca antes (dos minutos); un destino se vuelve a comprobar
    /// antes de cambiar porque también puede estar usándose en otra terminal.
    var usageFreshnessLimit: TimeInterval {
        max(600, 2 * inactiveRefreshInterval)
    }

    /// Cada cuánto vale la pena volver a preguntar por una cuenta que no está
    /// en uso.
    ///
    /// Las cuentas compartidas y las terminales anteriores pueden consumir
    /// aunque la cuenta ya no figure como activa en SwitchBar.
    private var inactiveRefreshInterval: TimeInterval {
        min(600, max(180, pollIntervalSeconds))
    }

    /// Los datos de esta cuenta son demasiado viejos para fiarse de ellos.
    func isUsageStale(for accountUuid: String) -> Bool {
        guard let snapshot = usageByAccount[accountUuid] else { return false }
        let now = max(monitoringDate, Date())
        return now.timeIntervalSince(snapshot.fetchedAt)
            >= (accountUuid == activeAccountUuid ? 120 : usageFreshnessLimit)
    }

    var autoSwitchMonitoringNotice: String? {
        _ = monitoringDate
        guard autoSwitchEnabled else { return nil }
        if autoSwitchPausedByManualLogin {
            return L10n.tr("auto_switch.paused_manual_login")
        }
        guard let activeAccountUuid, freshUsage(for: activeAccountUuid) != nil else {
            return L10n.tr("auto_switch.monitoring_stale")
        }
        return nil
    }

    /// Instantánea válida para tomar decisiones: descarta datos más viejos de
    /// dos intervalos de sondeo y ventanas cuyo reseteo ya pasó (su porcentaje
    /// ya no refleja la realidad).
    private func freshUsage(for accountUuid: String) -> UsageSnapshot? {
        guard let snapshot = usageByAccount[accountUuid] else { return nil }
        guard !isUsageStale(for: accountUuid) else { return nil }
        // An expired window is unknown until refreshed, not evidence of 0%.
        let windows = [snapshot.fiveHour, snapshot.sevenDay, snapshot.sevenDayOpus]
        guard !windows.contains(where: { window in
            window?.resetsAt.map { $0 <= Date() } ?? false
        }) else { return nil }
        return snapshot
    }

    /// Situación de cada cuenta tal y como la ve la política.
    ///
    /// Para la política, el uso de las cuentas compartidas se reescala a su
    /// tope personal: así el cambio salta antes y deja margen a la otra persona.
    private func autoSwitchStates() -> [AccountUsageState] {
        profilesList.map { profile in
            AccountUsageState(
                accountUuid: profile.accountUuid,
                usage: freshUsage(for: profile.accountUuid)?
                    .scaledToPersonalCaps(fiveHourCap: profile.sharedFiveHourCap, weeklyCap: profile.sharedWeeklyCap),
                needsLogin: profile.needsLogin
            )
        }
    }

    private func autoSwitchCandidate(
        policy: AutoSwitchPolicy, active: AccountUsageState, states: [AccountUsageState]
    ) -> String? {
        let now = Date()
        let recentlyVerified = states.filter {
            $0.usage.map { now.timeIntervalSince($0.fetchedAt) < 60 } ?? false
        }
        if let verified = policy.bestCandidate(active: active, others: recentlyVerified) {
            return verified
        }
        // Do not let the cheapest cached account hold up a usable alternative
        // while its usage endpoint is in cooldown.
        return policy.bestCandidate(active: active, others: states.filter {
            rateLimitedUntilByAccount[$0.accountUuid].map { $0 <= now } ?? true
        })
    }

    private func runAutoSwitchIfNeeded() async {
        guard autoSwitchEnabled, let active = activeAccountUuid else { return }
        guard !isSwitchingAccount, !isEvaluatingAutoSwitch, !addAccountVisible, !addAccountBusy else { return }
        // Un login manual reciente manda: no se le cambia la cuenta al usuario
        // justo después de que la haya elegido a mano en la terminal.
        guard !autoSwitchPausedByManualLogin else { return }
        isEvaluatingAutoSwitch = true
        defer { isEvaluatingAutoSwitch = false }

        let policy = AutoSwitchPolicy(
            triggerThreshold: triggerThreshold,
            weeklyThreshold: weeklyTriggerThreshold,
            fableThreshold: fableTriggerThreshold,
            considersFable: useFableForAutoSwitch
        )
        var states = autoSwitchStates()
        guard var activeState = states.first(where: { $0.accountUuid == active }) else { return }
        guard policy.shouldSwitch(active: activeState) else {
            lastNoCandidateNotice = nil
            return
        }
        var target = autoSwitchCandidate(policy: policy, active: activeState, states: states)
        // Antes de darse por vencido: las cuentas descartadas solo por no
        // tener datos vigentes se consultan ahora mismo. Sin esto, una racha
        // de pausas del servidor las deja fuera durante horas y el aviso
        // acaba afirmando lo contrario de lo que enseña el panel.
        if target == nil {
            let unverified = states.filter {
                $0.accountUuid != active
                    && policy.rejection(for: $0) == .noUsageData
            }.map(\.accountUuid)
            if await refreshUnverifiedAccounts(unverified) {
                // Esas consultas llevan su tiempo: si entre medias el usuario
                // ha cambiado de cuenta a mano, la decisión ya no es válida.
                guard activeAccountUuid == active, !isSwitchingAccount,
                      autoSwitchEnabled, !autoSwitchPausedByManualLogin else {
                    return
                }
                states = autoSwitchStates()
                guard let refreshed = states.first(where: {
                    $0.accountUuid == active
                }) else { return }
                activeState = refreshed
                guard policy.shouldSwitch(active: activeState) else {
                    lastNoCandidateNotice = nil
                    return
                }
                target = autoSwitchCandidate(policy: policy, active: activeState, states: states)
            }
        }
        let triggerDescription = autoSwitchTriggerDescription(activeState)
        guard let target else {
            notifyNoCandidate(policy: policy, states: states, active: active)
            return
        }
        // A standby account may have kept consuming in an older terminal.
        // Verify the destination before writing credentials, using the same
        // admission gate; a blocked request leaves the decision pending.
        if usageByAccount[target].map({ Date().timeIntervalSince($0.fetchedAt) >= 60 }) ?? true {
            guard await performUsageRefresh(target) == .attempted,
                  usageByAccount[target].map({ Date().timeIntervalSince($0.fetchedAt) < 60 }) == true
            else { return }
        }
        guard autoSwitchEnabled, !autoSwitchPausedByManualLogin,
              activeAccountUuid == active, !isSwitchingAccount,
              let verifiedActive = autoSwitchStates().first(where: { $0.accountUuid == active }),
              let verifiedTarget = autoSwitchStates().first(where: { $0.accountUuid == target }),
              policy.shouldSwitch(active: verifiedActive), policy.isCandidate(verifiedTarget)
        else { return }
        lastNoCandidateNotice = nil
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

    /// Consulta ya mismo las cuentas cuyo uso no se conoce, de una en una y
    /// separadas entre sí: el endpoint castiga las ráfagas. Las que estén en
    /// pausa del servidor se saltan solas. Devuelve `true` si alguna consulta
    /// llegó a hacerse, que es cuando merece la pena volver a decidir.
    private func refreshUnverifiedAccounts(
        _ accountUuids: [String]
    ) async -> Bool {
        var attempted = false
        for accountUuid in accountUuids {
            guard !Task.isCancelled else { break }
            if await performUsageRefresh(accountUuid) == .attempted {
                attempted = true
                break
            }
        }
        return attempted
    }

    private enum NoCandidateReason: Equatable {
        /// Todas las demás cuentas tienen datos vigentes y están al límite.
        case allAtLimit
        /// De alguna cuenta no se sabe nada: sin datos vigentes o sin sesión.
        case unverified
    }

    /// Avisa de que no hay a dónde cambiar, diciendo la verdad sobre el motivo
    /// y sin repetirse en cada vuelta del sondeo: solo cuando cambia el motivo
    /// o cuando ha pasado un buen rato desde el último aviso igual.
    private func notifyNoCandidate(
        policy: AutoSwitchPolicy,
        states: [AccountUsageState],
        active: String
    ) {
        let others = states.filter { $0.accountUuid != active }
        let reason: NoCandidateReason =
            others.allSatisfy { policy.rejection(for: $0) == .atLimit }
                ? .allAtLimit
                : .unverified
        if let last = lastNoCandidateNotice,
           last.reason == reason,
           Date().timeIntervalSince(last.at) < noCandidateNoticeInterval {
            return
        }
        lastNoCandidateNotice = (reason, Date())
        switch reason {
        case .allAtLimit:
            Notifier.notify(
                title: L10n.tr("auto_switch.no_available.title"),
                body: L10n.tr(
                    "auto_switch.no_available.body",
                    nextResetText(states: states)
                )
            )
        case .unverified:
            Notifier.notify(
                title: L10n.tr("auto_switch.unverified.title"),
                body: L10n.tr("auto_switch.unverified.body")
            )
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
    /// Petición de login en curso iniciada desde la app. Guarda el
    /// verificador PKCE, que solo vive en memoria durante el alta.
    private(set) var loginFlow: OAuthLoginFlow?
    private var enrollmentSession: OAuthEnrollmentSession?
    /// Código que el usuario pega desde el navegador.
    var pastedLoginCode = ""

    func beginAddAccount() {
        guard !addAccountBusy else { return }
        reconnectingProfile = nil
        addAccountError = nil
        resetLoginFlow()
        addAccountVisible = true
    }

    func beginReconnect(_ profile: AccountProfile) {
        guard !addAccountBusy else { return }
        reconnectingProfile = profile
        addAccountError = nil
        resetLoginFlow()
        addAccountVisible = true
    }

    private func resetLoginFlow() {
        loginFlow = nil
        enrollmentSession = nil
        pastedLoginCode = ""
    }

    // MARK: Alta sin terminal (autorización desde la propia app)

    /// Abre la pantalla oficial de inicio de sesión de Anthropic.
    ///
    /// Cada pulsación crea una petición nueva: reutilizar el verificador de
    /// un intento anterior haría que el canje fuese rechazado.
    func startInAppLogin() {
        guard !addAccountBusy else { return }
        let flow = OAuthLoginFlow()
        loginFlow = flow
        enrollmentSession = OAuthEnrollmentSession(api: api, flow: flow)
        pastedLoginCode = ""
        addAccountError = nil
        NSWorkspace.shared.open(flow.authorizationURL)
    }

    /// Canjea el código pegado, obtiene la identidad de la cuenta y la
    /// guarda como perfil. No toca la sesión de Claude Code: la cuenta se
    /// añade al almacén privado y el usuario decide cuándo cambiar a ella.
    func completeInAppLogin() async {
        guard !addAccountBusy, !isSwitchingAccount,
              let flow = loginFlow, let enrollmentSession else { return }
        guard let code = flow.normalizedCode(from: pastedLoginCode) else {
            addAccountError = L10n.tr("add_account.error.bad_code")
            return
        }
        addAccountBusy = true
        addAccountError = nil
        defer { addAccountBusy = false }

        let profiles = self.profiles
        let target = reconnectingProfile
        do {
            let enrolled = try await enrollmentSession.complete(code: code)
            let identity = enrolled.identity
            if let target, identity.accountUuid != target.accountUuid {
                addAccountError = L10n.tr(
                    "state.unexpected_reconnect_account",
                    identity.emailAddress,
                    target.emailAddress
                )
                return
            }
            let credentials = enrolled.credentials
            _ = try await offMain {
                Result {
                    try profiles.saveProfile(
                        identity: identity,
                        credentials: credentials
                    )
                }
            }.get()
            resetLoginFlow()
            reconnectingProfile = nil
            addAccountVisible = false
            infoMessage = target == nil
                ? L10n.tr("state.account_added", identity.emailAddress)
                : L10n.tr("state.account_reconnected", identity.emailAddress)
            await accountDidConnect(identity.accountUuid)
        } catch AnthropicAPIError.invalidGrant {
            addAccountError = L10n.tr("add_account.error.code_rejected")
        } catch AnthropicAPIError.malformedResponse {
            addAccountError = L10n.tr("add_account.error.profile_unreadable")
        } catch {
            addAccountError = L10n.tr(
                "state.enrollment_failed",
                describe(error)
            )
        }
    }

    /// Clear session failures after a successful login, while retaining any
    /// usage Retry-After deadline. The newly linked account gets the next
    /// available standby slot, even when its cached usage looked recent.
    private func accountDidConnect(_ accountUuid: String) async {
        let usageDeadline = rateLimitedUntilByAccount[accountUuid]
        clearUsageCooldown(for: accountUuid)
        rateLimitedUntilByAccount[accountUuid] = usageDeadline
        persistUsageCooldowns()
        usageByAccount[accountUuid] = nil
        usagePollingSchedule.forgetAttempt(for: accountUuid)
        pendingInitialUsageAccounts.insert(accountUuid)
        persistUsageCache()
        await reloadLocalState()
        await refreshUsageAccount(accountUuid, force: true)
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
        guard !addAccountBusy, !isSwitchingAccount else { return }
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
            resetLoginFlow()
            reconnectingProfile = nil
            addAccountVisible = false
            infoMessage = target == nil
                ? L10n.tr("state.account_added", saved.emailAddress)
                : L10n.tr("state.account_reconnected", saved.emailAddress)
            await accountDidConnect(saved.accountUuid)
        case .failure(SwitchError.unexpectedActiveAccount(_, _)):
            // Casi siempre ocurre porque el navegador ya tenía abierta la
            // sesión de otra cuenta y el login oficial la autorizó sin
            // preguntar. Nombrar la cuenta que quedó activa evita repetir
            // el mismo intento a ciegas.
            let store = self.store
            let actualEmail = await offMain {
                (try? store.readActiveIdentity())?.emailAddress
            }
            if let target {
                addAccountError = L10n.tr(
                    "state.unexpected_reconnect_account",
                    actualEmail ?? "—",
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
        guard !addAccountBusy else { return }
        resetLoginFlow()
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
