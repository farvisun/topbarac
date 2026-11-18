import Foundation

public enum SensorNaming {
    /// Friendly name and group for a raw sensor name (HID "Product" or SMC key). Nil means "don't show".
    public static func classify(_ raw: String) -> (name: String, group: SensorGroup)? {
        let lower = raw.lowercased()
        if lower.contains("tcal") { return nil }
        if let n = suffixNumber(raw, after: "tdie") { return ("CPU die \(n)", .cpu) }
        if let n = suffixNumber(raw, after: "tdev") { return ("SoC sensor \(n)", .soc) }
        if lower.contains("pacc") { return ("P-cluster \(trailingDigits(raw))".trimmed, .cpu) }
        if lower.contains("eacc") { return ("E-cluster \(trailingDigits(raw))".trimmed, .cpu) }
        if lower.contains("gpu") { return (raw.replacingOccurrences(of: " MTR Temp Sensor", with: "").trimmed, .gpu) }
        if lower.contains("nand") { return ("SSD \(trailingDigits(raw.replacingOccurrences(of: " temp", with: "")))".trimmed, .ssd) }
        if lower.contains("battery") || lower.contains("gas gauge") { return ("Battery", .battery) }
        if lower.contains("soc") { return ("SoC", .soc) }
        return (raw, .other)
    }

    private static func suffixNumber(_ s: String, after token: String) -> Int? {
        guard let r = s.range(of: token) else { return nil }
        return Int(s[r.upperBound...].prefix { $0.isNumber })
    }

    private static func trailingDigits(_ s: String) -> String {
        String(s.reversed().prefix { $0.isNumber }.reversed())
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}

/// Temperatures from the HID event system (no root on Apple Silicon), GPU temperatures and fans from the SMC.
/// Keeps per-sensor session minimum and maximum.
final class TemperatureProbe {
    private let hid = HIDTemperature()
    private let smc = SMC()
    private var gpuKeys: [String]?
    private var fanCount: Int?
    private var fanLimits: [Int: (Double, Double)] = [:]
    private var minMax: [String: (Double, Double)] = [:]

    func sample() -> TemperatureSnapshot {
        var s = TemperatureSnapshot()
        var readings: [(String, SensorGroup, Double)] = []
        for (raw, value) in hid.read() {
            guard value > 5, value < 130, let c = SensorNaming.classify(raw) else { continue }
            readings.append((c.name, c.group, value))
        }
        if let smc {
            if gpuKeys == nil { gpuKeys = Self.findGPUKeys(smc) }
            for (i, key) in (gpuKeys ?? []).enumerated() {
                if let v = smc.number(key), v > 5, v < 130 { readings.append(("GPU \(i + 1)", .gpu, v)) }
            }
            s.fans = readFans(smc)
        }
        // Several sensors can share a friendly name ("Battery"); keep the hottest.
        var merged: [String: (SensorGroup, Double)] = [:]
        for (name, group, value) in readings where (merged[name]?.1 ?? -1) < value { merged[name] = (group, value) }
        s.sensors = merged.map { name, entry in
            let old = minMax[name] ?? (entry.1, entry.1)
            let mm = (min(old.0, entry.1), max(old.1, entry.1))
            minMax[name] = mm
            return SensorReading(name: name, group: entry.0, celsius: entry.1, min: mm.0, max: mm.1)
        }.sorted { a, b in
            a.group == b.group ? a.name.localizedStandardCompare(b.name) == .orderedAscending
                : SensorGroup.allCases.firstIndex(of: a.group)! < SensorGroup.allCases.firstIndex(of: b.group)!
        }
        func average(_ g: SensorGroup) -> Double? {
            let v = s.sensors.filter { $0.group == g }.map(\.celsius)
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        s.cpu = average(.cpu)
        s.gpu = s.sensors.filter { $0.group == .gpu }.map(\.celsius).max()
        s.ssd = s.sensors.filter { $0.group == .ssd }.map(\.celsius).max()
        s.battery = s.sensors.first { $0.group == .battery }?.celsius
        s.thermalState = ProcessInfo.processInfo.thermalState.rawValue
        return s
    }

    private func readFans(_ smc: SMC) -> [FanReading] {
        if fanCount == nil { fanCount = Int(smc.number("FNum") ?? 0) }
        return (0..<(fanCount ?? 0)).compactMap { i in
            guard let rpm = smc.number("F\(i)Ac") else { return nil }
            if fanLimits[i] == nil { fanLimits[i] = (smc.number("F\(i)Mn") ?? 0, smc.number("F\(i)Mx") ?? 0) }
            let limits = fanLimits[i]!
            return FanReading(id: i, rpm: max(0, rpm), minRPM: limits.0, maxRPM: limits.1)
        }
    }

    /// GPU die temperature keys differ per chip ("Tg0f", "Tg0j", "Tg1k", ...). Pick every "Tg??" float key with a
    /// plausible value.
    private static func findGPUKeys(_ smc: SMC) -> [String] {
        smc.allKeys().filter { $0.hasPrefix("Tg") }.filter { key in
            guard let v = smc.read(key), v.type == "flt ", let n = v.number else { return false }
            return n > 10 && n < 120
        }.prefix(4).map { $0 }
    }
}

/// `IOHIDEventSystemClient` temperature services (private API, resolved at runtime). Returns raw name → °C.
final class HIDTemperature {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?

    private var copyEvent: CopyEvent?
    private var getFloat: GetFloat?
    private var services: [(name: String, service: AnyObject)] = []
    private var client: AnyObject?

    init() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let c = dlsym(h, "IOHIDEventSystemClientCreate"),
              let m = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let s = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let e = dlsym(h, "IOHIDServiceClientCopyEvent"),
              let f = dlsym(h, "IOHIDEventGetFloatValue"),
              let p = dlsym(h, "IOHIDServiceClientCopyProperty") else { return }
        copyEvent = unsafeBitCast(e, to: CopyEvent.self)
        getFloat = unsafeBitCast(f, to: GetFloat.self)
        let copyProperty = unsafeBitCast(p, to: CopyProperty.self)
        guard let made = unsafeBitCast(c, to: ClientCreate.self)(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        client = made
        _ = unsafeBitCast(m, to: SetMatching.self)(made, ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5] as CFDictionary)
        let list = unsafeBitCast(s, to: CopyServices.self)(made)?.takeRetainedValue() as? [AnyObject] ?? []
        services = list.map { (copyProperty($0, "Product" as CFString)?.takeRetainedValue() as? String ?? "Sensor", $0) }
    }

    func read() -> [(String, Double)] {
        guard let copyEvent, let getFloat else { return [] }
        let type: Int64 = 15   // kIOHIDEventTypeTemperature
        return services.compactMap { entry in
            guard let event = copyEvent(entry.service, type, 0, 0)?.takeRetainedValue() else { return nil }
            return (entry.name, getFloat(event, Int32(type << 16)))
        }
    }
}
