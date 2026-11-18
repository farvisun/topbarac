import SwiftUI
import TopbaracCore

private func percentAxis(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

// MARK: CPU

struct CPUDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let c = store.cpu ?? CPUSnapshot()
        let config = settings.config(.cpu)
        VStack(alignment: .leading, spacing: DS.gap) {
            StatStrip(stats: [
                Stat(label: "Usage", value: Format.percent(c.usage),
                     detail: "\(Format.percent(c.user)) user · \(Format.percent(c.system)) sys",
                     level: Level.of(c.usage * 100, config: config, inverted: false)),
                c.powerWatts.map { Stat(label: "Power", value: Format.watts($0), detail: "CPU package") }
                    ?? Stat(label: "Frequency", value: c.pFrequencyMHz.map(Format.mhz) ?? "—",
                            detail: c.eFrequencyMHz.map { "E-cores \(Format.mhz($0))" } ?? "P-cores"),
                Stat(label: "Load", value: String(format: "%.2f", c.load.0),
                     detail: String(format: "%.2f · %.2f", c.load.1, c.load.2)),
            ])
            Card {
                // User and system stacked: the height is total usage, the split shows who is using it.
                LiveChart(spec: ChartSpec(series: [
                    ChartSeries(key: .cpuUser, label: "User", color: WidgetKind.cpu.accent),
                    ChartSeries(key: .cpuSystem, label: "System", color: Color(red: 0.98, green: 0.36, blue: 0.42)),
                ], domain: 0...1, stacked: true, format: percentAxis))
            }
            Card {
                VStack(alignment: .leading, spacing: 7) {
                    SectionTitle("Cores", trailing: c.busiestCore.map { "Busiest #\($0.index + 1) · \(Format.percent($0.usage)) · up \(Format.duration(c.uptime))" })
                    CoreGrid(snapshot: c, config: config)
                }
            }
        }
    }
}

/// P and E clusters side by side, one slim bar per core, cluster average above each group.
struct CoreGrid: View {
    var snapshot: CPUSnapshot
    var config: WidgetConfig

    var body: some View {
        let indexed = Array(snapshot.perCore.enumerated())
        let kinds = snapshot.coreKinds
        let p = indexed.filter { kinds.indices.contains($0.offset) && kinds[$0.offset] == .performance }
        let e = indexed.filter { kinds.indices.contains($0.offset) && kinds[$0.offset] == .efficiency }
        let groups: [(String, String?, [(offset: Int, element: Double)])] = (p.isEmpty && e.isEmpty)
            ? [("Cores", nil, indexed)]
            : [("Performance", snapshot.pClusterUsage.map { Format.percent($0) }, p), ("Efficiency", snapshot.eClusterUsage.map { Format.percent($0) }, e)].filter { !$0.2.isEmpty }
        // Each cluster gets width in proportion to its core count, so every bar is the same width.
        let total = CGFloat(max(1, groups.reduce(0) { $0 + $1.2.count }))
        let spacing: CGFloat = 12
        let available = Metrics.popoverWidth - 2 * DS.pad - 2 * DS.inner - spacing * CGFloat(groups.count - 1)
        HStack(alignment: .top, spacing: spacing) {
            ForEach(groups, id: \.0) { name, average, cores in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(name).font(DS.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 2)
                        if let average { Text(average).font(DS.value) }
                    }
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(cores, id: \.offset) { core in
                            CoreBar(index: core.offset, usage: core.element, level: Level.of(core.element * 100, config: config, inverted: false))
                        }
                    }
                    .frame(height: 26)
                }
                .frame(width: floor(available * CGFloat(cores.count) / total))
            }
        }
        .animation(.smooth(duration: 0.3), value: snapshot.perCore)
    }
}

private struct CoreBar: View {
    var index: Int
    var usage: Double
    var level: Level

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(.primary.opacity(0.07))
                RoundedRectangle(cornerRadius: 2)
                    .fill(level == .normal ? WidgetKind.cpu.accent : level.color)
                    .frame(height: max(2, geo.size.height * usage))
            }
        }
        .help("Core \(index + 1): \(Format.percent(usage))")
        .accessibilityElement()
        .accessibilityLabel("Core \(index + 1)")
        .accessibilityValue(Format.percent(usage))
    }
}

