import SwiftUI
import TopbaracCore

/// Every widget at a glance: one card per widget with its key figure and the last minute as a sparkline.
/// Clicking a card opens that widget's full detail in place.
struct OverviewPopover: View {
    @State private var toasts = ToastCenter()
    @State private var detail: WidgetKind?
    @Environment(MonitorStore.self) private var store

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.vertical) {
                Group {
                    if let detail {
                        VStack(alignment: .leading, spacing: DS.gap) {
                            BackBar(title: "Overview") { navigate(nil) }
                            WidgetContent(kind: detail)
                        }
                    } else {
                        OverviewContent { navigate($0) }
                    }
                }
                .padding(DS.pad)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            .frame(maxHeight: (NSScreen.main?.visibleFrame.height ?? 900) - 60)
            .fixedSize(horizontal: false, vertical: true)
            if let toast = toasts.current { ToastView(toast: toast).padding(.bottom, 12) }
        }
        .frame(width: Metrics.popoverWidth)
        .environment(toasts)
        .animation(.smooth(duration: 0.25), value: toasts.current)
        .background { WidgetShortcuts { navigate($0) } }
    }

    private func navigate(_ kind: WidgetKind?) {
        if let old = detail { store.closeDetail(old) }
        withAnimation(.smooth(duration: 0.2)) { detail = kind }
        if let kind { store.openDetail(kind) }
    }
}

/// "‹ Overview" row above a widget opened from the overview.
struct BackBar: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.escape, modifiers: [])
        .help("Back to the overview (Esc)")
    }
}

/// ⌘1…⌘7 jump to a widget, ⌘0 back to the overview. Invisible buttons that only carry the shortcuts.
struct WidgetShortcuts: View {
    var go: (WidgetKind?) -> Void
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ZStack {
            Button("") { go(nil) }.keyboardShortcut("0", modifiers: .command)
            ForEach(Array(settings.settings.order.prefix(9).enumerated()), id: \.element) { index, kind in
                Button("") { go(kind) }.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

struct OverviewContent: View {
    var open: (WidgetKind) -> Void
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    private var kinds: [WidgetKind] {
        settings.settings.order.filter { kind in
            switch kind {
            case .battery: store.battery?.present ?? true
            case .gpu: store.gpu?.available ?? true
            default: true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            OverviewHeader()
            OverviewExtras(open: open)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.gap), GridItem(.flexible(), spacing: DS.gap)], spacing: DS.gap) {
                ForEach(kinds) { kind in
                    MiniCard(kind: kind) { open(kind) }
                }
            }
        }
    }
}

/// Health check above the cards; what keeps the Mac awake and accessory batteries below it.
struct OverviewExtras: View {
    var open: (WidgetKind) -> Void
    @State private var blockers: [SleepBlocker] = []
    @State private var accessories: [BluetoothBattery] = ExtrasLoader.cachedAccessories

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            HealthCheck()
            SleepBlockersSection(blockers: blockers)
            AccessoriesSection(list: accessories, compact: true)
        }
        .task {
            while !Task.isCancelled {
                blockers = await ExtrasLoader.blockers()
                accessories = await ExtrasLoader.accessories()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

private struct OverviewHeader: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(LinearGradient(colors: [Color(red: 0.35, green: 0.45, blue: 1), Color(red: 0.65, green: 0.35, blue: 0.95)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 0) {
                Text("Overview").font(.system(size: 13, weight: .semibold))
                Text("\(SystemInfo.chipName) · up \(Format.duration(store.cpu?.uptime ?? ProcessInfo.processInfo.systemUptime))")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            HeaderActions()
        }
        .frame(height: 30)
    }
}

/// Activity Monitor, pause, settings, quit: shared by every popover header.
struct HeaderActions: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "chart.bar.xaxis", help: "Open Activity Monitor") { ProcessActions.openActivityMonitor() }
            IconButton(symbol: store.paused ? "play.fill" : "pause.fill", help: store.paused ? "Resume monitoring" : "Pause monitoring") {
                store.setPaused(!store.paused)
                AppDelegate.shared.statusItems?.refresh()
            }
            IconButton(symbol: "gearshape", help: "Settings (⌘,)") { AppDelegate.shared.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            IconButton(symbol: "power", help: "Quit Topbarac") { NSApp.terminate(nil) }
        }
    }
}

/// One widget in the overview grid.
struct MiniCard: View {
    var kind: WidgetKind
    var action: () -> Void
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @State private var hovering = false

