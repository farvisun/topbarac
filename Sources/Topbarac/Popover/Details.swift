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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                StatTile(label: "Usage", value: Format.percent(c.usage),
                         caption: "\(Format.percent(c.user)) usr · \(Format.percent(c.system)) sys",
                         level: Level.of(c.usage * 100, config: config, inverted: false))
                StatTile(label: "Frequency", value: c.pFrequencyMHz.map(Format.mhz) ?? "—",
                         caption: c.eFrequencyMHz.map { "E-cores \(Format.mhz($0))" } ?? "P-cores")
                if let w = c.powerWatts {
                    StatTile(label: "Power", value: Format.watts(w), caption: "CPU package")
                } else {
                    StatTile(label: "Load", value: String(format: "%.2f", c.load.0), caption: "1-minute average")
                }
            }
            Card {
                LiveChart(spec: ChartSpec(series: [
                    ChartSeries(key: .cpuUsage, label: "Total", color: WidgetKind.cpu.accent),
                    ChartSeries(key: .cpuP, label: "P-cores", color: .orange, area: false),
                    ChartSeries(key: .cpuE, label: "E-cores", color: .teal, area: false),
                ].filter { $0.key == .cpuUsage || c.pClusterUsage != nil }, domain: 0...1, format: percentAxis))
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Cores", trailing: c.busiestCore.map { "Busiest: core \($0.index + 1) at \(Format.percent($0.usage))" })
                    CoreGrid(cores: c.perCore, kinds: c.coreKinds, config: config)
                    Divider().opacity(0.5)
                    HStack {
                        InfoRow(label: "Load", value: String(format: "%.2f  %.2f  %.2f", c.load.0, c.load.1, c.load.2), symbol: "gauge.medium")
                    }
                    InfoRow(label: "Uptime", value: Format.duration(c.uptime), symbol: "clock")
                }
            }
        }
    }
}

/// One small vertical bar per logical core, P-cores and E-cores in separate groups.
struct CoreGrid: View {
    var cores: [Double]
    var kinds: [CoreKind]
    var config: WidgetConfig

    var body: some View {
        let groups: [(String, [(Int, Double)])] = {
            let indexed = Array(cores.enumerated())
            let p = indexed.filter { kinds.indices.contains($0.offset) && kinds[$0.offset] == .performance }.map { ($0.offset, $0.element) }
            let e = indexed.filter { kinds.indices.contains($0.offset) && kinds[$0.offset] == .efficiency }.map { ($0.offset, $0.element) }
            if p.isEmpty && e.isEmpty { return [("Cores", indexed.map { ($0.offset, $0.element) })] }
            return [("Performance", p), ("Efficiency", e)].filter { !$0.1.isEmpty }
        }()
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groups, id: \.0) { name, list in
                HStack(alignment: .bottom, spacing: 10) {
                    Text(name == "Performance" ? "P" : (name == "Efficiency" ? "E" : ""))
                        .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                        .frame(width: 10)
                        .help(name + " cores")
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(list, id: \.0) { index, usage in
                            let level = Level.of(usage * 100, config: config, inverted: false)
                            VStack(spacing: 3) {
                                ZStack(alignment: .bottom) {
                                    RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.07))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(level == .normal ? AnyShapeStyle(WidgetKind.cpu.accent.gradient) : AnyShapeStyle(level.color.gradient))
                                        .frame(height: max(2, 34 * usage))
                                }
                                .frame(height: 34)
                                Text("\(index + 1)").font(.system(size: 8.5)).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: 24)
                            .help("Core \(index + 1): \(Format.percent(usage))")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Core \(index + 1)")
                            .accessibilityValue(Format.percent(usage))
                        }
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: cores)
    }
}

// MARK: Memory

struct MemoryDetail: View {
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(ToastCenter.self) private var toasts
    @State private var purging = false
    @State private var confirmPurge = false

