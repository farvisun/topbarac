import AppKit
import SwiftUI
import TopbaracCore
import UserNotifications

enum SettingsPane: Hashable {
    case general, menuBar, widget(WidgetKind), alerts, history, about

    var title: String {
        switch self {
        case .general: "General"
        case .menuBar: "Menu Bar"
        case .widget(let k): k.title
        case .alerts: "Alerts"
        case .history: "History"
        case .about: "About"
        }
    }
}

struct SettingsView: View {
    @State private var pane: SettingsPane? = .general
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section {
                    row(.general, "gearshape", .gray)
                    row(.menuBar, "menubar.rectangle", .blue)
                }
                Section("Widgets") {
                    ForEach(settings.settings.order) { kind in
                        NavigationLink(value: SettingsPane.widget(kind)) {
                            Label {
                                HStack {
                                    Text(kind.title)
                                    Spacer()
                                    if !settings.config(kind).enabled {
                                        Text("Off").font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                            } icon: { WidgetIcon(kind: kind, size: 20) }
                        }
                    }
                }
                Section {
                    row(.alerts, "bell.badge", .red)
                    row(.history, "clock.arrow.circlepath", .indigo)
                    row(.about, "info.circle", .gray)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            Group {
                switch pane ?? .general {
                case .general: GeneralPane()
                case .menuBar: MenuBarPane(pane: $pane)
                case .widget(let kind): WidgetPane(kind: kind).id(kind)
                case .alerts: AlertsPane()
                case .history: HistoryPane()
                case .about: AboutPane()
                }
            }
            .navigationTitle((pane ?? .general).title)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    private func row(_ p: SettingsPane, _ symbol: String, _ color: Color) -> some View {
        NavigationLink(value: p) {
            Label {
                Text(p.title)
            } icon: {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(color.gradient, in: .rect(cornerRadius: 6))
            }
        }
    }
}

// MARK: General

struct GeneralPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(MonitorStore.self) private var store
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LoginItem.set(on); launchAtLogin = LoginItem.isEnabled }
                Picker("Refresh every", selection: $settings.settings.refreshInterval) {
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                }
                Toggle("Pause monitoring", isOn: Binding(get: { store.paused }, set: { store.setPaused($0); AppDelegate.shared.statusItems?.refresh() }))
            } footer: {
                Text("One timer feeds every widget. Only widgets that are turned on are measured, and details are read only while their popover is open.")
            }
            Section {
                LabeledContent("Open the overview") {
                    HotkeyRecorder(hotkey: $settings.settings.hotkey)
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Works in every app. In a popover, ⌘1–⌘7 jump to a widget, ⌘0 to the overview, Esc goes back.")
            }
            Section {
                TextField("Internet latency target", text: $settings.settings.latencyHost, prompt: Text("1.1.1.1"))
            } header: {
                Text("Network")
            } footer: {
                Text("While the Network popover is open, Topbarac pings your router and this IPv4 address every 2 seconds. Nothing is sent otherwise.")
            }
            Section("Units") {
                Picker("Temperature", selection: $settings.settings.temperatureUnit) {
                    Text("Celsius (°C)").tag(TemperatureUnit.celsius)
                    Text("Fahrenheit (°F)").tag(TemperatureUnit.fahrenheit)
                }
                Picker("Network speed", selection: $settings.settings.networkUnit) {
                    Text("Bytes (MB/s)").tag(NetworkUnit.bytes)
                    Text("Bits (Mb/s)").tag(NetworkUnit.bits)
                }
            }
            Section {
                Toggle("Protect system processes", isOn: $settings.settings.protectSystemProcesses)
            } header: {
                Text("Managing processes")
            } footer: {
                Text("Hides Quit and Force Quit for processes macOS needs, such as WindowServer, Dock and Finder.")
            }
            Section {
                Button("Reset All Settings…", role: .destructive) { confirmReset() }
            }
        }
        .formStyle(.grouped)
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText = "Widgets, styles, thresholds and alert rules go back to their defaults. History is kept."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { settings.resetAll() }
    }
}

// MARK: Menu bar

