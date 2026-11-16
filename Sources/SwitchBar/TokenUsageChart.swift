import Charts
import SwiftUI
import SwitchBarCore

/// Qué mide el gráfico diario.
enum UsageChartMetric: String, CaseIterable, Identifiable {
    case cost, tokens
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cost: L10n.tr("usage_stats.chart.metric.cost")
        case .tokens: L10n.tr("usage_stats.chart.metric.tokens")
        }
    }

    func value(_ totals: UsageTotals) -> Double {
        switch self {
        case .cost: totals.cost
        case .tokens: Double(totals.counts.total)
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .cost: UsageFormat.cost(value)
        case .tokens: UsageFormat.tokens(Int64(value))
        }
    }

    func axis(_ value: Double) -> String {
        switch self {
        case .cost: UsageFormat.costAxis(value)
        case .tokens: UsageFormat.tokens(Int64(value))
        }
    }
}

/// Barras apiladas por modelo, un día por barra, con ayuda al pasar el ratón.
struct TokenUsageChart: View {
    let report: TokenUsageReport
    let range: ClosedRange<Int32>
    /// Días del periodo elegido; el resto del gráfico queda de contexto, atenuado.
    let focus: ClosedRange<Int32>?
    let metric: UsageChartMetric
    let modelOrder: [String]

    @State private var hoveredDay: Int32?
    @State private var grown = false

    private static let plotHeight: CGFloat = 220

    private struct Segment: Identifiable {
        var day: Int32
        var series: String
        var value: Double
        var start: Double
        var end: Double
        var id: String { "\(day)-\(series)" }
    }

    /// Series del periodo: los modelos con color propio, en su orden fijo, y
    /// «Otros» al final.
    private var seriesKeys: [String] {
        var keys: [String] = []
        for model in modelOrder where keys.count < UsagePalette.slotCount {
            if report.byModel.contains(where: { $0.id == model && metric.value($0.totals) > 0 }) {
                keys.append(model)
            }
        }
        let hasOther = report.byModel.contains {
            UsagePalette.seriesKey(for: $0.id, order: modelOrder) == UsagePalette.otherKey
                && metric.value($0.totals) > 0
        }
        if hasOther { keys.append(UsagePalette.otherKey) }
        return keys
    }

    private func seriesValues(_ day: TokenUsageReport.Day) -> [String: Double] {
        var values: [String: Double] = [:]
        for (model, totals) in day.byModel {
            let key = UsagePalette.seriesKey(for: model, order: modelOrder)
            values[key, default: 0] += metric.value(totals)
        }
        return values
    }

    private var maxValue: Double {
        report.byDay.filter { range.contains($0.day) }.map { metric.value($0.totals) }.max() ?? 0
    }

    /// Techo del eje redondeado a un número limpio.
    private var yCeiling: Double {
        let top = max(maxValue, metric == .cost ? 1 : 1_000)
        let magnitude = pow(10, floor(log10(top)))
        for step in [1.0, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10] where step * magnitude >= top * 1.08 {
            return step * magnitude
        }
        return 10 * magnitude
    }

    private var segments: [Segment] {
        let keys = seriesKeys
        // Separación de 2 px entre segmentos y un mínimo de 3 px por segmento,
        // en unidades del eje: un modelo que gasta cien veces menos que otro
        // mediría menos de un píxel y desaparecería. La ayuda da la cifra exacta.
        let pixel = yCeiling / Self.plotHeight
        let gap = pixel * 2
        let minimum = pixel * 3
        var result: [Segment] = []
        for day in report.byDay where range.contains(day.day) {
            let values = seriesValues(day)
            let present = keys.filter { (values[$0] ?? 0) > 0 }
            var running = 0.0
            for (index, key) in present.enumerated() {
                let value = values[key] ?? 0
                let isTop = index == present.count - 1
                let height = max(value, minimum + (isTop ? 0 : gap))
                let end = running + height
                let drawnEnd = isTop ? end : end - gap
                result.append(Segment(day: day.day, series: key, value: value, start: running, end: drawnEnd))
                running = end
            }
        }
        return result
    }

