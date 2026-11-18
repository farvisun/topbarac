import Foundation
import IOKit

/// CPU/GPU cluster frequency and power on Apple Silicon from IOReport (private `libIOReport`, loaded at runtime),
/// the same source `powermetrics` uses, but without root. Every function is optional: on a Mac or macOS release where
/// a symbol or channel is missing, the matching values stay nil.
final class IOReportProbe {
    struct Reading {
        var cpuPowerW: Double?
        var gpuPowerW: Double?
        var aneDramPowerW: Double?
        var eFrequencyMHz: Double?
        var pFrequencyMHz: Double?
        var gpuFrequencyMHz: Double?
        var gpuActive: Double?
    }

    private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeChannels = @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias SimpleInteger = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidency = @convention(c) (CFDictionary, Int32) -> Int64

    private var createSamples: CreateSamples?
    private var createDelta: CreateSamplesDelta?
    private var getGroup: ChannelString?
    private var getSubGroup: ChannelString?
    private var getName: ChannelString?
    private var getUnit: ChannelString?
    private var simpleInteger: SimpleInteger?
    private var stateCount: StateCount?
    private var stateName: StateName?
    private var stateResidency: StateResidency?

    private var subscription: OpaquePointer?
    private var subscribed: CFMutableDictionary?
    private var previous: (sample: CFDictionary, time: TimeInterval)?

    private let eFreqs: [Double]
    private let pFreqs: [Double]
    private let gpuFreqs: [Double]

    init() {
        let tables = Self.readFrequencyTables()
        eFreqs = tables.e; pFreqs = tables.p; gpuFreqs = tables.gpu
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        func sym<T>(_ name: String, _: T.Type) -> T? { dlsym(h, name).map { unsafeBitCast($0, to: T.self) } }
        guard let copyChannels = sym("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let merge = sym("IOReportMergeChannels", MergeChannels.self),
              let createSubscription = sym("IOReportCreateSubscription", CreateSubscription.self) else { return }
        createSamples = sym("IOReportCreateSamples", CreateSamples.self)
        createDelta = sym("IOReportCreateSamplesDelta", CreateSamplesDelta.self)
        getGroup = sym("IOReportChannelGetGroup", ChannelString.self)
        getSubGroup = sym("IOReportChannelGetSubGroup", ChannelString.self)
        getName = sym("IOReportChannelGetChannelName", ChannelString.self)
        getUnit = sym("IOReportChannelGetUnitLabel", ChannelString.self)
        simpleInteger = sym("IOReportSimpleGetIntegerValue", SimpleInteger.self)
        stateCount = sym("IOReportStateGetCount", StateCount.self)
        stateName = sym("IOReportStateGetNameForIndex", StateName.self)
        stateResidency = sym("IOReportStateGetResidency", StateResidency.self)

        guard let energy = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return }
        if let cpu = copyChannels("CPU Stats" as CFString, "CPU Complex Performance States" as CFString, 0, 0, 0)?.takeRetainedValue() {
            merge(energy, cpu, nil)
        }
        if let gpu = copyChannels("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0)?.takeRetainedValue() {
            merge(energy, gpu, nil)
        }
        var subbed: Unmanaged<CFMutableDictionary>?
        subscription = createSubscription(nil, energy, &subbed, 0, nil)
        subscribed = subbed?.takeRetainedValue()
    }

    var isAvailable: Bool { subscription != nil && subscribed != nil && createSamples != nil }

    func reset() { previous = nil }

