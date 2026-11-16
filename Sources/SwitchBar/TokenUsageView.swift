import SwiftUI
import SwitchBarCore

/// Ventana de consumo: tokens y coste equivalente de Claude Code, por día,
/// por modelo y por cuenta.
struct TokenUsageView: View {
    @Bindable var model: TokenUsageModel
    let state: AppState
    var scrolls = true

    @State private var period: UsagePeriod = .month
    @State private var account: String?
    @State private var metric: UsageChartMetric = .cost
    @State private var showAllDays = false
    @State private var appeared = false

    private static let collapsedDays = 10

    var body: some View {
        if scrolls {
            ScrollView { page }
                .background(.background)
        } else {
            page.background(.background)
        }
    }

    private var page: some View {
            VStack(alignment: .leading, spacing: 18) {
                header
                if model.ledger.buckets.isEmpty {
                    if !model.isLoaded || model.isReadingHistory || !model.ledger.hasScanned {
                        FirstScanCard(progress: model.scanProgress)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        emptyState
                    }
                } else {
                    content
                        .transition(.opacity)
                }
                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 34)
            .padding(.bottom, 28)
            .frame(maxWidth: 1_100, alignment: .leading)
            .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.35), value: model.ledger.buckets.isEmpty)
        .onAppear {
            withAnimation(.smooth(duration: 0.5).delay(0.05)) { appeared = true }
        }
    }

    // MARK: Cabecera

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("usage_stats.window_title"))
                    .font(.system(size: 24, weight: .semibold))
                Text(L10n.tr("usage_stats.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            UpdatedLabel(model: model)
            RefreshButton(model: model)
        }
    }

    // MARK: Contenido

    @ViewBuilder
    private var content: some View {
        let today = model.today
        let firstDay = model.ledger.firstDay
        let report = model.report(period, account: account)
        let chartRange = period.chartDays(today: today, firstDay: firstDay)
        let chartReport = model.report(days: chartRange, account: account)
        let days = period.dayCount(today: today, firstDay: firstDay)

        controls

        KPIRow(report: report, days: days, period: period)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)

        chartCard(report: report, chartReport: chartReport, range: chartRange)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)

        modelsCard(report)

        if account == nil, report.byAccount.count > 1 {
            accountsCard(report)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }

        daysCard(report)

        footnotes(report)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("", selection: $period.animation(.smooth(duration: 0.4))) {
                ForEach(UsagePeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)

            Spacer()

            AccountFilterMenu(
                selection: $account,
                accounts: model.accountsWithUsage,
                profiles: state.profilesList
            )
        }
    }

    private func chartCard(report: TokenUsageReport, chartReport: TokenUsageReport, range: ClosedRange<Int32>) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    Text(L10n.tr("usage_stats.chart.title"))
                        .font(.headline)
                    Spacer()
                    Picker("", selection: $metric.animation(.smooth(duration: 0.45))) {
                        ForEach(UsageChartMetric.allCases) { metric in
                            Text(metric.title).tag(metric)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 150)
                }
                UsageLegend(report: report, metric: metric, modelOrder: model.modelOrder)
                    .animation(.smooth, value: report.total.cost)
                TokenUsageChart(
                    report: chartReport,
                    range: range,
                    focus: period == .today ? range.upperBound...range.upperBound : nil,
                    metric: metric,
                    modelOrder: model.modelOrder
                )
            }
        }
    }

    // MARK: Por modelo

    private func modelsCard(_ report: TokenUsageReport) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("usage_stats.models.title"))
                    .font(.headline)
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 0) {
                    tableHeader(first: L10n.tr("usage_stats.column.model"))
                    ForEach(Array(report.byModel.enumerated()), id: \.element.id) { index, group in
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            ModelNameCell(
                                model: group.id,
                                color: UsagePalette.color(
                                    forSeries: UsagePalette.seriesKey(for: group.id, order: model.modelOrder),
                                    order: model.modelOrder
                                ),
                                share: report.total.cost > 0 ? group.totals.cost / report.total.cost : 0
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .gridColumnAlignment(.leading)
                            tokenCells(group.totals)
                        }
                        .padding(.vertical, 9)
                    }
                    if report.byModel.count > 1 {
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            Text(L10n.tr("usage_stats.tooltip.total"))
                                .fontWeight(.semibold)
                                .gridColumnAlignment(.leading)
                            tokenCells(report.total, emphasized: true)
                        }
                        .padding(.vertical, 9)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func tableHeader(first: String) -> some View {
        GridRow {
            Text(first).gridColumnAlignment(.leading)
            Text(L10n.tr("usage_stats.column.input"))
            Text(L10n.tr("usage_stats.column.output"))
            Text(L10n.tr("usage_stats.column.cache_write"))
            Text(L10n.tr("usage_stats.column.cache_read"))
            Text(L10n.tr("usage_stats.column.total"))
            Text(L10n.tr("usage_stats.column.cost"))
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func tokenCells(_ totals: UsageTotals, emphasized: Bool = false) -> some View {
        TokenCell(value: totals.counts.input)
        TokenCell(value: totals.counts.output)
        TokenCell(value: totals.counts.cacheWrite)
        TokenCell(value: totals.counts.cacheRead)
        TokenCell(value: totals.counts.total, emphasized: true)
        Text(UsageFormat.cost(totals.cost))
            .fontWeight(.semibold)
            .monospacedDigit()
            .contentTransition(.numericText(value: totals.cost))
            .foregroundStyle(emphasized ? .primary : .primary)
    }

    // MARK: Por cuenta

    private func accountsCard(_ report: TokenUsageReport) -> some View {
        let maxCost = report.byAccount.map(\.totals.cost).max() ?? 0
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("usage_stats.accounts.title"))
                    .font(.headline)
                VStack(spacing: 0) {
                    // Lo que no se sabe de qué cuenta es va al final: no es una cuenta.
                    let groups = report.byAccount.filter { !$0.id.isEmpty } + report.byAccount.filter { $0.id.isEmpty }
                    ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                        if index > 0 { Divider() }
                        AccountUsageRow(
                            label: UsageAccountLabel(key: group.id, profiles: state.profilesList),
                            totals: group.totals,
                            share: report.total.cost > 0 ? group.totals.cost / report.total.cost : 0,
                            relative: maxCost > 0 ? group.totals.cost / maxCost : 0,
                            onSelect: {
                                withAnimation(.smooth(duration: 0.4)) { account = group.id }
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: Día a día

    private func daysCard(_ report: TokenUsageReport) -> some View {
        let days = report.byDay
        let visible = showAllDays ? days : Array(days.prefix(Self.collapsedDays))
        let maxCost = days.map(\.totals.cost).max() ?? 0
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("usage_stats.days.title"))
                    .font(.headline)
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 0) {
                    tableHeader(first: L10n.tr("usage_stats.column.day"))
                    ForEach(visible) { day in
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            DayNameCell(day: day.day, today: model.today, relative: maxCost > 0 ? day.totals.cost / maxCost : 0)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .gridColumnAlignment(.leading)
                            tokenCells(day.totals)
                        }
                        .padding(.vertical, 8)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity)
                if days.count > Self.collapsedDays {
                    Button {
                        withAnimation(.smooth(duration: 0.35)) { showAllDays.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showAllDays
                                 ? L10n.tr("usage_stats.days.show_less")
                                 : L10n.tr("usage_stats.days.show_all", days.count))
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(showAllDays ? 180 : 0))
                        }
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: Notas

    private func footnotes(_ report: TokenUsageReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if report.total.unpricedTokens > 0 {
                Label(
                    L10n.tr("usage_stats.unpriced", UsageFormat.tokens(report.total.unpricedTokens)),
                    systemImage: "questionmark.circle"
                )
            }
            Label(L10n.tr("usage_stats.footnote.pricing"), systemImage: "info.circle")
            Label(L10n.tr("usage_stats.footnote.attribution"), systemImage: "person.crop.circle.badge.questionmark")
            if let first = model.ledger.firstDay {
                Label(
                    L10n.tr("usage_stats.footnote.history", UsageFormat.dayLong(first)),
                    systemImage: "clock.arrow.circlepath"
                )
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
    }

    private var emptyState: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(L10n.tr("usage_stats.empty.title"))
                    .font(.headline)
                Text(L10n.tr("usage_stats.empty.detail"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        }
    }
}

// MARK: - Piezas

/// Tarjeta con el mismo aspecto que las de la ventana de detalle.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quinary))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
            )
    }
}

/// Las cuatro cifras principales del periodo.
private struct KPIRow: View {
    let report: TokenUsageReport
    let days: Int
    let period: UsagePeriod

    var body: some View {
        let counts = report.total.counts
        let cacheShare = counts.total > 0 ? Double(counts.cacheRead) / Double(counts.total) : 0
        HStack(spacing: 12) {
            KPITile(
                title: L10n.tr("usage_stats.kpi.cost"),
                systemImage: "dollarsign.circle",
                value: UsageFormat.cost(report.total.cost),
                numeric: report.total.cost,
                detail: period == .today
                    ? L10n.tr("usage_stats.kpi.cost_today")
                    : L10n.tr("usage_stats.kpi.cost_detail", UsageFormat.cost(report.total.cost / Double(max(1, days))))
            )
            KPITile(
                title: L10n.tr("usage_stats.kpi.tokens"),
                systemImage: "text.word.spacing",
                value: UsageFormat.tokens(counts.total),
                numeric: Double(counts.total),
                detail: L10n.tr(
                    "usage_stats.kpi.tokens_detail",
                    UsageFormat.tokens(counts.input),
                    UsageFormat.tokens(counts.output)
                ),
                help: UsageFormat.tokensFull(counts.total)
            )
            KPITile(
                title: L10n.tr("usage_stats.kpi.cache"),
                systemImage: "memorychip",
                value: UsageFormat.percent(cacheShare),
                numeric: cacheShare,
                detail: L10n.tr(
                    "usage_stats.kpi.cache_detail",
                    UsageFormat.tokens(counts.cacheRead),
                    UsageFormat.tokens(counts.cacheWrite)
                )
            )
            KPITile(
                title: L10n.tr("usage_stats.kpi.messages"),
                systemImage: "bubble.left.and.text.bubble.right",
                value: UsageFormat.count(counts.messages),
                numeric: Double(counts.messages),
                detail: L10n.tr(
                    "usage_stats.kpi.messages_detail",
                    UsageFormat.count(counts.messages / Int64(max(1, days)))
                )
            )
        }
    }
}

private struct KPITile: View {
    let title: String
    let systemImage: String
    let value: String
    let numeric: Double
    let detail: String
    var help: String?

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .contentTransition(.numericText(value: numeric))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quinary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(hovering ? 0.12 : 0.05), lineWidth: 1)
        )
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.snappy(duration: 0.2), value: hovering)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

