import Foundation

/// Estado de uso de una cuenta para la política de cambio automático.
public struct AccountUsageState: Sendable {
    public var id: String
    public var usage: UsageSnapshot?
    public var needsLogin: Bool
    /// El usuario salió a mano de esta cuenta y aún no ha llegado su reinicio
    /// semanal. Puede saber algo que la app no ve, como el límite semanal de
    /// Team, que Anthropic no informa: la cuenta queda para el final y el
    /// modo autónomo no vuelve a ella por su cuenta.
    public var leftByUser: Bool
    /// Cuenta compartida con un tope personal. Su uso ya llega reescalado al
    /// tope; además, nunca se deja activa para esperar a que se recupere,
    /// porque lo que gastara por encima del tope sería de la otra persona.
    public var hasPersonalCap: Bool
    /// Puntos de 5 h por hora que gastaría si se usara ahora, según el ritmo
    /// medido. `nil` si todavía no se sabe.
    public var fiveHourPace: Double?
    /// Cota alta del ritmo medido ahora mismo en esta cuenta. Solo la tiene
    /// la cuenta que se está usando; es la que decide un cambio por ritmo.
    public var fiveHourPaceUpper: Double?
    /// Puntos de la semana general que cuesta cada punto de 5 h (Max).
    public var weeklyPerFiveHour: Double?

    public init(
        id: String,
        usage: UsageSnapshot?,
        needsLogin: Bool,
        leftByUser: Bool = false,
        hasPersonalCap: Bool = false,
        fiveHourPace: Double? = nil,
        fiveHourPaceUpper: Double? = nil,
        weeklyPerFiveHour: Double? = nil
    ) {
        self.id = id
        self.usage = usage
        self.needsLogin = needsLogin
        self.leftByUser = leftByUser
        self.hasPersonalCap = hasPersonalCap
        self.fiveHourPace = fiveHourPace
        self.fiveHourPaceUpper = fiveHourPaceUpper
        self.weeklyPerFiveHour = weeklyPerFiveHour
    }
}

/// Motivo por el que una cuenta no puede recibir el cambio automático.
///
/// Distinguirlos importa: «no tiene margen» y «no se ha podido comprobar»
/// son situaciones muy distintas y merecen avisos distintos.
public enum CandidateRejection: Sendable, Equatable {
    /// Su sesión caducó: hace falta volver a iniciar sesión.
    case needsLogin
    /// Sin datos de uso vigentes; no se puede afirmar nada sobre su margen.
    case noUsageData
    /// Algún cupo relevante está en su umbral o por encima.
    case atLimit
}

/// Qué se perdería si una cuenta no se usara ahora. Ordena las candidatas
/// antes que cualquier fecha de reinicio.
public enum QuotaUrgency: Int, Sendable, Comparable {
    /// Cupo que caduca si no se gasta: la ventana de 5 h ya abierta y con
    /// margen de una cuenta sin límite semanal a la vista, o la semana de una
    /// cuenta que no daría tiempo a gastar antes de su reinicio.
    case expiring
    /// Cuenta sin límite semanal a la vista (Team) con su ventana de 5 h sin
    /// abrir: usarla no gasta cupo semanal, y su ventana vuelve a llenarse
    /// cinco horas después de abrirla.
    case renewable
    /// Cuenta con límite semanal que no corre peligro de perderse (Max): se
    /// reserva para cuando las demás no lleguen.
    case reserve

