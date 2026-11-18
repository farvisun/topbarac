import Foundation

public enum AlertMetric: String, Codable, CaseIterable, Sendable, Identifiable {
    case cpuUsage, memoryUsage, memoryPressure, diskFree, temperature, gpuUsage, batteryLevel, networkDown
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpuUsage: "CPU usage"
        case .memoryUsage: "Memory used"
        case .memoryPressure: "Memory pressure"
        case .diskFree: "Free space on startup disk"
        case .temperature: "Hottest temperature"
        case .gpuUsage: "GPU usage"
        case .batteryLevel: "Battery charge"
        case .networkDown: "Download speed"
        }
    }

    public var unit: String {
        switch self {
        case .cpuUsage, .memoryUsage, .gpuUsage, .batteryLevel: "%"
        case .memoryPressure: ""
        case .diskFree: "GB"
        case .temperature: "°C"
        case .networkDown: "MB/s"
        }
    }

    public var widget: WidgetKind {
        switch self {
        case .cpuUsage: .cpu
        case .memoryUsage, .memoryPressure: .memory
        case .diskFree: .disk
        case .temperature: .temperature
        case .gpuUsage: .gpu
        case .batteryLevel: .battery
        case .networkDown: .network
        }
    }

    /// Current value from a frame, in the metric's unit. Memory pressure: 0 normal, 1 warning, 2 critical.
    public func value(in frame: SampleFrame) -> Double? {
        switch self {
        case .cpuUsage: frame.cpu.map { $0.usage * 100 }
        case .memoryUsage: frame.memory.map { $0.usage * 100 }
        case .memoryPressure: frame.memory.map { m in m.pressure == .critical ? 2 : (m.pressure == .warning ? 1 : 0) }
        case .diskFree: frame.disk?.root.map { Double($0.available) / 1e9 }
        case .temperature: frame.temperature?.hottest
        case .gpuUsage: frame.gpu.flatMap { $0.available ? $0.utilization * 100 : nil }
        case .batteryLevel: frame.battery.flatMap { $0.present && !$0.onAC ? $0.percent * 100 : nil }
        case .networkDown: frame.network.map { $0.downBps / 1e6 }
        }
    }
}

public enum Comparison: String, Codable, CaseIterable, Sendable {
    case above, below
    public var symbol: String { self == .above ? ">" : "<" }
    func test(_ value: Double, _ threshold: Double) -> Bool { self == .above ? value > threshold : value < threshold }
}

public struct AlertRule: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var enabled: Bool
    public var metric: AlertMetric
    public var comparison: Comparison
    public var threshold: Double
    public var duration: TimeInterval      // condition must hold this long
    public var cooldown: TimeInterval      // minimum time between two notifications of this rule

    public init(id: UUID = UUID(), enabled: Bool = true, metric: AlertMetric, comparison: Comparison, threshold: Double,
                duration: TimeInterval, cooldown: TimeInterval = 600) {
        self.id = id; self.enabled = enabled; self.metric = metric; self.comparison = comparison
        self.threshold = threshold; self.duration = duration; self.cooldown = cooldown
    }

    public var summary: String {
        if metric == .memoryPressure { return "Memory pressure is critical for \(Int(duration)) s" }
        let t = threshold.rounded() == threshold ? String(Int(threshold)) : String(format: "%.1f", threshold)
        return "\(metric.title) \(comparison.symbol) \(t)\(metric.unit.isEmpty ? "" : " " + metric.unit) for \(Int(duration)) s"
    }

    public static let defaults: [AlertRule] = [
        AlertRule(metric: .cpuUsage, comparison: .above, threshold: 90, duration: 60),
        AlertRule(metric: .memoryPressure, comparison: .above, threshold: 1.5, duration: 30),
        AlertRule(metric: .diskFree, comparison: .below, threshold: 10, duration: 5, cooldown: 3600),
        AlertRule(metric: .temperature, comparison: .above, threshold: 95, duration: 30),
        AlertRule(metric: .batteryLevel, comparison: .below, threshold: 15, duration: 5, cooldown: 1800),
    ]
}

public struct AlertEvent: Sendable, Equatable {
    public var rule: AlertRule
    public var value: Double
    public var time: Date
}

/// Tracks how long each rule's condition has held and decides when to fire. Pure logic: feed it frames, it returns
/// the rules that just fired. The caller turns those into notifications.
public struct AlertEngine: Sendable {
    private var since: [UUID: Date] = [:]
    private var lastFired: [UUID: Date] = [:]
    /// Rules whose condition currently holds (used to flash the menu bar item).
    public private(set) var active: Set<UUID> = []

    public init() {}

    public mutating func evaluate(_ frame: SampleFrame, rules: [AlertRule]) -> [AlertEvent] {
        var fired: [AlertEvent] = []
        let now = frame.time
        var stillActive: Set<UUID> = []
        for rule in rules where rule.enabled {
            guard let value = rule.metric.value(in: frame) else { continue }
            guard rule.comparison.test(value, rule.threshold) else {
                since[rule.id] = nil
                continue
            }
            let start = since[rule.id] ?? now
            since[rule.id] = start
            guard now.timeIntervalSince(start) >= rule.duration else { continue }
            stillActive.insert(rule.id)
            if let last = lastFired[rule.id], now.timeIntervalSince(last) < rule.cooldown { continue }
            lastFired[rule.id] = now
            fired.append(AlertEvent(rule: rule, value: value, time: now))
        }
        active = stillActive
        return fired
    }

    /// After sleep the durations restart; a laptop that slept hot shouldn't alert the moment it wakes.
    public mutating func reset() { since = [:]; active = [] }
}
