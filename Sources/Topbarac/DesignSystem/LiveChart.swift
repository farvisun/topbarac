import Charts
import SwiftUI
import TopbaracCore

nonisolated enum ChartRange: String, CaseIterable, Identifiable, Sendable {
    case m1 = "1m", m10 = "10m", h1 = "1h", h24 = "24h", d7 = "7d", d30 = "30d", all = "All"
    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .m1: 60
        case .m10: 600
        case .h1: 3600
        case .h24: 86400
        case .d7: 7 * 86400
        case .d30: 30 * 86400
        case .all: nil
        }
    }

    /// Ranges beyond one hour come from the on-disk history.
    var persisted: Bool { self == .h24 || self == .d7 || self == .d30 || self == .all }
}

struct ChartSeries: Identifiable {
    var key: SeriesKey
    var label: String
    var color: Color
    /// Drawn below the axis (writes, uploads) so two rates share one chart.
    var mirrored = false
    var area = true
    var id: SeriesKey { key }
}

struct ChartSpec {
    var series: [ChartSeries]
    /// Fixed domain (usage charts) or nil to fit the data.
    var domain: ClosedRange<Double>?
    /// Temperatures read better on a scale that doesn't start at zero.
    var includesZero = true
    /// Areas stack on top of each other (parts of one whole, like user + system CPU).
    var stacked = false
    /// Warning and critical lines, in chart units. Lines outside the visible scale are skipped.
    var thresholds: [(value: Double, level: Level)] = []
    /// Alert events of this widget are marked on the time axis.
    var kind: WidgetKind?
    var format: (Double) -> String
}

extension ChartSpec {
    /// Threshold lines from a widget's settings; `scale` converts the setting (percent, °C) to chart units.
    static func thresholds(_ config: WidgetConfig, scale: Double = 1) -> [(value: Double, level: Level)] {
        guard config.thresholdsEnabled else { return [] }
        return [(config.warning * scale, .warning), (config.critical * scale, .critical)]
    }
}

nonisolated private struct ChartPoint: Identifiable, Sendable {
    var series: SeriesKey
    var segment: Int
    var time: Date
    var raw: Double          // the sample itself
    var base: Double = 0     // bottom of the area (stacked charts)
    var top: Double          // top of the area / line position
    var id: String { "\(series.rawValue)-\(segment)-\(time.timeIntervalSince1970)" }
    var seriesID: String { "\(series.rawValue)-\(segment)" }
}

/// Compact live chart: legend with current values and range switch on one line, then the plot.
/// Hover or use the arrow keys to read a sample; the chart holds still while you do.
struct LiveChart: View {
    var spec: ChartSpec
    var height: CGFloat = 78

    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @State private var range: ChartRange = .m1
    @State private var selection: Date?
    @State private var frozen: [ChartPoint]?
    @State private var persisted: [ChartPoint] = []
    @State private var loadingPersisted = false
    @FocusState private var focused: Bool

    private var ranges: [ChartRange] {
        settings.settings.historyEnabled ? ChartRange.allCases : [.m1, .m10, .h1]
    }

