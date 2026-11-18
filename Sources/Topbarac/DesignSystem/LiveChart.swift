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
    var format: (Double) -> String
}

nonisolated private struct ChartPoint: Identifiable, Sendable {
    var series: SeriesKey
    var segment: Int
    var time: Date
    var value: Double
    var id: String { "\(series.rawValue)-\(segment)-\(time.timeIntervalSince1970)" }
    var seriesID: String { "\(series.rawValue)-\(segment)" }
}

/// One-minute (or longer) chart. Hover or use the arrow keys to read a sample; the chart holds still while you do.
struct LiveChart: View {
    var spec: ChartSpec
    var height: CGFloat = 110

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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                legend
                Spacer(minLength: 4)
                Picker("Range", selection: $range) {
                    ForEach(ranges) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
            }
            chart(points)
                .frame(height: height)
                .overlay {
                    if points.isEmpty {
                        Text(loadingPersisted ? "Loading history…" : "Collecting samples…")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
        }
        .task(id: range) { await loadPersisted() }
        .onChange(of: settings.settings.historyEnabled) { if !ranges.contains(range) { range = .m1 } }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach(spec.series) { s in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5).fill(s.color).frame(width: 8, height: 3)
                    Text(s.label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
        }
        .lineLimit(1)
    }

    // MARK: Data

    private func currentPoints() -> [ChartPoint] {
        if range.persisted { return persisted }
        let since = Date().addingTimeInterval(-(range.seconds ?? 60))
        var out: [ChartPoint] = []
        for s in spec.series {
            guard let history = store.series(s.key) else { continue }
            out += Self.segments(history.window(since: since, maxPoints: 180), key: s.key, mirrored: s.mirrored)
        }
        return out
    }

    nonisolated private static func segments(_ points: [SeriesPoint], key: SeriesKey, mirrored: Bool) -> [ChartPoint] {
        var out: [ChartPoint] = []
        var segment = 0
        for p in points {
            guard let v = p.value else { segment += 1; continue }
            out.append(ChartPoint(series: key, segment: segment, time: p.time, value: mirrored ? -v : v))
        }
        return out
    }

    private func loadPersisted() async {
        guard range.persisted, let historyStore = store.historyStore else { persisted = []; return }
        loadingPersisted = true
        let specSeries = spec.series.map { ($0.key, $0.mirrored) }
        let range = self.range
        let points = await Task.detached(priority: .userInitiated) { () -> [ChartPoint] in
            let since = range.seconds.map { Date().addingTimeInterval(-$0) } ?? (historyStore.oldest() ?? Date().addingTimeInterval(-86400))
            historyStore.flush()
            var out: [ChartPoint] = []
            for (key, mirrored) in specSeries {
                out += Self.segments(historyStore.query(key, since: since, maxPoints: 240), key: key, mirrored: mirrored)
            }
            return out
        }.value
        persisted = points
        loadingPersisted = false
    }

    // MARK: Chart

    private func color(_ key: SeriesKey) -> Color { spec.series.first { $0.key == key }?.color ?? .accentColor }
    private func label(_ key: SeriesKey) -> String { spec.series.first { $0.key == key }?.label ?? key.rawValue }
    private func isArea(_ key: SeriesKey) -> Bool { spec.series.first { $0.key == key }?.area ?? true }

    @ViewBuilder
    private func chart(_ points: [ChartPoint]) -> some View {
        let selected = selection.map { nearest(to: $0, in: points) } ?? []
        Chart {
            ForEach(points) { p in
                if isArea(p.series) {
                    AreaMark(x: .value("Time", p.time), yStart: .value("Zero", 0), yEnd: .value("Value", p.value), series: .value("Series", p.seriesID))
                        .foregroundStyle(LinearGradient(colors: [color(p.series).opacity(0.38), color(p.series).opacity(0.04)],
                                                        startPoint: p.value >= 0 ? .top : .bottom, endPoint: p.value >= 0 ? .bottom : .top))
                        .interpolationMethod(.monotone)
                }
                LineMark(x: .value("Time", p.time), y: .value("Value", p.value), series: .value("Series", p.seriesID))
                    .foregroundStyle(color(p.series))
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let first = selected.first {
                RuleMark(x: .value("Selected", first.time))
                    .foregroundStyle(.primary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .center, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(selected)
                    }
                ForEach(selected) { p in
                    PointMark(x: .value("Time", p.time), y: .value("Value", p.value))
                        .foregroundStyle(color(p.series))
                        .symbolSize(28)
                }
            }
        }
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(.primary.opacity(0.12))
                AxisValueLabel(format: axisFormat).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.primary.opacity(0.08))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(spec.format(abs(v))).font(.system(size: 9)).foregroundStyle(.tertiary) }
                }
            }
        }
        .modifier(DomainModifier(domain: spec.domain, includesZero: spec.includesZero, mirroredMax: spec.series.contains(where: \.mirrored)
            ? max(points.map { abs($0.value) }.max() ?? 1, 1) * 1.1 : nil))
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geo[plot].origin.x
                            if frozen == nil { frozen = points }
                            selection = proxy.value(atX: x, as: Date.self)
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

    private var axisFormat: Date.FormatStyle {
        switch range {
        case .m1: .dateTime.hour().minute().second()
        case .m10, .h1, .h24: .dateTime.hour().minute()
        case .d7, .d30: .dateTime.month(.abbreviated).day()
        case .all: .dateTime.month(.abbreviated).day()
        }
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

    private func tooltip(_ selected: [ChartPoint]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(selected.first!.time, format: range.persisted ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.hour().minute().second())
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
            ForEach(selected) { p in
                HStack(spacing: 4) {
                    Circle().fill(color(p.series)).frame(width: 5, height: 5)
                    Text("\(label(p.series)) \(spec.format(abs(p.value)))").font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: .rect(cornerRadius: 7))
    }

    private func accessibilitySummary(_ points: [ChartPoint]) -> String {
        spec.series.compactMap { s in
            let values = points.filter { $0.series == s.key }.map { abs($0.value) }
            guard let last = values.last, let maxValue = values.max() else { return nil }
            return "\(s.label) now \(spec.format(last)), peak \(spec.format(maxValue))"
        }.joined(separator: ". ")
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
