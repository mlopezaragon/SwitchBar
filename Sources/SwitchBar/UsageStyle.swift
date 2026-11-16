import AppKit
import SwiftUI
import SwitchBarCore

/// Colores de los modelos en los gráficos de consumo.
///
/// Paleta categórica validada para daltonismo en claro y en oscuro (cada modo
/// con sus propios tonos). El orden es parte de esa validación: los colores
/// vecinos de una barra apilada son los que se comprobaron juntos. Cada modelo
/// conserva su color por su posición en el total histórico, no por la del
/// periodo que se mira; a partir del séptimo se agrupan en «Otros».
enum UsagePalette {
    private static let slots: [(light: UInt32, dark: UInt32)] = [
        (0x2A78D6, 0x3987E5),   // azul
        (0xEB6834, 0xD95926),   // naranja
        (0x1BAF7A, 0x199E70),   // aguamarina
        (0xEDA100, 0xC98500),   // amarillo
        (0xE87BA4, 0xD55181),   // magenta
        (0x008300, 0x0CA30C)    // verde
    ]

    static let otherKey = "__other__"
    static var slotCount: Int { slots.count }

    static func color(slot: Int) -> Color {
        guard slot < slots.count else { return other }
        return dynamic(light: slots[slot].light, dark: slots[slot].dark)
    }

    /// Gris neutro: «Otros» no compite con ningún modelo.
    static let other = dynamic(light: 0x9A9994, dark: 0x6C6B66)

    /// Clave de serie de un modelo: él mismo o «Otros».
    static func seriesKey(for model: String, order: [String]) -> String {
        guard let index = order.firstIndex(of: model), index < slots.count else { return otherKey }
        return model
    }

    static func color(forSeries key: String, order: [String]) -> Color {
        guard key != otherKey, let index = order.firstIndex(of: key) else { return other }
        return color(slot: index)
    }

    static func name(forSeries key: String) -> String {
        key == otherKey ? L10n.tr("usage_stats.chart.other") : ModelPricing.displayName(key)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Cifras de la ventana de consumo, en el idioma de la app.
enum UsageFormat {
    /// «274 B», «9,32 B», «34,4 M», «43,3 K», «812»: tres cifras significativas
    /// con sufijos K, M, B y T en todos los idiomas. Leer «274 B» de un vistazo
    /// es más claro que «274 mil M», y en una columna todas usan la misma escala.
    static func tokens(_ value: Int64) -> String {
        let number = Double(value)
        let magnitude = abs(number)
        if magnitude < 10_000 {
            return Int(value).formatted(.number.locale(L10n.locale))
        }
        let units: [(scale: Double, suffix: String)] = [(1e12, "T"), (1e9, "B"), (1e6, "M"), (1e3, "K")]
        // Con tres cifras, 999 950 sería «1000 K»: pasa ya a «1 M».
        let unit = units.first { magnitude >= $0.scale * 0.9995 } ?? units[units.count - 1]
        let scaled = (number / unit.scale).formatted(
            .number.precision(.significantDigits(1...3)).locale(L10n.locale)
        )
        return "\(scaled) \(unit.suffix)"
    }

    /// Todas las cifras, para la ayuda emergente: «273 758 634 414».
    static func tokensFull(_ value: Int64) -> String {
        Int(value).formatted(.number.locale(L10n.locale))
    }

    /// Dólares: sin decimales a partir de 1 000; con dos por debajo.
    static func cost(_ value: Double) -> String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: "USD", locale: L10n.locale)
        if value >= 1_000 { return value.formatted(style.precision(.fractionLength(0))) }
        if value > 0, value < 0.01 { return "< " + 0.01.formatted(style.precision(.fractionLength(2))) }
        return value.formatted(style.precision(.fractionLength(2)))
    }

    /// Ejes del gráfico: «3000 US$», «400 US$».
    static func costAxis(_ value: Double) -> String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: "USD", locale: L10n.locale)
        return value.formatted(style.precision(.fractionLength(value < 10 && value != 0 ? 1 : 0)))
    }

    static func percent(_ fraction: Double) -> String {
        if fraction > 0, fraction < 0.001 {
            return "< " + 0.001.formatted(.percent.precision(.fractionLength(1)).locale(L10n.locale))
        }
        return fraction.formatted(
            .percent.precision(.fractionLength(fraction < 0.1 && fraction > 0 ? 1 : 0)).locale(L10n.locale)
        )
    }

    static func count(_ value: Int64) -> String {
        Int(value).formatted(.number.locale(L10n.locale))
    }

    /// «lun, 16 nov».
    static func dayShort(_ day: Int32) -> String {
        LocalDay.date(day).formatted(
            .dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(L10n.locale)
        )
    }

    /// «lunes, 16 de noviembre de 2026».
    static func dayLong(_ day: Int32) -> String {
        LocalDay.date(day).formatted(
            .dateTime.weekday(.wide).day().month(.wide).year().locale(L10n.locale)
        )
    }
}

/// Nombre de una cuenta en la ventana de consumo.
struct UsageAccountLabel {
    var isUnattributed = false
    var title: String
    var detail: String?
    var plan: AccountPlan?
    var organizationName: String?

    init(key: String, profiles: [AccountProfile]) {
        if key.isEmpty {
            isUnattributed = true
            title = L10n.tr("usage_stats.unattributed")
            return
        }
        if let profile = profiles.first(where: { $0.id == key })
            ?? profiles.first(where: { $0.accountUuid == key.split(separator: "/").first.map(String.init) }) {
            title = profile.emailAddress
            plan = profile.plan
            organizationName = profile.organizationName
            // La misma persona en dos organizaciones: el nombre las distingue.
            let sameEmail = profiles.filter { $0.emailAddress == profile.emailAddress }.count > 1
            if sameEmail || profile.plan?.isOrganization == true {
                detail = profile.organizationName
            }
            return
        }
        title = L10n.tr("usage_stats.unknown_account", String(key.prefix(8)))
    }
}
