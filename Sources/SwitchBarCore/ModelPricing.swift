import Foundation

/// Precio de catálogo de un modelo en el API de Anthropic, en dólares por
/// millón de tokens.
public struct ModelPrice: Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double

    /// Las escrituras de caché cuestan 1,25× la entrada (5 min) y 2× (1 h)
    /// en todos los modelos; la lectura cambia según el modelo.
    init(input: Double, output: Double, cacheRead: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = input * 1.25
        self.cacheWrite1h = input * 2
    }

    func scaled(input inputFactor: Double, output outputFactor: Double) -> ModelPrice {
        var price = self
        price.input *= inputFactor
        price.cacheRead *= inputFactor
        price.cacheWrite5m *= inputFactor
        price.cacheWrite1h *= inputFactor
        price.output *= outputFactor
        return price
    }
}

/// Lo que cuesta en el API lo que Claude Code gastó con una suscripción.
///
/// Las suscripciones no cobran por token: esta cifra dice cuánto habría
/// costado el mismo trabajo pagando el API, que es la única forma de
/// comparar el uso entre modelos y entre cuentas con una misma unidad.
/// Precios de platform.claude.com a 2026-11-03.
public enum ModelPricing {
    /// Una búsqueda web del servidor: 10 $ cada mil.
    public static let webSearchPrice = 0.01

    private static let catalog: [String: ModelPrice] = {
        var table: [String: ModelPrice] = [:]
        func add(_ ids: [String], _ input: Double, _ output: Double, read: Double? = nil) {
            for id in ids {
                table[id] = ModelPrice(input: input, output: output, cacheRead: read ?? input * 0.1)
            }
        }
        add(["claude-fable-5-2", "claude-mythos-5-2"], 8, 40, read: 0.20)
        add(["claude-fable-5-1", "claude-mythos-5-1"], 10, 50, read: 0.25)
        add(["claude-fable-5", "claude-mythos-5"], 10, 50, read: 1.00)
        add(["claude-opus-5-5"], 4, 20, read: 0.20)
        add(["claude-opus-5", "claude-opus-4-8", "claude-opus-4-7",
             "claude-opus-4-6", "claude-opus-4-5"], 5, 25)
        add(["claude-opus-4-1", "claude-opus-4", "claude-3-opus"], 15, 75)
        add(["claude-sonnet-5-5"], 2, 10, read: 0.10)
        add(["claude-sonnet-5"], 2, 10)
        add(["claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4",
             "claude-3-7-sonnet", "claude-3-5-sonnet"], 3, 15)
        add(["claude-haiku-5-5"], 0.10, 0.50)
        add(["claude-haiku-4-5"], 1, 5)
        add(["claude-3-5-haiku"], 0.80, 4)
        add(["claude-3-haiku"], 0.25, 1.25)
        return table
    }()

    /// Identificador canónico: sin prefijos de proveedor (`us.anthropic.`),
    /// sin fecha de versión (`-20251001`), sin sufijos de contexto (`[1m]`)
    /// ni de versión de Bedrock o Vertex (`-v1:0`, `@20251001`).
    public static func canonicalID(_ model: String) -> String {
        var id = model.lowercased()
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
        if let range = id.range(of: "claude-") { id = String(id[range.lowerBound...]) }
        if let colon = id.range(of: #"-v\d+(:\d+)?$"#, options: .regularExpression) {
            id.removeSubrange(colon)
        }
        if let date = id.range(of: #"-\d{8}$"#, options: .regularExpression) {
            id.removeSubrange(date)
        }
        return id
    }

    /// Precio aplicable a un mensaje. `nil` si el modelo no está en el
    /// catálogo: mejor no sumarlo que inventar una cifra.
    public static func price(for model: String, variant: UsageVariant = []) -> ModelPrice? {
        let id = canonicalID(model)
        guard var price = catalog[id] else { return nil }
        // Haiku 5.5 cobra 5× por encima de 100 000 tokens de prompt.
        if id == "claude-haiku-5-5", variant.contains(.promptOver100K) {
            price = price.scaled(input: 5, output: 5)
        }
        // Sonnet 4 y 4.5 con contexto de 1M: por encima de 200 000 tokens.
        if (id == "claude-sonnet-4" || id == "claude-sonnet-4-5"),
           variant.contains(.promptOver200K) {
            price = price.scaled(input: 2, output: 1.5)
        }
        // El modo rápido cuesta el doble en todos los modelos que lo ofrecen.
        if variant.contains(.fast) {
            price = price.scaled(input: 2, output: 2)
        }
        return price
    }

    /// Coste en dólares; `nil` si no se conoce el precio del modelo.
    public static func cost(of counts: TokenCounts, model: String, variant: UsageVariant = []) -> Double? {
        guard let price = price(for: model, variant: variant) else { return nil }
        var perMillion: Double = Double(counts.input) * price.input
        perMillion += Double(counts.output) * price.output
        perMillion += Double(counts.cacheRead) * price.cacheRead
        perMillion += Double(counts.cacheWrite5m) * price.cacheWrite5m
        perMillion += Double(counts.cacheWrite1h) * price.cacheWrite1h
        let searches = Double(counts.webSearches) * webSearchPrice
        return perMillion / 1_000_000 + searches
    }

    /// Nombre corto para la interfaz: «Opus 5.5», «Haiku 4.5», «Sonnet 3.7».
    public static func displayName(_ model: String) -> String {
        let id = canonicalID(model)
        let parts = id.split(separator: "-").map(String.init)
        guard parts.first == "claude", parts.count >= 2 else { return model }
        let rest = Array(parts.dropFirst())
        let families = ["opus", "sonnet", "haiku", "fable", "mythos"]
        if let index = rest.firstIndex(where: { families.contains($0) }) {
            let family = rest[index].capitalized
            // Nombres antiguos: el número va delante («claude-3-5-sonnet»).
            let numbers = index == 0 ? Array(rest.dropFirst()) : Array(rest[..<index])
            let version = numbers.filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
            let extra = index == 0 ? [] : Array(rest[(index + 1)...])
            return ([family, version] + extra).filter { !$0.isEmpty }.joined(separator: " ")
        }
        return rest.joined(separator: " ").capitalized
    }
}
