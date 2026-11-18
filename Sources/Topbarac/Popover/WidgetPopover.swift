import SwiftUI
import TopbaracCore

/// Popover for one widget: header, stat tiles, chart, details, management tools, top processes, footer.
struct WidgetPopover: View {
    var kind: WidgetKind
    @State private var toasts = ToastCenter()

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView(.vertical) {
                WidgetContent(kind: kind)
                    .padding(16)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            if let toast = toasts.current {
                ToastView(toast: toast).padding(.bottom, 54)
            }
        }
        .frame(width: Metrics.popoverWidth)
        .environment(toasts)
        .animation(.smooth(duration: 0.25), value: toasts.current)
    }

    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) - 60
    }
}

/// Merged mode: one popover with a tab per widget.
struct MergedPopover: View {
    var kinds: [WidgetKind]
    @Bindable var selection: MergedSelection
    @State private var toasts = ToastCenter()

    private var current: WidgetKind { selection.kind.flatMap { kinds.contains($0) ? $0 : nil } ?? kinds.first ?? .cpu }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(kinds) { kind in
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { selection.kind = kind }
                        AppDelegate.shared.statusItems?.mergedTabChanged(to: kind)
                    } label: {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 28)
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
            .padding(4)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 16)
            .padding(.top, 14)

            ZStack(alignment: .bottom) {
                ScrollView(.vertical) {
                    WidgetContent(kind: current).id(current).padding(16)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: (NSScreen.main?.visibleFrame.height ?? 900) - 110)
                .fixedSize(horizontal: false, vertical: true)
                if let toast = toasts.current { ToastView(toast: toast).padding(.bottom, 54) }
            }
        }
        .frame(width: Metrics.popoverWidth)
        .environment(toasts)
        .animation(.smooth(duration: 0.25), value: toasts.current)
    }
}

struct WidgetContent: View {
    var kind: WidgetKind
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
            PopoverFooter()
        }
    }
}

struct PopoverHeader: View {
    var kind: WidgetKind
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let value = PanelValue.make(kind, store: store, settings: settings.settings)
        HStack(spacing: 10) {
            WidgetIcon(kind: kind, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(value.lines.joined(separator: "  "))
                    .font(.system(size: value.lines.count > 1 ? 15 : 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                StatusPill(level: value.level, text: pillText(value.level))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        switch kind {
        case .cpu:
            let cores = store.cpu?.perCore.count ?? ProcessInfo.processInfo.activeProcessorCount
            return "\(SystemInfo.chipName) · \(cores) cores"
        case .memory:
            return "\(Format.memory(store.memory?.total ?? ProcessInfo.processInfo.physicalMemory)) installed"
        case .disk:
            return store.disk?.root.map { "\($0.name) · \(Format.bytes($0.total)) total" } ?? "Volumes"
        case .temperature:
            let n = store.temperature?.sensors.count ?? 0
            let fans = store.temperature?.fans.count ?? 0
            return "\(n) sensors" + (fans > 0 ? " · \(fans) fan\(fans == 1 ? "" : "s")" : "")
        case .gpu:
            return store.gpu?.name ?? "Graphics"
        case .network:
            return store.network?.interfaces.first(where: { !$0.isVirtual })?.displayName ?? "Not connected"
        case .battery:
            guard let b = store.battery else { return "Battery" }
            return b.charging ? "Charging" : (b.onAC ? (b.fullyCharged ? "Fully charged" : "On power adapter") : "On battery")
        }
    }

    private func pillText(_ level: Level) -> String? {
        switch kind {
        case .memory: store.memory.map { "Pressure: \($0.pressure.title)" }
        case .temperature: thermalText
        default: nil
        }
    }

    private var thermalText: String {
        switch store.temperature?.thermalState ?? 0 {
        case 0: "Thermals nominal"
        case 1: "Thermals fair"
        case 2: "Throttling"
        default: "Critical heat"
        }
    }
}

struct PopoverFooter: View {
    @Environment(MonitorStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Button {
                AppDelegate.shared.openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Button {
                ProcessActions.openActivityMonitor()
            } label: {
                Label("Activity Monitor", systemImage: "chart.bar.xaxis")
            }
            Spacer()
            Button {
                store.setPaused(!store.paused)
                AppDelegate.shared.statusItems?.refresh()
            } label: {
                Image(systemName: store.paused ? "play.fill" : "pause.fill")
            }
            .help(store.paused ? "Resume monitoring" : "Pause monitoring")
            .accessibilityLabel(store.paused ? "Resume monitoring" : "Pause monitoring")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Topbarac")
            .accessibilityLabel("Quit Topbarac")
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
        .padding(.top, 2)
    }
}
