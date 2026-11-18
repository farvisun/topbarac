import Foundation

/// Compact, fixed-width-friendly formatting for the menu bar and popovers.
public enum Format {
    public static func percent(_ fraction: Double, decimals: Int = 0) -> String {
        let v = max(0, fraction * 100)
        return decimals == 0 ? "\(Int(v.rounded()))%" : String(format: "%.\(decimals)f%%", v)
    }

    /// 1.2 GB, 512 MB, 980 KB. Decimal units (like Finder).
    public static func bytes(_ value: Double, decimals: Int? = nil) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = max(0, value)
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        let d = decimals ?? (i == 0 ? 0 : (v < 10 ? 1 : 0))
        return String(format: "%.\(d)f %@", v, units[i])
    }

    public static func bytes(_ value: UInt64, decimals: Int? = nil) -> String { bytes(Double(value), decimals: decimals) }

    /// Memory sizes use binary units like Activity Monitor (16 GB = 16 GiB).
    public static func memory(_ value: UInt64) -> String {
        let gib = Double(value) / 1_073_741_824
        if gib >= 1 { return String(format: gib < 10 ? "%.2f GB" : "%.1f GB", gib) }
        return String(format: "%.0f MB", Double(value) / 1_048_576)
    }

    /// Network or disk rate. `bits` shows Mb/s instead of MB/s.
    public static func rate(_ bytesPerSecond: Double, bits: Bool = false, compact: Bool = false) -> String {
        let units = bits ? ["b", "Kb", "Mb", "Gb", "Tb"] : ["B", "KB", "MB", "GB", "TB"]
        var v = max(0, bytesPerSecond) * (bits ? 8 : 1)
        var i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        let number = v < 10 && i > 0 ? String(format: "%.1f", v) : String(format: "%.0f", v)
        return compact ? "\(number)\(units[i])" : "\(number) \(units[i])/s"
    }

    public static func temperature(_ celsius: Double, fahrenheit: Bool, decimals: Int = 0) -> String {
        let v = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return String(format: "%.\(decimals)f°", v)
    }

    public static func temperatureUnitValue(_ celsius: Double, fahrenheit: Bool) -> Double {
        fahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    public static func watts(_ w: Double) -> String {
        abs(w) < 10 ? String(format: "%.1f W", w) : String(format: "%.0f W", w)
    }

    public static func mhz(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.2f GHz", v / 1000) : String(format: "%.0f MHz", v)
    }

    /// 1:36, 12:05.
    public static func minutes(_ m: Int) -> String { String(format: "%d:%02d", m / 60, m % 60) }

    /// 3d 4h, 5h 12m, 7m.
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

extension String {
    /// String from a NUL-terminated C buffer.
    init(cBuffer buffer: [CChar]) {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        self = String(decoding: bytes, as: UTF8.self)
    }
}