    public static func < (lhs: QuotaUrgency, rhs: QuotaUrgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Política pura (sin efectos) del cambio automático.
///
/// Disparo: la ventana de 5 h o la semana general alcanzan su umbral. Fable
/// participa únicamente cuando `considersFable` está activado. Con
/// `switchesByPace`, también cuando al ritmo medido la ventana de 5 h se
/// agotaría antes de `paceRunway`.
/// Candidatas: cuentas con sesión válida, datos de uso, y las ventanas
/// relevantes por debajo de sus respectivos umbrales. Una cuenta en su umbral
/// nunca es destino, por mucho cupo que le vaya a caducar.
/// Elección, por este orden:
/// 0. Las que el usuario no ha abandonado a mano (`leftByUser`) van antes.
/// 1. Las que tienen margen útil (`minimumUsefulRoom`) en todas sus ventanas,
///    y al ritmo medido aguantan al menos `comfortableRunway`, van antes que
///    las que obligarían a cambiar otra vez enseguida.
/// 2. Lo que se perdería si no se usa (`QuotaUrgency`): primero el cupo que
///    caduca, después las cuentas sin límite semanal a la vista (Team), que
///    solo gastan su ventana de 5 h, y por último las de límite semanal (Max),
///    que se guardan para cuando haga falta.
/// 3. Dentro de cada grupo, la que antes perdería cupo: el reinicio de una
///    ventana de 5 h ya abierta con margen o el de su semana, aunque sea por
///    minutos. Una ventana sin abrir no caduca y se guarda para después.
/// 4. La que más tiempo aguantaría sin cortarse al ritmo medido.
/// 5. Menor uso de 5 h.
/// 6. Mayor margen ponderado de los cupos semanales que estén habilitados.
///
/// Si ninguna tiene margen, `recoveryTarget` deja activa la que antes se
/// recupera, para que Claude Code siga cuanto antes.
public struct AutoSwitchPolicy: Sendable {
    public var triggerThreshold: Double
    public var weeklyThreshold: Double
    public var fableThreshold: Double
    public var considersFable: Bool
    /// Gestión autónoma: cambiar sin esperar a un límite a la cuenta que va
    /// antes en el orden de elección. Ver `expiringQuotaTarget`.
    public var anticipatesExpiringQuota: Bool
    /// Usar el ritmo medido: cambiar antes si la cuenta activa se va a
    /// agotar enseguida y no elegir destinos que se agotarían en minutos.
    public var switchesByPace: Bool

    /// Puntos hasta el umbral por debajo de los cuales una cuenta solo sirve
    /// de último recurso: se gastarían en minutos y habría que volver a cambiar.
    public static let minimumUsefulRoom: Double = 5
    /// Cuánto antes debe caducar el cupo de otra cuenta del mismo grupo para
    /// cambiar a ella sin esperar a un límite. Por debajo, el cambio no
    /// aprovecha nada.
    public static let anticipationMargin: TimeInterval = 30 * 60
    /// Margen mínimo, en todas sus ventanas informadas, de la cuenta a la que
    /// se adelanta el cambio. Con menos se gastaría enseguida y habría que
    /// volver a cambiar, solo para regresar en su siguiente ventana de 5 h.
    public static let anticipationMinimumRoom: Double = 15
    /// Si al ritmo medido la ventana de 5 h de la activa se agotaría antes de
    /// este plazo, se cambia ya: una sesión nueva no debe empezar en una
    /// cuenta a punto de cortarse, y el sondeo puede tardar en volver a mirar.
    public static let paceRunway: TimeInterval = 20 * 60
    /// El cambio por ritmo solo actúa a esta distancia del umbral, para que
    /// una ráfaga de trabajo no saque al usuario de una cuenta casi vacía.
    public static let paceTriggerMargin: Double = 30
    /// Tiempo mínimo que debe aguantar un destino al ritmo medido para no ser
    /// solo un último recurso, y también para adelantar un cambio. Una
    /// ventana de Team entera dura poco más de una hora: exigir más dejaría
    /// sin usar sus ventanas a medio gastar.
    public static let comfortableRunway: TimeInterval = 30 * 60
    /// Hasta dónde se mira la autonomía de una cuenta.
    public static let runwayHorizon: TimeInterval = 12 * 3_600
    /// Fracción del tiempo que se supone que se trabaja al estimar si una
    /// semana dará tiempo a gastarse. Quedarse corto solo adelanta su uso, y
    /// una semana gastada antes de su reinicio no pierde nada.
    public static let assumedWorkShare: Double = 0.5
    /// Sin saber cuánta semana cuesta cada punto de 5 h, se da por perdida la
    /// semana que se reinicia antes de este plazo.
    public static let unmeasuredWeeklyRisk: TimeInterval = 24 * 3_600
    /// Puntos de 5 h por hora que se pueden gastar de media como mucho: una
    /// ventana entera cada cinco horas.
    static let sustainablePace: Double = 20
    /// Cuánto antes que la activa debe recuperarse otra cuenta, cuando
    /// ninguna tiene margen, para dejarla activa a la espera.
    public static let recoveryMargin: TimeInterval = 15 * 60

    public init(
        triggerThreshold: Double = 90,
        weeklyThreshold: Double = 95,
        fableThreshold: Double = 95,
        considersFable: Bool = false,
        anticipatesExpiringQuota: Bool = false,
        switchesByPace: Bool = false
    ) {
        self.triggerThreshold = triggerThreshold
        self.weeklyThreshold = weeklyThreshold
        self.fableThreshold = fableThreshold
        self.considersFable = considersFable
        self.anticipatesExpiringQuota = anticipatesExpiringQuota
        self.switchesByPace = switchesByPace
    }

    public func shouldSwitch(active: AccountUsageState) -> Bool {
        reachedThreshold(active) || paceRequiresSwitch(active)
    }

    /// Al ritmo medido, la ventana de 5 h de la activa se agotaría antes de
    /// `paceRunway`. Se calcula con la cota alta del ritmo: es mejor cambiar
    /// un poco antes que dejar que una sesión se corte.
    public func paceRequiresSwitch(_ active: AccountUsageState) -> Bool {
        guard let remaining = timeToFiveHourLimit(active) else { return false }
        return remaining <= Self.paceRunway
    }

    /// Tiempo hasta que la ventana de 5 h llegaría al 100 % al ritmo actual,
    /// o `nil` si no se mide o la cuenta aún está lejos del umbral.
    public func timeToFiveHourLimit(_ active: AccountUsageState) -> TimeInterval? {
        guard switchesByPace,
              let pace = active.fiveHourPaceUpper, pace > 0,
              active.usage != nil else { return nil }
        let used = fiveHourUtilization(active)
        guard used >= triggerThreshold - Self.paceTriggerMargin else { return nil }
        return max(0, 100 - used) / pace * 3_600
    }

    /// Algún cupo de la activa llegó a su umbral configurado.
    public func reachedThreshold(_ active: AccountUsageState) -> Bool {
        guard let usage = active.usage else { return false }
        if let fiveHour = usage.fiveHour,
           fiveHour.utilization >= triggerThreshold {
            return true
        }
        if let weekly = usage.sevenDay,
           weekly.utilization >= weeklyThreshold {
            return true
        }
        if considersFable,
           let fable = usage.sevenDayOpus,
           fable.utilization >= fableThreshold {
            return true
        }
        return false
    }

    /// Por qué se descarta esta cuenta, o `nil` si sirve como destino.
    ///
    /// Una instantánea vigente sin ventana de 5 h describe una cuenta sin
    /// sesión abierta (o cuya ventana ya se reinició): su consumo de 5 h es
    /// cero, no un dato desconocido, así que no la descalifica.
    public func rejection(for account: AccountUsageState) -> CandidateRejection? {
        if account.needsLogin { return .needsLogin }
        guard let usage = account.usage else { return .noUsageData }
        if fiveHourUtilization(account) >= triggerThreshold { return .atLimit }
        if let sevenDay = usage.sevenDay,
           sevenDay.utilization >= weeklyThreshold {
            return .atLimit
        }
        if considersFable,
           let opus = usage.sevenDayOpus,
           opus.utilization >= fableThreshold {
            return .atLimit
        }
        return nil
    }

    public func isCandidate(_ account: AccountUsageState) -> Bool {
        rejection(for: account) == nil
    }

    func fiveHourUtilization(_ account: AccountUsageState) -> Double {
        account.usage?.fiveHour?.utilization ?? 0
    }

    func weeklyMargin(_ account: AccountUsageState) -> Double {
        let sevenDay = account.usage?.sevenDay?.utilization ?? 0
        guard considersFable else {
            return 100 - sevenDay
        }
        let opus = account.usage?.sevenDayOpus?.utilization ?? 0
        return 0.6 * (100 - sevenDay) + 0.4 * (100 - opus)
    }

    /// Puntos que le quedan a la cuenta hasta el umbral más próximo de las
    /// ventanas que cuentan. Una semana no informada (Team) no se puede medir.
    func usefulRoom(_ account: AccountUsageState) -> Double {
        var room = triggerThreshold - fiveHourUtilization(account)
        if let sevenDay = account.usage?.sevenDay {
            room = min(room, weeklyThreshold - sevenDay.utilization)
        }
        if considersFable, let opus = account.usage?.sevenDayOpus {
            room = min(room, fableThreshold - opus.utilization)
        }
        return room
    }

    /// Cuándo caduca el cupo semanal de la cuenta.
    ///
    /// En las cuentas que informan de ambas, la semana general y la de Fable
    /// se reinician a la vez. Cuando falta la general (Team), la de Fable es
    /// la mejor estimación disponible. Sin ninguna, la semana aún no ha
    /// empezado y su cupo no caduca.
    public func weeklyDeadline(_ usage: UsageSnapshot) -> Date? {
        usage.sevenDay?.resetsAt ?? usage.sevenDayOpus?.resetsAt
    }

    /// La cuenta gasta un cupo semanal visible. Las de Team solo informan de
    /// Fable: su semana general, si existe, no se ve ni se agota a la vista,
    /// así que lo que las limita es la ventana de 5 h.
    public func hasWeeklyLimit(_ account: AccountUsageState) -> Bool {
        !(account.usage?.weeklyLimitUnreported ?? false)
    }

    /// Reinicio de la ventana de 5 h si ya está abierta y le queda margen
    /// útil: lo que no se gaste antes de esa hora se pierde.
    public func openWindowReset(_ account: AccountUsageState, now: Date = Date()) -> Date? {
        guard let window = account.usage?.fiveHour,
              let reset = window.resetsAt, reset > now,
              triggerThreshold - window.utilization >= Self.minimumUsefulRoom
        else { return nil }
        return reset
    }

    /// La semana de la cuenta se reiniciaría con cupo sin gastar aunque se
    /// usara desde ahora todo lo que se suele trabajar.
    ///
    /// Su ventana de 5 h no deja gastar más de un cupo entero cada cinco
    /// horas, y cada punto de 5 h cuesta `weeklyPerFiveHour` de la semana.
    /// Como no se trabaja sin parar, se cuenta con `assumedWorkShare` del
    /// tiempo que falta. Sin esa medida, se da por perdida la semana que se
    /// reinicia antes de `unmeasuredWeeklyRisk`.
    public func weeklyQuotaAtRisk(_ account: AccountUsageState, now: Date = Date()) -> Bool {
        guard let weekly = account.usage?.sevenDay,
              let reset = weekly.resetsAt, reset > now else { return false }
        let room = weeklyThreshold - weekly.utilization
        guard room >= Self.minimumUsefulRoom else { return false }
        let remaining = reset.timeIntervalSince(now)
        guard let ratio = account.weeklyPerFiveHour, ratio > 0 else {
            return remaining <= Self.unmeasuredWeeklyRisk
        }
        let pace = min(account.fiveHourPace ?? Self.sustainablePace, Self.sustainablePace)
        guard pace > 0 else { return true }
        let needed = room / (pace * ratio) * 3_600
        return remaining * Self.assumedWorkShare <= needed
    }

    /// Qué se perdería si la cuenta no se usara ahora.
    public func urgency(_ account: AccountUsageState, now: Date = Date()) -> QuotaUrgency {
        if hasWeeklyLimit(account) {
            return weeklyQuotaAtRisk(account, now: now) ? .expiring : .reserve
        }
        return openWindowReset(account, now: now) != nil ? .expiring : .renewable
    }

    /// Cuánto tiempo seguido podría usarse la cuenta desde ahora sin que una
    /// sesión se corte, al ritmo medido, o `nil` si no hay ritmo.
    ///
    /// Una sesión sigue con su cuenta hasta agotarla, así que cuenta hasta el
    /// 100 %. Si la ventana de 5 h se reinicia antes, la sesión continúa con
    /// una ventana nueva: por eso una ventana a punto de reiniciarse aguanta
    /// mucho más de lo que sugiere su porcentaje.
    public func runway(_ account: AccountUsageState, now: Date = Date()) -> TimeInterval? {
        guard switchesByPace,
              let pace = account.fiveHourPace, pace > 0,
              let usage = account.usage else { return nil }
        let toLimit = max(0, 100 - fiveHourUtilization(account)) / pace * 3_600
        var runway = toLimit
        if let reset = usage.fiveHour?.resetsAt, reset > now,
           reset.timeIntervalSince(now) < toLimit {
            let freshWindow = 100 / pace * 3_600
            runway = freshWindow >= 5 * 3_600
                ? Self.runwayHorizon
                : reset.timeIntervalSince(now) + freshWindow
        }
        if let weekly = usage.sevenDay, let ratio = account.weeklyPerFiveHour, ratio > 0 {
            let toWeeklyLimit = max(0, 100 - weekly.utilization) / (pace * ratio) * 3_600
            if weekly.resetsAt.map({ $0.timeIntervalSince(now) > toWeeklyLimit }) ?? true {
                runway = min(runway, toWeeklyLimit)
            }
        }
        return min(runway, Self.runwayHorizon)
    }

    /// Primer momento en que la cuenta perdería cupo si no se usa: el
    /// reinicio de una ventana de 5 h ya abierta y con margen útil, o el de
    /// su semana general. Una ventana de 5 h sin abrir no caduca: empieza a
    /// contar cuando se usa. En Team la semana de Fable no cuenta: lo que
    /// limita a esas cuentas es su ventana de 5 h.
    public func expiryDeadline(_ account: AccountUsageState, now: Date = Date()) -> Date? {
        [openWindowReset(account, now: now), account.usage?.sevenDay?.resetsAt]
            .compactMap { $0 }
            .min()
    }

    /// Plazo que ordena a las cuentas de una misma urgencia. En las de
    /// reserva solo cuenta la semana: si no corre peligro, dejar que caduque
    /// su ventana de 5 h no pierde nada, porque su semana sigue intacta.
    func deadline(_ account: AccountUsageState, urgency: QuotaUrgency, now: Date) -> Date? {
        switch urgency {
        case .expiring: expiryDeadline(account, now: now)
        case .renewable: nil
        case .reserve: account.usage?.sevenDay?.resetsAt
        }
    }

    /// Clave de orden de una candidata: menor es mejor. Una cuenta sin nada
    /// que caduque va la última de su grupo: su cupo no se pierde por esperar.
    private func rank(
        _ account: AccountUsageState,
        now: Date
    ) -> (Int, Int, Double, Double, Double, Double) {
        let runway = runway(account, now: now)
        let cramped = usefulRoom(account) < Self.minimumUsefulRoom
            || (runway.map { $0 < Self.comfortableRunway } ?? false)
        let urgency = urgency(account, now: now)
        let deadline = deadline(account, urgency: urgency, now: now)?.timeIntervalSince1970 ?? .infinity
        return (
            (account.leftByUser ? 2 : 0) + (cramped ? 1 : 0),
            urgency.rawValue,
            deadline,
            -(runway ?? 0),
            fiveHourUtilization(account),
            -weeklyMargin(account)
        )
    }

    /// La mejor cuenta a la que cambiar, o nil si ninguna candidata sirve.
    public func bestCandidate(
        active: AccountUsageState,
        others: [AccountUsageState],
        now: Date = Date()
    ) -> String? {
        let candidates = others.filter { $0.id != active.id && isCandidate($0) }
        return candidates.min { rank($0, now: now) < rank($1, now: now) }?.id
    }

    /// Decisión completa: a qué cuenta cambiar dada la situación actual, o nil.
    public func decision(
        active: AccountUsageState,
        all: [AccountUsageState],
        now: Date = Date()
    ) -> String? {
        guard shouldSwitch(active: active) else { return nil }
        return bestCandidate(active: active, others: all, now: now)
    }

    /// Cuenta a la que conviene cambiar aunque la activa no esté en ningún
    /// límite, o nil.
    ///
    /// Mantiene activa la cuenta que va antes en el orden de elección: una
    /// de un grupo más urgente (`QuotaUrgency`), o del mismo grupo cuyo cupo
    /// caduca al menos `anticipationMargin` antes. Así una cuenta Max cede
    /// ante una Team con margen, y nadie deja caducar cupo en un reinicio.
    /// El destino necesita un margen holgado (`anticipationMinimumRoom`) y,
    /// con ritmo medido, aguantar al menos `comfortableRunway`: un cambio
    /// para unos minutos no compensa. Los umbrales se respetan igual que en
    /// cualquier cambio.
    public func expiringQuotaTarget(
        active: AccountUsageState,
        all: [AccountUsageState],
        now: Date = Date()
    ) -> String? {
        guard anticipatesExpiringQuota,
              active.usage != nil,
              !shouldSwitch(active: active) else { return nil }
        let activeUrgency = urgency(active, now: now)
        let activeDeadline = deadline(active, urgency: activeUrgency, now: now)
        let ahead = all.filter { account in
            guard account.id != active.id,
                  !account.leftByUser,
                  isCandidate(account),
                  usefulRoom(account) >= Self.anticipationMinimumRoom,
                  runway(account, now: now).map({ $0 >= Self.comfortableRunway }) ?? true
            else { return false }
            let urgency = urgency(account, now: now)
            if urgency != activeUrgency { return urgency < activeUrgency }
            guard let deadline = deadline(account, urgency: urgency, now: now),
                  deadline > now else { return false }
            guard let activeDeadline else { return true }
            return deadline.addingTimeInterval(Self.anticipationMargin) <= activeDeadline
        }
        return bestCandidate(active: active, others: ahead, now: now)
    }

    /// Cuándo recupera margen la activa: el reinicio más tardío de los cupos
    /// que la obligan a cambiar. Sin hora conocida, no se sabe y se supone
    /// lejano.
    func recovery(ofActive active: AccountUsageState, now: Date) -> Date {
        guard let usage = active.usage else { return .distantFuture }
        var blocking: [Date?] = []
        if fiveHourUtilization(active) >= triggerThreshold || paceRequiresSwitch(active) {
            blocking.append(usage.fiveHour?.resetsAt)
        }
        if let weekly = usage.sevenDay, weekly.utilization >= weeklyThreshold {
            blocking.append(weekly.resetsAt)
        }
        if considersFable, let fable = usage.sevenDayOpus, fable.utilization >= fableThreshold {
            blocking.append(fable.resetsAt)
        }
        return blocking.map { $0 ?? .distantFuture }.max() ?? now
    }

    /// Hora a la que recupera margen una cuenta que solo tiene bloqueada su
    /// ventana de 5 h, o `nil` si la bloquea otro cupo o no se sabe.
    func fiveHourRecovery(_ account: AccountUsageState, now: Date) -> Date? {
        guard let usage = account.usage else { return nil }
        if let weekly = usage.sevenDay, weekly.utilization >= weeklyThreshold { return nil }
        if considersFable, let fable = usage.sevenDayOpus, fable.utilization >= fableThreshold {
            return nil
        }
        guard let reset = usage.fiveHour?.resetsAt, reset > now else { return nil }
        return reset
    }

    /// Cuenta que dejar activa cuando la activa tiene que cambiar y ninguna
    /// otra tiene margen, o nil.
    ///
    /// Claude Code, al agotar su cuenta, sigue con la que esté activa y
    /// espera a que se recupere. Si ninguna tiene margen, conviene que esa
    /// sea la primera en recuperarse: la de la ventana de 5 h que antes se
    /// reinicia. Solo cuentan las que bloquea su ventana de 5 h y no tienen
    /// tope personal: esperar en ellas no gasta semana ni el cupo de otra
    /// persona. Debe recuperarse al menos `recoveryMargin` antes que la
    /// activa; si no, no compensa cambiar.
    public func recoveryTarget(
        active: AccountUsageState,
        all: [AccountUsageState],
        now: Date = Date()
    ) -> String? {
        guard shouldSwitch(active: active),
              bestCandidate(active: active, others: all, now: now) == nil else { return nil }
        let activeRecovery = recovery(ofActive: active, now: now)
        let waiting = all.compactMap { account -> (id: String, at: Date)? in
            guard account.id != active.id,
                  !account.needsLogin,
                  !account.leftByUser,
                  !account.hasPersonalCap,
                  let at = fiveHourRecovery(account, now: now) else { return nil }
            return (account.id, at)
        }
        guard let first = waiting.min(by: { $0.at < $1.at }),
              first.at.addingTimeInterval(Self.recoveryMargin) <= activeRecovery
        else { return nil }
        return first.id
    }
}
