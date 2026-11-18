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

/// Combined mode: one popover with an overview tab and a tab per widget.
struct MergedPopover: View {
    var kinds: [WidgetKind]
    @Bindable var selection: MergedSelection
    @State private var toasts = ToastCenter()

    private var current: WidgetKind? {
        if selection.showingOverview { return nil }
        return selection.kind.flatMap { kinds.contains($0) ? $0 : nil } ?? kinds.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                tab(symbol: "square.grid.2x2", title: "Overview", accent: Color(red: 0.45, green: 0.42, blue: 0.98), selected: current == nil) { select(nil) }
                ForEach(kinds) { kind in
                    tab(symbol: kind.symbol, title: kind.title, accent: kind.accent, selected: current == kind) { select(kind) }
                }
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
            .padding([.horizontal, .top], DS.pad)

            ZStack(alignment: .bottom) {
                ScrollView(.vertical) {
                    Group {
                        if let current {
                            WidgetContent(kind: current).id(current)
                        } else {
                            OverviewContent { select($0) }
                        }
                    }
                    .padding(DS.pad)
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
        .background { WidgetShortcuts { kind in if kind == nil || kinds.contains(kind!) { select(kind) } } }
    }

    private func tab(symbol: String, title: String, accent: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 24)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .background { if selected { Capsule().fill(accent.gradient) } }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func select(_ kind: WidgetKind?) {
        withAnimation(.smooth(duration: 0.2)) {
            selection.showingOverview = kind == nil
            if let kind { selection.kind = kind }
        }
        AppDelegate.shared.statusItems?.mergedTabChanged(to: kind)
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
            HeaderActions()
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