    var body: some View {
        let points = frozen ?? currentPoints()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                legend(points)
                Spacer(minLength: 4)
                RangeSwitch(ranges: ranges, selection: $range)
            }
            chart(points)
                .frame(height: height)
                .overlay {
                    if points.isEmpty {
                        Text(loadingPersisted ? "Loading history…" : "Collecting samples…")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
            if let summary = summary(points) {
                Text(summary).font(.system(size: 9.5)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
            }
        }
        .task(id: range) { await loadPersisted() }
        .onChange(of: settings.settings.historyEnabled) { if !ranges.contains(range) { range = .m1 } }
    }

    /// Legend entries carry the latest value (or the hovered one), so the chart doubles as a readout.
    private func legend(_ points: [ChartPoint]) -> some View {
        let shown = selection.map { nearest(to: $0, in: points) } ?? latest(points)
        return HStack(spacing: 9) {
            ForEach(spec.series) { s in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(s.color).frame(width: 7, height: 7)
                    Text(s.label).foregroundStyle(.secondary)
                    if let p = shown.first(where: { $0.series == s.key }) {
                        Text(spec.format(abs(p.raw))).fontWeight(.semibold).monospacedDigit()
                    }
                }
                .font(.system(size: 10.5))
                .fixedSize()
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    // MARK: Data

    private func currentPoints() -> [ChartPoint] {
        if range.persisted { return persisted }
        let since = Date().addingTimeInterval(-(range.seconds ?? 60))
        var input: [(SeriesKey, Bool, [SeriesPoint])] = []
        for s in spec.series {
            guard let history = store.series(s.key) else { continue }
            input.append((s.key, s.mirrored, history.window(since: since, maxPoints: 150)))
        }
        return Self.build(input, stacked: spec.stacked)
    }

    nonisolated private static func build(_ input: [(SeriesKey, Bool, [SeriesPoint])], stacked: Bool) -> [ChartPoint] {
        var out: [ChartPoint] = []
        var running: [Date: Double] = [:]
        for (key, mirrored, points) in input {
            var segment = 0
            for p in points {
                guard let v = p.value else { segment += 1; continue }
                if stacked {
                    let base = running[p.time] ?? 0
                    out.append(ChartPoint(series: key, segment: segment, time: p.time, raw: v, base: base, top: base + v))
                    running[p.time] = base + v
                } else {
                    out.append(ChartPoint(series: key, segment: segment, time: p.time, raw: v, top: mirrored ? -v : v))
                }
            }
        }
        return out
    }

    private func loadPersisted() async {
        guard range.persisted, let historyStore = store.historyStore else { persisted = []; return }
        loadingPersisted = true
        let specSeries = spec.series.map { ($0.key, $0.mirrored) }
        let stacked = spec.stacked
        let range = self.range
        let points = await Task.detached(priority: .userInitiated) { () -> [ChartPoint] in
            let since = range.seconds.map { Date().addingTimeInterval(-$0) } ?? (historyStore.oldest() ?? Date().addingTimeInterval(-86400))
            historyStore.flush()
            let input = specSeries.map { key, mirrored in (key, mirrored, historyStore.query(key, since: since, maxPoints: 200)) }
            return Self.build(input, stacked: stacked)
        }.value
        persisted = points
        loadingPersisted = false
    }

    // MARK: Chart

    private func color(_ key: SeriesKey) -> Color { spec.series.first { $0.key == key }?.color ?? .accentColor }
    private func isArea(_ key: SeriesKey) -> Bool { spec.series.first { $0.key == key }?.area ?? true }

    private func latest(_ points: [ChartPoint]) -> [ChartPoint] {
        var best: [SeriesKey: ChartPoint] = [:]
        for p in points where (best[p.series]?.time ?? .distantPast) <= p.time { best[p.series] = p }
        return spec.series.compactMap { best[$0.key] }
    }

    @ViewBuilder
    private func chart(_ points: [ChartPoint]) -> some View {
        let selected = selection.map { nearest(to: $0, in: points) } ?? []
        let ends = selection == nil ? latest(points) : []
        Chart {
            ForEach(points) { p in
                if isArea(p.series) {
                    AreaMark(x: .value("Time", p.time), yStart: .value("Base", p.base), yEnd: .value("Value", p.top),
                             series: .value("Series", p.seriesID))
                        .foregroundStyle(areaStyle(p))
                        .interpolationMethod(.monotone)
                }
                LineMark(x: .value("Time", p.time), y: .value("Value", p.top), series: .value("Series", p.seriesID))
                    .foregroundStyle(color(p.series))
                    .lineStyle(StrokeStyle(lineWidth: isArea(p.series) ? 1.3 : 1.6, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            ForEach(Array(visibleThresholds(points).enumerated()), id: \.offset) { _, t in
                RuleMark(y: .value("Threshold", t.value))
                    .foregroundStyle(t.level.color.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            }
            ForEach(events(points), id: \.time) { e in
                RuleMark(x: .value("Alert", e.time))
                    .foregroundStyle(Color.red.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .center, spacing: -2) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 7)).foregroundStyle(.red)
                            .help("\(e.rule.metric.title) alert at \(e.time.formatted(date: .omitted, time: .shortened))")
                    }
            }
            ForEach(ends) { p in
                PointMark(x: .value("Time", p.time), y: .value("Value", p.top))
                    .foregroundStyle(color(p.series))
                    .symbolSize(14)
            }
            if let first = selected.first {
                RuleMark(x: .value("Selected", first.time))
                    .foregroundStyle(.primary.opacity(0.3))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .annotation(position: .top, alignment: .center, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(first.time)
                    }
                ForEach(selected) { p in
                    PointMark(x: .value("Time", p.time), y: .value("Value", p.top))
                        .foregroundStyle(color(p.series))
                        .symbolSize(30)
                }
            }
        }
        .chartLegend(.hidden)
        .chartXAxis {
            if range.persisted {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel(format: axisFormat).font(.system(size: 8.5)).foregroundStyle(.tertiary)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(.primary.opacity(0.12))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(spec.format(abs(v))).font(.system(size: 8.5)).foregroundStyle(.tertiary) }
                }
            }
        }
        .modifier(DomainModifier(domain: spec.domain ?? fittedDomain(points), includesZero: spec.includesZero,
                                 mirroredMax: spec.series.contains(where: \.mirrored) ? max(points.map { abs($0.top) }.max() ?? 1, 1) * 1.15 : nil))
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            if frozen == nil { frozen = points }
                            selection = proxy.value(atX: location.x - geo[plot].origin.x, as: Date.self)
                        case .ended:
                            selection = nil
                            frozen = nil
                        }
                    }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1, points); return .handled }
        .onKeyPress(.rightArrow) { step(1, points); return .handled }
        .onKeyPress(.escape) { selection = nil; frozen = nil; return .handled }
        .accessibilityLabel(spec.series.map(\.label).joined(separator: " and ") + " chart")
        .accessibilityValue(accessibilitySummary(points))
    }

    /// The whole-chart readout under the plot: low, average and peak of the main series over the shown range
    /// (the stacked total for stacked charts), plus the peak of a mirrored series.
    private func summary(_ points: [ChartPoint]) -> String? {
        guard selection == nil, let main = spec.series.first else { return nil }
        var values: [Double]
        if spec.stacked, let last = spec.series.last {
            values = points.filter { $0.series == last.key }.map(\.top)
        } else {
            values = points.filter { $0.series == main.key }.map(\.raw)
        }
        guard values.count > 2, let lo = values.min(), let hi = values.max() else { return nil }
        let avg = values.reduce(0, +) / Double(values.count)
        let label = spec.stacked ? "Total" : (spec.series.count > 1 ? main.label : "")
        var text = "\(label.isEmpty ? "" : label + "  ")low \(spec.format(lo))  ·  avg \(spec.format(avg))  ·  peak \(spec.format(hi))"
        if let mirrored = spec.series.first(where: \.mirrored),
           let peak = points.filter({ $0.series == mirrored.key }).map(\.raw).max() {
            text += "  ·  \(mirrored.label) peak \(spec.format(peak))"
        }
        return text
    }

    private func visibleThresholds(_ points: [ChartPoint]) -> [(value: Double, level: Level)] {
        guard let domain = spec.domain ?? fittedDomain(points) else { return [] }
        return spec.thresholds.filter { domain.contains($0.value) }
    }

    private func events(_ points: [ChartPoint]) -> [AlertEvent] {
        guard let kind = spec.kind, let first = points.map(\.time).min() else { return [] }
        return store.recentAlerts.filter { $0.rule.metric.widget == kind && $0.time >= first }
    }

    /// Domain for charts without a fixed one. Temperatures hug the data (padded, snapped to 5s) so lines don't sit
    /// flat in the middle; other charts keep zero and get headroom so a steady value doesn't fill the whole plot.
    private func fittedDomain(_ points: [ChartPoint]) -> ClosedRange<Double>? {
        guard !spec.series.contains(where: \.mirrored), let lo = points.map(\.top).min(), let hi = points.map(\.top).max() else { return nil }
        if !spec.includesZero {
            let low = ((lo - 3) / 5).rounded(.down) * 5
            return low...max(low + 10, ((hi + 3) / 5).rounded(.up) * 5)
        }
        let low = min(0, lo * 1.25), high = max(0, hi * 1.25)
        return high - low < 1e-9 ? 0...1 : low...high
    }

    private func areaStyle(_ p: ChartPoint) -> AnyShapeStyle {
        let c = color(p.series)
        if spec.stacked { return AnyShapeStyle(c.opacity(0.5)) }
        let up = p.top >= 0
        return AnyShapeStyle(LinearGradient(colors: [c.opacity(0.32), c.opacity(0.02)], startPoint: up ? .top : .bottom, endPoint: up ? .bottom : .top))
    }

    private var axisFormat: Date.FormatStyle {
        range == .h24 ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day()
    }

    private func nearest(to date: Date, in points: [ChartPoint]) -> [ChartPoint] {
        var best: [SeriesKey: ChartPoint] = [:]
        for p in points {
            if let b = best[p.series], abs(b.time.timeIntervalSince(date)) <= abs(p.time.timeIntervalSince(date)) { continue }
            best[p.series] = p
        }
        return spec.series.compactMap { best[$0.key] }
    }

    private func step(_ direction: Int, _ points: [ChartPoint]) {
        let times = Array(Set(points.map(\.time))).sorted()
        guard !times.isEmpty else { return }
        if frozen == nil { frozen = points }
        guard let current = selection, let index = times.firstIndex(where: { $0 >= current }) else {
            selection = times.last
            return
        }
        selection = times[max(0, min(times.count - 1, index + direction))]
    }

    /// The values themselves are in the legend while hovering; the tooltip only says when.
    private func tooltip(_ time: Date) -> some View {
        Text(time, format: range.persisted ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.hour().minute().second())
            .font(.system(size: 9.5, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.regularMaterial, in: .capsule)
    }

    private func accessibilitySummary(_ points: [ChartPoint]) -> String {
        spec.series.compactMap { s in
            let values = points.filter { $0.series == s.key }.map(\.raw)
            guard let last = values.last, let maxValue = values.max() else { return nil }
            return "\(s.label) now \(spec.format(last)), peak \(spec.format(maxValue))"
        }.joined(separator: ". ")
    }
}