    func sample() -> Reading? {
        guard let subscription, let subscribed, let createSamples, let createDelta,
              let current = createSamples(subscription, subscribed, nil)?.takeRetainedValue() else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        defer { previous = (current, now) }
        // After a pause (popover closed) the delta would average minutes; start over instead.
        guard let previous, now - previous.time > 0.05, now - previous.time < 10,
              let delta = createDelta(previous.sample, current, nil)?.takeRetainedValue(),
              let channels = (delta as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return nil }
        let dt = now - previous.time
        var r = Reading()
        var other = 0.0
        for channel in channels {
            let group = getGroup?(channel)?.takeUnretainedValue() as String? ?? ""
            let name = getName?(channel)?.takeUnretainedValue() as String? ?? ""
            if group == "Energy Model" {
                guard let simpleInteger else { continue }
                let unit = getUnit?(channel)?.takeUnretainedValue() as String? ?? ""
                let joules = Self.joules(Double(simpleInteger(channel, 0)), unit: unit)
                let watts = joules / dt
                // Some macOS releases zero the CPU channels for non-root readers; a real CPU never draws 0 W, so
                // treat 0 as "not available" and hide the value.
                if name == "CPU Energy" { if watts > 0 { r.cpuPowerW = watts } }
                else if name == "GPU Energy" { r.gpuPowerW = watts }
                else if name.hasPrefix("ANE") || name.hasPrefix("DRAM") { other += watts }
            } else if group == "CPU Stats" {
                let residencies = states(channel)
                if name.hasPrefix("ECPU"), let f = Self.averageFrequency(residencies, table: eFreqs) {
                    r.eFrequencyMHz = max(r.eFrequencyMHz ?? 0, f.mhz)
                } else if name.hasPrefix("PCPU"), let f = Self.averageFrequency(residencies, table: pFreqs) {
                    r.pFrequencyMHz = max(r.pFrequencyMHz ?? 0, f.mhz)
                }
            } else if group == "GPU Stats", name == "GPUPH" {
                if let f = Self.averageFrequency(states(channel), table: Array(gpuFreqs.dropFirst())) {
                    r.gpuFrequencyMHz = f.mhz
                    r.gpuActive = f.active
                }
            }
        }
        if other > 0 { r.aneDramPowerW = other }
        return r
    }

    private func states(_ channel: CFDictionary) -> [(String, Double)] {
        guard let stateCount, let stateName, let stateResidency else { return [] }
        return (0..<stateCount(channel)).map { i in
            (stateName(channel, i)?.takeUnretainedValue() as String? ?? "", Double(stateResidency(channel, i)))
        }
    }

    static func joules(_ value: Double, unit: String) -> Double {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "mJ": value / 1e3
        case "uJ", "µJ": value / 1e6
        case "nJ": value / 1e9
        default: value / 1e3
        }
    }

    /// Residency-weighted average frequency of the active (non-idle) states, plus the active fraction.
    static func averageFrequency(_ states: [(String, Double)], table: [Double]) -> (mhz: Double, active: Double)? {
        guard !table.isEmpty, let offset = states.firstIndex(where: { !["IDLE", "DOWN", "OFF"].contains($0.0) }) else { return nil }
        let total = states.reduce(0) { $0 + $1.1 }
        let active = states[offset...].reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        guard active > 0 else { return (0, 0) }
        var mhz = 0.0
        for i in 0..<table.count where i + offset < states.count {
            mhz += states[i + offset].1 / active * table[i]
        }
        return (mhz, active / total)
    }

    /// DVFS tables from the `pmgr` registry node: pairs of (frequency, voltage) as little-endian UInt32.
    static func readFrequencyTables() -> (e: [Double], p: [Double], gpu: [Double]) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS else { return ([], [], []) }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var nameBuffer = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &nameBuffer) == KERN_SUCCESS, String(cBuffer: nameBuffer) == "pmgr" else { continue }
            func table(_ key: String) -> [Double] {
                guard let data = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data else { return [] }
                let raw: [Double] = stride(from: 0, to: data.count - 7, by: 8).map { i in
                    Double(data[i..<i + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) })
                }
                guard let maxValue = raw.max(), maxValue > 0 else { return [] }
                // Older chips store Hz, newer ones kHz.
                let divisor = maxValue > 1e8 ? 1e6 : (maxValue > 1e5 ? 1e3 : 1)
                return raw.map { $0 / divisor }
            }
            return (table("voltage-states1-sram"), table("voltage-states5-sram"), table("voltage-states9"))
        }
        return ([], [], [])
    }
}
