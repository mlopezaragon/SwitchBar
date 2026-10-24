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
        fiveHourPace: Double? = nil,
        fiveHourPaceUpper: Double? = nil,
        weeklyPerFiveHour: Double? = nil
    ) {
        self.id = id
        self.usage = usage
        self.needsLogin = needsLogin
        self.leftByUser = leftByUser
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
/// 2. La que antes perdería cupo: el reinicio de una ventana de 5 h ya
///    abierta con margen, o el de su semana, aunque sea por minutos. Lo que
///    no se gasta antes del reinicio se pierde; una ventana sin abrir no
///    caduca y se guarda para después.
/// 3. La que más tiempo aguantaría sin cortarse al ritmo medido.
/// 4. Menor uso de 5 h.
/// 5. Mayor margen ponderado de los cupos semanales que estén habilitados.
public struct AutoSwitchPolicy: Sendable {
    public var triggerThreshold: Double
    public var weeklyThreshold: Double
    public var fableThreshold: Double
    public var considersFable: Bool
    /// Gestión autónoma: cambiar sin esperar a un límite a la cuenta cuyo
    /// cupo semanal caduca antes. Ver `expiringQuotaTarget`.
    public var anticipatesExpiringQuota: Bool
    /// Usar el ritmo medido: cambiar antes si la cuenta activa se va a
    /// agotar enseguida y no elegir destinos que se agotarían en minutos.
    public var switchesByPace: Bool

    /// Puntos hasta el umbral por debajo de los cuales una cuenta solo sirve
    /// de último recurso: se gastarían en minutos y habría que volver a cambiar.
    public static let minimumUsefulRoom: Double = 5
    /// Cuánto antes debe caducar el cupo de otra cuenta para cambiar a ella
    /// sin esperar a un límite. Por debajo, el cambio no aprovecha nada.
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
    /// solo un último recurso.
    public static let comfortableRunway: TimeInterval = 45 * 60
    /// Adelantarse a un cupo que caduca exige que el destino aguante al menos
    /// esto: un cambio para unos minutos no compensa.
    public static let anticipationMinimumRunway: TimeInterval = 60 * 60
    /// Hasta dónde se mira la autonomía de una cuenta.
    public static let runwayHorizon: TimeInterval = 12 * 3_600

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
    /// su semana. Una ventana de 5 h sin abrir no caduca: empieza a contar
    /// cuando se usa.
    public func expiryDeadline(_ account: AccountUsageState, now: Date = Date()) -> Date? {
        guard let usage = account.usage else { return nil }
        var deadlines: [Date] = []
        if let window = usage.fiveHour, let reset = window.resetsAt, reset > now,
           triggerThreshold - window.utilization >= Self.minimumUsefulRoom {
            deadlines.append(reset)
        }
        if let weekly = weeklyDeadline(usage) {
            deadlines.append(weekly)
        }
        return deadlines.min()
    }

    /// Clave de orden de una candidata: menor es mejor. Una cuenta sin nada
    /// que caduque va la última: su cupo no se pierde por esperar.
    private func rank(
        _ account: AccountUsageState,
        now: Date
    ) -> (Int, Int, Double, Double, Double, Double) {
        let left = account.leftByUser ? 1 : 0
        let runway = runway(account, now: now)
        let cramped = usefulRoom(account) < Self.minimumUsefulRoom
            || (runway.map { $0 < Self.comfortableRunway } ?? false)
        let deadline = expiryDeadline(account, now: now)?.timeIntervalSince1970 ?? .infinity
        return (
            left,
            cramped ? 1 : 0,
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
    /// Mantiene activa la cuenta cuyo cupo semanal caduca antes: si otra con
    /// margen holgado (`anticipationMinimumRoom`) se reinicia al menos
    /// `anticipationMargin` antes que la activa, gastar primero el suyo no
    /// cuesta nada y la activa conserva el propio para después. Los umbrales
    /// se respetan igual que en cualquier cambio. En Team, cuya semana general
    /// no se informa, cuentan las ventanas que sí se informan y el reinicio
    /// de Fable. Con ritmo medido, el destino debe aguantar al menos
    /// `anticipationMinimumRunway`: un cambio para unos minutos no compensa.
    public func expiringQuotaTarget(
        active: AccountUsageState,
        all: [AccountUsageState],
        now: Date = Date()
    ) -> String? {
        guard anticipatesExpiringQuota,
              let activeUsage = active.usage,
              !shouldSwitch(active: active) else { return nil }
        let activeDeadline = weeklyDeadline(activeUsage)
        let expiringFirst = all.filter { account in
            guard account.id != active.id,
                  !account.leftByUser,
                  isCandidate(account),
                  usefulRoom(account) >= Self.anticipationMinimumRoom,
                  runway(account, now: now).map({ $0 >= Self.anticipationMinimumRunway }) ?? true,
                  let deadline = account.usage.flatMap(weeklyDeadline),
                  deadline > now
            else { return false }
            guard let activeDeadline else { return true }
            return deadline.addingTimeInterval(Self.anticipationMargin) <= activeDeadline
        }
        return bestCandidate(active: active, others: expiringFirst, now: now)
    }
}