    var body: some View {
        let segments = self.segments
        let ceiling = yCeiling
        Chart(segments) { segment in
            BarMark(
                x: .value("day", LocalDay.date(segment.day), unit: .day),
                yStart: .value("start", segment.start * (grown ? 1 : 0)),
                yEnd: .value("end", segment.end * (grown ? 1 : 0)),
                width: .ratio(range.count > 40 ? 0.7 : 0.62)
            )
            .cornerRadius(3, style: .continuous)
            .foregroundStyle(UsagePalette.color(forSeries: segment.series, order: modelOrder))
            .opacity(opacity(for: segment.day))
        }
        .chartXScale(domain: LocalDay.date(range.lowerBound).addingTimeInterval(-43_200)
            ... LocalDay.date(range.upperBound).addingTimeInterval(43_200))
        .chartYScale(domain: 0...ceiling)
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(Color.secondary.opacity(0.35))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(metric.axis(number))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            // Una marca al mediodía de cada día elegido: es el centro de su barra.
            AxisMarks(values: xAxisDates) { value in
                // La última etiqueta se apoya a la izquierda para no salirse.
                AxisValueLabel(anchor: value.as(Date.self) == xAxisDates.first ? .topTrailing : .top) {
                    if let date = value.as(Date.self) {
                        Text(date.formatted(.dateTime.day().month(.abbreviated).locale(L10n.locale)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                hoverLayer(proxy: proxy, geometry: geometry)
            }
        }
        .frame(height: Self.plotHeight)
        .animation(.smooth(duration: 0.5), value: segments.map(\.end))
        .onAppear {
            withAnimation(.spring(response: 0.75, dampingFraction: 0.86).delay(0.05)) {
                grown = true
            }
        }
        .accessibilityLabel(L10n.tr("usage_stats.chart.title"))
    }

    /// Fechas del eje: siempre incluye hoy y retrocede de `xStride` en `xStride`.
    private var xAxisDates: [Date] {
        stride(from: Int(range.upperBound), through: Int(range.lowerBound), by: -xStride)
            .map { LocalDay.date(Int32($0)) }
    }

    private var xStride: Int {
        switch range.count {
        case ...8: 1
        case ...15: 2
        case ...31: 5
        case ...70: 10
        default: 30
        }
    }

    private func opacity(for day: Int32) -> Double {
        if let hoveredDay { return hoveredDay == day ? 1 : 0.38 }
        if let focus, !focus.contains(day) { return 0.32 }
        return 1
    }

    // MARK: Ayuda al pasar el ratón

    @ViewBuilder
    private func hoverLayer(proxy: ChartProxy, geometry: GeometryProxy) -> some View {
        let plot = proxy.plotFrame.map { geometry[$0] } ?? .zero
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let x = location.x - plot.minX
                        guard x >= 0, x <= plot.width,
                              let date: Date = proxy.value(atX: x) else {
                            setHovered(nil)
                            return
                        }
                        let day = LocalDay.number(of: date)
                        setHovered(range.contains(day) ? day : nil)
                    case .ended:
                        setHovered(nil)
                    }
                }

            if let hoveredDay,
               let center = proxy.position(forX: LocalDay.date(hoveredDay)) {
                let width: CGFloat = 232
                let barX = plot.minX + center
                let placeRight = barX + 18 + width <= geometry.size.width
                let x = placeRight ? barX + 18 : max(0, barX - 18 - width)
                tooltip(for: hoveredDay)
                    .frame(width: width, alignment: .leading)
                    .offset(x: x, y: plot.minY + 4)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    .id(hoveredDay)
            }
        }
    }

    private func setHovered(_ day: Int32?) {
        guard day != hoveredDay else { return }
        withAnimation(.easeOut(duration: 0.14)) { hoveredDay = day }
    }

    private func tooltip(for day: Int32) -> some View {
        let entry = report.byDay.first { $0.day == day }
        let values = entry.map(seriesValues) ?? [:]
        let rows = seriesKeys.filter { (values[$0] ?? 0) > 0 }.sorted { (values[$0] ?? 0) > (values[$1] ?? 0) }
        return VStack(alignment: .leading, spacing: 7) {
            Text(UsageFormat.dayLong(day))
                .font(.caption.weight(.semibold))
            if rows.isEmpty {
                Text(L10n.tr("usage_stats.chart.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.self) { key in
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(UsagePalette.color(forSeries: key, order: modelOrder))
                        .frame(width: 9, height: 9)
                    Text(UsagePalette.name(forSeries: key))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(metric.format(values[key] ?? 0))
                        .monospacedDigit()
                }
                .font(.caption)
            }
            if let entry {
                Divider()
                HStack {
                    Text(L10n.tr("usage_stats.tooltip.total"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(UsageFormat.cost(entry.totals.cost))
                        .fontWeight(.semibold)
                }
                .font(.caption.monospacedDigit())
                HStack {
                    Text(L10n.tr("usage_stats.kpi.tokens"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(UsageFormat.tokens(entry.totals.counts.total))
                }
                .font(.caption.monospacedDigit())
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

/// Leyenda: cada modelo con su color, su nombre y su cifra del periodo, para
/// que el color nunca sea lo único que lo identifica.
struct UsageLegend: View {
    let report: TokenUsageReport
    let metric: UsageChartMetric
    let modelOrder: [String]

    private var entries: [(key: String, value: Double)] {
        var values: [String: Double] = [:]
        for group in report.byModel {
            let key = UsagePalette.seriesKey(for: group.id, order: modelOrder)
            values[key, default: 0] += metric.value(group.totals)
        }
        let ordered = modelOrder.filter { values[$0] != nil } + (values[UsagePalette.otherKey] != nil ? [UsagePalette.otherKey] : [])
        return ordered.compactMap { key in values[key].map { (key, $0) } }.filter { $0.value > 0 }
    }

    var body: some View {
        FlowLayout(spacing: 16, lineSpacing: 8) {
            ForEach(entries, id: \.key) { entry in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(UsagePalette.color(forSeries: entry.key, order: modelOrder))
                        .frame(width: 10, height: 10)
                    Text(UsagePalette.name(forSeries: entry.key))
                        .foregroundStyle(.primary)
                    Text(metric.format(entry.value))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .font(.caption)
            }
        }
    }
}

/// Disposición en filas que saltan de línea cuando no caben.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
