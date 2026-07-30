import Foundation
import Testing
@testable import ClaudeSwitchCore

private let outageSummary = Data(
    """
    {
      "status": {"indicator": "major", "description": "Partial System Outage"},
      "components": [
        {"id": "api", "name": "Claude API (api.anthropic.com)", "status": "major_outage"},
        {"id": "code", "name": "Claude Code", "status": "degraded_performance"},
        {"id": "console", "name": "Claude Console", "status": "operational"}
      ],
      "incidents": [{
        "id": "incident-1",
        "name": "Elevated errors across all models",
        "status": "identified",
        "impact": "critical",
        "updated_at": "2026-07-29T20:33:45.587Z",
        "shortlink": "https://stspg.io/example",
        "incident_updates": [
          {
            "body": "<strong>Investigating</strong> elevated errors.",
            "updated_at": "2026-07-29T19:49:45.537Z"
          },
          {
            "body": "Issue identified &amp; fix in progress.",
            "updated_at": "2026-07-29T20:33:45.585Z"
          }
        ]
      }]
    }
    """.utf8
)

@Test func parseaEstadoPublicoEIncidenteActivo() throws {
    let date = Date(timeIntervalSince1970: 100)
    let snapshot = try AnthropicStatusSnapshot.parse(
        outageSummary,
        fetchedAt: date
    )
    #expect(snapshot.overall == .partialOutage)
    #expect(snapshot.api?.health == .majorOutage)
    #expect(snapshot.claudeCode?.health == .degraded)
    #expect(snapshot.relevantHealth == .majorOutage)
    #expect(snapshot.incidents.first?.status == "identified")
    #expect(
        snapshot.incidents.first?.latestUpdate
            == "Issue identified & fix in progress."
    )
    #expect(snapshot.fetchedAt == date)
}

@Test func respuestaDeEstadoMalformadaFalla() {
    #expect(throws: AnthropicStatusError.malformedResponse) {
        _ = try AnthropicStatusSnapshot.parse(Data("{}".utf8))
    }
}

private final class StatusProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestSeen: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestSeen = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: outageSummary)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Test func consultaEstadoPublicoSinCredenciales() async throws {
    StatusProtocol.requestSeen = nil
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StatusProtocol.self]
    let api = AnthropicStatusAPI(
        session: URLSession(configuration: configuration)
    )

    let snapshot = try await api.fetch()
    #expect(snapshot.api?.health == .majorOutage)
    #expect(StatusProtocol.requestSeen?.httpMethod == "GET")
    #expect(
        StatusProtocol.requestSeen?.url?.absoluteString
            == "https://status.claude.com/api/v2/summary.json"
    )
    #expect(
        StatusProtocol.requestSeen?.value(
            forHTTPHeaderField: "Authorization"
        ) == nil
    )
    #expect(StatusProtocol.requestSeen?.httpBody == nil)
}
