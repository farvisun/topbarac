import Foundation
import IOKit

/// Read-only access to the System Management Controller (fans, extra temperature and power keys).
/// Nothing here writes to the SMC.
final class SMC {
    // Layout of the struct AppleSMC exchanges through selector 2 (kSMCHandleYPCEvent). 80 bytes.
    private struct KeyData {
        struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
        struct LimitData { var version: UInt16 = 0, length: UInt16 = 0, cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }
        var key: UInt32 = 0
        var version = Version()
        var limit = LimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private enum Command: UInt8 { case readBytes = 5, readIndex = 8, readKeyInfo = 9 }

    struct Value {
        var type: String
        var bytes: [UInt8]

        var number: Double? {
            switch type {
            case "flt ": guard bytes.count >= 4 else { return nil }
                return Double(Float(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
            case "fpe2": guard bytes.count >= 2 else { return nil }
                return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
            case "sp78": guard bytes.count >= 2 else { return nil }
                return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
            case "ui8 ": return bytes.first.map(Double.init)
            case "ui16": guard bytes.count >= 2 else { return nil }
                return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            case "ui32": guard bytes.count >= 4 else { return nil }
                return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
            default: return nil
            }
        }
    }

    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: KeyData.KeyInfo] = [:]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    static func fourCC(_ s: String) -> UInt32 { s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
    static func string(_ v: UInt32) -> String {
        String(bytes: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)], encoding: .ascii) ?? "????"
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var outSize = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.stride, &output, &outSize)
        guard result == KERN_SUCCESS, output.result == 0 else { return nil }
        return output
    }

    private func info(_ key: UInt32) -> KeyData.KeyInfo? {
        if let cached = infoCache[key] { return cached }
        var input = KeyData()
        input.key = key
        input.data8 = Command.readKeyInfo.rawValue
        guard let out = call(&input) else { return nil }
        infoCache[key] = out.keyInfo
        return out.keyInfo
    }

    func read(_ name: String) -> Value? { read(key: Self.fourCC(name)) }

    func read(key: UInt32) -> Value? {
        guard let info = info(key), info.dataSize > 0, info.dataSize <= 32 else { return nil }
        var input = KeyData()
        input.key = key
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Command.readBytes.rawValue
        guard let out = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return Value(type: Self.string(info.dataType), bytes: bytes)
    }

    func number(_ name: String) -> Double? { read(name)?.number }

    /// All key names. About two thousand on Apple Silicon; read once and cached by the caller.
    func allKeys() -> [String] {
        guard let count = number("#KEY"), count > 0, count < 10_000 else { return [] }
        var keys: [String] = []
        for i in 0..<Int(count) {
            var input = KeyData()
            input.data8 = Command.readIndex.rawValue
            input.data32 = UInt32(i)
            if let out = call(&input) { keys.append(Self.string(out.key)) }
        }
        return keys
    }
}