/// Range picker as a small menu button ("1m ⌄"): fits next to a full legend at any width.
struct RangeSwitch: View {
    var ranges: [ChartRange]
    @Binding var selection: ChartRange

    var body: some View {
        Menu {
            Picker("Range", selection: $selection) {
                ForEach(ranges.filter { !$0.persisted }) { Text(label($0)).tag($0) }
                if ranges.contains(where: \.persisted) {
                    Divider()
                    ForEach(ranges.filter(\.persisted)) { Text(label($0)).tag($0) }
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 2) {
                Text(selection.rawValue).font(.system(size: 10, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(.primary.opacity(0.06), in: .rect(cornerRadius: 5))
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Chart range")
        .accessibilityLabel("Chart range, \(label(selection))")
    }

    private func label(_ r: ChartRange) -> String {
        switch r {
        case .m1: "Last minute"
        case .m10: "Last 10 minutes"
        case .h1: "Last hour"
        case .h24: "Last 24 hours"
        case .d7: "Last 7 days"
        case .d30: "Last 30 days"
        case .all: "All history"
        }
    }
}

private struct DomainModifier: ViewModifier {
    var domain: ClosedRange<Double>?
    var includesZero: Bool
    var mirroredMax: Double?

    func body(content: Content) -> some View {
        if let domain {
            content.chartYScale(domain: domain)
        } else if let m = mirroredMax {
            content.chartYScale(domain: -m...m)
        } else {
            content.chartYScale(domain: .automatic(includesZero: includesZero))
        }
    }
}
