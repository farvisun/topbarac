import Foundation

/// The seven widgets. Raw values are stable: they key settings, history series and status item autosave names.
public enum WidgetKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case cpu, memory, disk, temperature, gpu, network, battery
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .temperature: "Temperature"
        case .gpu: "GPU"
        case .network: "Network"
        case .battery: "Battery"
        }
    }

    public var shortLabel: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "MEM"
        case .disk: "SSD"
        case .temperature: "TMP"
        case .gpu: "GPU"
        case .network: "NET"
        case .battery: "BAT"
        }
    }

    public var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .temperature: "thermometer.medium"
        case .gpu: "square.stack.3d.up"
        case .network: "arrow.up.arrow.down"
        case .battery: "battery.75percent"
        }
    }
}

public enum CoreKind: String, Sendable, Codable { case performance, efficiency, unknown }

public struct CPUSnapshot: Sendable, Equatable {
    public var usage: Double = 0          // 0...1
    public var user: Double = 0
    public var system: Double = 0
    public var perCore: [Double] = []
    public var coreKinds: [CoreKind] = []
    public var pClusterUsage: Double?
    public var eClusterUsage: Double?
    public var pFrequencyMHz: Double?
    public var eFrequencyMHz: Double?
    public var powerWatts: Double?
    public var load: (Double, Double, Double) = (0, 0, 0)
    public var uptime: TimeInterval = 0
    public init() {}

    public static func == (a: CPUSnapshot, b: CPUSnapshot) -> Bool {
        a.usage == b.usage && a.perCore == b.perCore && a.pFrequencyMHz == b.pFrequencyMHz
            && a.powerWatts == b.powerWatts && a.load == b.load
    }

    public var busiestCore: (index: Int, usage: Double)? {
        guard let m = perCore.enumerated().max(by: { $0.element < $1.element }) else { return nil }
        return (m.offset, m.element)
    }
}

public enum MemoryPressure: Int, Sendable, Codable, Comparable {
    case normal = 1, warning = 2, critical = 4
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    public var title: String {
        switch self { case .normal: "Normal"; case .warning: "Warning"; case .critical: "Critical" }
    }
}

public struct MemorySnapshot: Sendable, Equatable {
    public var total: UInt64 = 0
    public var app: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressed: UInt64 = 0
    public var cached: UInt64 = 0
    public var free: UInt64 = 0
    public var pressure: MemoryPressure = .normal
    public var swapUsed: UInt64 = 0
    public var swapTotal: UInt64 = 0
    public init() {}

    /// "Memory Used" as Activity Monitor shows it: app + wired + compressed.
    public var used: UInt64 { app + wired + compressed }
    public var usage: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
}

public struct VolumeInfo: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var total: UInt64
    public var available: UInt64          // free for important usage (includes purgeable)
    public var freeStrict: UInt64         // free without purgeable
    public var isInternal: Bool
    public var isEjectable: Bool
    public var isRoot: Bool
    public init(name: String, path: String, total: UInt64, available: UInt64, freeStrict: UInt64,
                isInternal: Bool, isEjectable: Bool, isRoot: Bool) {
        self.name = name; self.path = path; self.total = total; self.available = available
        self.freeStrict = freeStrict; self.isInternal = isInternal; self.isEjectable = isEjectable; self.isRoot = isRoot
    }
    public var used: UInt64 { total > available ? total - available : 0 }
    public var usage: Double { total > 0 ? Double(used) / Double(total) : 0 }
    public var purgeable: UInt64 { available > freeStrict ? available - freeStrict : 0 }
}

public struct DiskSnapshot: Sendable, Equatable {
    public var volumes: [VolumeInfo] = []
    public var readBps: Double = 0
    public var writeBps: Double = 0
    public var busy: Double = 0           // 0...1, busiest whole disk
    public var busiestDevice: String?
    public init() {}
    public var root: VolumeInfo? { volumes.first(where: \.isRoot) ?? volumes.first }
}

public enum SensorGroup: String, Sendable, Codable, CaseIterable {
    case cpu = "CPU", gpu = "GPU", ssd = "SSD", battery = "Battery", soc = "SoC", other = "Other"
}

public struct SensorReading: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var group: SensorGroup
    public var celsius: Double
    public var min: Double
    public var max: Double
    public init(name: String, group: SensorGroup, celsius: Double, min: Double, max: Double) {
        self.name = name; self.group = group; self.celsius = celsius; self.min = min; self.max = max
    }
}

