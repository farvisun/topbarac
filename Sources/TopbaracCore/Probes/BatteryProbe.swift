import Foundation
import IOKit
import IOKit.ps

/// Charge and time from IOPowerSources; health, cycles, voltage, current and system load from the AppleSmartBattery
/// registry entry.
final class BatteryProbe {
    private var service: io_service_t = 0

    deinit { if service != 0 { IOObjectRelease(service) } }

    func sample() -> BatterySnapshot {
        var s = BatterySnapshot()
        readPowerSources(into: &s)
        readRegistry(into: &s)
        return s
    }

    private func readPowerSources(into s: inout BatterySnapshot) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            s.present = true
            let current = Double(d[kIOPSCurrentCapacityKey] as? Int ?? 0)
            let max = Double(d[kIOPSMaxCapacityKey] as? Int ?? 100)
            s.percent = max > 0 ? min(1, current / max) : 0
            s.charging = d[kIOPSIsChargingKey] as? Bool ?? false
            s.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            s.fullyCharged = d[kIOPSIsChargedKey] as? Bool ?? false
            let empty = d[kIOPSTimeToEmptyKey] as? Int ?? -1
            let full = d[kIOPSTimeToFullChargeKey] as? Int ?? -1
            s.minutesToEmpty = empty > 0 && !s.onAC ? empty : nil
            s.minutesToFull = full > 0 && s.charging ? full : nil
            s.condition = d[kIOPSBatteryHealthKey] as? String
        }
    }

    private func readRegistry(into s: inout BatterySnapshot) {
        if service == 0 { service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("AppleSmartBattery")) }
        guard service != 0 else { return }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return }
        let data = dict["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { (dict[key] as? NSNumber)?.intValue ?? (data[key] as? NSNumber)?.intValue }
        /// Signed values (current) are stored as unsigned 64-bit; reinterpret the bits.
        func signed(_ key: String) -> Int64? {
            guard let n = (dict[key] as? NSNumber) ?? (data[key] as? NSNumber) else { return nil }
            return Int64(bitPattern: n.uint64Value)
        }
        s.cycleCount = int("CycleCount")
        s.designCapacity = int("DesignCapacity")
        s.maxCapacity = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity")
        if let design = s.designCapacity, design > 0, let max = s.maxCapacity {
            s.health = min(1.2, Double(max) / Double(design))
        }
        if let mv = int("Voltage") { s.voltage = Double(mv) / 1000 }
        if let ma = signed("InstantAmperage") ?? signed("Amperage") { s.amperage = Double(ma) / 1000 }
        if let t = int("Temperature") ?? int("VirtualTemperature"), t > 0 { s.temperature = Double(t) / 100 }
        if let adapter = dict["AdapterDetails"] as? [String: Any], let watts = (adapter["Watts"] as? NSNumber)?.doubleValue, watts > 0 {
            s.adapterWatts = watts
        }
        if let telemetry = dict["PowerTelemetryData"] as? [String: Any],
           let load = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue, load > 0 {
            s.systemPowerWatts = load / 1000
        }
    }
}