    var body: some View {
        let m = store.memory ?? MemorySnapshot()
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                StatTile(label: "Used", value: Format.memory(m.used), caption: "of \(Format.memory(m.total))",
                         level: Level.of(m.usage * 100, config: settings.config(.memory), inverted: false))
                StatTile(label: "Cached files", value: Format.memory(m.cached), caption: "Reclaimable")
                StatTile(label: "Swap", value: Format.memory(m.swapUsed),
                         caption: m.swapTotal > 0 ? "of \(Format.memory(m.swapTotal))" : "Not in use",
                         level: m.swapUsed > m.total / 4 ? .warning : .normal)
            }
            Card {
                LiveChart(spec: ChartSpec(series: [ChartSeries(key: .memUsage, label: "Used", color: WidgetKind.memory.accent)],
                                          domain: 0...1, format: percentAxis))
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Breakdown", trailing: Format.percent(m.usage) + " used")
                    let parts = [
                        StackedBar.Part(label: "App", value: Double(m.app), color: WidgetKind.memory.accent),
                        StackedBar.Part(label: "Wired", value: Double(m.wired), color: .orange),
                        StackedBar.Part(label: "Compressed", value: Double(m.compressed), color: .pink),
                        StackedBar.Part(label: "Cached", value: Double(m.cached), color: .teal.opacity(0.7)),
                    ]
                    StackedBar(parts: parts, total: Double(m.total))
                    Grid(horizontalSpacing: 16, verticalSpacing: 5) {
                        GridRow {
                            LegendDot(color: parts[0].color, label: "App", value: Format.memory(m.app))
                            LegendDot(color: parts[1].color, label: "Wired", value: Format.memory(m.wired))
                        }
                        GridRow {
                            LegendDot(color: parts[2].color, label: "Compressed", value: Format.memory(m.compressed))
                            LegendDot(color: parts[3].color, label: "Cached", value: Format.memory(m.cached))
                        }
                        GridRow {
                            LegendDot(color: .primary.opacity(0.15), label: "Free", value: Format.memory(m.free))
                            LegendDot(color: m.pressure == .normal ? .green : (m.pressure == .warning ? .yellow : .red),
                                      label: "Pressure", value: m.pressure.title)
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Tools")
                    if confirmPurge {
                        Text("Free inactive memory runs `purge`. It asks for an administrator password and can make apps briefly slower while caches refill.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Free Memory") { purge() }.buttonStyle(.glassProminent).tint(WidgetKind.memory.accent)
                            Button("Cancel") { confirmPurge = false }.buttonStyle(.borderless)
                        }
                        .controlSize(.small)
                    } else {
                        HStack {
                            Button {
                                confirmPurge = true
                            } label: {
                                Label(purging ? "Freeing…" : "Free Inactive Memory", systemImage: "wind")
                            }
                            .disabled(purging)
                            Spacer()
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                StatTile(label: "Read", value: Format.rate(d.readBps), tint: WidgetKind.disk.accent)
                StatTile(label: "Write", value: Format.rate(d.writeBps), tint: WidgetKind.disk.secondaryAccent)
                StatTile(label: "Busy", value: Format.percent(d.busy), caption: d.busiestDevice)
            }
            Card {
                LiveChart(spec: ChartSpec(series: [
                    ChartSeries(key: .diskRead, label: "Read", color: WidgetKind.disk.accent),
                    ChartSeries(key: .diskWrite, label: "Write", color: WidgetKind.disk.secondaryAccent, mirrored: true),
                ], domain: nil, format: { Format.rate($0, compact: true) }))
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle("Volumes", trailing: "\(d.volumes.count)")
                    if d.volumes.isEmpty {
                        Text("Reading volumes…").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    ForEach(d.volumes) { volume in VolumeRow(volume: volume) }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Clean up")
                    HStack(spacing: 8) {
                        Image(systemName: "trash").frame(width: 16).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Trash").font(.system(size: 12, weight: .medium))
                            Text(sizeText(trashSize, unreadable: "Needs Full Disk Access to measure"))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if confirmEmpty {
                            Button("Empty") { emptyTrash() }.buttonStyle(.glassProminent).tint(.red)
                            Button("Cancel") { confirmEmpty = false }.buttonStyle(.borderless)
                        } else {
                            Button("Empty Trash…") { confirmEmpty = true }.buttonStyle(.glass).disabled(working)
                        }
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "archivebox").frame(width: 16).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("User caches").font(.system(size: 12, weight: .medium))
                            Text(sizeText(cachesSize, unreadable: "Couldn't read")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show in Finder") { SystemActions.reveal(SystemActions.cachesURL) }.buttonStyle(.glass)
                    }
                    Text("Topbarac never deletes caches itself. Remove what you don't need in Finder.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .controlSize(.small)
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

struct VolumeRow: View {
    var volume: VolumeInfo
    @Environment(ToastCenter.self) private var toasts
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive").foregroundStyle(.secondary)
                Text(volume.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                if hovering {
                    Button { SystemActions.open(volume) } label: { Image(systemName: "folder") }
                        .help("Open in Finder").accessibilityLabel("Open \(volume.name) in Finder")
                    if volume.isEjectable {
                        Button {
                            Task { toasts.show(await SystemActions.eject(volume), success: "Ejected \(volume.name)") }
                        } label: { Image(systemName: "eject") }
                            .help("Eject").accessibilityLabel("Eject \(volume.name)")
                    }
                } else {
                    Text(Format.percent(volume.usage)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
            }
            .buttonStyle(.borderless)
            MeterBar(fraction: volume.usage, tint: volume.usage > 0.9 ? .red : (volume.usage > 0.8 ? .yellow : WidgetKind.disk.accent))
            HStack {
                Text("\(Format.bytes(volume.available)) free of \(Format.bytes(volume.total))")
                Spacer()
                if volume.purgeable > 1_000_000_000 { Text("\(Format.bytes(volume.purgeable)) purgeable") }
            }
            .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                StatTile(label: "CPU", value: fmt(t.cpu), level: Level.of(t.cpu, config: config, inverted: false))
                StatTile(label: "GPU", value: fmt(t.gpu), level: Level.of(t.gpu, config: config, inverted: false))
                StatTile(label: t.ssd != nil ? "SSD" : "Battery", value: fmt(t.ssd ?? t.battery))
            }
            Card {
                LiveChart(spec: ChartSpec(series: [
                    ChartSeries(key: .tempCPU, label: "CPU", color: WidgetKind.temperature.accent, area: false),
                    ChartSeries(key: .tempGPU, label: "GPU", color: WidgetKind.gpu.accent, area: false),
                    ChartSeries(key: .tempSSD, label: "SSD", color: WidgetKind.disk.accent, area: false),
                ], domain: nil, includesZero: false, format: { Format.temperature($0, fahrenheit: f) }))
            }
            if !t.fans.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle("Fans")
                        ForEach(t.fans) { fan in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: "fan").foregroundStyle(.secondary)
                                        .symbolEffect(.rotate, options: .repeat(.continuous), isActive: fan.rpm > 1)
                                    Text(t.fans.count > 1 ? (fan.id == 0 ? "Left fan" : "Right fan") : "Fan").font(.system(size: 12))
                                    Spacer()
                                    Text(fan.rpm < 1 ? "Off" : "\(Int(fan.rpm)) RPM").font(.system(size: 12, weight: .medium)).monospacedDigit()
                                }
                                MeterBar(fraction: fan.fraction, tint: WidgetKind.temperature.accent, height: 5)
                                Text("Range \(Int(fan.minRPM))–\(Int(fan.maxRPM)) RPM").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Sensors", trailing: "click a group for min · now · max")
                    if t.sensors.isEmpty {
                        Text("No sensors found on this Mac.").font(.system(size: 11)).foregroundStyle(.tertiary)
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

/// One sensor group: a summary row (count, average, hottest) that expands to every sensor.
struct SensorGroupView: View {
    var group: SensorGroup
    var sensors: [SensorReading]
    var config: WidgetConfig
    var format: (Double?) -> String
    @State private var expanded = false

    var body: some View {
        let hottest = sensors.map(\.celsius).max() ?? 0
        let average = sensors.map(\.celsius).reduce(0, +) / Double(max(1, sensors.count))
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(group.rawValue).font(.system(size: 12, weight: .medium))
                    Text(sensors.count == 1 ? "" : "\(sensors.count) sensors").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    Spacer()
                    if sensors.count > 1 {
                        Text("avg \(format(average))").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    let level = Level.of(hottest, config: config, inverted: false)
                    Text(format(hottest)).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(level == .normal ? .primary : level.color)
                        .frame(width: 38, alignment: .trailing)
                }
                .monospacedDigit()
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.rawValue), hottest \(format(hottest))")
            .accessibilityHint(expanded ? "Collapse" : "Show every sensor")
            if expanded {
                ForEach(sensors) { s in
                    let level = Level.of(s.celsius, config: config, inverted: false)
                    HStack(spacing: 8) {
                        Text(s.name).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(format(s.min)).foregroundStyle(.tertiary)
                        Text(format(s.celsius)).fontWeight(.semibold)
                            .foregroundStyle(level == .normal ? .primary : level.color)
                            .frame(width: 38, alignment: .trailing)
                        Text(format(s.max)).foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 11)).monospacedDigit()
                    .padding(.leading, 15)
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
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
        VStack(alignment: .leading, spacing: 14) {
            if !g.available && store.gpu != nil {
                Card { Text("No supported GPU found on this Mac.").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            HStack(spacing: 8) {
                StatTile(label: "Usage", value: Format.percent(g.utilization),
                         level: Level.of(g.utilization * 100, config: settings.config(.gpu), inverted: false))
                StatTile(label: "Frequency", value: g.frequencyMHz.map(Format.mhz) ?? "—")
                StatTile(label: "Power", value: g.powerWatts.map(Format.watts) ?? "—",
                         caption: g.temperature.map { Format.temperature($0, fahrenheit: f) })
            }
            Card {
                LiveChart(spec: ChartSpec(series: [ChartSeries(key: .gpuUsage, label: "Usage", color: WidgetKind.gpu.accent)],
                                          domain: 0...1, format: percentAxis))
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Engines")
                    engine("Renderer", g.renderer)
                    engine("Tiler", g.tiler)
                    Divider().opacity(0.5)
                    SectionTitle("Memory", trailing: g.memoryAllocated > 0 ? "\(Format.memory(g.memoryUsed)) in use" : nil)
                    MeterBar(fraction: g.memoryAllocated > 0 ? Double(g.memoryUsed) / Double(g.memoryAllocated) : 0, tint: WidgetKind.gpu.accent)
                    InfoRow(label: "In use", value: Format.memory(g.memoryUsed))
                    InfoRow(label: "Allocated", value: Format.memory(g.memoryAllocated))
                    Text("Apple GPUs share system memory; this is what the GPU has mapped right now.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func engine(_ name: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Text(Format.percent(value)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }
            MeterBar(fraction: value, tint: WidgetKind.gpu.accent, height: 5)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                StatTile(label: "Download", value: Format.rate(n.downBps, bits: bits), tint: WidgetKind.network.accent)
                StatTile(label: "Upload", value: Format.rate(n.upBps, bits: bits), tint: WidgetKind.network.secondaryAccent)
                StatTile(label: "This session", value: Format.bytes(n.sessionIn + n.sessionOut),
                         caption: "↓\(Format.bytes(n.sessionIn)) ↑\(Format.bytes(n.sessionOut))")
            }
            Card {
                LiveChart(spec: ChartSpec(series: [
                    ChartSeries(key: .netDown, label: "Download", color: WidgetKind.network.accent),
                    ChartSeries(key: .netUp, label: "Upload", color: WidgetKind.network.secondaryAccent, mirrored: true),
                ], domain: nil, format: { Format.rate($0, bits: bits, compact: true) }))
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Interfaces")
                    if n.interfaces.isEmpty {
                        Text("No traffic yet.").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    ForEach(n.interfaces.prefix(6)) { i in
                        HStack(spacing: 8) {
                            Image(systemName: icon(i)).foregroundStyle(.secondary).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(i.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text("\(i.bsdName)\(i.isVirtual ? " · not counted in total" : "") · ↓ \(Format.bytes(i.sessionIn)) ↑ \(Format.bytes(i.sessionOut))")
                                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("↓ " + Format.rate(i.downBps, bits: bits))
                                Text("↑ " + Format.rate(i.upBps, bits: bits)).foregroundStyle(.secondary)
                            }
                            .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                        }
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
        VStack(alignment: .leading, spacing: 14) {
            if !b.present && store.battery != nil {
                Card { Text("This Mac has no battery.").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            HStack(spacing: 8) {
                StatTile(label: "Charge", value: Format.percent(b.percent),
                         level: b.onAC ? .normal : Level.of(b.percent * 100, config: settings.config(.battery), inverted: true))
                StatTile(label: b.charging ? "Charging at" : "Draining at",
                         value: b.batteryWatts.map { Format.watts(abs($0)) } ?? "—",
                         caption: b.systemPowerWatts.map { "System \(Format.watts($0))" })
                StatTile(label: b.charging ? "Until full" : "Remaining",
                         value: (b.charging ? b.minutesToFull : b.minutesToEmpty).map(Format.minutes) ?? (b.onAC ? "On AC" : "Estimating"))
            }
            Card {
                LiveChart(spec: ChartSpec(series: [ChartSeries(key: .battery, label: "Charge", color: WidgetKind.battery.accent)],
                                          domain: 0...1, format: percentAxis))
            }
            Card {
                VStack(alignment: .leading, spacing: 7) {
                    SectionTitle("Health")
                    if let h = b.health {
                        HStack {
                            Text("Maximum capacity").font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.percent(h)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        }
                        MeterBar(fraction: min(1, h), tint: h < 0.8 ? .orange : WidgetKind.battery.accent)
                    }
                    InfoRow(label: "Condition", value: b.condition ?? "Normal", symbol: "heart")
                    if let c = b.cycleCount { InfoRow(label: "Cycle count", value: "\(c)", symbol: "arrow.triangle.2.circlepath") }
                    if let max = b.maxCapacity, let design = b.designCapacity {
                        InfoRow(label: "Capacity", value: "\(max) of \(design) mAh", symbol: "battery.100percent")
                    }
                    if let v = b.voltage { InfoRow(label: "Voltage", value: String(format: "%.2f V", v), symbol: "bolt") }
                    if let t = b.temperature { InfoRow(label: "Temperature", value: Format.temperature(t, fahrenheit: f, decimals: 1), symbol: "thermometer.medium") }
                    if let a = b.adapterWatts { InfoRow(label: "Power adapter", value: "\(Int(a)) W", symbol: "powerplug") }
                }
            }
        }
    }
}
