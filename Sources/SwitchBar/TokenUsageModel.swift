import Foundation
import SwitchBarCore

/// Consumo de Claude Code en este Mac: registro guardado y lecturas
/// periódicas de las transcripciones.
///
/// Lee aunque la ventana esté cerrada: Claude Code borra sus transcripciones
/// a los 30 días y el histórico solo se conserva si SwitchBar las ha leído
/// antes. Con la ventana abierta lee más a menudo para que las cifras se
/// muevan en directo.
@MainActor
@Observable
final class TokenUsageModel {
    static let shared = TokenUsageModel()

    /// Registro que muestra la interfaz. Solo se sustituye cuando cambian sus
    /// totales: una lectura sin novedades no redibuja la ventana.
    private(set) var ledger = TokenUsageLedger()
    private(set) var isLoaded = false
    /// Última lectura de las transcripciones, aunque no trajera nada nuevo.
    private(set) var lastScanAt: Date?
    /// Primera lectura en curso: el registro está vacío y hay mucho que leer.
    private(set) var isReadingHistory = false
    /// Lectura pedida con el botón de actualizar.
    private(set) var isRefreshingByHand = false
    /// Avance de la lectura en curso (0…1), solo cuando hay mucho que leer.
    private(set) var scanProgress: Double?
    private(set) var lastError: String?
    /// Modelos por coste total de todo el registro. Su posición fija el color:
    /// cambiar de periodo o de cuenta no repinta un modelo.
    private(set) var modelOrder: [String] = []

    @ObservationIgnored private let store: TokenUsageStore
    @ObservationIgnored private let scanner: TranscriptScanner
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    /// Registro completo con el que sigue cada lectura (hasta dónde se leyó
    /// cada fichero, claves recientes…), aunque la interfaz no cambie.
    @ObservationIgnored private var working = TokenUsageLedger()
    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored var windowVisible = false {
        didSet { if windowVisible { refresh() } }
    }

    /// Por encima de esto se muestra el avance: la primera lectura recorre
    /// decenas de GB, las siguientes apenas unos KB.
    private static let progressThreshold: Int64 = 256 << 20
    private static let backgroundInterval: Duration = .seconds(300)
    private static let liveInterval: Duration = .seconds(30)

    init(store: TokenUsageStore = TokenUsageStore(), scanner: TranscriptScanner = TranscriptScanner()) {
        self.store = store
        self.scanner = scanner
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            let store = self.store
            let loaded = await Task.detached(priority: .utility) { store.load() }.value
            self.working = loaded
            self.publish(loaded)
            self.isLoaded = true
            // Sin prisa al arrancar: primero las cuentas y el cambio automático.
            if loaded.hasScanned {
                try? await Task.sleep(for: .seconds(20))
            }
            while !Task.isCancelled {
                await self.scan()
                let interval = self.windowVisible ? Self.liveInterval : Self.backgroundInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Lectura inmediata al abrir la ventana: sin indicadores, es una más.
    func refresh() {
        guard isLoaded, !isScanning else { return }
        Task { await scan() }
    }

    /// Lectura pedida a mano: el botón muestra que está trabajando.
    func refreshByHand() {
        guard isLoaded, !isScanning else { return }
        isRefreshingByHand = true
        Task {
            let started = Date()
            await scan()
            // Un instante mínimo: un parpadeo de 50 ms no se percibe como respuesta.
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.6 { try? await Task.sleep(for: .seconds(0.6 - elapsed)) }
            isRefreshingByHand = false
        }
    }

    private func scan() async {
        guard !isScanning else { return }
        isScanning = true
        if ledger.buckets.isEmpty { isReadingHistory = true }
        defer {
            isScanning = false
            if isReadingHistory { isReadingHistory = false }
            if scanProgress != nil { scanProgress = nil }
        }
        let scanner = self.scanner
        let store = self.store
        let current = working
        let saveDue = Date().timeIntervalSince(lastSave) > 3_600
        let threshold = Self.progressThreshold
        let outcome = await Task.detached(priority: .utility) { () -> (TokenUsageLedger, saved: Bool, failure: String?) in
            var ledger = current
            let changed = scanner.scan(into: &ledger) { progress in
                guard progress.bytesTotal > threshold else { return }
                let fraction = progress.fraction
                Task { @MainActor in
                    TokenUsageModel.shared.reportProgress(fraction)
                }
            }
            guard changed || saveDue else { return (ledger, false, nil) }
            do {
                try store.save(ledger)
                return (ledger, true, nil)
            } catch {
                return (ledger, false, error.localizedDescription)
            }
        }.value
        if outcome.saved { lastSave = Date() }
        let error = outcome.failure.map { L10n.tr("usage_stats.error", $0) }
        if error != lastError { lastError = error }
        working = outcome.0
        publish(outcome.0)
    }

    private func reportProgress(_ fraction: Double) {
        guard isScanning else { return }
        // Solo cambios visibles: cada punto porcentual.
        if let scanProgress, abs(scanProgress - fraction) < 0.01 { return }
        scanProgress = fraction
    }

    private func publish(_ ledger: TokenUsageLedger) {
        lastScanAt = ledger.lastScanAt
        guard ledger.buckets != self.ledger.buckets || ledger.hasScanned != self.ledger.hasScanned else { return }
        self.ledger = ledger
        let all = TokenUsageReport(ledger: ledger, days: nil, account: nil)
        let order = all.byModel.map(\.id)
        if order != modelOrder { modelOrder = order }
    }

    // MARK: Consultas

    var today: Int32 { LocalDay.number(of: Date()) }

    func report(_ period: UsagePeriod, account: String?) -> TokenUsageReport {
        report(days: period.days(today: today, firstDay: ledger.firstDay), account: account)
    }

    func report(days: ClosedRange<Int32>?, account: String?) -> TokenUsageReport {
        TokenUsageReport(ledger: ledger, days: days, account: account)
    }

    /// Cuentas con uso registrado, de mayor a menor coste.
    var accountsWithUsage: [String] {
        TokenUsageReport(ledger: ledger, days: nil, account: nil).byAccount.map(\.id)
    }
}

/// Periodo de la ventana de consumo.
enum UsagePeriod: String, CaseIterable, Identifiable {
    case today, week, month, all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: L10n.tr("usage_stats.period.today")
        case .week: L10n.tr("usage_stats.period.week")
        case .month: L10n.tr("usage_stats.period.month")
        case .all: L10n.tr("usage_stats.period.all")
        }
    }

    /// Días incluidos; `nil` = todo el registro.
    func days(today: Int32, firstDay: Int32?) -> ClosedRange<Int32>? {
        switch self {
        case .today: today...today
        case .week: (today - 6)...today
        case .month: (today - 29)...today
        case .all: nil
        }
    }

    /// Días que muestra el gráfico: con «Hoy» se ven las dos últimas semanas
    /// para tener con qué comparar.
    func chartDays(today: Int32, firstDay: Int32?) -> ClosedRange<Int32> {
        switch self {
        case .today: (today - 13)...today
        case .week: (today - 6)...today
        case .month: (today - 29)...today
        case .all: min(firstDay ?? today, today - 13)...today
        }
    }

    /// Días naturales del periodo, para las medias.
    func dayCount(today: Int32, firstDay: Int32?) -> Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        case .all: Int(today - (firstDay ?? today)) + 1
        }
    }
}