private struct TokenCell: View {
    let value: Int64
    var emphasized = false

    var body: some View {
        Text(UsageFormat.tokens(value))
            .monospacedDigit()
            .foregroundStyle(emphasized ? .primary : .secondary)
            .contentTransition(.numericText(value: Double(value)))
            .help(UsageFormat.tokensFull(value))
    }
}

private struct ModelNameCell: View {
    let model: String
    let color: Color
    let share: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .frame(width: 10, height: 10)
                Text(ModelPricing.displayName(model))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .fixedSize()
                Text(UsageFormat.percent(share))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText(value: share))
            }
            ShareBar(fraction: share, color: color)
                .frame(width: 150, height: 4)
        }
        .help(model)
    }
}

private struct DayNameCell: View {
    let day: Int32
    let today: Int32
    let relative: Double

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Text(UsageFormat.dayShort(day))
                    .fontWeight(day == today ? .semibold : .regular)
                    .lineLimit(1)
                    .fixedSize()
                if day == today {
                    Text(L10n.tr("usage_stats.period.today"))
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 150, alignment: .leading)
            ShareBar(fraction: relative, color: Color.primary.opacity(0.45))
                .frame(width: 70, height: 4)
        }
    }
}

/// Barra fina de proporción que crece al aparecer.
private struct ShareBar: View {
    let fraction: Double
    let color: Color
    @State private var shown = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(color)
                    .frame(width: max(fraction > 0 ? 3 : 0, geometry.size.width * min(1, fraction) * (shown ? 1 : 0)))
            }
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: fraction)
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.1)) { shown = true }
        }
    }
}

