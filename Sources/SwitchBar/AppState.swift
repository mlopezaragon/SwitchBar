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
    private let historyStore: UsageHistoryStore

    // MARK: Estado observable

    private(set) var profilesList: [AccountProfile] = []
    private(set) var usageByAccount: [String: UsageSnapshot] = [:]
    private(set) var activeProfileID: String?
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
    var anticipateExpiringQuota: Bool {
        didSet { preferences.anticipateExpiringQuota = anticipateExpiringQuota }
    }
    var switchByPace: Bool {
        didSet { preferences.switchByPace = switchByPace }
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
    /// Cuentas cuya sesión se está renovando ahora mismo. Un cambio de cuenta
    /// espera a que terminen: copiaría al Llavero de Claude Code un refresh
    /// token que Anthropic invalida al rotarlo.
    private var renewingAccounts: Set<String> = []
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
    /// Último cambio automático. Adelantarse a un cupo que caduca espera un
    /// rato después de cualquier cambio, para que unos datos que oscilan no
    /// hagan saltar de una cuenta a otra.
    private var lastAutomaticSwitchAt: Date?
    private let expiringQuotaSwitchCooldown: TimeInterval = 10 * 60
    /// Cuentas de las que el usuario salió a mano, hasta su reinicio semanal.
    /// Ver `AccountUsageState.leftByUser`.
    private var leftByUserUntil: [String: Date] = [:]
    /// Lecturas recientes de cada cuenta, para medir a qué ritmo se gastan.
    private var usageHistory = UsageHistory()
    /// Ritmo habitual de cada cuenta y de cada plan, recalculado al llegar
    /// lecturas nuevas.
    private(set) var paceModel = PaceModel()
    private var lastHistorySave: Date?
    private let historySaveInterval: TimeInterval = 5 * 60
    /// Último aviso de que se va a acabar el cupo, para no repetirlo.
    private var lastCoverageNotice: (runsOutAt: Date, at: Date)?

    // MARK: Ciclo de vida

    init(store: ClaudeCodeStore = ClaudeCodeStore(),
         profiles: ProfileStore = ProfileStore(),
         api: AnthropicAPI = AnthropicAPI(),
         statusAPI: AnthropicStatusAPI = AnthropicStatusAPI(),
         preferences: AppPreferences = AppPreferences(),
         usageCache: UsageSnapshotCache = UsageSnapshotCache(),
         historyStore: UsageHistoryStore = UsageHistoryStore()) {
        self.store = store
        self.profiles = profiles
        self.preferences = preferences
        self.usageCache = usageCache
        self.historyStore = historyStore
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
        self.anticipateExpiringQuota = preferences.anticipateExpiringQuota
        self.switchByPace = preferences.switchByPace
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
        self.leftByUserUntil = Self.loadCooldowns(
            preferences.leftByUserTimestamps,
            maximum: 7 * 24 * 3_600
        )
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
            adoptLegacyProfileKeys()
            await restoreCachedUsage()
            await restoreUsageHistory()
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
            let initialProfileID = initialIdentity?.id
            let previouslyObserved =
                self.preferences.lastObservedAccountUuid
            self.identityTracker = ActiveIdentityTracker(
                profileID: initialProfileID
            )
            if let previouslyObserved,
               let initialProfileID,
               previouslyObserved != initialProfileID,
               // La 1.0.3 y anteriores guardaban solo el accountUuid.
               !initialProfileID.hasPrefix(previouslyObserved + "/") {
                // La identidad cambió mientras SwitchBar estaba cerrado:
                // esta sí es una elección externa que conviene respetar.
                self.manualLoginAt = Date()
                self.recordManualChoice(initialProfileID, leaving: previouslyObserved)
            }
            self.preferences.lastObservedAccountUuid = initialProfileID
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

                let previousProfileID = self.identityTracker.profileID
                let change = self.identityTracker.observe(
                    profileID: identity.id,
                    expectedAppProfileID: self.lastSwitchByApp
                )
                if change == .unchanged {
                    // Claude Code reescribe este fichero por otros motivos.
                    // No renovar la pausa ni volver a consultar el uso.
                    if identity.id == self.lastSwitchByApp {
                        self.lastSwitchByApp = nil
                    }
                    continue
                }
                self.lastSwitchByApp = nil
                self.preferences.lastObservedAccountUuid =
                    identity.id
                if change == .manual {
                    self.manualLoginAt = Date()
                    self.recordManualChoice(identity.id, leaving: previousProfileID)
                    self.infoMessage = nil
                    // Claude Code termina de confirmar el Llavero alrededor
                    // de la escritura de ~/.claude.json. Un breve margen evita
                    // capturar el par a medio actualizar.
                    try? await Task.sleep(for: .milliseconds(750))
                    if self.profilesList.contains(where: {
                        $0.id == identity.id
                    }) {
                        let result = await self.offMain {
                            Result { try engine.syncActiveIntoProfile() }
                        }
                        switch result {
                        case .success:
                            self.clearUsageCooldown(
                                for: identity.id
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

    /// El usuario eligió `chosen` a mano dejando `previous`. La elegida se
    /// respeta hasta que llegue a un límite; la abandonada queda para el final
    /// hasta su reinicio semanal (o un día, si no se conoce). Una cuenta sin
    /// límite semanal a la vista (Team) solo puede haberse dejado por su
    /// ventana de 5 h: queda para el final hasta que esa ventana se reinicie.
    private func recordManualChoice(_ chosen: String, leaving previous: String?) {
        preferences.manuallyChosenProfileID = chosen
        let now = Date()
        leftByUserUntil = leftByUserUntil.filter { $0.key != chosen && $0.value > now }
        if let previous, previous != chosen, let usage = usageByAccount[previous] {
            if usage.weeklyLimitUnreported {
                if let reset = usage.fiveHour?.resetsAt, reset > now {
                    leftByUserUntil[previous] = reset
                }
            } else {
                let reset = autoSwitchPolicy.weeklyDeadline(usage).flatMap { $0 > now ? $0 : nil }
                leftByUserUntil[previous] = min(
                    reset ?? now.addingTimeInterval(24 * 3_600),
                    now.addingTimeInterval(7 * 24 * 3_600)
                )
            }
        } else if let previous, previous != chosen {
            leftByUserUntil[previous] = now.addingTimeInterval(24 * 3_600)
        }
        preferences.leftByUserTimestamps =
            leftByUserUntil.mapValues(\.timeIntervalSince1970)
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
                self.notifyCoverageIfNeeded()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Rellena el panel con la última instantánea guardada de cada cuenta,
    /// sin esperar a la red. Las consultas posteriores las van sustituyendo.
    private func restoreCachedUsage() async {
        let usageCache = self.usageCache
        let loaded = await offMain { usageCache.load() }
        guard !loaded.isEmpty else { return }
        let cached = ProfileID.adoptingLegacyKeys(loaded, profiles: profilesList)
        for (account, snapshot) in cached
        where usageByAccount[account] == nil {
            usageByAccount[account] = snapshot
        }
        if let activeProfileID,
           let restored = usageByAccount[activeProfileID] {
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

    // MARK: Ritmo de uso

    private func restoreUsageHistory() async {
        let historyStore = self.historyStore
        var history = await offMain { historyStore.load() }
        // Lecturas tomadas mientras se cargaba el fichero: no se pierden.
        for (account, samples) in usageHistory.samplesByAccount {
            for sample in samples {
                history.record(sample, for: account)
            }
        }
        usageHistory = history
        rebuildPaceModel()
    }

    /// Guarda la lectura recién traída y recalcula los ritmos si aportaba
    /// algo. El fichero se escribe como mucho cada pocos minutos: perder las
    /// últimas lecturas al cerrar la app no cambia ningún ritmo.
    private func recordUsageSample(for profileID: String) {
        guard let snapshot = usageByAccount[profileID],
              usageHistory.record(snapshot, for: profileID) else { return }
        rebuildPaceModel()
        let now = Date()
        if let lastHistorySave, now.timeIntervalSince(lastHistorySave) < historySaveInterval {
            return
        }
        lastHistorySave = now
        // Las cuentas borradas se olvidan; una lista vacía (aún sin cargar)
        // no debe borrar el historial de todas.
        usageHistory.prune(
            now: now,
            keeping: profilesList.isEmpty ? nil : Set(profilesList.map(\.id))
        )
        let historyStore = self.historyStore
        let history = usageHistory
        Task.detached(priority: .utility) {
            try? historyStore.save(history)
        }
    }

    private func rebuildPaceModel() {
        let plans = Dictionary(
            profilesList.map { ($0.id, $0.plan) },
            uniquingKeysWith: { first, _ in first }
        )
        paceModel = PaceModel(history: usageHistory, plans: plans)
    }

    /// Ritmo de la cuenta activa en la última media hora, contando también
    /// la lectura más reciente aunque no se haya guardado por repetida.
    private var activeCurrentPace: PaceEstimate? {
        guard let activeProfileID else { return nil }
        var samples = usageHistory.samples(for: activeProfileID)
        if let latest = usageByAccount[activeProfileID].map(UsageSample.init),
           latest.at > (samples.last?.at ?? .distantPast) {
            samples.append(latest)
        }
        return UsagePace.current(samples, now: max(monitoringDate, Date()))
    }

    private func paceContext() -> PaceContext {
        PaceContext(
            model: paceModel,
            activeID: activeProfileID,
            activePlan: activeProfile?.plan,
            activeCurrent: activeCurrentPace
        )
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
            if let activeProfileID,
               let last = usageByAccount[activeProfileID]?.fetchedAt,
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
        var activeProfileID: String?
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
                _ = try profiles.migrateProfileKeysIfNeeded()
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

    /// Las pausas y bloqueos guardados por la 1.0.3 o anteriores usan el
    /// `accountUuid` como clave. Se trasladan al identificador de perfil para
    /// no perder una pausa del servidor que todavía siga vigente.
    private func adoptLegacyProfileKeys() {
        let profiles = profilesList
        rateLimitedUntilByAccount = ProfileID.adoptingLegacyKeys(
            rateLimitedUntilByAccount, profiles: profiles
        )
        renewalBlockedUntilByAccount = ProfileID.adoptingLegacyKeys(
            renewalBlockedUntilByAccount, profiles: profiles
        )
        renewalBlockedAccounts = Set(renewalBlockedAccounts.map {
            ProfileID.currentKey(for: $0, profiles: profiles)
        })
        preferences.renewalBlockedAccounts = renewalBlockedAccounts
        persistUsageCooldowns()
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
                    list.contains { $0.id == id.id } ? nil : id
                }
                // La cuenta en uso siempre la primera; el resto por correo.
                let activeUuid = identity?.id
                list.sort { a, b in
                    if (a.id == activeUuid)
                        != (b.id == activeUuid) {
                        return a.id == activeUuid
                    }
                    return a.emailAddress.localizedCaseInsensitiveCompare(
                        b.emailAddress
                    ) == .orderedAscending
                }
                return LocalLoadOutcome(
                    snapshot: LocalSnapshot(
                        profiles: list,
                        activeProfileID: identity?.id,
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
        activeProfileID = snapshot.activeProfileID
        lastRefreshAt = activeProfileID.flatMap { usageByAccount[$0]?.fetchedAt }
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

    /// Anota si el servidor informó de restablecimientos: el bloque no está
    /// documentado y así se ve enseguida si deja de llegar. Sin secretos.
    private func logLimitResets(_ usage: UsageSnapshot, for profileID: String) {
        let summary = usage.limitResets.map { resets in
            "\(resets.resetsLeft())/\(resets.resetsTotal()) en \(resets.grants.count) lote(s), elegible: \(resets.eligible)"
        } ?? "sin bloque"
        Diagnostics.usage.debug(
            "\(Diagnostics.tag(profileID), privacy: .public) restablecimientos: \(summary, privacy: .public)"
        )
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
    func isRenewalBlocked(for profileID: String) -> Bool {
        renewalBlockedAccounts.contains(profileID)
    }

    /// Conviene ofrecerle al usuario reconectar esta cuenta.
    ///
    /// Solo cuando el problema es la sesión: Anthropic no deja renovarla y
    /// reconectar emite credenciales nuevas al instante. Antes bastaba con
    /// que los datos llevaran una hora parados, por cualquier causa, y una
    /// pausa del endpoint de uso acababa pidiendo un login que no arreglaba
    /// nada que no arreglara esperar. El registro lo confirmó: ninguna de esas
    /// sesiones había caducado. La antigüedad de los datos ya se indica en la
    /// tarjeta, y la renovación aparcada sobrevive a los reinicios.
    func suggestsReconnect(for profileID: String) -> Bool {
        guard !profilesList.contains(where: {
            $0.id == profileID && $0.needsLogin
        }) else { return false }
        return renewalBlockedAccounts.contains(profileID)
    }

    private func markRenewalBlocked(
        _ profileID: String,
        _ blocked: Bool
    ) {
        let changed = blocked
            ? renewalBlockedAccounts.insert(profileID).inserted
            : renewalBlockedAccounts.remove(profileID) != nil
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
        guard let activeProfileID else {
            usageRefreshNotice = nil
            return
        }
        await refreshUsageAccount(activeProfileID, force: force)
    }

    /// Ritmo de la cuenta activa. Solo se acelera cerca de un umbral cuando
    /// el cambio automático está activado: sin él, nadie actúa sobre ese dato
    /// y acelerar solo gastaría el cupo de consultas de la cuenta.
    private var activeUsageInterval: TimeInterval {
        guard autoSwitchEnabled else {
            return UsagePollingSchedule.activeInterval(nearLimit: false)
        }
        let usage = activeProfileID.flatMap { uuid in
            let profile = profilesList.first { $0.id == uuid }
            return usageByAccount[uuid]?.scaledToPersonalCaps(
                fiveHourCap: profile?.sharedFiveHourCap,
                weeklyCap: profile?.sharedWeeklyCap
            )
        }
        let nearLimit = (usage?.fiveHour?.utilization ?? 0) >= triggerThreshold - 15
            || (usage?.sevenDay?.utilization ?? 0) >= weeklyTriggerThreshold - 10
            || (useFableForAutoSwitch && (usage?.sevenDayOpus?.utilization ?? 0) >= fableTriggerThreshold - 10)
            || activeTimeToFiveHourLimit.map { $0 <= paceNearLimit } ?? false
        return UsagePollingSchedule.activeInterval(nearLimit: nearLimit)
    }

    /// Al ritmo actual, la activa se agotaría en menos de esto: se mira más
    /// a menudo para cambiar a tiempo.
    private let paceNearLimit: TimeInterval = 45 * 60

    private var activeTimeToFiveHourLimit: TimeInterval? {
        guard let activeProfileID,
              let active = autoSwitchStates().first(where: { $0.id == activeProfileID })
        else { return nil }
        return autoSwitchPolicy.timeToFiveHourLimit(active)
    }

    private func refreshNextScheduledAccount() async {
        await reloadLocalState()
        let now = Date()
        clearExpiredUsageCooldowns(now: now)
        clearExpiredRenewalBlocks(now: now)
        let refreshable = profilesList.filter { !$0.needsLogin }
        let blocked: Set<String> = Set(
            refreshable.compactMap { profile in
                if let until = rateLimitedUntilByAccount[profile.id],
                   until > now {
                    return profile.id
                }
                // Su token caducó y el endpoint de renovación está aparcado:
                // esta cuenta no puede conseguir nada hasta que el aparcado
                // expire. Sin esta salvedad su intento fallaba sin actualizar
                // la fecha del dato, así que el filtro de frescura no la
                // apartaba nunca y volvía a llevarse el turno cada vuelta,
                // dejando sin él a las cuentas que sí podían actualizarse.
                // Solo aplica a las inactivas: a la activa puede renovársela
                // Claude Code en cualquier momento.
                if profile.id != activeProfileID,
                   case .renewalBlocked = usageIssueByAccount[
                       profile.id
                   ],
                   let until = renewalBlockedUntilByAccount[
                       profile.id
                   ],
                   until > now {
                    return profile.id
                }
                return nil
            }
        )
        Diagnostics.usage.debug(
            "turno: \(refreshable.map { Diagnostics.tag($0.id) }.joined(separator: ","), privacy: .public) | en pausa: \(blocked.map(Diagnostics.tag).joined(separator: ","), privacy: .public)"
        )
        guard let target = usagePollingSchedule.nextAccount(
            accounts: refreshable.map(\.id),
            active: activeProfileID,
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
        _ profileID: String,
        force: Bool = false
    ) async {
        guard await performUsageRefresh(profileID, force: force)
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
        _ profileID: String,
        force: Bool = false
    ) async -> UsageRefreshAttempt {
        if isRefreshing {
            Diagnostics.usage.debug(
                "\(Diagnostics.tag(profileID), privacy: .public) omitida: otra consulta en curso"
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
            $0.id == profileID && !$0.needsLogin
        }) else {
            Diagnostics.usage.debug(
                "\(Diagnostics.tag(profileID), privacy: .public) omitida: sin perfil utilizable"
            )
            updateActiveUsageNotice()
            return .skipped
        }
        if let until = rateLimitedUntilByAccount[profileID],
           until > now {
            Diagnostics.usage.debug(
                "\(Diagnostics.tag(profileID), privacy: .public) omitida: pausa del servidor \(Int(until.timeIntervalSinceNow)) s"
            )
            updateActiveUsageNotice()
            return .skipped
        }

        // Tras un cambio de cuenta coinciden varios disparadores (vigilante de
        // identidad, apertura del panel y sondeo). Un dato muy reciente no se
        // vuelve a pedir: encadenar peticiones provoca la pausa del servidor.
        if !force,
           let fetchedAt = usageByAccount[profileID]?.fetchedAt,
           now.timeIntervalSince(fetchedAt) < 30 {
            Diagnostics.usage.debug(
                "\(Diagnostics.tag(profileID), privacy: .public) omitida: dato de hace \(Int(now.timeIntervalSince(fetchedAt))) s"
            )
            updateActiveUsageNotice()
            return .skipped
        }
        // Manual refresh and switch rescue share the same gate as the timer.
        // Force bypasses freshness only, never server cooldowns or spacing.
        guard !Task.isCancelled, usagePollingSchedule.canStart(now: Date()) else {
            return .skipped
        }
        // El cupo estimado evita provocar la pausa del servidor. Solo el botón
        // se lo salta: es una petición explícita y aislada del usuario.
        guard force || usagePollingSchedule.hasBudget(for: profileID, now: Date()) else {
            Diagnostics.usage.debug(
                "\(Diagnostics.tag(profileID), privacy: .public) omitida: sin cupo estimado de consultas"
            )
            updateActiveUsageNotice()
            return .skipped
        }
        usagePollingSchedule.recordAttempt(profileID, now: Date())
        await adoptActiveCredentialsIfFresher(profile)
        let outcome = await refreshUsage(for: profile)
        pendingInitialUsageAccounts.remove(profileID)
        Diagnostics.usage.log(
            "\(Diagnostics.tag(profileID), privacy: .public) -> \(outcome.logDescription, privacy: .public)"
        )
        switch outcome {
        case .updated, .failed:
            usagePollingSchedule.recordUsageRequest(profileID, now: Date())
        case .rateLimited(_, .usage):
            usagePollingSchedule.recordUsageRateLimit(profileID, now: Date())
        case .rateLimited(_, .renewal), .renewalUnavailable, .waitingForSession, .unchanged:
            break
        }
        switch outcome {
        case .updated:
            rateLimitedUntilByAccount[profileID] = nil
            usageRateLimitStreakByAccount[profileID] = nil
            usageIssueByAccount[profileID] = nil
            markRenewalBlocked(profileID, false)
            if profileID == activeProfileID {
                lastRefreshAt = Date()
            }
            persistUsageCache()
            recordUsageSample(for: profileID)
        case .rateLimited(let retryAfter, let source):
            let renewal = source == .renewal
            let streak = (renewal
                ? renewalRateLimitStreakByAccount[profileID]
                : usageRateLimitStreakByAccount[profileID]) ?? 0
            if renewal {
                renewalRateLimitStreakByAccount[profileID] = streak + 1
            } else {
                usageRateLimitStreakByAccount[profileID] = streak + 1
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
                renewalBlockedUntilByAccount[profileID] = until
                usageIssueByAccount[profileID] = .renewalBlocked
                markRenewalBlocked(profileID, true)
            case .usage:
                rateLimitedUntilByAccount[profileID] = until
                usageIssueByAccount[profileID] = nil
            }
        case .renewalUnavailable:
            usageIssueByAccount[profileID] = .renewalBlocked
        case .waitingForSession:
            usageIssueByAccount[profileID] = .waitingForSession
        case .failed(.server(let code)):
            usageIssueByAccount[profileID] = .server(code)
        case .failed(.connection):
            usageIssueByAccount[profileID] = .connection
        case .unchanged:
            usageIssueByAccount[profileID] = nil
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
        for profileID in expired {
            rateLimitedUntilByAccount[profileID] = nil
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
        for profileID in expired {
            renewalBlockedUntilByAccount[profileID] = nil
            markRenewalBlocked(profileID, false)
            if case .renewalBlocked = usageIssueByAccount[profileID] {
                usageIssueByAccount[profileID] = nil
            }
        }
        persistUsageCooldowns()
    }

    private func refreshUsage(
        for profile: AccountProfile
    ) async -> UsageRefreshOutcome {
        do {
            guard var creds = try await credentials(for: profile.id) else {
                markNeedsLogin(profile.id, true)
                return .unchanged
            }
            if creds.isRefreshTokenExpired() {
                markNeedsLogin(profile.id, true)
                return .unchanged
            }
            // La cuenta activa es propiedad de Claude Code: su token se
            // recoge del Llavero oficial cuando Claude Code lo renueva. Las
            // inactivas se renuevan aquí con el flujo OAuth estándar.
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
                let usage = try await api.fetchUsage(
                    accessToken: creds.accessToken
                )
                usageByAccount[profile.id] = usage
                logLimitResets(usage, for: profile.id)
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
                    let usage = try await api.fetchUsage(
                        accessToken: renewed.accessToken
                    )
                    usageByAccount[profile.id] = usage
                    logLimitResets(usage, for: profile.id)
                    return .updated
                case .failure(let outcome):
                    return outcome
                }
            }
        } catch AnthropicAPIError.rateLimited(let retryAfter) {
            Diagnostics.usage.log(
                "\(Diagnostics.tag(profile.id), privacy: .public) 429 al consultar el uso (retry-after: \(retryAfter.map { String(Int($0)) } ?? "ninguno", privacy: .public))"
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
        guard profile.id == activeProfileID else { return }
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
    /// - Cuenta inactiva: se renueva aunque queden terminales abiertas con
    ///   ella. Antes de renovar, Claude Code relee su Llavero y, si el token
    ///   ya no es el que tenía en memoria, adopta el que encuentra; la
    ///   renovación siempre usa el refresh token del Llavero, nunca uno
    ///   guardado solo en memoria (comprobado en Claude Code 2.1.309). Una
    ///   terminal anterior nunca presenta el refresh token que se rota aquí.
    ///   Exigir que no hubiera ninguna abierta dejaba estas cuentas sin
    ///   renovar en la práctica, y a las pocas horas pedían un login que no
    ///   hacía falta.
    private func renewedCredentials(
        for profile: AccountProfile,
        previousAccessToken: String,
        current creds: OAuthCredentials
    ) async -> CredentialRenewal {
        let isActive = profile.id == activeProfileID
        if isActive {
            if let synchronized = await synchronizeActiveCredentials(
                for: profile,
                previousAccessToken: previousAccessToken
            ) {
                return .success(synchronized)
            }
            return .failure(.waitingForSession)
        }
        // Un cambio de cuenta en curso podría estar copiando este mismo refresh
        // token al Llavero de Claude Code. Se deja para la próxima vuelta.
        guard !isSwitchingAccount else { return .failure(.unchanged) }
        // El endpoint de renovación está castigado para esta cuenta: pedirle
        // otra solo alargaría el castigo. Se informa sin gastar la petición.
        if let until = renewalBlockedUntilByAccount[profile.id],
           until > Date() {
            Diagnostics.usage.debug(
                "\(Diagnostics.tag(profile.id), privacy: .public) renovación aparcada \(Int(until.timeIntervalSinceNow)) s"
            )
            return .failure(.renewalUnavailable)
        }
        renewingAccounts.insert(profile.id)
        defer { renewingAccounts.remove(profile.id) }
        do {
            let refreshed = try await api.refreshAccessToken(
                refreshToken: creds.refreshToken
            )
            func epochMilliseconds(_ lifetime: TimeInterval?) -> Int? {
                lifetime.map {
                    Int(Date().addingTimeInterval($0)
                        .timeIntervalSince1970 * 1000)
                }
            }
            let updated = try creds.updating(
                accessToken: refreshed.accessToken,
                refreshToken: refreshed.refreshToken,
                expiresAt: epochMilliseconds(refreshed.expiresIn),
                refreshTokenExpiresAt: epochMilliseconds(
                    refreshed.refreshTokenExpiresIn
                )
            )
            let profiles = self.profiles
            let profileID = profile.id
            let saved = try await offMain {
                Result {
                    try profiles.updateCredentials(
                        updated,
                        for: profileID,
                        expectedAccessToken: creds.accessToken
                    )
                }
            }.get()
            guard saved else { return .failure(.unchanged) }
            renewalRateLimitStreakByAccount[profileID] = nil
            return .success(updated)
        } catch AnthropicAPIError.invalidGrant {
            markNeedsLogin(profile.id, true)
            return .failure(.unchanged)
        } catch AnthropicAPIError.rateLimited(let retryAfter) {
            Diagnostics.usage.log(
                "\(Diagnostics.tag(profile.id), privacy: .public) 429 al renovar la sesión (retry-after: \(retryAfter.map { String(Int($0)) } ?? "ninguno", privacy: .public))"
            )
            return .failure(.rateLimited(retryAfter: retryAfter, source: .renewal))
        } catch AnthropicAPIError.httpError(let code) {
            return .failure(.failed(.server(code)))
        } catch {
            return .failure(.failed(.connection(describe(error))))
        }
    }

    /// Espera a que terminen las renovaciones en curso antes de cambiar de
    /// cuenta. Cambiar a mitad de una copiaría al Llavero de Claude Code el
    /// refresh token que Anthropic está a punto de invalidar al rotarlo. El
    /// plazo cubre de sobra el máximo de una petición al endpoint de tokens.
    private func waitForPendingRenewals() async {
        let deadline = Date().addingTimeInterval(35)
        while !renewingAccounts.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
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
        guard profile.id == activeProfileID else { return nil }
        let engine = self.engine
        let result = await offMain {
            Result { try engine.syncActiveIntoProfile() }
        }
        guard case .success = result,
              let synchronized = try? await credentials(
                for: profile.id
              ),
              synchronized.accessToken != previousAccessToken,
              !synchronized.isAccessTokenExpired() else {
            return nil
        }
        clearUsageCooldown(for: profile.id)
        return synchronized
    }

    /// Los problemas de cuentas inactivas quedan reflejados por la antigüedad
    /// de sus datos, sin convertirlos en una alerta global. El aviso naranja
    /// solo aparece si la cuenta que el usuario está utilizando necesita
    /// esperar o renovar su sesión.
    private func updateActiveUsageNotice() {
        guard let activeProfileID,
              let profile = profilesList.first(where: {
                $0.id == activeProfileID
              }) else {
            usageRefreshNotice = nil
            return
        }
        if let until = rateLimitedUntilByAccount[activeProfileID],
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
        switch usageIssueByAccount[activeProfileID] {
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
            usageRefreshNotice = isUsageStale(for: activeProfileID)
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

    private func clearUsageCooldown(for profileID: String) {
        rateLimitedUntilByAccount[profileID] = nil
        renewalBlockedUntilByAccount[profileID] = nil
        usageRateLimitStreakByAccount[profileID] = nil
        usageIssueByAccount[profileID] = nil
        markRenewalBlocked(profileID, false)
        renewalRateLimitStreakByAccount[profileID] = nil
        persistUsageCooldowns()
        if profileID == activeProfileID {
            updateActiveUsageNotice()
        }
    }

    /// Credenciales para consultar el uso.
    ///
    /// Se usan siempre las del almacén privado de SwitchBar. El refresco
    /// periódico nunca consulta ni modifica "Claude Code-credentials".
    private func credentials(for profileID: String) async throws -> OAuthCredentials? {
        let profiles = self.profiles
        return try await offMain { Result { try profiles.credentials(for: profileID) } }.get()
    }

    private func markNeedsLogin(_ profileID: String, _ flag: Bool) {
        let profiles = self.profiles
        Task {
            let result = await offMain {
                Result { try profiles.markNeedsLogin(profileID, flag) }
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
    /// La activa caduca antes (`activeFreshnessLimit`); un destino se vuelve
    /// a comprobar antes de cambiar porque también puede estar usándose en
    /// otra terminal.
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
    func isUsageStale(for profileID: String) -> Bool {
        guard let snapshot = usageByAccount[profileID] else { return false }
        let now = max(monitoringDate, Date())
        let limit: TimeInterval
        if profileID == activeProfileID {
            limit = activeFreshnessLimit
        } else if UsagePollingSchedule.saturatedUntil(snapshot, now: now) != nil {
            // Agotada: se consulta de hora en hora porque su uso no cambia.
            limit = UsagePollingSchedule.saturatedRecheckInterval + usageFreshnessLimit
        } else {
            limit = usageFreshnessLimit
        }
        return now.timeIntervalSince(snapshot.fetchedAt) >= limit
    }

    /// Antigüedad a partir de la cual los datos de la cuenta activa son
    /// viejos: dos turnos de su ritmo normal más la separación entre
    /// peticiones. Con menos, cada turno ordinario la marcaría como vieja.
    private var activeFreshnessLimit: TimeInterval {
        2 * UsagePollingSchedule.activeInterval(nearLimit: false)
            + UsagePollingSchedule.minimumSpacing
    }

    var autoSwitchMonitoringNotice: String? {
        _ = monitoringDate
        guard autoSwitchEnabled else { return nil }
        if autoSwitchPausedByManualLogin {
            return L10n.tr("auto_switch.paused_manual_login")
        }
        guard let activeProfileID, freshUsage(for: activeProfileID) != nil else {
            return L10n.tr("auto_switch.monitoring_stale")
        }
        return nil
    }

    /// Instantánea válida para tomar decisiones: descarta datos más viejos de
    /// dos intervalos de sondeo y ventanas cuyo reseteo ya pasó (su porcentaje
    /// ya no refleja la realidad).
    private func freshUsage(for profileID: String) -> UsageSnapshot? {
        guard let snapshot = usageByAccount[profileID] else { return nil }
        guard !isUsageStale(for: profileID) else { return nil }
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
    private func autoSwitchStates(context: PaceContext? = nil) -> [AccountUsageState] {
        let context = context ?? paceContext()
        return profilesList.map { profile in
            let isActive = profile.id == activeProfileID
            // Con un tope personal, cada punto real es más de un punto propio.
            let fiveHourScale = 100 / (profile.sharedFiveHourCap ?? 100)
            let weeklyScale = 100 / (profile.sharedWeeklyCap ?? 100)
            let usage = freshUsage(for: profile.id)?
                .scaledToPersonalCaps(fiveHourCap: profile.sharedFiveHourCap, weeklyCap: profile.sharedWeeklyCap)
            return AccountUsageState(
                id: profile.id,
                usage: usage,
                needsLogin: profile.needsLogin,
                leftByUser: isLeftByUser(profile.id, usage: usage),
                hasPersonalCap: profile.sharedFiveHourCap != nil || profile.sharedWeeklyCap != nil,
                fiveHourPace: context.expectedPace(
                    for: profile.id, plan: profile.plan, isActive: isActive
                ).map { $0 * fiveHourScale },
                fiveHourPaceUpper: isActive
                    ? context.activeCurrent.map { $0.upperPointsPerHour * fiveHourScale }
                    : nil,
                weeklyPerFiveHour: context.weeklyPerFiveHour(
                    for: profile.id, plan: profile.plan
                ).map { $0 * weeklyScale / fiveHourScale }
            )
        }
    }

    /// Ver `recordManualChoice`. En una cuenta sin límite semanal a la vista
    /// solo cuenta mientras siga abierta una ventana de 5 h: así tampoco
    /// pesan las marcas guardadas por versiones que la apartaban hasta el
    /// reinicio de Fable.
    private func isLeftByUser(_ profileID: String, usage: UsageSnapshot?) -> Bool {
        let now = Date()
        guard let until = leftByUserUntil[profileID], until > now else { return false }
        guard usage?.weeklyLimitUnreported == true else { return true }
        return usage?.fiveHour?.resetsAt.map { $0 > now } ?? false
    }

    private var autoSwitchPolicy: AutoSwitchPolicy {
        AutoSwitchPolicy(
            triggerThreshold: triggerThreshold,
            weeklyThreshold: weeklyTriggerThreshold,
            fableThreshold: fableTriggerThreshold,
            considersFable: useFableForAutoSwitch,
            anticipatesExpiringQuota: anticipateExpiringQuota,
            switchesByPace: switchByPace
        )
    }

    /// Datos de hace menos de un minuto: sirven para cambiar sin volver a
    /// preguntar al servidor.
    private func isRecentlyVerified(_ profileID: String, now: Date = Date()) -> Bool {
        usageByAccount[profileID].map { now.timeIntervalSince($0.fetchedAt) < 60 } ?? false
    }

    /// Antes se preferían las cuentas consultadas en el último minuto aunque
    /// hubiera otras mejores, y eso deshacía el orden de la política: ganaba
    /// la que el sondeo acababa de visitar, no la que más convenía. El destino
    /// se verifica de todos modos antes de cambiar.
    private func autoSwitchCandidate(
        policy: AutoSwitchPolicy, active: AccountUsageState, states: [AccountUsageState]
    ) -> String? {
        policy.bestCandidate(active: active, others: verifiableStates(states))
    }

    /// Do not let an account whose usage endpoint is in cooldown hold up a
    /// usable alternative: it could not be verified before switching.
    private func verifiableStates(_ states: [AccountUsageState]) -> [AccountUsageState] {
        let now = Date()
        return states.filter {
            isRecentlyVerified($0.id, now: now)
                || (rateLimitedUntilByAccount[$0.id].map { $0 <= now } ?? true)
        }
    }

    /// Cuenta a la que iría el cambio automático si la activa llegara ahora a
    /// un límite. El panel la señala para que el orden no sea un misterio.
    var nextAutoSwitchTarget: String? {
        _ = monitoringDate
        guard autoSwitchEnabled, let activeProfileID else { return nil }
        let states = autoSwitchStates()
        guard let active = states.first(where: { $0.id == activeProfileID }) else { return nil }
        return autoSwitchCandidate(policy: autoSwitchPolicy, active: active, states: states)
    }

    /// Hasta cuándo alcanza el cupo de todas las cuentas si se sigue
    /// trabajando, con el cambio automático eligiendo la siguiente. Solo con
    /// el cambio automático y el ritmo activados: sin ellos no describiría lo
    /// que va a pasar.
    var coverageForecast: CoverageForecast? {
        _ = monitoringDate
        guard autoSwitchEnabled, switchByPace, let activeProfileID else { return nil }
        let context = paceContext()
        return CoveragePlanner.forecast(
            activeID: activeProfileID,
            states: autoSwitchStates(context: context),
            policy: autoSwitchPolicy,
            basis: context.basis,
            now: max(monitoringDate, Date())
        )
    }

    /// Ritmos medidos, para explicarlos en la ventana de detalle.
    struct PaceSummary {
        var activeEmail: String?
        /// Puntos de 5 h por hora en la cuenta activa ahora mismo.
        var currentPace: Double?
        var plans: [(plan: AccountPlan, pace: TypicalPace)]
    }

    var paceSummary: PaceSummary {
        let current = activeCurrentPace.flatMap {
            $0.pointsPerHour >= PaceContext.workingPace ? $0.pointsPerHour : nil
        }
        return PaceSummary(
            activeEmail: activeProfile?.emailAddress,
            currentPace: current,
            plans: paceModel.byPlan
                .map { (plan: $0.key, pace: $0.value) }
                .sorted { $0.plan.rawValue < $1.plan.rawValue }
        )
    }

    /// Avisa una vez, con margen, de que al ritmo actual todas las cuentas
    /// van a llegar a su límite. Solo mientras se está trabajando: al ritmo
    /// habitual es una hipótesis, no algo que vaya a pasar.
    private func notifyCoverageIfNeeded() {
        guard let forecast = coverageForecast,
              forecast.basis == .currentPace,
              let runsOutAt = forecast.runsOutAt else { return }
        let now = Date()
        let lead = runsOutAt.timeIntervalSince(now)
        guard lead > 0, lead <= coverageNoticeLead else { return }
        if let last = lastCoverageNotice,
           abs(last.runsOutAt.timeIntervalSince(runsOutAt)) < 30 * 60,
           now.timeIntervalSince(last.at) < 2 * 3_600 {
            return
        }
        lastCoverageNotice = (runsOutAt, now)
        let body = forecast.resumesAt.map {
            L10n.tr(
                "forecast.notification.body",
                ResetFormatter.compact(runsOutAt),
                ResetFormatter.absolute($0)
            )
        } ?? L10n.tr("forecast.notification.body_open", ResetFormatter.compact(runsOutAt))
        Notifier.notify(title: L10n.tr("forecast.notification.title"), body: body)
    }

    private let coverageNoticeLead: TimeInterval = 45 * 60

    private func runAutoSwitchIfNeeded() async {
        guard autoSwitchEnabled, let active = activeProfileID else { return }
        guard !isSwitchingAccount, !isEvaluatingAutoSwitch, !addAccountVisible, !addAccountBusy else { return }
        // Un login manual reciente manda: no se le cambia la cuenta al usuario
        // justo después de que la haya elegido a mano en la terminal.
        guard !autoSwitchPausedByManualLogin else { return }
        isEvaluatingAutoSwitch = true
        defer { isEvaluatingAutoSwitch = false }

        let policy = autoSwitchPolicy
        var states = autoSwitchStates()
        guard var activeState = states.first(where: { $0.id == active }) else { return }
        guard policy.shouldSwitch(active: activeState) else {
            lastNoCandidateNotice = nil
            await anticipateExpiringQuotaIfNeeded(policy: policy, active: activeState, states: states)
            return
        }
        var target = autoSwitchCandidate(policy: policy, active: activeState, states: states)
        // Antes de darse por vencido: las cuentas descartadas solo por no
        // tener datos vigentes se consultan ahora mismo. Sin esto, una racha
        // de pausas del servidor las deja fuera durante horas y el aviso
        // acaba afirmando lo contrario de lo que enseña el panel.
        if target == nil {
            let unverified = states.filter {
                $0.id != active
                    && policy.rejection(for: $0) == .noUsageData
            }.map(\.id)
            if await refreshUnverifiedAccounts(unverified) {
                // Esas consultas llevan su tiempo: si entre medias el usuario
                // ha cambiado de cuenta a mano, la decisión ya no es válida.
                guard activeProfileID == active, !isSwitchingAccount,
                      autoSwitchEnabled, !autoSwitchPausedByManualLogin else {
                    return
                }
                states = autoSwitchStates()
                guard let refreshed = states.first(where: {
                    $0.id == active
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
            if await waitOnFirstRecoveryIfNeeded(policy: policy, active: activeState, states: states) {
                return
            }
            notifyNoCandidate(policy: policy, states: states, active: active)
            return
        }
        guard await verifyDestination(target, from: active, isValid: { activeState, targetState, _ in
            policy.shouldSwitch(active: activeState) && policy.isCandidate(targetState)
        }) else { return }
        lastNoCandidateNotice = nil
        let pct = usageByAccount[target]?.fiveHour.map { Int($0.utilization) } ?? 0
        await switchAutomatically(
            to: target,
            body: L10n.tr("auto_switch.changed.body", triggerDescription, pct)
        )
    }

    /// Gestión autónoma: cambia sin esperar a un límite a la cuenta cuyo cupo
    /// semanal caduca antes, para que la activa guarde el suyo para después.
    /// La política nunca propone una cuenta en su umbral ni en su tope
    /// personal; una cuenta elegida a mano se respeta hasta que llegue a un
    /// límite.
    private func anticipateExpiringQuotaIfNeeded(
        policy: AutoSwitchPolicy,
        active: AccountUsageState,
        states: [AccountUsageState]
    ) async {
        guard policy.anticipatesExpiringQuota,
              preferences.manuallyChosenProfileID != active.id else { return }
        if let lastAutomaticSwitchAt,
           Date().timeIntervalSince(lastAutomaticSwitchAt) < expiringQuotaSwitchCooldown {
            return
        }
        guard let target = policy.expiringQuotaTarget(
            active: active, all: verifiableStates(states)
        ) else { return }
        guard await verifyDestination(target, from: active.id, isValid: { activeState, _, states in
            policy.expiringQuotaTarget(active: activeState, all: states) == target
        }) else { return }
        guard let targetState = autoSwitchStates().first(where: { $0.id == target }),
              let body = anticipationReason(policy: policy, target: targetState)
        else { return }
        await switchAutomatically(to: target, body: body)
    }

    /// Por qué el modo autónomo se adelanta a esta cuenta, según lo que
    /// perdería si no se usara.
    private func anticipationReason(policy: AutoSwitchPolicy, target: AccountUsageState) -> String? {
        let now = Date()
        let f = RelativeDateTimeFormatter()
        f.locale = L10n.locale
        func relative(_ date: Date) -> String { f.localizedString(for: date, relativeTo: now) }
        switch policy.urgency(target, now: now) {
        case .renewable:
            return L10n.tr("auto_switch.weekly_free.body")
        case .expiring where !policy.hasWeeklyLimit(target):
            return policy.openWindowReset(target, now: now).map {
                L10n.tr("auto_switch.open_window.body", relative($0))
            }
        case .expiring:
            return target.usage?.sevenDay?.resetsAt.map {
                L10n.tr("auto_switch.weekly_at_risk.body", relative($0))
            }
        case .reserve:
            return target.usage.flatMap(policy.weeklyDeadline).map {
                L10n.tr("auto_switch.expiring.body", relative($0))
            }
        }
    }

    /// Ninguna cuenta tiene margen: deja activa la que antes se recupera,
    /// para que Claude Code, que sigue con la cuenta activa al agotar la
    /// suya, espere lo menos posible. Devuelve `true` si ha cambiado.
    private func waitOnFirstRecoveryIfNeeded(
        policy: AutoSwitchPolicy,
        active: AccountUsageState,
        states: [AccountUsageState]
    ) async -> Bool {
        guard let target = policy.recoveryTarget(
            active: active, all: verifiableStates(states)
        ) else { return false }
        guard await verifyDestination(target, from: active.id, isValid: { activeState, _, states in
            policy.recoveryTarget(active: activeState, all: states) == target
        }) else { return false }
        guard let recoversAt = usageByAccount[target]?.fiveHour?.resetsAt else { return false }
        let f = RelativeDateTimeFormatter()
        f.locale = L10n.locale
        // Este cambio ya avisa de que no queda margen.
        lastNoCandidateNotice = (.allAtLimit, Date())
        await switchAutomatically(
            to: target,
            body: L10n.tr(
                "auto_switch.recovery.body",
                f.localizedString(for: recoversAt, relativeTo: Date())
            )
        )
        return true
    }

    /// A standby account may have kept consuming in an older terminal.
    /// Verify the destination before writing credentials, using the same
    /// admission gate: it waits for the spacing between requests, and a
    /// request blocked otherwise (budget, server pause) leaves the decision
    /// pending.
    private func verifyDestination(
        _ target: String,
        from active: String,
        isValid: (
            _ active: AccountUsageState,
            _ target: AccountUsageState,
            _ all: [AccountUsageState]
        ) -> Bool
    ) async -> Bool {
        if !isRecentlyVerified(target) {
            // El sondeo acaba de gastar el turno leyendo la activa. Sin esperar
            // a que el espaciado lo permita, esta consulta se descartaba y el
            // cambio quedaba para cuando al destino le tocara su turno: con
            // varias cuentas, minutos en los que una Team se agota entera.
            let wait = usagePollingSchedule.delayBeforeStart(now: Date())
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait + 0.2))
            }
            guard await performUsageRefresh(target) == .attempted,
                  isRecentlyVerified(target)
            else { return false }
        }
        let states = autoSwitchStates()
        guard autoSwitchEnabled, !autoSwitchPausedByManualLogin,
              activeProfileID == active, !isSwitchingAccount,
              let verifiedActive = states.first(where: { $0.id == active }),
              let verifiedTarget = states.first(where: { $0.id == target })
        else { return false }
        return isValid(verifiedActive, verifiedTarget, states)
    }

    private func switchAutomatically(to target: String, body: String) async {
        let engine = self.engine
        isSwitchingAccount = true
        defer { isSwitchingAccount = false }
        await waitForPendingRenewals()
        lastSwitchByApp = target
        let result: Result<AccountIdentity, Error> = await offMain {
            Result { try engine.switchTo(target) }
        }
        switch result {
        case .success(let identity):
            preferences.lastObservedAccountUuid = identity.id
            preferences.manuallyChosenProfileID = nil
            lastAutomaticSwitchAt = Date()
            await reloadLocalState()
            lastRefreshAt = usageByAccount[target]?.fetchedAt
            updateActiveUsageNotice()
            Notifier.notify(
                title: L10n.tr(
                    "auto_switch.changed.title",
                    identity.emailAddress
                ),
                body: body
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
        for profileID in accountUuids {
            guard !Task.isCancelled else { break }
            if await performUsageRefresh(profileID) == .attempted {
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
        let others = states.filter { $0.id != active }
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
        let policy = autoSwitchPolicy
        if !policy.reachedThreshold(active),
           let remaining = policy.timeToFiveHourLimit(active),
           remaining <= AutoSwitchPolicy.paceRunway {
            return L10n.tr(
                "auto_switch.trigger.pace",
                max(1, Int((remaining / 60).rounded()))
            )
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

    func switchTo(_ profileID: String) {
        guard !isSwitchingAccount else { return }
        isSwitchingAccount = true
        let previous = activeProfileID
        let engine = self.engine
        lastError = nil
        infoMessage = nil
        lastSwitchByApp = profileID
        Task {
            defer { isSwitchingAccount = false }
            await waitForPendingRenewals()
            let result: Result<(AccountIdentity, Bool), Error> = await offMain {
                Result {
                    do {
                        return (try engine.switchTo(profileID), false)
                    } catch let error as CoreError {
                        guard case .malformedJSON = error else {
                            throw error
                        }
                        return (
                            try engine.repairAndSwitchTo(profileID),
                            true
                        )
                    } catch SwitchError.inconsistentActiveState {
                        return (
                            try engine.repairAndSwitchTo(profileID),
                            true
                        )
                    }
                }
            }
            if case .failure = result,
               lastSwitchByApp == profileID {
                lastSwitchByApp = nil
            }
            await reloadLocalState()
            lastRefreshAt = activeProfileID.flatMap {
                usageByAccount[$0]?.fetchedAt
            }
            updateActiveUsageNotice()
            switch result {
            case .success(let outcome):
                preferences.lastObservedAccountUuid =
                    outcome.0.id
                recordManualChoice(outcome.0.id, leaving: previous)
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
        let previous = activeProfileID
        let engine = self.engine
        lastError = nil
        infoMessage = nil
        Task {
            defer { isSwitchingAccount = false }
            await waitForPendingRenewals()
            let result: Result<AccountIdentity, Error> = await offMain {
                Result { try engine.undoLastSwitch() }
            }
            await reloadLocalState()
            lastRefreshAt = activeProfileID.flatMap {
                usageByAccount[$0]?.fetchedAt
            }
            updateActiveUsageNotice()
            switch result {
            case .success(let identity):
                lastSwitchByApp = identity.id
                preferences.lastObservedAccountUuid =
                    identity.id
                recordManualChoice(identity.id, leaving: previous)
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
        addAccountOrganizationUuid = nil
        resetLoginFlow()
        addAccountVisible = true
    }

    /// Organización que se pide autorizar al añadir una cuenta; `nil` deja
    /// la predeterminada. Con el mismo correo en una Max personal y en una
    /// Team, el navegador autoriza siempre la predeterminada aunque se cambie
    /// de organización en claude.ai: solo pidiéndola explícitamente se
    /// consigue la otra.
    var addAccountOrganizationUuid: String?

    /// Organizaciones de equipo que ya aparecen en otras cuentas guardadas.
    /// Son las únicas cuyo identificador conoce la app para pedirlas.
    var knownTeamOrganizations: [OrganizationChoice] {
        var seen = Set<String>()
        return profilesList.compactMap { profile in
            guard profile.plan?.isOrganization == true,
                  let organization = profile.organizationUuid,
                  seen.insert(organization).inserted else { return nil }
            return OrganizationChoice(
                id: organization,
                name: profile.planLabel ?? organization
            )
        }
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
        let flow = OAuthLoginFlow(
            organizationUuid: reconnectingProfile?.organizationUuid
                ?? addAccountOrganizationUuid
        )
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
        let knownProfiles = Set(profilesList.map(\.id))
        do {
            let enrolled = try await enrollmentSession.complete(code: code)
            let identity = enrolled.identity
            let credentials = enrolled.credentials
            let authorized = AccountProfile(
                identity: identity,
                subscriptionType: credentials.subscriptionType
            )
            if let target, identity.id != target.id {
                addAccountError = unexpectedReconnectMessage(
                    actual: authorized,
                    target: target
                )
                return
            }
            // Se pidió una organización y Anthropic autorizó otra: guardarla
            // pisaría la sesión de esa otra organización sin que el usuario
            // lo quisiera.
            if target == nil,
               let requested = flow.organizationUuid,
               identity.organizationUuid != requested {
                addAccountError = L10n.tr(
                    "add_account.error.other_organization",
                    displayName(for: authorized, withPlan: true),
                    knownTeamOrganizations.first { $0.id == requested }?.name
                        ?? requested
                )
                return
            }
            let saved = try await offMain {
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
            await reloadLocalState()
            infoMessage = enrollmentMessage(
                for: saved,
                reconnected: target != nil,
                existed: knownProfiles.contains(saved.id)
            )
            await accountDidConnect(identity.id)
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

    /// Cómo nombrar un perfil en un mensaje. Si otro perfil comparte su
    /// correo (la misma cuenta en otra organización), o si se pide
    /// expresamente, se añade el plan: el correo solo no los distingue.
    private func displayName(
        for profile: AccountProfile,
        withPlan: Bool = false
    ) -> String {
        let sharesEmail = profilesList.contains {
            $0.id != profile.id && $0.emailAddress == profile.emailAddress
        }
        guard withPlan || sharesEmail, let label = profile.planLabel else {
            return profile.emailAddress
        }
        return "\(profile.emailAddress) (\(label))"
    }

    /// Resultado de un login: cuenta nueva, reconectada o una que ya estaba.
    /// Repetir el login de una cuenta ya añadida solo renueva su sesión, y
    /// suele significar que el navegador autorizó otra vez la misma
    /// organización cuando se quería añadir otra del mismo correo.
    private func enrollmentMessage(
        for saved: AccountProfile,
        reconnected: Bool,
        existed: Bool
    ) -> String {
        if reconnected {
            return L10n.tr("state.account_reconnected", displayName(for: saved))
        }
        if existed {
            return L10n.tr(
                "state.account_already_added",
                displayName(for: saved, withPlan: true)
            )
        }
        return L10n.tr("state.account_added", displayName(for: saved))
    }

    /// El login trajo una sesión distinta de la que se quería reconectar.
    /// Con el mismo correo, lo que cambió es la organización, y así se dice.
    private func unexpectedReconnectMessage(
        actual: AccountProfile?,
        target: AccountProfile
    ) -> String {
        if let actual, actual.accountUuid == target.accountUuid {
            return L10n.tr(
                "state.unexpected_reconnect_organization",
                actual.planLabel ?? actual.emailAddress,
                target.planLabel ?? target.emailAddress
            )
        }
        return L10n.tr(
            "state.unexpected_reconnect_account",
            actual?.emailAddress ?? "—",
            target.emailAddress
        )
    }

    /// Clear session failures after a successful login, while retaining any
    /// usage Retry-After deadline. The newly linked account gets the next
    /// available standby slot, even when its cached usage looked recent.
    private func accountDidConnect(_ profileID: String) async {
        let usageDeadline = rateLimitedUntilByAccount[profileID]
        clearUsageCooldown(for: profileID)
        rateLimitedUntilByAccount[profileID] = usageDeadline
        persistUsageCooldowns()
        usageByAccount[profileID] = nil
        usagePollingSchedule.forgetAttempt(for: profileID)
        pendingInitialUsageAccounts.insert(profileID)
        persistUsageCache()
        await reloadLocalState()
        await refreshUsageAccount(profileID, force: true)
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
        let knownProfiles = Set(profilesList.map(\.id))
        let result = await offMain {
            Result {
                try engine.captureActiveAsProfile(
                    expectedProfileID: target?.id
                )
            }
        }
        switch result {
        case .success(let saved):
            resetLoginFlow()
            reconnectingProfile = nil
            addAccountVisible = false
            await reloadLocalState()
            infoMessage = enrollmentMessage(
                for: saved,
                reconnected: target != nil,
                existed: knownProfiles.contains(saved.id)
            )
            await accountDidConnect(saved.id)
        case .failure(SwitchError.unexpectedActiveAccount(_, _)):
            // Casi siempre ocurre porque el navegador ya tenía abierta la
            // sesión de otra cuenta y el login oficial la autorizó sin
            // preguntar. Nombrar la cuenta que quedó activa evita repetir
            // el mismo intento a ciegas.
            let store = self.store
            let actual = await offMain {
                (try? store.readActiveIdentity()).flatMap {
                    AccountProfile(identity: $0, subscriptionType: nil)
                }
            }
            if let target {
                addAccountError = unexpectedReconnectMessage(
                    actual: actual,
                    target: target
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

    func setSharedCaps(fiveHour: Double?, weekly: Double?, for profileID: String) {
        let profiles = self.profiles
        Task {
            let result = await offMain {
                Result {
                    try profiles.setSharedCaps(
                        fiveHour: fiveHour,
                        weekly: weekly,
                        for: profileID
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

    func removeProfile(_ profileID: String) {
        let profiles = self.profiles
        clearUsageCooldown(for: profileID)
        Task {
            let ok = await offMain { (try? profiles.removeProfile(profileID)) != nil }
            usageByAccount[profileID] = nil
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
        profilesList.first { $0.id == activeProfileID }
    }

    /// Uso de 5 h de la cuenta activa (0–1) para el icono de la barra.
    var activeFiveHourFraction: Double? {
        guard let uuid = activeProfileID,
              let u = usageByAccount[uuid]?.fiveHour?.utilization else { return nil }
        return min(max(u / 100, 0), 1)
    }
}

/// Organización que se puede pedir al añadir una cuenta.
struct OrganizationChoice: Identifiable, Hashable {
    let id: String
    let name: String
}
