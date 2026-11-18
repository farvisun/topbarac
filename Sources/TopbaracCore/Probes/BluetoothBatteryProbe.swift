import Foundation
import IOKit

/// Battery level of a connected Bluetooth accessory.
public struct BluetoothBattery: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var kind: Kind
    public var levels: [Level]

    public enum Kind: String, Sendable { case mouse, keyboard, trackpad, headphones, controller, other }

    public struct Level: Sendable, Equatable {
        /// nil for a single battery, otherwise "Left", "Right" or "Case" (AirPods and similar).
        public var label: String?
        public var fraction: Double       // 0...1
        public init(label: String?, fraction: Double) { self.label = label; self.fraction = fraction }
    }

    public init(id: String, name: String, kind: Kind, levels: [Level]) {
        self.id = id; self.name = name; self.kind = kind; self.levels = levels
    }

    /// The lowest level, the one worth warning about.
    public var lowest: Double? { levels.map(\.fraction).min() }
}

/// Two sources, because neither sees everything:
/// - the IORegistry (`BatteryPercent` on the HID service) covers Magic Mouse, Keyboard and Trackpad cheaply;
/// - `system_profiler SPBluetoothDataType` is the only public place AirPods and other headphones report their
///   left, right and case levels. It is slow (up to seconds), so call `read()` at most once a minute, off the main
///   thread.
public enum BluetoothBatteryProbe {
    public static func read() -> [BluetoothBattery] {
        let registry = readRegistry()
        var profiler: [BluetoothBattery] = []
        if let output = Shell.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 8) {
            profiler = parseSystemProfiler(Data(output.utf8))
        }
        return merge(registry: registry, profiler: profiler)
    }

    /// Registry entries win (fresher, and their names are the product names); profiler entries fill in the rest.
    /// Matched by Bluetooth address when both have one, otherwise by name.
    static func merge(registry: [BluetoothBattery], profiler: [BluetoothBattery]) -> [BluetoothBattery] {
        var out = registry
        let ids = Set(registry.map(\.id))
        let names = Set(registry.map { $0.name.lowercased() })
        for device in profiler where !ids.contains(device.id) && !names.contains(device.name.lowercased()) {
            out.append(device)
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - IORegistry

    static func readRegistry() -> [BluetoothBattery] {
        var out: [BluetoothBattery] = []
        var seen = Set<String>()
        // Apple Silicon publishes the level on AppleDeviceManagementHIDEventService, Intel Macs on the HID device.
        for className in ["AppleDeviceManagementHIDEventService", "IOHIDDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let entry = IOIteratorNext(iterator), entry != 0 {
                defer { IOObjectRelease(entry) }
                guard let percent = property(entry, "BatteryPercent") as? NSNumber,
                      let name = (property(entry, "Product") as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty
                else { continue }
                let address = (property(entry, "DeviceAddress") as? String).flatMap(normalizedAddress)
                let id = address ?? name
                guard seen.insert(id).inserted else { continue }
                let fraction = max(0, min(1, percent.doubleValue / 100))
                out.append(BluetoothBattery(id: id, name: name, kind: kind(name: name, minorType: nil),
                                            levels: [.init(label: nil, fraction: fraction)]))
            }
        }
        return out
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    // MARK: - system_profiler

    /// Parses `system_profiler SPBluetoothDataType -json`. Only devices under `device_connected` count: the
    /// "not connected" list keeps the last level a device ever reported, which would be stale.
    public static func parseSystemProfiler(_ json: Data) -> [BluetoothBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var out: [BluetoothBattery] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    let levels: [BluetoothBattery.Level] = [
                        ("device_batteryLevelMain", nil), ("device_batteryLevel", nil),
                        ("device_batteryLevelLeft", "Left"), ("device_batteryLevelRight", "Right"),
                        ("device_batteryLevelCase", "Case"),
                    ].compactMap { key, label in
                        (info[key] as? String).flatMap(percent).map { BluetoothBattery.Level(label: label, fraction: $0) }
                    }
                    guard !levels.isEmpty else { continue }
                    let address = (info["device_address"] as? String).flatMap(normalizedAddress)
                    out.append(BluetoothBattery(id: address ?? name, name: name,
                                                kind: kind(name: name, minorType: info["device_minorType"] as? String),
                                                levels: levels))
                }
            }
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "85%" or "85 %" → 0.85.
    static func percent(_ text: String) -> Double? {
        let digits = text.filter { $0.isNumber || $0 == "." }
        guard let value = Double(digits), value >= 0, value <= 100 else { return nil }
        return value / 100
    }

    /// "AA:BB:CC:DD:EE:FF" and "aa-bb-cc-dd-ee-ff" both become "aa:bb:cc:dd:ee:ff".
    static func normalizedAddress(_ text: String) -> String? {
        let hex = text.lowercased().filter(\.isHexDigit)
        guard hex.count == 12 else { return nil }
        return stride(from: 0, to: 12, by: 2).map { i in
            String(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 2)])
        }.joined(separator: ":")
    }

    static func kind(name: String, minorType: String?) -> BluetoothBattery.Kind {
        let type = minorType?.lowercased() ?? ""
        let lower = name.lowercased()
        if type.contains("mouse") || lower.contains("mouse") { return .mouse }
        if type.contains("trackpad") || lower.contains("trackpad") { return .trackpad }
        if type.contains("keyboard") || lower.contains("keyboard") { return .keyboard }
        if type.contains("headphone") || type.contains("headset") || type.contains("earbud")
            || lower.contains("airpods") || lower.contains("beats") || lower.contains("buds") { return .headphones }
        if type.contains("gamepad") || type.contains("joystick") || type.contains("controller")
            || lower.contains("controller") { return .controller }
        return .other
    }
}
