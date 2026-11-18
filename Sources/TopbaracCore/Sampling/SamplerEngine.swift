import Foundation

/// What the engine should measure. Built by the app from settings and from which popovers are open.
public struct SamplingPlan: Sendable, Equatable {
    public var interval: TimeInterval = 1
    /// Widgets whose summary value is needed (menu bar items, alert rules, history).
    public var widgets: Set<WidgetKind> = []
    /// Widgets whose popover is open: their detail data (sensors list, volumes, per-interface rates) is refreshed
    /// faster and the process list is sampled.
    public var detail: Set<WidgetKind> = []
    /// Widgets measured only for alert rules or history (not shown): sampled every fifth tick.
    public var background: Set<WidgetKind> = []
    /// Frequency and power (IOReport) cost more than everything else together; read them only when shown.
    public var needsPower = false
    /// App usage history is on: sample processes every `appUsageInterval` seconds even with no popover open, so
    /// per-app CPU and energy can be accumulated. Rarely enough that the `ps` call costs nothing noticeable.
    public var appUsage = false
    public init() {}
}

/// One timer, one serial queue, all probes. Frames are delivered on the main queue.
public final class SamplerEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.farvisun.topbarac.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var plan = SamplingPlan()
    private var tick = 0
    private var pendingGap = false
    private var paused = false

    private lazy var cpu = CPUProbe()
    private lazy var memory = MemoryProbe()
    private lazy var disk = DiskProbe()
    private lazy var network = NetworkProbe()
    private lazy var battery = BatteryProbe()
    private lazy var gpu = GPUProbe()
    private lazy var temperature = TemperatureProbe()
    private lazy var ioreport = IOReportProbe()
    private lazy var processes = ProcessProbe()
    private let nettop = NetTopProbe()

    private var lastTemperature: TemperatureSnapshot?
    private var lastBattery: BatterySnapshot?
    /// Uptime of the previous process sample; nil after a gap, when the probe's deltas restart too.
    private var lastProcessSample: TimeInterval?

    /// Seconds between background process samples for app usage history.
    public static let appUsageInterval: TimeInterval = 30

    private let deliver: @Sendable (SampleFrame) -> Void

    public init(deliver: @escaping @Sendable (SampleFrame) -> Void) {
        self.deliver = deliver
    }

    public func update(_ newPlan: SamplingPlan) {
        queue.async { [self] in
            let intervalChanged = newPlan.interval != plan.interval
            let openedDetail = !newPlan.detail.subtracting(plan.detail).isEmpty
            plan = newPlan
            if newPlan.detail.contains(.network) { nettop.start() } else { nettop.stop() }
            if intervalChanged || timer == nil { restartTimer() }
            // Fresh data right away when a popover opens instead of waiting for the next tick.
            if openedDetail { disk.invalidateVolumes(); sampleNow() }
        }
    }

    public func setPaused(_ value: Bool) {
        queue.async { [self] in
            paused = value
            if value { timer?.cancel(); timer = nil } else { markGapLocked(); restartTimer() }
        }
    }

    /// Call on sleep, wake and clock changes: the next frame is a gap and every delta restarts.
    public func markGap() { queue.async { [self] in markGapLocked() } }

    /// Re-read volumes on the next tick (after eject, mount, emptying Trash).
    public func refreshVolumes() { queue.async { [self] in disk.invalidateVolumes() } }

    private func markGapLocked() {
        pendingGap = true
        cpu.reset(); disk.reset(); network.reset(); processes.reset(); ioreport.reset()
        lastProcessSample = nil
    }

    private func restartTimer() {
        timer?.cancel()
        guard !paused else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(0.5, plan.interval)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        t.setEventHandler { [weak self] in self?.sampleNow() }
        t.resume()
        timer = t
    }

    private func sampleNow() {
        tick &+= 1
        var wanted = plan.widgets.union(plan.detail)
        if tick % 5 == 1 { wanted.formUnion(plan.background) }
        var frame = SampleFrame(time: Date(), gap: pendingGap)
        pendingGap = false
        if frame.gap { deliver(frame); return }   // a gap frame carries no values

        var report: IOReportProbe.Reading?
        if plan.needsPower || plan.detail.contains(.cpu) || plan.detail.contains(.gpu) { report = ioreport.sample() }

        if wanted.contains(.cpu), var c = cpu.sample() {
            c.pFrequencyMHz = report?.pFrequencyMHz
            c.eFrequencyMHz = report?.eFrequencyMHz
            c.powerWatts = report?.cpuPowerW
            frame.cpu = c
        }
        if wanted.contains(.memory) { frame.memory = memory.sample() }
        if wanted.contains(.disk) {
            frame.disk = disk.sample(volumeRefreshInterval: plan.detail.contains(.disk) ? 3 : 15)
        }
        if wanted.contains(.network) { frame.network = network.sample() }
        if wanted.contains(.gpu) {
            var g = gpu.sample()
            g.frequencyMHz = report?.gpuFrequencyMHz
            g.powerWatts = report?.gpuPowerW
            frame.gpu = g
        }
        // Sensors and SMC cost the most: every tick only while someone looks at them or alerts need them closely.
        if wanted.contains(.temperature) || wanted.contains(.gpu) {
            // Every tick while a popover shows them, every third tick for the menu bar.
            if plan.detail.contains(.temperature) || plan.detail.contains(.gpu) || tick % 3 == 1 || lastTemperature == nil {
                lastTemperature = temperature.sample()
            }
            frame.temperature = lastTemperature
            if frame.gpu != nil { frame.gpu?.temperature = lastTemperature?.gpu }
        }
        if wanted.contains(.battery) {
            if plan.detail.contains(.battery) || tick % 5 == 1 || lastBattery == nil { lastBattery = battery.sample() }
            frame.battery = lastBattery
        }
        // Every tick while a popover shows the list; otherwise every 30 s when app usage history wants it.
        let now = ProcessInfo.processInfo.systemUptime
        let usageDue = plan.appUsage && lastProcessSample.map { now - $0 >= Self.appUsageInterval - 0.5 } ?? true
        if !plan.detail.isEmpty || usageDue {
            frame.processes = processes.sample(includeOtherUsers: true, network: plan.detail.contains(.network) ? nettop.rates : [:])
            // The probe's rates are averages since its previous sample, so this is the span they cover.
            frame.processInterval = lastProcessSample.map { now - $0 }
            lastProcessSample = now
        }
        deliver(frame)
    }
}
