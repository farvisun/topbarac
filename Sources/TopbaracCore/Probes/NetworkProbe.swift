import Darwin
import Foundation
import SystemConfiguration

public struct InterfaceCounters: Sendable, Equatable {
    public var bytesIn: UInt64, bytesOut: UInt64
    public init(bytesIn: UInt64, bytesOut: UInt64) { self.bytesIn = bytesIn; self.bytesOut = bytesOut }
}

public enum NetworkMath {
    /// Per-interface byte deltas. A counter that went backwards (interface reset) yields nil for that interface.
    public static func deltas(previous: [String: InterfaceCounters], current: [String: InterfaceCounters])
        -> [String: (inBytes: UInt64, outBytes: UInt64)?] {
        var out: [String: (inBytes: UInt64, outBytes: UInt64)?] = [:]
        for (name, b) in current {
            guard let a = previous[name] else { out[name] = (0, 0); continue }
            if b.bytesIn < a.bytesIn || b.bytesOut < a.bytesOut { out[name] = .some(nil); continue }
            out[name] = (b.bytesIn - a.bytesIn, b.bytesOut - a.bytesOut)
        }
        return out
    }

    /// Interfaces counted in the total: physical links and cellular. Tunnels (VPN) carry traffic that also crosses a
    /// physical link, so counting them would double the total.
    public static func isVirtual(_ name: String) -> Bool {
        ["lo", "utun", "ipsec", "gif", "stf", "awdl", "llw", "anpi", "ap", "bridge", "vmenet", "feth"].contains { name.hasPrefix($0) }
    }
}

/// 64-bit per-interface counters from `sysctl(NET_RT_IFLIST2)`; `getifaddrs` only has 32-bit counters that wrap at 4 GB.
final class NetworkProbe {
    private var previous: [String: InterfaceCounters]?
    private var previousTime: TimeInterval = 0
    private var session: [String: InterfaceCounters] = [:]
    private var displayNames: [String: String] = [:]
    private var lastNameRefresh: TimeInterval = -.infinity

    func reset() { previous = nil }

    func sample() -> NetworkSnapshot? {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastNameRefresh > 60 { displayNames = Self.readDisplayNames(); lastNameRefresh = now }
        let current = Self.readCounters()
        defer { previous = current; previousTime = now }
        guard let previous else { return nil }
        let dt = now - previousTime
        guard dt > 0 else { return nil }
        var s = NetworkSnapshot()
        var rates: [InterfaceRate] = []
        for (name, delta) in NetworkMath.deltas(previous: previous, current: current) {
            guard let delta else { continue }
            var acc = session[name] ?? InterfaceCounters(bytesIn: 0, bytesOut: 0)
            acc.bytesIn += delta.inBytes
            acc.bytesOut += delta.outBytes
            session[name] = acc
            let virtual = NetworkMath.isVirtual(name)
            let rate = InterfaceRate(bsdName: name, displayName: displayNames[name] ?? Self.fallbackName(name),
                                     downBps: Double(delta.inBytes) / dt, upBps: Double(delta.outBytes) / dt,
                                     sessionIn: acc.bytesIn, sessionOut: acc.bytesOut, isVirtual: virtual)
            if !virtual {
                s.downBps += rate.downBps
                s.upBps += rate.upBps
                s.sessionIn += acc.bytesIn
                s.sessionOut += acc.bytesOut
            }
            if acc.bytesIn + acc.bytesOut > 0 && !name.hasPrefix("lo") { rates.append(rate) }
        }
        s.interfaces = rates.sorted { a, b in
            if a.isVirtual != b.isVirtual { return !a.isVirtual }
            return a.sessionIn + a.sessionOut > b.sessionIn + b.sessionOut
        }
        return s
    }

    private static func fallbackName(_ bsd: String) -> String {
        if bsd.hasPrefix("utun") || bsd.hasPrefix("ipsec") { return "VPN (\(bsd))" }
        if bsd.hasPrefix("pdp_ip") { return "Cellular (\(bsd))" }
        if bsd.hasPrefix("bridge") { return "Bridge (\(bsd))" }
        return bsd
    }

    static func readDisplayNames() -> [String: String] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var out: [String: String] = [:]
        for i in all {
            if let bsd = SCNetworkInterfaceGetBSDName(i) as String?, let name = SCNetworkInterfaceGetLocalizedDisplayName(i) as String? {
                out[bsd] = name
            }
        }
        return out
    }

    static func readCounters() -> [String: InterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [:] }
        var out: [String: InterfaceCounters] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if header.ifm_type == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let m = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(m.ifm_index), &nameBuffer) != nil {
                        let name = String(cBuffer: nameBuffer)
                        out[name] = InterfaceCounters(bytesIn: m.ifm_data.ifi_ibytes, bytesOut: m.ifm_data.ifi_obytes)
                    }
                }
                offset += messageLength
            }
        }
        return out
    }
}
