import SwiftUI
import TopbaracCore

// Sections fed by slower, on-demand probes. Each polls only while its view is on screen (the `.task` ends with
// the popover), and the blocking calls run off the main thread.

// MARK: Health check

/// "Why is my Mac slow?": the findings of `Diagnostics`, most severe first, each with a one-click fix.
struct HealthCheck: View {
    @Environment(MonitorStore.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @State private var working: String?

    var body: some View {
        let findings = Diagnostics.run(DiagnosticInput(cpu: store.cpu, memory: store.memory, temperature: store.temperature,
                                                       disk: store.disk, battery: store.battery, processes: store.processes))
        Group {
            if findings.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 15)).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Everything looks fine").font(.system(size: 12, weight: .semibold))
                        Text("No app hogging the CPU, enough memory and disk, no throttling.")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.inner).padding(.vertical, 8)
                .background(Color.green.opacity(0.08), in: .rect(cornerRadius: DS.corner))
            } else {
                Card(padding: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionTitle("Why it may feel slow", trailing: "\(findings.count) found").padding(.horizontal, 2).padding(.bottom, 2)
                        ForEach(findings.prefix(4)) { finding in row(finding) }
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: findings.map(\.id))
    }

    private func row(_ f: Finding) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: f.severity == .info ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(color(f.severity)).frame(width: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(2)
                Text(f.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let action = f.action {
                Button(working == f.id ? "…" : title(action)) { run(action, id: f.id) }
                    .buttonStyle(.bordered).controlSize(.small).disabled(working != nil)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private func color(_ s: Finding.Severity) -> Color {
        switch s { case .info: .blue; case .warning: .orange; case .critical: .red }
    }

    private func title(_ a: Finding.Action) -> String {
        switch a {
        case .quitProcess: "Quit"
        case .freeMemory: "Free"
        case .openStorage: "Analyze"
        case .showProcesses: "Show"
        }
    }

    private func run(_ action: Finding.Action, id: String) {
        switch action {
        case .quitProcess(let pid, let name):
            toasts.show(ProcessActions.quit(pid: pid), success: "Asked \(name) to quit")
        case .freeMemory:
            working = id
            Task {
                let (result, freed) = await SystemActions.purgeMemory()
                working = nil
                toasts.show(result, success: freed > 0 ? "Freed \(Format.memory(freed))" : "Inactive memory released")
            }
        case .openStorage:
            AppDelegate.shared.openStorage()
        case .showProcesses(let metric):
            AppDelegate.shared.openProcesses(sort: ProcessSort(rawValue: metric) ?? .cpu)
        }
    }
}

// MARK: Sleep blockers

/// Apps holding a power assertion that keeps the Mac (or its display) awake. Hidden when there are none.
struct SleepBlockersSection: View {
    var blockers: [SleepBlocker]

    var body: some View {
        if !blockers.isEmpty {
            Card(padding: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    SectionTitle("Keeping your Mac awake", trailing: "\(blockers.count)").padding(.horizontal, 2).padding(.bottom, 3)
                    ForEach(blockers.prefix(5)) { b in
                        HStack(spacing: 7) {
                            Image(systemName: b.kind == .display ? "display" : "moon.zzz")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).frame(width: 15)
                            Text(b.processName).font(DS.body).lineLimit(1).layoutPriority(1)
                            Text(b.reason).font(DS.label).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 4)
                            if let since = b.since {
                                Text(since, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                                    .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                            }
                        }
                        .frame(height: 20)
                        .padding(.horizontal, 4)
                        .help("\(b.processName) (PID \(b.pid)) prevents \(b.kind == .display ? "the display from sleeping" : "sleep"): \(b.reason)")
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

/// Slow probes run off the main thread. Views poll these from a parent that is always on screen: `.task` on a view
/// that renders nothing never starts.
enum ExtrasLoader {
    static func blockers() async -> [SleepBlocker] {
        await Task.detached(priority: .utility) { PowerAssertionProbe.blockers() }.value
    }

    /// Bluetooth readings are cached for a minute (system_profiler is slow).
    static func accessories() async -> [BluetoothBattery] {
        if let cached = accessoriesCache, Date().timeIntervalSince(cached.time) < 55 { return cached.list }
        let fresh = await Task.detached(priority: .utility) { BluetoothBatteryProbe.read() }.value
        accessoriesCache = (Date(), fresh)
        return fresh
    }

    static var cachedAccessories: [BluetoothBattery] { accessoriesCache?.list ?? [] }
}

// MARK: Bluetooth accessories

/// Last reading, so a reopened popover shows batteries at once while a fresh read runs.
@MainActor private var accessoriesCache: (time: Date, list: [BluetoothBattery])?

struct AccessoriesSection: View {
    var list: [BluetoothBattery]
    var compact = false

    var body: some View {
        if !list.isEmpty {
            Card(padding: compact ? 8 : DS.inner) {
                VStack(alignment: .leading, spacing: 3) {
                    SectionTitle("Accessories").padding(.horizontal, compact ? 2 : 0)
                    ForEach(list) { device in row(device) }
                }
            }
        }
    }

    private func row(_ d: BluetoothBattery) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol(d.kind)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(d.name).font(DS.body).lineLimit(1)
            Spacer(minLength: 4)
            ForEach(Array(d.levels.enumerated()), id: \.offset) { _, level in
                HStack(spacing: 3) {
                    if let label = level.label { Text(label.prefix(1)).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
                    BatteryGlyph(fraction: level.fraction)
                    Text(Format.percent(level.fraction)).font(DS.value)
                }
                .help(level.label.map { "\($0): \(Format.percent(level.fraction))" } ?? Format.percent(level.fraction))
            }
        }
        .frame(height: 20)
        .padding(.horizontal, compact ? 4 : 0)
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ k: BluetoothBattery.Kind) -> String {
        switch k {
        case .mouse: "computermouse"
        case .keyboard: "keyboard"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .headphones: "airpods"
        case .controller: "gamecontroller"
        case .other: "dot.radiowaves.left.and.right"
        }
    }
}

/// Small battery outline with a fill, red below 15 %.
struct BatteryGlyph: View {
    var fraction: Double

    var body: some View {
        HStack(spacing: 0.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).strokeBorder(.secondary, lineWidth: 1)
                RoundedRectangle(cornerRadius: 1)
                    .fill(fraction < 0.15 ? Color.red : Color.primary.opacity(0.75))
                    .frame(width: max(1.5, 14 * min(1, fraction)))
                    .padding(1.5)
            }
            .frame(width: 18, height: 9)
            RoundedRectangle(cornerRadius: 0.5).fill(.secondary).frame(width: 1.5, height: 3.5)
        }
        .accessibilityHidden(true)
    }
}

// MARK: Wi-Fi and latency

private nonisolated let latencyProbe = LatencyProbe()

/// Wi-Fi link quality and round-trip time to the router and an internet host, refreshed every 2 s.
struct LinkSection: View {
    @Environment(SettingsStore.self) private var settings
    @State private var wifi: WiFiInfo?
    @State private var wifiRead = false
    @State private var gateway: String?
    @State private var routerTrail: [Double?] = []
    @State private var internetTrail: [Double?] = []

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle("Connection quality")
                if let wifi {
                    HStack(spacing: 7) {
                        SignalBars(quality: wifi.quality)
                        Text(wifi.ssid ?? "Wi‑Fi").font(DS.body).lineLimit(1)
                        Text([wifi.phyMode, wifi.band].compactMap { $0 }.joined(separator: " · "))
                            .font(DS.label).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(wifi.rssi) dBm").font(DS.value)
                    }
                    .frame(height: 18)
                    .help("Signal \(wifi.rssi) dBm, noise \(wifi.noise) dBm\(wifi.snr.map { ", SNR \($0) dB" } ?? "")")
                    InfoGrid(items: [
                        ("Link rate", "\(Int(wifi.txRateMbps)) Mb/s"),
                        ("Channel", wifi.channel.map { "\($0)\(wifi.channelWidthMHz.map { " · \($0) MHz" } ?? "")" } ?? "—"),
                        ("Noise", "\(wifi.noise) dBm"),
                        ("Security", wifi.security ?? "—"),
                    ])
                    Divider().padding(.vertical, 2)
                } else if wifiRead {
                    Text("Not on Wi‑Fi").font(DS.label).foregroundStyle(.tertiary).frame(height: 16)
                }
                LatencyRow(title: "Router", detail: gateway, trail: routerTrail)
                LatencyRow(title: "Internet", detail: settings.settings.latencyHost, trail: internetTrail)
            }
        }
        .task { await poll() }
    }

    private func poll() async {
        gateway = await Task.detached { LatencyProbe.defaultGateway() }.value
        while !Task.isCancelled {
            let host = settings.settings.latencyHost.trimmingCharacters(in: .whitespaces)
            let gw = gateway
            let probe = latencyProbe
            async let w = Task.detached(priority: .utility) { WiFiProbe.read() }.value
            async let r = Task.detached(priority: .utility) { gw.flatMap { probe.ping($0, timeout: 1) } }.value
            async let i = Task.detached(priority: .utility) { host.isEmpty ? nil : probe.ping(host, timeout: 1) }.value
            let (wv, rv, iv) = await (w, r, i)
            wifi = wv
            wifiRead = true
            routerTrail = Array((routerTrail + [rv]).suffix(30))
            internetTrail = Array((internetTrail + [iv]).suffix(30))
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

private struct LatencyRow: View {
    var title: String
    var detail: String?
    var trail: [Double?]

    var body: some View {
        let last = trail.last ?? nil
        let answered = trail.compactMap { $0 }
        let loss = trail.isEmpty ? 0 : Double(trail.count - answered.count) / Double(trail.count)
        HStack(spacing: 7) {
            Circle().fill(color(last)).frame(width: 6, height: 6).frame(width: 16)
            Text(title).font(DS.body)
            if let detail { Text(detail).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1) }
            Spacer(minLength: 4)
            LatencyTrail(values: trail).frame(width: 64, height: 14)
            Text(trail.isEmpty ? "…" : (last.map { $0 < 10 ? String(format: "%.1f ms", $0) : "\(Int($0)) ms" } ?? (answered.isEmpty ? "no reply" : "timeout")))
                .font(DS.value).foregroundStyle(last == nil && !trail.isEmpty ? .secondary : .primary)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .frame(height: 20)
        .help(answered.isEmpty ? "No replies. Some routers never answer ping."
              : "Last 30: avg \(Int(answered.reduce(0, +) / Double(answered.count))) ms, max \(Int(answered.max() ?? 0)) ms, \(Int(loss * 100))% lost")
        .accessibilityElement(children: .combine)
    }

    private func color(_ ms: Double?) -> Color {
        guard let ms else { return trail.isEmpty || trail.allSatisfy({ $0 == nil }) ? .secondary : .red }
        return ms < 60 ? .green : (ms < 150 ? .yellow : .orange)
    }
}

/// Bars for the last pings; gaps are timeouts.
private struct LatencyTrail: View {
    var values: [Double?]

    var body: some View {
        Canvas { context, size in
            let peak = max(50, values.compactMap { $0 }.max() ?? 50)
            let w = size.width / 30
            for (i, v) in values.enumerated() {
                let x = size.width - CGFloat(values.count - i) * w
                if let v {
                    let h = max(1.5, CGFloat(v / peak) * size.height)
                    context.fill(Path(CGRect(x: x, y: size.height - h, width: max(1, w - 0.8), height: h)),
                                 with: .color(WidgetKind.network.accent.opacity(0.8)))
                } else {
                    context.fill(Path(CGRect(x: x, y: 0, width: max(1, w - 0.8), height: size.height)), with: .color(.red.opacity(0.35)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Four rising bars, filled by link quality.
struct SignalBars: View {
    var quality: Double

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 0.8)
                    .fill(Double(i) < quality * 4 + 0.25 ? Color.primary : Color.primary.opacity(0.15))
                    .frame(width: 2.5, height: 3 + CGFloat(i) * 2.5)
            }
        }
        .frame(width: 16, height: 11, alignment: .bottom)
        .accessibilityLabel("Signal \(Int(quality * 100)) percent")
    }
}
