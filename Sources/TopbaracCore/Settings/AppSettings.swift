import Foundation

public enum PanelStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case numbers, sparkline, bars, ring, meter
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .numbers: "Numbers"
        case .sparkline: "Sparkline"
        case .bars: "Bars"
        case .ring: "Ring"
        case .meter: "Level meter"
        }
    }
}

/// What a widget shows in the menu bar. Each widget accepts a subset (`WidgetKind.panelMetrics`).
public enum PanelMetric: String, Codable, CaseIterable, Sendable, Identifiable {
    // CPU
    case cpuUsage, cpuPower
    // Memory
    case memoryPercent, memoryUsed, memoryPressure
    // Disk
    case diskUsed, diskBusy, diskSpeed
    // Temperature
    case tempCPU, tempGPU, tempSSD, tempHottest, fanSpeed
    // GPU
    case gpuUsage, gpuMemory, gpuPower
    // Network
    case netBoth, netDown, netUp
    // Battery
    case batteryPercent, batteryWatts, batteryTime

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpuUsage: "Usage"
        case .cpuPower: "Power draw"
        case .memoryPercent: "Percent used"
        case .memoryUsed: "Amount used"
        case .memoryPressure: "Memory pressure"
        case .diskUsed: "Space used"
        case .diskBusy: "Busy time"
        case .diskSpeed: "Read/write speed"
        case .tempCPU: "CPU"
        case .tempGPU: "GPU"
        case .tempSSD: "SSD"
        case .tempHottest: "Hottest sensor"
        case .fanSpeed: "Fan speed"
        case .gpuUsage: "Usage"
        case .gpuMemory: "Memory in use"
        case .gpuPower: "Power draw"
        case .netBoth: "Download and upload"
        case .netDown: "Download"
        case .netUp: "Upload"
        case .batteryPercent: "Charge"
        case .batteryWatts: "Power in/out"
        case .batteryTime: "Time remaining"
        }
    }
}

public extension WidgetKind {
    var panelMetrics: [PanelMetric] {
        switch self {
        case .cpu: [.cpuUsage, .cpuPower]
        case .memory: [.memoryPercent, .memoryUsed, .memoryPressure]
        case .disk: [.diskUsed, .diskBusy, .diskSpeed]
        case .temperature: [.tempCPU, .tempGPU, .tempSSD, .tempHottest, .fanSpeed]
        case .gpu: [.gpuUsage, .gpuMemory, .gpuPower]
        case .network: [.netBoth, .netDown, .netUp]
        case .battery: [.batteryPercent, .batteryWatts, .batteryTime]
        }
    }

    /// Thresholds are in this unit. Battery is inverted: lower is worse.
    var thresholdUnit: String {
        switch self {
        case .temperature: "°C"
        case .network: "MB/s"
        default: "%"
        }
    }

    var thresholdInverted: Bool { self == .battery }

    var thresholdRange: ClosedRange<Double> {
        switch self {
        case .temperature: 40...110
        case .network: 1...1000
        default: 1...100
        }
    }
}

public struct WidgetConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var style: PanelStyle
    public var showValue: Bool
    public var showLabel: Bool
    public var metric: PanelMetric
    public var warning: Double
    public var critical: Double
    public var thresholdsEnabled: Bool

    public init(enabled: Bool, style: PanelStyle, showValue: Bool = true, showLabel: Bool = false, metric: PanelMetric,
                warning: Double, critical: Double, thresholdsEnabled: Bool = true) {
        self.enabled = enabled; self.style = style; self.showValue = showValue; self.showLabel = showLabel
        self.metric = metric; self.warning = warning; self.critical = critical; self.thresholdsEnabled = thresholdsEnabled
    }

    public static func defaults(for kind: WidgetKind) -> WidgetConfig {
        switch kind {
        case .cpu: WidgetConfig(enabled: true, style: .sparkline, metric: .cpuUsage, warning: 70, critical: 90)
        case .memory: WidgetConfig(enabled: true, style: .meter, metric: .memoryPercent, warning: 80, critical: 92)
        case .disk: WidgetConfig(enabled: false, style: .numbers, metric: .diskUsed, warning: 85, critical: 95)
        case .temperature: WidgetConfig(enabled: true, style: .numbers, metric: .tempHottest, warning: 80, critical: 95)
        case .gpu: WidgetConfig(enabled: false, style: .bars, metric: .gpuUsage, warning: 75, critical: 92)
        case .network: WidgetConfig(enabled: true, style: .numbers, metric: .netBoth, warning: 50, critical: 100, thresholdsEnabled: false)
        case .battery: WidgetConfig(enabled: false, style: .numbers, metric: .batteryPercent, warning: 20, critical: 10)
        }
    }
}