// MARK: Memory

struct MemoryDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(ToastCenter.self) private var toasts
    @State private var purging = false
    @State private var confirmPurge = false

    private static let app = WidgetKind.memory.accent
    private static let wired = Color(red: 1.0, green: 0.62, blue: 0.25)
    private static let compressed = Color(red: 0.95, green: 0.38, blue: 0.55)
    private static let cached = Color(red: 0.25, green: 0.72, blue: 0.75)

    var body: some View {
        let m = store.memory ?? MemorySnapshot()
        VStack(alignment: .leading, spacing: DS.gap) {
            StatStrip(stats: [
                Stat(label: "Used", value: Format.memory(m.used), detail: "\(Format.percent(m.usage)) of \(Format.memory(m.total))",
                     level: Level.of(m.usage * 100, config: settings.config(.memory), inverted: false)),
                Stat(label: "Cached", value: Format.memory(m.cached), detail: "reclaimable"),
                Stat(label: "Swap", value: Format.memory(m.swapUsed), detail: m.swapTotal > 0 ? "of \(Format.memory(m.swapTotal))" : "not in use",
                     level: m.swapUsed > m.total / 4 ? .warning : .normal),
            ])
            Card {
                // What fills memory over time, not just how much.
                LiveChart(spec: ChartSpec(series: [
                    ChartSeries(key: .memApp, label: "App", color: Self.app),
                    ChartSeries(key: .memWired, label: "Wired", color: Self.wired),
                    ChartSeries(key: .memCompressed, label: "Compr.", color: Self.compressed),
                ], domain: 0...1, stacked: true, format: percentAxis))
            }
            Card {
                VStack(alignment: .leading, spacing: 7) {
                    SectionTitle("Breakdown") {
                        Button(purging ? "Freeing…" : "Free Inactive…") { confirmPurge = true }
                            .buttonStyle(.borderless).font(.system(size: 10.5, weight: .medium)).disabled(purging || confirmPurge)
                            .help("Runs purge after an administrator prompt")
                    }
                    StackedBar(parts: [
                        .init(label: "App", value: Double(m.app), color: Self.app, text: Format.memory(m.app)),
                        .init(label: "Wired", value: Double(m.wired), color: Self.wired, text: Format.memory(m.wired)),
                        .init(label: "Compressed", value: Double(m.compressed), color: Self.compressed, text: Format.memory(m.compressed)),
                        .init(label: "Cached", value: Double(m.cached), color: Self.cached, text: Format.memory(m.cached)),
                    ], total: Double(m.total))
                    if confirmPurge {
                        ConfirmBar(text: "Asks for your password. Apps may feel slower briefly while caches refill.",
                                   action: "Free Memory", destructive: false, onCancel: { confirmPurge = false }, onConfirm: purge)
                    }
                }
            }
        }
    }

    private func purge() {
        confirmPurge = false
        purging = true
        Task {
            let (result, freed) = await SystemActions.purgeMemory()
            purging = false
            toasts.show(result, success: freed > 0 ? "Freed \(Format.memory(freed))" : "Inactive memory released")
        }
    }
}

/// Inline confirmation inside a card (popovers close when an alert window appears).
struct ConfirmBar: View {
    var text: String
    var action: String
    var destructive: Bool
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Cancel", action: onCancel).buttonStyle(.borderless)
            Button(action, action: onConfirm).buttonStyle(.glassProminent).tint(destructive ? .red : .accentColor)
        }
        .controlSize(.small)
        .padding(7)
        .background((destructive ? Color.red : Color.accentColor).opacity(0.07), in: .rect(cornerRadius: 7))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: Disk

