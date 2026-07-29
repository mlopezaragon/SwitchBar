import Foundation

/// Formato del tiempo que falta para que una ventana de uso se restablezca.
/// El texto de `RelativeDateTimeFormatter` ("dentro de 3 horas") no cabe en las
/// filas del panel y se cortaba; aquí se genera una forma compacta y exacta.
enum ResetFormatter {
    /// "45 min", "3 h 20", "2 d 4 h", "ahora".
    static func compact(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "ahora" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(1, minutes)) min" }
        let hours = minutes / 60
        if hours < 24 {
            let restMinutes = minutes % 60
            return restMinutes == 0 ? "\(hours) h" : "\(hours) h \(restMinutes)"
        }
        let days = hours / 24
        let restHours = hours % 24
        return restHours == 0 ? "\(days) d" : "\(days) d \(restHours) h"
    }

    /// Texto largo para el detalle: "queda 3 h 20 (hoy a las 18:09)".
    static func long(_ date: Date?) -> String {
        guard let date else { return " " }
        if date.timeIntervalSinceNow <= 0 { return "se restablece ya" }
        return "quedan \(compact(date)) · \(absolute(date))"
    }

    /// Fecha y hora concretas, en español.
    static func absolute(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
}