private struct AccountUsageRow: View {
    let label: UsageAccountLabel
    let totals: UsageTotals
    let share: Double
    let relative: Double
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if label.isUnattributed {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        Text(label.title)
                            .fontWeight(label.isUnattributed ? .regular : .medium)
                            .foregroundStyle(label.isUnattributed ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let plan = label.plan {
                            PlanBadge(plan: plan, organizationName: label.organizationName)
                        }
                    }
                    if let detail = label.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ShareBar(fraction: relative, color: Color.primary.opacity(0.5))
                    .frame(width: 160, height: 5)

                Text(UsageFormat.percent(share))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)

                Text(UsageFormat.tokens(totals.counts.total))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
                    .help(UsageFormat.tokensFull(totals.counts.total))

                Text(UsageFormat.cost(totals.cost))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .frame(width: 96, alignment: .trailing)
                    .contentTransition(.numericText(value: totals.cost))

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .font(.callout)
            .padding(.vertical, 9)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(label.isUnattributed
              ? L10n.tr("usage_stats.footnote.attribution")
              : L10n.tr("usage_stats.accounts.filter_help"))
    }
}

private struct AccountFilterMenu: View {
    @Binding var selection: String?
    let accounts: [String]
    let profiles: [AccountProfile]

    var body: some View {
        Menu {
            Button(L10n.tr("usage_stats.all_accounts")) {
                withAnimation(.smooth(duration: 0.4)) { selection = nil }
            }
            Divider()
            ForEach(accounts, id: \.self) { key in
                let label = UsageAccountLabel(key: key, profiles: profiles)
                Button {
                    withAnimation(.smooth(duration: 0.4)) { selection = key }
                } label: {
                    if let detail = label.detail {
                        Text("\(label.title) · \(detail)")
                    } else {
                        Text(label.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selection == nil ? "person.2" : "person.crop.circle")
                Text(currentTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .menuStyle(.button)
        .fixedSize()
    }

    private var currentTitle: String {
        guard let selection else { return L10n.tr("usage_stats.all_accounts") }
        let label = UsageAccountLabel(key: selection, profiles: profiles)
        return label.detail.map { "\(label.title) · \($0)" } ?? label.title
    }
}

/// «Actualizado hace 2 min». Vista aparte: cada lectura cambia la hora y así
/// solo se redibuja este texto, no la ventana entera.
private struct UpdatedLabel: View {
    let model: TokenUsageModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            if let last = model.lastScanAt {
                Text(L10n.tr("usage_stats.updated", ResetFormatter.since(last)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Actualizar a mano. Las lecturas automáticas no se anuncian; la pedida con
/// el botón muestra un indicador breve y una marca al terminar.
private struct RefreshButton: View {
    let model: TokenUsageModel
    @State private var showDone = false

    var body: some View {
        Button {
            model.refreshByHand()
        } label: {
            ZStack {
                if model.isRefreshingByHand {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                        .transition(.opacity)
                } else if showDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(model.isRefreshingByHand)
        .help(L10n.tr("usage_stats.refresh"))
        .animation(.snappy(duration: 0.2), value: model.isRefreshingByHand)
        .animation(.snappy(duration: 0.2), value: showDone)
        .onChange(of: model.isRefreshingByHand) { _, refreshing in
            guard !refreshing else { return }
            showDone = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                showDone = false
            }
        }
    }
}

/// Primera lectura: recorre todas las transcripciones que queden en disco.
private struct FirstScanCard: View {
    let progress: Double?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.tr("usage_stats.scanning", Int(((progress ?? 0) * 100).rounded())))
                        .font(.headline)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: progress ?? 0))
                }
                ProgressView(value: progress ?? 0)
                    .progressViewStyle(.linear)
                    .animation(.smooth(duration: 0.4), value: progress)
                Text(L10n.tr("usage_stats.scanning.first"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
