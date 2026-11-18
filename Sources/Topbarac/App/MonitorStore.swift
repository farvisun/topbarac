import AppKit
import Foundation
import Observation
import TopbaracCore

/// Latest values, in-memory history and processes. Fed by the sampler on the main thread. Views read the property
/// they show, so a CPU tick does not redraw the memory popover.
@Observable
final class MonitorStore {
    static let shared = MonitorStore()

    private(set) var cpu: CPUSnapshot?
    private(set) var memory: MemorySnapshot?
    private(set) var disk: DiskSnapshot?
    private(set) var temperature: TemperatureSnapshot?
    private(set) var gpu: GPUSnapshot?
    private(set) var network: NetworkSnapshot?
    private(set) var battery: BatterySnapshot?
    private(set) var processes: [ProcessSample] = []
    /// Ring buffers are mutated in place (no copy per tick); views observe `historyTick` instead.
    @ObservationIgnored private var histories: [SeriesKey: SeriesHistory] = [:]
    /// Per-core usage for the core heatmap: the last two minutes or so, oldest first. Reads go through `historyTick`.
    /// Per-app CPU over the last minute, kept only while the processes window is open.
    @ObservationIgnored private var cpuTrails: [Int32: [Double]] = [:]
    @ObservationIgnored private var coreSamples: [(time: Date, usage: [Double])] = []
    private(set) var historyTick = 0
    private(set) var lastFrame: Date?
    private(set) var paused = false
    /// Alert rules whose condition currently holds (drives the flashing menu bar item).
    private(set) var activeAlertWidgets: Set<WidgetKind> = []
    /// Alerts fired this session (newest last), marked on the charts.
    private(set) var recentAlerts: [AlertEvent] = []
    /// Popovers that are open right now.
    private(set) var openDetails: Set<WidgetKind> = []

    /// Called after each frame is applied (menu bar items redraw from here, outside SwiftUI).
    @ObservationIgnored var onFrame: [() -> Void] = []

    @ObservationIgnored private var engine: SamplerEngine!
    @ObservationIgnored private var alertEngine = AlertEngine()
    @ObservationIgnored private(set) var historyStore: HistoryStore?
    @ObservationIgnored private var lastPrune = Date.distantPast
    @ObservationIgnored private let settings = SettingsStore.shared
    @ObservationIgnored private var lastPlan: SamplingPlan?

    private init() {
        engine = SamplerEngine { frame in
            DispatchQueue.main.async { MonitorStore.shared.apply(frame) }
        }
        configureHistory()
        settings.observe { [weak self] old, new in
            guard let self else { return }
            if old.historyEnabled != new.historyEnabled { configureHistory() }
            updatePlan()
        }
        updatePlan()
    }

    // MARK: Plan

    /// The All Processes window samples processes (and per-app network) while it is open.
    @ObservationIgnored private var processWindowOpen = false
    func setProcessWindow(open: Bool) {
        processWindowOpen = open
        if !open { cpuTrails = [:]; if openDetails.isEmpty && !overviewOpen { processes = [] } }
        updatePlan()
    }

    /// Reading this registers the caller for history updates.
    func cpuTrail(_ pid: Int32) -> [Double] {
        _ = historyTick
        return cpuTrails[pid] ?? []
    }

    func openDetail(_ kind: WidgetKind) { openDetails.insert(kind); updatePlan() }

    /// The overview shows every widget, so all of them are sampled while it is open, plus the process list
    /// (the health check names the app to blame).
    private(set) var overviewOpen = false
    func setOverview(open: Bool) {
        guard open != overviewOpen else { return }
        overviewOpen = open
        if !open && openDetails.isEmpty && !processWindowOpen { processes = [] }
        updatePlan()
    }
    func closeDetail(_ kind: WidgetKind) {
        openDetails.remove(kind)
        if openDetails.isEmpty && !processWindowOpen { processes = [] }
        updatePlan()
    }

    func setPaused(_ value: Bool) {
        paused = value
        engine.setPaused(value)
        if value { appendGap() }
    }