public struct FanReading: Sendable, Equatable, Identifiable {
    public var id: Int
    public var rpm: Double
    public var minRPM: Double
    public var maxRPM: Double
    public init(id: Int, rpm: Double, minRPM: Double, maxRPM: Double) {
        self.id = id; self.rpm = rpm; self.minRPM = minRPM; self.maxRPM = maxRPM
    }
    public var fraction: Double { maxRPM > minRPM ? Swift.max(0, Swift.min(1, (rpm - minRPM) / (maxRPM - minRPM))) : 0 }
}

public struct TemperatureSnapshot: Sendable, Equatable {
    public var sensors: [SensorReading] = []
    public var fans: [FanReading] = []
    public var cpu: Double?
    public var gpu: Double?
    public var ssd: Double?
    public var battery: Double?
    public var thermalState: Int = 0      // ProcessInfo.ThermalState raw value
    public init() {}
    public var hottest: Double? { sensors.map(\.celsius).max() }
    public var hottestSensor: SensorReading? { sensors.max(by: { $0.celsius < $1.celsius }) }
}

public struct GPUSnapshot: Sendable, Equatable {
    public var available = false
    public var name: String = "GPU"
    public var utilization: Double = 0    // 0...1
    public var renderer: Double = 0
    public var tiler: Double = 0
    public var memoryUsed: UInt64 = 0
    public var memoryAllocated: UInt64 = 0
    public var frequencyMHz: Double?
    public var powerWatts: Double?
    public var temperature: Double?
    public init() {}
}

public struct InterfaceRate: Sendable, Equatable, Identifiable {
    public var id: String { bsdName }
    public var bsdName: String
    public var displayName: String
    public var downBps: Double
    public var upBps: Double
    public var sessionIn: UInt64
    public var sessionOut: UInt64
    public var isVirtual: Bool
    public init(bsdName: String, displayName: String, downBps: Double, upBps: Double,
                sessionIn: UInt64, sessionOut: UInt64, isVirtual: Bool) {
        self.bsdName = bsdName; self.displayName = displayName; self.downBps = downBps; self.upBps = upBps
        self.sessionIn = sessionIn; self.sessionOut = sessionOut; self.isVirtual = isVirtual
    }
}

public struct NetworkSnapshot: Sendable, Equatable {
    public var downBps: Double = 0
    public var upBps: Double = 0
    public var sessionIn: UInt64 = 0
    public var sessionOut: UInt64 = 0
    public var interfaces: [InterfaceRate] = []
    public init() {}
}

public struct BatterySnapshot: Sendable, Equatable {
    public var present = false
    public var percent: Double = 0        // 0...1
    public var charging = false
    public var onAC = false
    public var fullyCharged = false
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?
    public var cycleCount: Int?
    public var designCapacity: Int?       // mAh
    public var maxCapacity: Int?          // mAh
    public var health: Double?            // 0...1
    public var temperature: Double?       // °C
    public var voltage: Double?           // V
    public var amperage: Double?          // A, negative while discharging
    public var adapterWatts: Double?
    public var systemPowerWatts: Double?
    public var condition: String?
    public init() {}
    public var batteryWatts: Double? {
        guard let voltage, let amperage else { return nil }
        return voltage * amperage
    }
}

public struct ProcessSample: Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var name: String
    public var path: String?
    public var uid: UInt32
    public var cpu: Double                // percent of one core (100 = one full core)
    public var memory: UInt64
    public var diskReadBps: Double
    public var diskWriteBps: Double
    public var energyWatts: Double?
    public var netInBps: Double = 0
    public var netOutBps: Double = 0
    public var groupCount: Int = 1        // >1 when helper processes are folded into their app
    /// The individual processes folded into this group, busiest first. Empty for single processes and for the
    /// members themselves, so the tree is at most one level deep.
    public var members: [ProcessSample] = []
    public var isOwned: Bool
    public init(pid: Int32, name: String, path: String?, uid: UInt32, cpu: Double, memory: UInt64,
                diskReadBps: Double, diskWriteBps: Double, energyWatts: Double?, isOwned: Bool) {
        self.pid = pid; self.name = name; self.path = path; self.uid = uid; self.cpu = cpu; self.memory = memory
        self.diskReadBps = diskReadBps; self.diskWriteBps = diskWriteBps; self.energyWatts = energyWatts; self.isOwned = isOwned
    }
}

/// Everything one tick produced. Optional members are nil when that widget was not sampled this tick.
public struct SampleFrame: Sendable {
    public var time: Date
    public var gap: Bool
    public var cpu: CPUSnapshot?
    public var memory: MemorySnapshot?
    public var disk: DiskSnapshot?
    public var temperature: TemperatureSnapshot?
    public var gpu: GPUSnapshot?
    public var network: NetworkSnapshot?
    public var battery: BatterySnapshot?
    public var processes: [ProcessSample]?
    public init(time: Date, gap: Bool = false) { self.time = time; self.gap = gap }
}
