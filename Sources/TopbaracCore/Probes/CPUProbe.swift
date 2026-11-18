import Darwin
import Foundation

public struct CoreTicks: Sendable, Equatable {
    public var user: UInt64, system: UInt64, idle: UInt64, nice: UInt64
    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user; self.system = system; self.idle = idle; self.nice = nice
    }
}

public enum CPUMath {
    /// Busy fraction per core between two tick samples. Returns nil when the core count changed or a counter went
    /// backwards (the caller treats that as a gap, not a spike).
    public static func usage(previous: [CoreTicks], current: [CoreTicks]) -> (cores: [Double], user: Double, system: Double)? {
        guard previous.count == current.count, !current.isEmpty else { return nil }
        var cores: [Double] = []
        cores.reserveCapacity(current.count)
        var userSum = 0.0, systemSum = 0.0, totalSum = 0.0
        for (a, b) in zip(previous, current) {
            guard b.user >= a.user, b.system >= a.system, b.idle >= a.idle, b.nice >= a.nice else { return nil }
            let user = Double(b.user - a.user + b.nice - a.nice)
            let system = Double(b.system - a.system)
            let idle = Double(b.idle - a.idle)
            let total = user + system + idle
            cores.append(total > 0 ? (user + system) / total : 0)
            userSum += user; systemSum += system; totalSum += total
        }
        guard totalSum > 0 else { return (cores, 0, 0) }
        return (cores, userSum / totalSum, systemSum / totalSum)
    }
}

/// Per-core load from `host_processor_info`, P/E layout from `hw.perflevel*`, load average and uptime.
final class CPUProbe {
    private var previous: [CoreTicks]?
    let coreKinds: [CoreKind]

    init() {
        // perflevel0 is the performance cluster. CPU numbering puts efficiency cores first on Apple Silicon.
        let p = Sysctl.int("hw.perflevel0.logicalcpu") ?? 0
        let e = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0
        let total = Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        if p > 0, e > 0, p + e == total {
            coreKinds = Array(repeating: .efficiency, count: e) + Array(repeating: .performance, count: p)
        } else {
            coreKinds = Array(repeating: .unknown, count: total)
        }
    }

    /// Resets the delta base, used after sleep so the first sample after wake isn't averaged across the sleep.
    func reset() { previous = nil }

    func sample() -> CPUSnapshot? {
        guard let ticks = Self.readTicks() else { return nil }
        defer { previous = ticks }
        guard let previous, let result = CPUMath.usage(previous: previous, current: ticks) else { return nil }
        var s = CPUSnapshot()
        s.perCore = result.cores
        s.user = result.user
        s.system = result.system
        s.usage = result.user + result.system
        s.coreKinds = coreKinds.count == result.cores.count ? coreKinds : Array(repeating: .unknown, count: result.cores.count)
        let pCores = zip(s.perCore, s.coreKinds).filter { $0.1 == .performance }.map(\.0)
        let eCores = zip(s.perCore, s.coreKinds).filter { $0.1 == .efficiency }.map(\.0)
        if !pCores.isEmpty { s.pClusterUsage = pCores.reduce(0, +) / Double(pCores.count) }
        if !eCores.isEmpty { s.eClusterUsage = eCores.reduce(0, +) / Double(eCores.count) }
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { s.load = (load[0], load[1], load[2]) }
        s.uptime = Sysctl.uptime()
        return s
    }

    static func readTicks() -> [CoreTicks]? {
        var count: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &count) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(count) * MemoryLayout<integer_t>.stride)) }
        return (0..<Int(cpus)).map { i in
            let base = Int(CPU_STATE_MAX) * i
            return CoreTicks(
                user: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])),
                system: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])),
                idle: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])),
                nice: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            )
        }
    }
}

enum Sysctl {
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        // 32-bit sysctls only fill the low half.
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cBuffer: buffer)
    }

    static func uptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0 else { return ProcessInfo.processInfo.systemUptime }
        return Date().timeIntervalSince1970 - (Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000)
    }
}

public enum SystemInfo {
    public static let chipName: String = Sysctl.string("machdep.cpu.brand_string") ?? "Processor"
    public static let modelIdentifier: String = Sysctl.string("hw.model") ?? "Mac"
    public static let performanceCores: Int = Sysctl.int("hw.perflevel0.logicalcpu") ?? 0
    public static let efficiencyCores: Int = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0
}