struct DiskDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @State private var trashSize: UInt64??
    @State private var cachesSize: UInt64??
    @State private var confirmEmpty = false
    @State private var working = false

    var body: some View {
        let d = store.disk ?? DiskSnapshot()
        VStack(alignment: .leading, spacing: DS.gap) {
            StatStrip(stats: [
                Stat(label: "Read", value: Format.rate(d.readBps), tint: WidgetKind.disk.accent),
                Stat(label: "Write", value: Format.rate(d.writeBps), tint: WidgetKind.disk.secondaryAccent),
                Stat(label: "Busy", value: Format.percent(d.busy), detail: d.busiestDevice),
            ])
            Card {
                LiveChart(spec: ChartSpec(series: [
                    ChartSeries(key: .diskRead, label: "Read", color: WidgetKind.disk.accent),
                    ChartSeries(key: .diskWrite, label: "Write", color: WidgetKind.disk.secondaryAccent, mirrored: true),
                ], domain: nil, format: { Format.rate($0, compact: true) }))
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Volumes", trailing: "\(d.volumes.count)")
                    if d.volumes.isEmpty {
                        Text("Reading volumes…").font(DS.label).foregroundStyle(.tertiary)
                    }
                    ForEach(d.volumes) { volume in VolumeRow(volume: volume) }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle("Clean up")
                    CleanupRow(symbol: "trash", title: "Trash", detail: sizeText(trashSize, unreadable: "needs Full Disk Access")) {
                        if !confirmEmpty {
                            Button("Empty…") { confirmEmpty = true }.disabled(working || (trashSize ?? nil) == 0)
                        }
                    }
                    if confirmEmpty {
                        ConfirmBar(text: "Everything in the Trash is deleted for good.", action: "Empty Trash", destructive: true,
                                   onCancel: { confirmEmpty = false }, onConfirm: emptyTrash)
                    }
                    CleanupRow(symbol: "archivebox", title: "User caches", detail: sizeText(cachesSize, unreadable: "couldn't read")) {
                        Button("Show") { SystemActions.reveal(SystemActions.cachesURL) }
                            .help("Topbarac never deletes caches itself. Remove what you don't need in Finder.")
                    }
                }
            }
        }
        .task { await measure() }
    }

    private func sizeText(_ size: UInt64??, unreadable: String) -> String {
        switch size {
        case .none: "Measuring…"
        case .some(.none): unreadable
        case .some(.some(let v)): v == 0 ? "Empty" : Format.bytes(v)
        }
    }

    private func measure() async {
        async let t = SystemActions.folderSize(SystemActions.trashURL)
        async let c = SystemActions.folderSize(SystemActions.cachesURL)
        trashSize = .some(await t)
        cachesSize = .some(await c)
    }

    private func emptyTrash() {
        confirmEmpty = false
        working = true
        Task {
            let result = await SystemActions.emptyTrash()
            working = false
            toasts.show(result, success: "Trash emptied")
            trashSize = nil
            await measure()
        }
    }
}

private struct CleanupRow<Accessory: View>: View {
    var symbol: String
    var title: String
    var detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
            Text(title).font(DS.body)
            Text(detail).font(DS.label).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
            Spacer(minLength: 4)
            accessory.buttonStyle(.borderless).font(.system(size: 10.5, weight: .medium))
        }
        .frame(height: DS.rowHeight)
    }
}