public enum TemperatureUnit: String, Codable, CaseIterable, Sendable { case celsius, fahrenheit }
public enum NetworkUnit: String, Codable, CaseIterable, Sendable { case bytes, bits }

public enum HistoryRetention: String, Codable, CaseIterable, Sendable, Identifiable {
    case week, month, year, forever
    public var id: String { rawValue }
    public var title: String {
        switch self { case .week: "7 days"; case .month: "30 days"; case .year: "1 year"; case .forever: "Forever" }
    }
    public var seconds: TimeInterval? {
        switch self { case .week: 7 * 86400; case .month: 30 * 86400; case .year: 365 * 86400; case .forever: nil }
    }
}

public struct AppSettings: Codable, Sendable, Equatable {
    public var widgets: [WidgetKind: WidgetConfig]
    /// Order used in merged mode and in the settings sidebar.
    public var order: [WidgetKind]
    public var refreshInterval: Double = 1
    public var temperatureUnit: TemperatureUnit = .celsius
    public var networkUnit: NetworkUnit = .bytes
    public var mergedMode = false
    public var mergedShowsIcons = true
    public var flashOnCritical = true
    public var historyEnabled = false
    public var historyRetention: HistoryRetention = .forever
    public var alertRules: [AlertRule] = AlertRule.defaults
    public var alertsEnabled = true
    public var protectSystemProcesses = true

    public init() {
        widgets = Dictionary(uniqueKeysWithValues: WidgetKind.allCases.map { ($0, WidgetConfig.defaults(for: $0)) })
        order = WidgetKind.allCases
    }

    public func config(_ kind: WidgetKind) -> WidgetConfig { widgets[kind] ?? .defaults(for: kind) }

    public var enabledWidgets: [WidgetKind] { order.filter { config($0).enabled } }

    // Decoding tolerates missing keys so older saved settings keep working after an update.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let w = try? c.decode([String: WidgetConfig].self, forKey: .widgets) {
            for (k, v) in w { if let kind = WidgetKind(rawValue: k) { widgets[kind] = v } }
        }
        if let o = try? c.decode([WidgetKind].self, forKey: .order) {
            order = o + WidgetKind.allCases.filter { !o.contains($0) }
        }
        refreshInterval = (try? c.decode(Double.self, forKey: .refreshInterval)) ?? refreshInterval
        temperatureUnit = (try? c.decode(TemperatureUnit.self, forKey: .temperatureUnit)) ?? temperatureUnit
        networkUnit = (try? c.decode(NetworkUnit.self, forKey: .networkUnit)) ?? networkUnit
        mergedMode = (try? c.decode(Bool.self, forKey: .mergedMode)) ?? mergedMode
        mergedShowsIcons = (try? c.decode(Bool.self, forKey: .mergedShowsIcons)) ?? mergedShowsIcons
        flashOnCritical = (try? c.decode(Bool.self, forKey: .flashOnCritical)) ?? flashOnCritical
        historyEnabled = (try? c.decode(Bool.self, forKey: .historyEnabled)) ?? historyEnabled
        historyRetention = (try? c.decode(HistoryRetention.self, forKey: .historyRetention)) ?? historyRetention
        alertRules = (try? c.decode([AlertRule].self, forKey: .alertRules)) ?? alertRules
        alertsEnabled = (try? c.decode(Bool.self, forKey: .alertsEnabled)) ?? alertsEnabled
        protectSystemProcesses = (try? c.decode(Bool.self, forKey: .protectSystemProcesses)) ?? protectSystemProcesses
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Dictionary(uniqueKeysWithValues: widgets.map { ($0.key.rawValue, $0.value) }), forKey: .widgets)
        try c.encode(order, forKey: .order)
        try c.encode(refreshInterval, forKey: .refreshInterval)
        try c.encode(temperatureUnit, forKey: .temperatureUnit)
        try c.encode(networkUnit, forKey: .networkUnit)
        try c.encode(mergedMode, forKey: .mergedMode)
        try c.encode(mergedShowsIcons, forKey: .mergedShowsIcons)
        try c.encode(flashOnCritical, forKey: .flashOnCritical)
        try c.encode(historyEnabled, forKey: .historyEnabled)
        try c.encode(historyRetention, forKey: .historyRetention)
        try c.encode(alertRules, forKey: .alertRules)
        try c.encode(alertsEnabled, forKey: .alertsEnabled)
        try c.encode(protectSystemProcesses, forKey: .protectSystemProcesses)
    }

    private enum CodingKeys: String, CodingKey {
        case widgets, order, refreshInterval, temperatureUnit, networkUnit, mergedMode, mergedShowsIcons, flashOnCritical
        case historyEnabled, historyRetention, alertRules, alertsEnabled, protectSystemProcesses
    }
}
