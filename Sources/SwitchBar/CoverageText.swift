import Foundation
import SwitchBarCore

/// Frase que resume la previsión de cupo para el panel y el detalle.
enum CoverageText {
    static func summary(_ forecast: CoverageForecast, now: Date = Date()) -> String {
        let current = forecast.basis == .currentPace
        guard let runsOutAt = forecast.runsOutAt else {
            let hours = Int(forecast.horizon / 3_600)
            return current
                ? L10n.tr("forecast.beyond.current", hours)
                : L10n.tr("forecast.beyond.typical", hours)
        }
        if runsOutAt.timeIntervalSince(now) < 60 {
            return forecast.resumesAt.map {
                L10n.tr("forecast.none.resumes", ResetFormatter.absolute($0))
            } ?? L10n.tr("forecast.none")
        }
        let remaining = ResetFormatter.compact(runsOutAt)
        let at = ResetFormatter.absolute(runsOutAt)
        if let resumesAt = forecast.resumesAt {
            let resumes = ResetFormatter.absolute(resumesAt)
            return current
                ? L10n.tr("forecast.gap.current", remaining, at, resumes)
                : L10n.tr("forecast.gap.typical", remaining, at, resumes)
        }
        return current
            ? L10n.tr("forecast.until.current", remaining, at)
            : L10n.tr("forecast.until.typical", remaining, at)
    }

    /// El cupo se acaba pronto al ritmo con que se está trabajando.
    static func isUrgent(_ forecast: CoverageForecast, now: Date = Date()) -> Bool {
        guard forecast.basis == .currentPace, let runsOutAt = forecast.runsOutAt else { return false }
        return runsOutAt.timeIntervalSince(now) <= 3_600
    }
}