struct VolumeRow: View {
    var volume: VolumeInfo
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        let tint: Color = volume.usage > 0.95 ? .red : (volume.usage > 0.85 ? .orange : WidgetKind.disk.accent)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(volume.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Format.bytes(volume.available)) free of \(Format.bytes(volume.total))")
                    .font(DS.label).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                Button { SystemActions.open(volume) } label: { Image(systemName: "folder") }
                    .help("Open in Finder").accessibilityLabel("Open \(volume.name) in Finder")
                if volume.isEjectable {
                    Button {
                        Task { toasts.show(await SystemActions.eject(volume), success: "Ejected \(volume.name)") }
                    } label: { Image(systemName: "eject.fill") }
                        .help("Eject").accessibilityLabel("Eject \(volume.name)")
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10.5))
            MeterBar(fraction: volume.usage, tint: tint, height: 5)
            if volume.purgeable > 1_000_000_000 {
                Text("\(Format.percent(volume.usage)) used · \(Format.bytes(volume.purgeable)) purgeable")
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .contextMenu {
            Button("Open in Finder") { SystemActions.open(volume) }
            if volume.isEjectable {
                Button("Eject \(volume.name)") { Task { toasts.show(await SystemActions.eject(volume), success: "Ejected \(volume.name)") } }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Temperature

struct TemperatureDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let t = store.temperature ?? TemperatureSnapshot()
        let f = settings.settings.temperatureUnit == .fahrenheit
        let config = settings.config(.temperature)
        let fmt: (Double?) -> String = { v in v.map { Format.temperature($0, fahrenheit: f) } ?? "—" }
        let fanRPM = t.fans.map(\.rpm).max()
        VStack(alignment: .leading, spacing: DS.gap) {
            StatStrip(stats: [
                Stat(label: "CPU", value: fmt(t.cpu), level: Level.of(t.cpu, config: config, inverted: false)),
                Stat(label: "GPU", value: fmt(t.gpu), level: Level.of(t.gpu, config: config, inverted: false)),
                t.ssd != nil ? Stat(label: "SSD", value: fmt(t.ssd)) : Stat(label: "Battery", value: fmt(t.battery)),
                Stat(label: "Fans", value: fanRPM.map { $0 < 1 ? "Off" : "\(Int($0))" } ?? "—",
                     detail: fanRPM.map { $0 < 1 ? nil : "rpm" } ?? "none"),
            ])
            Card {
                LiveChart(spec: ChartSpec(series: [
                    ChartSeries(key: .tempCPU, label: "CPU", color: WidgetKind.temperature.accent, area: false),
                    ChartSeries(key: .tempGPU, label: "GPU", color: WidgetKind.gpu.accent, area: false),
                    ChartSeries(key: .tempSSD, label: "SSD", color: WidgetKind.disk.accent, area: false),
                ], domain: nil, includesZero: false, format: { Format.temperature($0, fahrenheit: f) }))
            }
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    if !t.fans.isEmpty {
                        SectionTitle("Fans", trailing: "\(Int(t.fans.map(\.minRPM).min() ?? 0))–\(Int(t.fans.map(\.maxRPM).max() ?? 0)) rpm")
                        ForEach(t.fans) { fan in
                            MeterRow(label: t.fans.count > 1 ? (fan.id == 0 ? "Left" : "Right") : "Fan", fraction: fan.maxRPM > 0 ? fan.rpm / fan.maxRPM : 0,
                                     value: fan.rpm < 1 ? "Off" : "\(Int(fan.rpm))", tint: WidgetKind.temperature.accent, labelWidth: 40)
                        }
                        Divider().padding(.vertical, 3)
                    }
                    SectionTitle("Sensors", trailing: "hottest \(fmt(t.hottest))")
                    if t.sensors.isEmpty {
                        Text("No sensors found on this Mac.").font(DS.label).foregroundStyle(.tertiary)
                    }
                    ForEach(SensorGroup.allCases, id: \.self) { group in
                        let list = t.sensors.filter { $0.group == group }
                        if !list.isEmpty {
                            SensorGroupView(group: group, sensors: list, config: config, format: fmt)
                        }
                    }
                }
            }
        }
    }
}

/// One sensor group: a summary row (count, average, hottest) that expands to every sensor with min and max.
struct SensorGroupView: View {
    var group: SensorGroup
    var sensors: [SensorReading]
    var config: WidgetConfig
    var format: (Double?) -> String
    @State private var expanded = false

