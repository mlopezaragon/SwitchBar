import Foundation
import ClaudeSwitchCore

/// Formato del tiempo que falta para que una ventana de uso se restablezca.
/// El texto de `RelativeDateTimeFormatter` ("dentro de 3 horas") no cabe en las
/// filas del panel y se cortaba; aquí se genera una forma compacta y exacta.
enum ResetFormatter {
    /// "45 min", "3 h 20", "2 d 4 h", "ahora".
    static func compact(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return L10n.tr("time.now") }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return L10n.tr("time.minutes", max(1, minutes))
        }
        let hours = minutes / 60
        if hours < 24 {
            let restMinutes = minutes % 60
            return restMinutes == 0
                ? L10n.tr("time.hours", hours)
                : L10n.tr("time.hours_minutes", hours, restMinutes)
        }
        let days = hours / 24
        let restHours = hours % 24
        return restHours == 0
            ? L10n.tr("time.days", days)
            : L10n.tr("time.days_hours", days, restHours)
    }

    /// Texto largo para el detalle: "queda 3 h 20 (hoy a las 18:09)".
    static func long(_ date: Date?) -> String {
        guard let date else { return " " }
        if date.timeIntervalSinceNow <= 0 {
            return L10n.tr("time.reset_now")
        }
        return L10n.tr("time.remaining", compact(date), absolute(date))
    }

    /// Antigüedad de un dato: "ahora mismo", "hace 40 s", "hace 5 min".
    static func since(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = Int(max(0, Date().timeIntervalSince(date)))
        if seconds < 5 { return L10n.tr("time.now_full") }
        if seconds < 60 { return L10n.tr("time.seconds_ago", seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return L10n.tr("time.minutes_ago", minutes) }
        let hours = minutes / 60
        return hours < 24
            ? L10n.tr("time.hours_ago", hours)
            : L10n.tr("time.days_ago", hours / 24)
    }

    /// Fecha y hora concretas, en español.
    static func absolute(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = L10n.locale
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
}
