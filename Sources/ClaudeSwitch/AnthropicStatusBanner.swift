import SwiftUI
import ClaudeSwitchCore

/// Estado oficial de status.claude.com, presentado en lenguaje cotidiano.
struct AnthropicStatusBanner: View {
    let snapshot: AnthropicStatusSnapshot?
    let unavailable: Bool
    let checking: Bool
    let compact: Bool
    let openOfficialPage: () -> Void

    @ViewBuilder
    var body: some View {
        if snapshot?.relevantHealth == .operational && !unavailable {
            EmptyView()
        } else if compact {
            compactBody
        } else {
            detailedBody
        }
    }

    private var compactBody: some View {
        Button(action: openOfficialPage) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                    if let incident = displayIncident {
                        Text(incident.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if unavailable {
                        Text(L10n.tr("anthropic.status.unavailable.short"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(statusColor.opacity(0.09))
        )
    }

    private var detailedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(
                    L10n.tr("anthropic.status.official_page"),
                    action: openOfficialPage
                )
                    .controlSize(.small)
            }

            if snapshot?.relevantHealth.isDisrupted == true {
                Text(
                    L10n.tr("anthropic.status.incident_confirmed")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if unavailable {
                Text(
                    L10n.tr("anthropic.status.last_known")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let snapshot {
                HStack(spacing: 8) {
                    if let api = snapshot.api {
                        componentPill("API", health: api.health)
                    }
                    if let code = snapshot.claudeCode {
                        componentPill("Claude Code", health: code.health)
                    }
                    Text(
                        L10n.tr(
                            "anthropic.status.updated",
                            ResetFormatter.since(snapshot.fetchedAt)
                        )
                    )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let incident = displayIncident {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(incident.name)
                            .font(.callout.weight(.medium))
                        HStack(spacing: 5) {
                            Text(incidentStatus(incident.status))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(statusColor)
                            Text("· \(incidentExplanation(incident.status))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(statusColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(statusColor.opacity(0.22), lineWidth: 1)
        )
    }

    private func componentPill(
        _ name: String,
        health: AnthropicServiceHealth
    ) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color(for: health))
                .frame(width: 6, height: 6)
            Text("\(name): \(shortHealth(health))")
                .font(.caption2)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.quaternary))
    }

    private var title: String {
        guard let snapshot else {
            return checking
                ? L10n.tr("anthropic.status.checking")
                : L10n.tr("anthropic.status.unavailable")
        }
        if let api = snapshot.api {
            switch api.health {
            case .majorOutage:
                return L10n.tr("anthropic.status.api.major_outage")
            case .partialOutage:
                return L10n.tr("anthropic.status.api.partial_outage")
            case .degraded:
                return L10n.tr("anthropic.status.api.degraded")
            case .maintenance:
                return L10n.tr("anthropic.status.api.maintenance")
            case .operational, .unknown:
                break
            }
        }
        if let code = snapshot.claudeCode, code.health.isDisrupted {
            switch code.health {
            case .majorOutage:
                return L10n.tr("anthropic.status.code.major_outage")
            case .partialOutage:
                return L10n.tr("anthropic.status.code.partial_outage")
            case .degraded:
                return L10n.tr("anthropic.status.code.degraded")
            case .maintenance:
                return L10n.tr("anthropic.status.code.maintenance")
            case .operational, .unknown:
                break
            }
        }
        if snapshot.relevantHealth == .operational {
            return L10n.tr("anthropic.status.operational")
        }
        if snapshot.relevantHealth == .unknown {
            return L10n.tr("anthropic.status.unknown")
        }
        return L10n.tr("anthropic.status.incident")
    }

    private var displayIncident: AnthropicIncident? {
        guard snapshot?.relevantHealth.isDisrupted == true else { return nil }
        return snapshot?.incidents.first
    }

    private var statusColor: Color {
        guard let snapshot else { return .secondary }
        return color(for: snapshot.relevantHealth)
    }

    private func color(for health: AnthropicServiceHealth) -> Color {
        switch health {
        case .operational: .green
        case .degraded, .maintenance: .yellow
        case .partialOutage: .orange
        case .majorOutage: .red
        case .unknown: .secondary
        }
    }

    private func shortHealth(_ health: AnthropicServiceHealth) -> String {
        switch health {
        case .operational: L10n.tr("anthropic.health.operational")
        case .degraded: L10n.tr("anthropic.health.degraded")
        case .partialOutage: L10n.tr("anthropic.health.partial_outage")
        case .majorOutage: L10n.tr("anthropic.health.major_outage")
        case .maintenance: L10n.tr("anthropic.health.maintenance")
        case .unknown: L10n.tr("anthropic.health.unknown")
        }
    }

    private func incidentStatus(_ value: String) -> String {
        switch value {
        case "investigating": L10n.tr("anthropic.incident.investigating")
        case "identified": L10n.tr("anthropic.incident.identified")
        case "monitoring": L10n.tr("anthropic.incident.monitoring")
        case "resolved": L10n.tr("anthropic.incident.resolved")
        default: value.capitalized
        }
    }

    private func incidentExplanation(_ value: String) -> String {
        switch value {
        case "investigating":
            L10n.tr("anthropic.incident.explanation.investigating")
        case "identified":
            L10n.tr("anthropic.incident.explanation.identified")
        case "monitoring":
            L10n.tr("anthropic.incident.explanation.monitoring")
        case "resolved":
            L10n.tr("anthropic.incident.explanation.resolved")
        default:
            L10n.tr("anthropic.incident.explanation.default")
        }
    }
}