    func markGap() { engine.markGap(); alertEngine.reset() }
    func refreshVolumes() { engine.refreshVolumes() }

    private func updatePlan() {
        let s = settings.settings
        var plan = SamplingPlan()
        plan.interval = s.refreshInterval
        plan.widgets = Set(s.enabledWidgets)
        if s.alertsEnabled {
            for rule in s.alertRules where rule.enabled && !plan.widgets.contains(rule.metric.widget) { plan.background.insert(rule.metric.widget) }
        }
        plan.detail = openDetails
        plan.needsPower = (s.config(.cpu).enabled && s.config(.cpu).metric == .cpuPower)
            || (s.config(.gpu).enabled && s.config(.gpu).metric == .gpuPower)
        if processWindowOpen { plan.detail.formUnion([.cpu, .network]) }
        if overviewOpen {
            plan.widgets.formUnion(WidgetKind.allCases)
            plan.detail.insert(.cpu)
        }
        guard plan != lastPlan else { return }
        lastPlan = plan
        engine.update(plan)
    }

    // MARK: Frames

    private func apply(_ frame: SampleFrame) {
        lastFrame = frame.time
        if frame.gap {
            appendGap()
            for f in onFrame { f() }
            return
        }
        if let v = frame.cpu {
            cpu = v
            coreSamples.append((frame.time, v.perCore))
            if coreSamples.count > 60 { coreSamples.removeFirst(coreSamples.count - 60) }
        }
        if let v = frame.memory { memory = v }
        if let v = frame.disk { disk = v }
        if let v = frame.temperature { temperature = v }
        if let v = frame.gpu { gpu = v }
        if let v = frame.network { network = v }
        if let v = frame.battery { battery = v }
        if let v = frame.processes {
            processes = v
            if processWindowOpen {
                let limit = max(10, Int(60 / max(1, settings.settings.refreshInterval)))
                var next: [Int32: [Double]] = [:]
                for p in v { next[p.pid] = Array(((cpuTrails[p.pid] ?? []) + [p.cpu]).suffix(limit)) }
                cpuTrails = next
            }
        }

        let values = SeriesKey.values(in: frame)
        for (key, value) in values { histories[key, default: SeriesHistory()].append(value, at: frame.time) }
        historyTick &+= 1

        let s = settings.settings
        if s.alertsEnabled {
            let fired = alertEngine.evaluate(frame, rules: s.alertRules)
            let rulesByID = Dictionary(uniqueKeysWithValues: s.alertRules.map { ($0.id, $0) })
            let widgets = Set(alertEngine.active.compactMap { rulesByID[$0]?.metric.widget })
            if widgets != activeAlertWidgets { activeAlertWidgets = widgets }
            for event in fired { Notifier.shared.post(event) }
            if !fired.isEmpty { recentAlerts = Array((recentAlerts + fired).suffix(100)) }
        } else if !activeAlertWidgets.isEmpty {
            activeAlertWidgets = []
        }

        if let historyStore {
            historyStore.record(values, at: frame.time)
            if frame.time.timeIntervalSince(lastPrune) > 3600 {
                lastPrune = frame.time
                historyStore.prune(retention: s.historyRetention.seconds)
            }
        }
        for f in onFrame { f() }
    }

    private func appendGap() {
        let now = Date()
        for key in histories.keys { histories[key]?.append(nil, at: now) }
        historyTick &+= 1
        historyStore?.flush()
    }

    // MARK: History

    private func configureHistory() {
        if settings.settings.historyEnabled {
            if historyStore == nil { historyStore = HistoryStore(url: HistoryStore.defaultURL) }
        } else {
            historyStore?.flush(final: true)
            historyStore = nil
        }
    }

    func flushHistory() { historyStore?.flush(final: true) }

    /// Reading this registers the caller for history updates.
    func coreHistory() -> [(time: Date, usage: [Double])] {
        _ = historyTick
        return coreSamples
    }

    /// Reading this registers the caller for history updates.
    func series(_ key: SeriesKey) -> SeriesHistory? {
        _ = historyTick
        return histories[key]
    }
}
