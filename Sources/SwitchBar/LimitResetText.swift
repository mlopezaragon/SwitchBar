import Foundation
import SwitchBarCore

/// Textos de los restablecimientos de límite de una cuenta.
enum LimitResetText {
    /// "Restablecimientos: 1 de 2 · úsalo antes del 30 oct", o nil si la
    /// cuenta no tiene ninguno vigente.
    static func summary(_ resets: LimitResets?, now: Date = Date()) -> String? {
        guard let resets else { return nil }
        let total = resets.resetsTotal(now: now)
        guard total > 0 else { return nil }
        let left = resets.resetsLeft(now: now)
        guard let expiry = resets.nextExpiry(now: now) else {
            return L10n.tr("limit_resets.summary", left, total)
        }
        let until = format(expiry, template: "dMMM")
        return left == 1
            ? L10n.tr("limit_resets.summary_until.one", left, total, until)
            : L10n.tr("limit_resets.summary_until.many", left, total, until)
    }

    /// Una línea por lote: "5 horas: 1 de 2 · hasta el 30 oct, 18:00 · se
    /// usa al llegar a un límite".
    static func rows(_ resets: LimitResets?, now: Date = Date()) -> [String] {
        guard let resets else { return [] }
        return resets.current(now: now).map { grant in
            var parts = [
                L10n.tr("limit_resets.row", kindName(grant), grant.resetsLeft, grant.resetsTotal)
            ]
            if let endsAt = grant.endsAt {
                parts.append(L10n.tr("limit_resets.until", format(endsAt, template: "dMMMjmm")))
            }
            if grant.resetsLeft > 0 {
                if grant.paused {
                    parts.append(L10n.tr("limit_resets.paused"))
                } else if grant.usableNow {
                    parts.append(L10n.tr("limit_resets.usable_now"))
                } else if grant.useRequiresLimit {
                    parts.append(L10n.tr("limit_resets.requires_limit"))
                }
            }
            return parts.joined(separator: " · ")
        }
    }

    /// Ayuda de la línea de la tarjeta: el desglose y de dónde sale el dato.
    static func help(_ resets: LimitResets?, now: Date = Date()) -> String {
        (rows(resets, now: now) + [L10n.tr("limit_resets.help")]).joined(separator: "\n")
    }

    private static func kindName(_ grant: LimitResetGrant) -> String {
        switch grant.kind {
        case .session: L10n.tr("limit_resets.kind.session")
        case .weekly: L10n.tr("limit_resets.kind.weekly")
        case .full: L10n.tr("limit_resets.kind.full")
        case nil: grant.label.isEmpty ? L10n.tr("limit_resets.kind.other") : grant.label
        }
    }

    private static func format(_ date: Date, template: String) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }
}
