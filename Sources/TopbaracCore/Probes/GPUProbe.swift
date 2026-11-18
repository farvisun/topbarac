import Foundation
import IOKit

/// GPU utilization and memory from the `IOAccelerator` registry entry's PerformanceStatistics. Works for Apple GPUs
/// and AMD GPUs in Intel Macs alike.
final class GPUProbe {
    private var name: String?

    func sample() -> GPUSnapshot {
        var s = GPUSnapshot()
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return s }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["PerformanceStatistics"] as? [String: Any] else { continue }
            func num(_ key: String) -> Double? { (stats[key] as? NSNumber)?.doubleValue }
            guard let utilization = num("Device Utilization %") ?? num("GPU Activity(%)") else { continue }
            s.available = true
            s.utilization = min(1, max(0, utilization / 100))
            s.renderer = (num("Renderer Utilization %") ?? 0) / 100
            s.tiler = (num("Tiler Utilization %") ?? 0) / 100
            s.memoryUsed = UInt64(num("In use system memory") ?? num("vramUsedBytes") ?? 0)
            s.memoryAllocated = UInt64(num("Alloc system memory") ?? num("vramFreeBytes").map { $0 + Double(s.memoryUsed) } ?? 0)
            if name == nil {
                name = (dict["model"] as? String) ?? (dict["model"] as? Data).flatMap { String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) }
                    ?? Sysctl.string("machdep.cpu.brand_string")
            }
            s.name = name ?? "GPU"
            break
        }
        return s
    }
}