    var body: some View {
        let hottest = sensors.map(\.celsius).max() ?? 0
        let average = sensors.map(\.celsius).reduce(0, +) / Double(max(1, sensors.count))
        VStack(alignment: .leading, spacing: 1) {
            Button {
                withAnimation(.smooth(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 9)
                        .opacity(sensors.count > 1 ? 1 : 0)
                    Text(group.rawValue).font(DS.body)
                    if sensors.count > 1 {
                        Text("\(sensors.count)").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).background(.primary.opacity(0.07), in: .capsule)
                    }
                    Spacer()
                    if sensors.count > 1 {
                        Text("avg \(format(average))").font(DS.label).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    let level = Level.of(hottest, config: config, inverted: false)
                    Text(format(hottest)).font(DS.value)
                        .foregroundStyle(level == .normal ? .primary : level.color)
                        .frame(width: 34, alignment: .trailing)
                }
                .frame(height: 20)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(sensors.count < 2)
            .accessibilityLabel("\(group.rawValue), hottest \(format(hottest))")
            .accessibilityHint(expanded ? "Collapse" : "Show every sensor")
            if expanded {
                ForEach(sensors) { s in
                    let level = Level.of(s.celsius, config: config, inverted: false)
                    HStack(spacing: 6) {
                        Text(s.name).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text("\(format(s.min))–\(format(s.max))").foregroundStyle(.tertiary)
                        Text(format(s.celsius)).fontWeight(.semibold)
                            .foregroundStyle(level == .normal ? .primary : level.color)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .font(.system(size: 10.5)).monospacedDigit()
                    .frame(height: 16)
                    .padding(.leading, 15)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: GPU

struct GPUDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let g = store.gpu ?? GPUSnapshot()
        let f = settings.settings.temperatureUnit == .fahrenheit
        VStack(alignment: .leading, spacing: DS.gap) {
            if !g.available && store.gpu != nil {
                Card { Text("No supported GPU found on this Mac.").font(DS.body).foregroundStyle(.secondary) }
            }
            StatStrip(stats: [
                Stat(label: "Usage", value: Format.percent(g.utilization),
                     level: Level.of(g.utilization * 100, config: settings.config(.gpu), inverted: false)),
                Stat(label: "Frequency", value: g.frequencyMHz.map(Format.mhz) ?? "—"),
                Stat(label: "Power", value: g.powerWatts.map(Format.watts) ?? "—"),
                Stat(label: "Temp", value: g.temperature.map { Format.temperature($0, fahrenheit: f) } ?? "—"),
            ])
            Card {
                LiveChart(spec: ChartSpec(series: [ChartSeries(key: .gpuUsage, label: "Usage", color: WidgetKind.gpu.accent)],
                                          domain: 0...1, format: percentAxis))
            }
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle("Engines and memory")
                    MeterRow(label: "Renderer", fraction: g.renderer, value: Format.percent(g.renderer), tint: WidgetKind.gpu.accent)
                    MeterRow(label: "Tiler", fraction: g.tiler, value: Format.percent(g.tiler), tint: WidgetKind.gpu.accent)
                    MeterRow(label: "Memory", fraction: g.memoryAllocated > 0 ? Double(g.memoryUsed) / Double(g.memoryAllocated) : 0,
                             value: Format.memory(g.memoryUsed), tint: WidgetKind.gpu.secondaryAccent)
                        .help("In use of \(Format.memory(g.memoryAllocated)) mapped. Apple GPUs share system memory.")
                }
            }
        }
    }
}

// MARK: Network

struct NetworkDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let n = store.network ?? NetworkSnapshot()
        let bits = settings.settings.networkUnit == .bits
        VStack(alignment: .leading, spacing: DS.gap) {
            StatStrip(stats: [
                Stat(label: "Download", value: Format.rate(n.downBps, bits: bits), tint: WidgetKind.network.accent),
                Stat(label: "Upload", value: Format.rate(n.upBps, bits: bits), tint: WidgetKind.network.secondaryAccent),
                Stat(label: "Session", value: Format.bytes(n.sessionIn + n.sessionOut),
                     detail: "↓\(Format.bytes(n.sessionIn)) ↑\(Format.bytes(n.sessionOut))"),
            ])
            Card {
                LiveChart(spec: ChartSpec(series: [
                    ChartSeries(key: .netDown, label: "Down", color: WidgetKind.network.accent),
                    ChartSeries(key: .netUp, label: "Up", color: WidgetKind.network.secondaryAccent, mirrored: true),
                ], domain: nil, format: { Format.rate($0, bits: bits, compact: true) }))
            }
            Card {
                VStack(alignment: .leading, spacing: 2) {
                    SectionTitle("Interfaces")
                    if n.interfaces.isEmpty {
                        Text("No traffic yet.").font(DS.label).foregroundStyle(.tertiary)
                    }
                    ForEach(n.interfaces.prefix(5)) { i in
                        HStack(spacing: 6) {
                            Image(systemName: icon(i)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                            Text(i.displayName).font(DS.body).lineLimit(1)
                            Text(i.bsdName).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                            Spacer(minLength: 4)
                            Text("↓" + Format.rate(i.downBps, bits: bits, compact: true)).frame(minWidth: 52, alignment: .trailing)
                            Text("↑" + Format.rate(i.upBps, bits: bits, compact: true)).foregroundStyle(.secondary).frame(minWidth: 52, alignment: .trailing)
                        }
                        .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                        .frame(height: DS.rowHeight - 2)
                        .opacity(i.isVirtual ? 0.75 : 1)
                        .help(i.isVirtual ? "Tunnel: its traffic also crosses a physical link, so it isn't added to the total."
                              : "Session ↓\(Format.bytes(i.sessionIn)) ↑\(Format.bytes(i.sessionOut))")
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func icon(_ i: InterfaceRate) -> String {
        let name = i.displayName.lowercased()
        if name.contains("wi-fi") || name.contains("wifi") { return "wifi" }
        if i.isVirtual { return "lock.shield" }
        if i.bsdName.hasPrefix("pdp_ip") { return "antenna.radiowaves.left.and.right" }
        if name.contains("thunderbolt") || name.contains("ethernet") { return "cable.connector" }
        return "network"
    }
}

// MARK: Battery

struct BatteryDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let b = store.battery ?? BatterySnapshot()
        let f = settings.settings.temperatureUnit == .fahrenheit
        let minutes = b.charging ? b.minutesToFull : b.minutesToEmpty
        VStack(alignment: .leading, spacing: DS.gap) {
            if !b.present && store.battery != nil {
                Card { Text("This Mac has no battery.").font(DS.body).foregroundStyle(.secondary) }
            }
            StatStrip(stats: [
                Stat(label: "Charge", value: Format.percent(b.percent), detail: b.charging ? "charging" : (b.onAC ? "on adapter" : "on battery"),
                     level: b.onAC ? .normal : Level.of(b.percent * 100, config: settings.config(.battery), inverted: true)),
                Stat(label: (b.batteryWatts ?? 0) >= 0 ? "Into battery" : "Out of battery", value: b.batteryWatts.map { Format.watts(abs($0)) } ?? "—",
                     detail: b.systemPowerWatts.map { "system \(Format.watts($0))" }),
                Stat(label: b.charging ? "Until full" : "Remaining", value: minutes.map(Format.minutes) ?? "—",
                     detail: minutes == nil ? (b.onAC ? "on AC" : "estimating") : "h:mm"),
            ])
            Card {
                // Charge barely moves in a minute; power in (above zero) and out (below) is what changes.
                LiveChart(spec: ChartSpec(series: [ChartSeries(key: .batteryWatts, label: "Power", color: WidgetKind.battery.accent)],
                                          domain: nil, format: { String(format: "%.0f W", $0) }))
            }
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle("Health", trailing: b.condition ?? "Normal")
                    if let h = b.health {
                        MeterRow(label: "Capacity", fraction: min(1, h), value: Format.percent(h),
                                 tint: h < 0.8 ? .orange : WidgetKind.battery.accent, labelWidth: 58)
                    }
                    InfoGrid(items: [
                        ("Cycles", b.cycleCount.map(String.init)),
                        ("Max", b.maxCapacity.map { "\($0) mAh" }),
                        ("Design", b.designCapacity.map { "\($0) mAh" }),
                        ("Voltage", b.voltage.map { String(format: "%.2f V", $0) }),
                        ("Temp", b.temperature.map { Format.temperature($0, fahrenheit: f, decimals: 1) }),
                        ("Adapter", b.adapterWatts.map { "\(Int($0)) W" }),
                    ].compactMap { label, value in value.map { (label, $0) } })
                }
            }
        }
    }
}