struct MenuBarPane: View {
    @Binding var pane: SettingsPane?
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                MenuBarPreview(kinds: settings.settings.enabledWidgets, merged: settings.settings.mergedMode)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
            }
            Section {
                Toggle("Combine into one menu bar item", isOn: $settings.settings.mergedMode)
                if settings.settings.mergedMode {
                    Toggle("Show widget icons", isOn: $settings.settings.mergedShowsIcons)
                }
                if !settings.settings.mergedMode {
                    Toggle("Show the overview item", isOn: $settings.settings.showOverviewItem)
                }
                Toggle("Flash the item while an alert is active", isOn: $settings.settings.flashOnCritical)
            } footer: {
                Text(settings.settings.mergedMode
                     ? "One item shows every widget; its popover has a tab for each."
                     : "Each widget gets its own item. Hold ⌘ and drag an item to move it; macOS remembers the position.")
            }
            Section {
                List {
                    ForEach(settings.settings.order) { kind in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            WidgetIcon(kind: kind, size: 22)
                            Text(kind.title)
                            Spacer()
                            Button("Customize") { pane = .widget(kind) }.buttonStyle(.link).font(.callout)
                            Toggle("", isOn: Binding(get: { settings.config(kind).enabled },
                                                     set: { on in settings.update(kind) { $0.enabled = on } }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { from, to in settings.settings.order.move(fromOffsets: from, toOffset: to) }
                }
            } header: {
                Text("Widgets")
            } footer: {
                Text("Drag to reorder. The order is used in combined mode and when items are first added.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Live preview of the menu bar items using the real renderer.
struct MenuBarPreview: View {
    var kinds: [WidgetKind]
    var merged: Bool
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let _ = store.historyTick
        let s = settings.settings
        let groups: [[WidgetKind]] = merged ? [kinds] : kinds.map { [$0] }
        HStack(spacing: 2) {
            if kinds.isEmpty {
                Text("No widgets turned on").foregroundStyle(.secondary).padding(.horizontal, 12)
            }
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                PanelPreview(segments: group.map { kind in
                    var config = s.config(kind)
                    if merged { config.showLabel = false }
                    let showIcon = merged ? s.mergedShowsIcons : (config.style == .numbers && !config.showLabel && kind != .network)
                    return PanelView.Segment(kind: kind, config: config, value: PanelValue.make(kind, store: store, settings: s), showIcon: showIcon)
                })
            }
        }
        .frame(height: 26)
        .padding(.horizontal, 8)
        .background(.bar, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.08)))
        .accessibilityLabel("Menu bar preview")
    }
}

struct PanelPreview: NSViewRepresentable {
    var segments: [PanelView.Segment]

    func makeNSView(context: Context) -> PanelView { PanelView() }

    func updateNSView(_ view: PanelView, context: Context) {
        view.segments = segments
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PanelView, context: Context) -> CGSize? {
        CGSize(width: nsView.preferredWidth, height: 24)
    }
}

// MARK: Widget

struct WidgetPane: View {
    var kind: WidgetKind
    @Environment(SettingsStore.self) private var settings

    private func binding<T>(_ keyPath: WritableKeyPath<WidgetConfig, T>) -> Binding<T> {
        Binding(get: { settings.config(kind)[keyPath: keyPath] }, set: { v in settings.update(kind) { $0[keyPath: keyPath] = v } })
    }

    var body: some View {
        let config = settings.config(kind)
        Form {
            Section {
                HStack(spacing: 12) {
                    WidgetIcon(kind: kind, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title).font(.headline)
                        Text(description).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Show in menu bar", isOn: binding(\.enabled)).labelsHidden().toggleStyle(.switch)
                }
            }
            Section("Appearance") {
                HStack {
                    Text("Preview")
                    Spacer()
                    MenuBarPreview(kinds: [kind], merged: false)
                }
                StylePicker(selection: binding(\.style), kind: kind)
                Picker("Shows", selection: binding(\.metric)) {
                    ForEach(kind.panelMetrics) { Text($0.title).tag($0) }
                }
                Toggle("Show value", isOn: binding(\.showValue)).disabled(config.style == .numbers)
                Toggle("Show label (\(kind.shortLabel))", isOn: binding(\.showLabel))
            }
            Section {
                Toggle("Color the item past these thresholds", isOn: binding(\.thresholdsEnabled))
                if config.thresholdsEnabled {
                    ThresholdSlider(title: kind.thresholdInverted ? "Warning below" : "Warning at", value: binding(\.warning),
                                    range: kind.thresholdRange, unit: kind.thresholdUnit, color: .yellow)
                    ThresholdSlider(title: kind.thresholdInverted ? "Critical below" : "Critical at", value: binding(\.critical),
                                    range: kind.thresholdRange, unit: kind.thresholdUnit, color: .red)
                }
            } header: {
                Text("Thresholds")
            } footer: {
                Text(thresholdFooter)
            }
        }
        .formStyle(.grouped)
    }

    private var description: String {
        switch kind {
        case .cpu: "Usage per core, P and E clusters, frequency, load average."
        case .memory: "Used, cached, compressed and swap, plus memory pressure."
        case .disk: "Space on every volume, read and write speed, busy time."
        case .temperature: "Every sensor grouped by chip, with fan speeds."
        case .gpu: "Usage, memory, frequency and power of the graphics processor."
        case .network: "Live speeds, session totals, interfaces and apps using the network."
        case .battery: "Charge, power draw, health, cycles and time remaining."
        }
    }

    private var thresholdFooter: String {
        switch kind {
        case .temperature: "Compared with the hottest sensor, in °C."
        case .battery: "Only while running on battery."
        case .network: "Compared with the download speed."
        case .memory: "Memory pressure reported by macOS also turns the item yellow or red."
        default: "Values turn yellow at the warning level and red at the critical level."
        }
    }
}

struct ThresholdSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var unit: String
    var color: Color

    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
            Slider(value: $value, in: range, step: 1)
            Text("\(Int(value)) \(unit)").monospacedDigit().frame(width: 64, alignment: .trailing)
        }
    }
}

/// Visual picker: a card per panel style with a drawn sample.
struct StylePicker: View {
    @Binding var selection: PanelStyle
    var kind: WidgetKind
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Style")
            HStack(spacing: 8) {
                ForEach(PanelStyle.allCases) { style in
                    Button {
                        selection = style
                    } label: {
                        VStack(spacing: 6) {
                            PanelPreview(segments: [segment(style)])
                                .frame(height: 24)
                                .allowsHitTesting(false)
                            Text(style.title).font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selection == style ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04), in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selection == style ? Color.accentColor : .clear, lineWidth: 1.5))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.title)
                    .accessibilityAddTraits(selection == style ? .isSelected : [])
                }
            }
        }
    }

    private func segment(_ style: PanelStyle) -> PanelView.Segment {
        var config = settings.config(kind)
        config.style = style
        config.showValue = true
        config.showLabel = false
        let _ = store.historyTick
        return .init(kind: kind, config: config, value: PanelValue.make(kind, store: store, settings: settings.settings), showIcon: false)
    }
}
