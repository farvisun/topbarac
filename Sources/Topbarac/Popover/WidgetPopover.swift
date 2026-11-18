import SwiftUI
import TopbaracCore

/// Popover for one widget: compact header with actions, key figures, chart, details, processes.
struct WidgetPopover: View {
    var kind: WidgetKind
    @State private var toasts = ToastCenter()

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.vertical) {
                WidgetContent(kind: kind).padding(DS.pad)
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
    }
}

/// Combined mode: one popover with a tab per widget.
struct MergedPopover: View {
    var kinds: [WidgetKind]
    @Bindable var selection: MergedSelection
    @State private var toasts = ToastCenter()

    private var current: WidgetKind { selection.kind.flatMap { kinds.contains($0) ? $0 : nil } ?? kinds.first ?? .cpu }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(kinds) { kind in
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { selection.kind = kind }
                        AppDelegate.shared.statusItems?.mergedTabChanged(to: kind)
                    } label: {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .foregroundStyle(kind == current ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                            .background {
                                if kind == current { Capsule().fill(kind.accent.gradient) }
                            }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .help(kind.title)
                    .accessibilityLabel(kind.title)
                    .accessibilityAddTraits(kind == current ? .isSelected : [])
                }
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
            .padding([.horizontal, .top], DS.pad)

            ZStack(alignment: .bottom) {
                ScrollView(.vertical) {
                    WidgetContent(kind: current).id(current).padding(DS.pad)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: (NSScreen.main?.visibleFrame.height ?? 900) - 100)
                .fixedSize(horizontal: false, vertical: true)
                if let toast = toasts.current { ToastView(toast: toast).padding(.bottom, 12) }
            }
        }
        .frame(width: Metrics.popoverWidth)
        .environment(toasts)
        .animation(.smooth(duration: 0.25), value: toasts.current)
    }
}

struct WidgetContent: View {
    var kind: WidgetKind

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            PopoverHeader(kind: kind)
            switch kind {
            case .cpu: CPUDetail()
            case .memory: MemoryDetail()
            case .disk: DiskDetail()
            case .temperature: TemperatureDetail()
            case .gpu: GPUDetail()
            case .network: NetworkDetail()
            case .battery: BatteryDetail()
            }
            ProcessSection(kind: kind)
        }
    }
}

/// Icon, title, one-line context and status on the left; app actions on the right. The headline number lives in the
/// stat strip below, so it isn't shown twice.
struct PopoverHeader: View {
    var kind: WidgetKind
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let value = PanelValue.make(kind, store: store, settings: settings.settings)
        HStack(spacing: 8) {
            WidgetIcon(kind: kind, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(kind.title).font(.system(size: 13, weight: .semibold))
                    StatusPill(level: pillLevel(value.level), text: pillText)
                }
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                IconButton(symbol: "chart.bar.xaxis", help: "Open Activity Monitor") { ProcessActions.openActivityMonitor() }
                IconButton(symbol: store.paused ? "play.fill" : "pause.fill", help: store.paused ? "Resume monitoring" : "Pause monitoring") {
                    store.setPaused(!store.paused)
                    AppDelegate.shared.statusItems?.refresh()
                }
                IconButton(symbol: "gearshape", help: "Settings") { AppDelegate.shared.openSettings() }
                IconButton(symbol: "power", help: "Quit Topbarac") { NSApp.terminate(nil) }
            }
        }
        .frame(height: 30)
    }

    private var subtitle: String {
        switch kind {
        case .cpu:
            "\(SystemInfo.chipName) · \(store.cpu?.perCore.count ?? ProcessInfo.processInfo.activeProcessorCount) cores"
        case .memory:
            "\(Format.memory(store.memory?.total ?? ProcessInfo.processInfo.physicalMemory)) unified memory"
        case .disk:
            store.disk?.root.map { "\($0.name) · \(Format.bytes($0.total))" } ?? "Volumes"
        case .temperature:
            "\(store.temperature?.sensors.count ?? 0) sensors · \(thermalText)"
        case .gpu:
            store.gpu?.name ?? "Graphics"
        case .network:
            store.network?.interfaces.first(where: { !$0.isVirtual })?.displayName ?? "Not connected"
        case .battery:
            store.battery.map { b in
                b.charging ? "Charging" : (b.onAC ? (b.fullyCharged ? "Fully charged" : "On power adapter") : "On battery")
            } ?? "Battery"
        }
    }

    /// Memory reports pressure, not fill level: macOS fills RAM on purpose, and pressure is what slows things down.
    private func pillLevel(_ level: Level) -> Level {
        guard kind == .memory, let pressure = store.memory?.pressure else { return level }
        switch pressure {
        case .normal: return .normal
        case .warning: return .warning
        case .critical: return .critical
        }
    }

    private var pillText: String? {
        guard kind == .memory, let m = store.memory else { return nil }
        return m.pressure == .normal ? "Pressure OK" : "Pressure \(m.pressure.title.lowercased())"
    }

    private var thermalText: String {
        switch store.temperature?.thermalState ?? 0 {
        case 0: "nominal"
        case 1: "fair"
        case 2: "throttling"
        default: "critical"
        }
    }
}
