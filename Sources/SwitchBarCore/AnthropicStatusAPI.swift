import Foundation

public enum AnthropicServiceHealth: String, Sendable, Equatable {
    case operational
    case degraded
    case partialOutage
    case majorOutage
    case maintenance
    case unknown

    public var isDisrupted: Bool {
        switch self {
        case .operational:
            return false
        case .degraded, .partialOutage, .majorOutage, .maintenance:
            return true
        case .unknown:
            return false
        }
    }

    fileprivate var priority: Int {
        switch self {
        case .operational: 0
        case .unknown: 0
        case .maintenance: 2
        case .degraded: 3
        case .partialOutage: 4
        case .majorOutage: 5
        }
    }

    fileprivate static func componentStatus(_ value: String) -> Self {
        switch value {
        case "operational": .operational
        case "degraded_performance": .degraded
        case "partial_outage": .partialOutage
        case "major_outage": .majorOutage
        case "under_maintenance": .maintenance
        default: .unknown
        }
    }

    fileprivate static func pageIndicator(_ value: String) -> Self {
        switch value {
        case "none": .operational
        case "minor": .degraded
        case "major": .partialOutage
        case "critical": .majorOutage
        default: .unknown
        }
    }
}

public struct AnthropicComponentStatus: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var health: AnthropicServiceHealth
}

public struct AnthropicIncident: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var status: String
    public var impact: String
    public var latestUpdate: String?
    public var updatedAt: Date?
    public var url: URL?
}

public struct AnthropicStatusSnapshot: Sendable, Equatable {
    public var overall: AnthropicServiceHealth
    public var components: [AnthropicComponentStatus]
    public var incidents: [AnthropicIncident]
    public var fetchedAt: Date

    public var api: AnthropicComponentStatus? {
        components.first {
            $0.name.localizedCaseInsensitiveContains("api.anthropic.com")
                || $0.name.localizedCaseInsensitiveContains("Claude API")
        }
    }

    public var claudeCode: AnthropicComponentStatus? {
        components.first {
            $0.name.localizedCaseInsensitiveCompare("Claude Code")
                == .orderedSame
        }
    }

    /// Estado relevante para esta app. Una caída solo de un producto ajeno no
    /// debe presentarse como si Claude Code o la API estuvieran caídos.
    public var relevantHealth: AnthropicServiceHealth {
        let relevant = [api?.health, claudeCode?.health].compactMap { $0 }
        return relevant.max { $0.priority < $1.priority } ?? overall
    }

    public static func parse(
        _ data: Data,
        fetchedAt: Date = Date()
    ) throws -> AnthropicStatusSnapshot {
        let response: SummaryResponse
        do {
            response = try JSONDecoder().decode(SummaryResponse.self, from: data)
        } catch {
            throw AnthropicStatusError.malformedResponse
        }

        let components = response.components.map {
            AnthropicComponentStatus(
                id: $0.id,
                name: $0.name,
                health: .componentStatus($0.status)
            )
        }
        let incidents = response.incidents.map { incident in
            let latest = incident.incidentUpdates.max { lhs, rhs in
                (ISO8601.parse(lhs.updatedAt) ?? .distantPast)
                    < (ISO8601.parse(rhs.updatedAt) ?? .distantPast)
            }
            return AnthropicIncident(
                id: incident.id,
                name: incident.name,
                status: incident.status,
                impact: incident.impact,
                latestUpdate: latest?.body.strippingHTML,
                updatedAt: ISO8601.parse(incident.updatedAt),
                url: incident.shortlink.flatMap(URL.init(string:))
            )
        }
        return AnthropicStatusSnapshot(
            overall: .pageIndicator(response.status.indicator),
            components: components,
            incidents: incidents,
            fetchedAt: fetchedAt
        )
    }
}

public enum AnthropicStatusError: Error, Equatable {
    case httpError(Int)
    case malformedResponse
}

/// Consulta la página pública oficial de Anthropic. No requiere clave, cuenta
/// ni credenciales de Claude Code.
public final class AnthropicStatusAPI: Sendable {
    static let summaryEndpoint = URL(
        string: "https://status.claude.com/api/v2/summary.json"
    )!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch() async throws -> AnthropicStatusSnapshot {
        var request = URLRequest(
            url: Self.summaryEndpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AnthropicStatusError.malformedResponse
        }
        guard http.statusCode == 200 else {
            throw AnthropicStatusError.httpError(http.statusCode)
        }
        return try AnthropicStatusSnapshot.parse(data)
    }
}

private struct SummaryResponse: Decodable {
    var status: Status
    var components: [Component]
    var incidents: [Incident]

    struct Status: Decodable {
        var indicator: String
    }

    struct Component: Decodable {
        var id: String
        var name: String
        var status: String
    }

    struct Incident: Decodable {
        var id: String
        var name: String
        var status: String
        var impact: String
        var updatedAt: String
        var shortlink: String?
        var incidentUpdates: [Update]

        enum CodingKeys: String, CodingKey {
            case id, name, status, impact, shortlink
            case updatedAt = "updated_at"
            case incidentUpdates = "incident_updates"
        }
    }

    struct Update: Decodable {
        var body: String
        var updatedAt: String

        enum CodingKeys: String, CodingKey {
            case body
            case updatedAt = "updated_at"
        }
    }
}

private extension String {
    var strippingHTML: String {
        replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
