import Darwin
import Foundation

/// The vm_statistics64 fields the memory math needs, in pages. Split out so tests can feed fixtures.
public struct VMCounts: Sendable, Equatable, Codable {
    public var free: UInt64, active: UInt64, inactive: UInt64, speculative: UInt64, wired: UInt64
    public var compressor: UInt64, purgeable: UInt64, external: UInt64, `internal`: UInt64
    public init(free: UInt64, active: UInt64, inactive: UInt64, speculative: UInt64, wired: UInt64,
                compressor: UInt64, purgeable: UInt64, external: UInt64, internal: UInt64) {
        self.free = free; self.active = active; self.inactive = inactive; self.speculative = speculative
        self.wired = wired; self.compressor = compressor; self.purgeable = purgeable; self.external = external
        self.internal = `internal`
    }
}

public enum MemoryMath {
    /// Activity Monitor's breakdown: App = internal - purgeable, Wired, Compressed = compressor pages,
    /// Cached files = external + purgeable. "Used" = App + Wired + Compressed.
    public static func snapshot(counts c: VMCounts, pageSize: UInt64, total: UInt64) -> MemorySnapshot {
        var s = MemorySnapshot()
        s.total = total
        s.app = (c.internal > c.purgeable ? c.internal - c.purgeable : 0) * pageSize
        s.wired = c.wired * pageSize
        s.compressed = c.compressor * pageSize
        s.cached = (c.external + c.purgeable) * pageSize
        let used = s.app + s.wired + s.compressed + s.cached
        s.free = total > used ? total - used : 0
        return s
    }
}

final class MemoryProbe {
    private let total = ProcessInfo.processInfo.physicalMemory

    func sample() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let counts = VMCounts(
            free: UInt64(stats.free_count), active: UInt64(stats.active_count), inactive: UInt64(stats.inactive_count),
            speculative: UInt64(stats.speculative_count), wired: UInt64(stats.wire_count),
            compressor: UInt64(stats.compressor_page_count), purgeable: UInt64(stats.purgeable_count),
            external: UInt64(stats.external_page_count), internal: UInt64(stats.internal_page_count)
        )
        var s = MemoryMath.snapshot(counts: counts, pageSize: UInt64(getpagesize()), total: total)
        s.pressure = MemoryPressure(rawValue: Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1) ?? .normal
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            s.swapUsed = swap.xsu_used
            s.swapTotal = swap.xsu_total
        }
        return s
    }
}
