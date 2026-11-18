import Foundation
import IOKit

public struct BlockCounters: Sendable, Equatable {
    public var bytesRead: UInt64, bytesWritten: UInt64, timeRead: UInt64, timeWritten: UInt64   // times in ns
    public init(bytesRead: UInt64, bytesWritten: UInt64, timeRead: UInt64, timeWritten: UInt64) {
        self.bytesRead = bytesRead; self.bytesWritten = bytesWritten; self.timeRead = timeRead; self.timeWritten = timeWritten
    }
}

public enum DiskMath {
    /// Read/write bytes per second and busy fraction of the busiest disk between two samples.
    /// Disks that vanished or whose counters went backwards (reset) are skipped.
    public static func rates(previous: [String: BlockCounters], current: [String: BlockCounters], seconds: Double)
        -> (read: Double, write: Double, busy: Double, busiest: String?) {
        guard seconds > 0 else { return (0, 0, 0, nil) }
        var read = 0.0, write = 0.0, busy = 0.0
        var busiest: String?
        for (name, b) in current {
            guard let a = previous[name], b.bytesRead >= a.bytesRead, b.bytesWritten >= a.bytesWritten,
                  b.timeRead >= a.timeRead, b.timeWritten >= a.timeWritten else { continue }
            read += Double(b.bytesRead - a.bytesRead) / seconds
            write += Double(b.bytesWritten - a.bytesWritten) / seconds
            let busyFraction = min(1, Double((b.timeRead - a.timeRead) + (b.timeWritten - a.timeWritten)) / 1e9 / seconds)
            if busyFraction >= busy { busy = busyFraction; busiest = name }
        }
        return (read, write, busy, busiest)
    }
}

/// Volume capacities (slow, an XPC round trip per volume, refreshed every few seconds) and whole-disk I/O counters
/// from `IOBlockStorageDriver` (cheap, every tick). Partitions are not counted twice because the driver sits on the
/// whole disk.
final class DiskProbe {
    private var previous: [String: BlockCounters]?
    private var previousTime: TimeInterval = 0
    private var volumes: [VolumeInfo] = []
    private var lastVolumeRefresh: TimeInterval = -.infinity

    func reset() { previous = nil }

    func sample(volumeRefreshInterval: TimeInterval = 10) -> DiskSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastVolumeRefresh >= volumeRefreshInterval {
            volumes = Self.readVolumes()
            lastVolumeRefresh = now
        }
        var s = DiskSnapshot()
        s.volumes = volumes
        let counters = Self.readCounters()
        if let previous {
            let r = DiskMath.rates(previous: previous, current: counters, seconds: now - previousTime)
            s.readBps = r.read; s.writeBps = r.write; s.busy = r.busy; s.busiestDevice = r.busiest
        }
        previous = counters
        previousTime = now
        return s
    }

    /// Forces the next sample to re-read volume capacities (after mount, unmount or emptying Trash).
    func invalidateVolumes() { lastVolumeRefresh = -.infinity }

    static func readVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey,
                                      .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsBrowsableKey,
                                      .volumeIsRootFileSystemKey, .volumeIsLocalKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else { return [] }
        var out: [VolumeInfo] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable ?? true,
                  let total = v.volumeTotalCapacity, total > 0 else { continue }
            let path = url.path
            // Skip disk images of system components, simulator runtimes and similar noise.
            if path.hasPrefix("/System/Volumes/") || path.hasPrefix("/Library/Developer/CoreSimulator") { continue }
            let strict = UInt64(max(0, v.volumeAvailableCapacity ?? 0))
            let important = UInt64(max(0, v.volumeAvailableCapacityForImportantUsage ?? Int64(strict)))
            out.append(VolumeInfo(
                name: v.volumeName ?? url.lastPathComponent, path: path, total: UInt64(total),
                available: max(important, strict), freeStrict: strict,
                isInternal: v.volumeIsInternal ?? false,
                isEjectable: (v.volumeIsEjectable ?? false) || (v.volumeIsRemovable ?? false) || !(v.volumeIsInternal ?? true),
                isRoot: v.volumeIsRootFileSystem ?? (path == "/")
            ))
        }
        // Root first, then internal, then by name.
        return out.sorted { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            if a.isInternal != b.isInternal { return a.isInternal }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }.filter { !($0.isEjectable && $0.path == "/") }
    }

    static func readCounters() -> [String: BlockCounters] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var out: [String: BlockCounters] = [:]
        var index = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service); index += 1 }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            func n(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }
            let name = Self.bsdName(below: service) ?? "disk\(index)"
            out[name] = BlockCounters(bytesRead: n("Bytes (Read)"), bytesWritten: n("Bytes (Write)"),
                                      timeRead: n("Total Time (Read)"), timeWritten: n("Total Time (Write)"))
        }
        return out
    }

    private static func bsdName(below driver: io_registry_entry_t) -> String? {
        guard let value = IORegistryEntrySearchCFProperty(driver, kIOServicePlane, "BSD Name" as CFString, kCFAllocatorDefault,
                                                          IOOptionBits(kIORegistryIterateRecursively)) else { return nil }
        return value as? String
    }
}