    var body: some View {
        let value = PanelValue.make(kind, store: store, settings: settings.settings)
        let figures = self.figures
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: kind.symbol).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(kind.accent)
                    Text(kind.title).font(DS.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    if value.level != .normal { Circle().fill(value.level.color).frame(width: 6, height: 6) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(figures.main).font(DS.stat)
                        .foregroundStyle(value.level == .normal ? .primary : value.level.color)
                        .contentTransition(.numericText())
                    Text(figures.sub).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1).monospacedDigit()
                }
                .lineLimit(1).minimumScaleFactor(0.8)
                Sparkline(kind: kind, key: sparkKey, fixed: fixedScale).frame(height: 22)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(hovering ? 0.075 : 0.04), in: .rect(cornerRadius: DS.corner))
            .contentShape(.rect(cornerRadius: DS.corner))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(kind.title)")
        .accessibilityLabel("\(kind.title), \(figures.main) \(figures.sub)")
        .accessibilityHint("Shows details")
    }

    private var sparkKey: SeriesKey {
        switch kind {
        case .cpu: .cpuUsage
        case .memory: .memUsage
        case .disk: .diskRead
        case .temperature: .tempHottest
        case .gpu: .gpuUsage
        case .network: .netDown
        case .battery: .battery
        }
    }

    private var fixedScale: Bool { [.cpu, .memory, .gpu, .battery].contains(kind) }

    private var figures: (main: String, sub: String) {
        let s = settings.settings
        let f = s.temperatureUnit == .fahrenheit
        switch kind {
        case .cpu:
            let c = store.cpu
            return (c.map { Format.percent($0.usage) } ?? "—", c.map { String(format: "load %.1f", $0.load.0) } ?? "")
        case .memory:
            let m = store.memory
            return (m.map { Format.memory($0.used) } ?? "—", m.map { Format.percent($0.usage) } ?? "")
        case .disk:
            let d = store.disk
            return (d?.root.map { Format.bytes($0.available) } ?? "—", d?.root != nil ? "free" : "")
        case .temperature:
            let t = store.temperature
            return (t?.hottest.map { Format.temperature($0, fahrenheit: f) } ?? "—",
                    t.flatMap { $0.fans.map(\.rpm).max() }.map { $0 < 1 ? "fans off" : "\(Int($0)) rpm" } ?? "")
        case .gpu:
            return (store.gpu.map { Format.percent($0.utilization) } ?? "—", store.gpu?.powerWatts.map(Format.watts) ?? "")
        case .network:
            let n = store.network
            return (n.map { Format.rate($0.downBps, bits: s.networkUnit == .bits) } ?? "—",
                    n.map { "↑" + Format.rate($0.upBps, bits: s.networkUnit == .bits, compact: true) } ?? "")
        case .battery:
            let b = store.battery
            return (b.map { Format.percent($0.percent) } ?? "—",
                    b.map { $0.charging ? "charging" : ($0.onAC ? "on AC" : ($0.minutesToEmpty.map(Format.minutes) ?? "on battery")) } ?? "")
        }
    }
}

/// Last minute of one series as a filled line, drawn with a Canvas (cheap enough for seven at once).
struct Sparkline: View {
    var kind: WidgetKind
    var key: SeriesKey
    var fixed: Bool
    @Environment(MonitorStore.self) private var store

    var body: some View {
        let points = store.series(key)?.window(since: Date().addingTimeInterval(-60), maxPoints: 60) ?? []
        Canvas { context, size in
            let values = points.compactMap(\.value)
            guard values.count > 1, let first = points.first?.time, let last = points.last?.time else { return }
            let span = max(1, last.timeIntervalSince(first))
            let lo = fixed ? 0 : min(0, values.min() ?? 0)
            let hi = fixed ? 1 : max((values.max() ?? 1) * 1.15, lo + 1e-9)
            var line = Path()
            var started = false
            for p in points {
                guard let v = p.value else { started = false; continue }
                let x = CGFloat(p.time.timeIntervalSince(first) / span) * size.width
                let y = size.height - CGFloat((v - lo) / (hi - lo)) * size.height
                if started { line.addLine(to: CGPoint(x: x, y: y)) } else { line.move(to: CGPoint(x: x, y: y)); started = true }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [kind.accent.opacity(0.28), kind.accent.opacity(0.02)]),
                                                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(kind.accent), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
