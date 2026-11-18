import Darwin
import Foundation

/// Round-trip time to a host with ICMP echo, without root and without spawning `/sbin/ping`.
/// macOS allows unprivileged ICMP over `SOCK_DGRAM` sockets (the same trick `ping` uses when not setuid); the
/// kernel fills in nothing for us, so the checksum is ours, and replies arrive with their IPv4 header attached.
/// Every datagram ICMP socket sees every echo reply, so replies are matched by identifier and sequence.
public final class LatencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt16 = 0
    private let identifier = UInt16.random(in: 1...UInt16.max)

    public init() {}

    /// The IPv4 address of the default route's gateway (usually the Wi‑Fi or Ethernet router).
    public static func defaultGateway() -> String? {
        routingTableGateway() ?? routeCommandGateway()
    }

    /// Round trip in milliseconds, or nil on timeout, an unreachable host or a malformed address.
    /// Blocks the calling thread for up to `timeout`; call it off the main thread.
    public func ping(_ ipv4: String, timeout: TimeInterval) -> Double? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ipv4, &address.sin_addr) == 1 else { return nil }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let seq: UInt16 = lock.withLock { sequence &+= 1; return sequence }
        let packet = Self.echoRequest(identifier: identifier, sequence: seq)
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let deadline = start + UInt64(max(0, timeout) * 1e9)
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { return nil }

        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            guard now < deadline else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waitMs = Int32(min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000))
            let ready = poll(&pfd, 1, waitMs)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { return nil }
            if Self.isEchoReply(buffer[0..<n], identifier: identifier, sequence: seq) {
                return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
            }
        }
    }

    // MARK: - Packets

    static func echoRequest(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var packet: [UInt8] = [8, 0, 0, 0,                       // type 8 echo request, code 0, checksum
                               UInt8(identifier >> 8), UInt8(identifier & 0xff),
                               UInt8(sequence >> 8), UInt8(sequence & 0xff)]
        packet += Array("topbarac-latency".utf8)                   // 16 byte payload
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xff)
        return packet
    }

    /// RFC 1071 internet checksum over big-endian 16-bit words.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    /// Accepts the reply with or without a leading IPv4 header (macOS includes it, other systems don't).
    static func isEchoReply(_ data: ArraySlice<UInt8>, identifier: UInt16, sequence: UInt16) -> Bool {
        var icmp = data
        if let first = icmp.first, first >> 4 == 4 {
            let headerLength = Int(first & 0x0f) * 4
            guard icmp.count >= headerLength + 8 else { return false }
            icmp = icmp.dropFirst(headerLength)
        }
        guard icmp.count >= 8 else { return false }
        let b = Array(icmp.prefix(8))
        return b[0] == 0 && b[1] == 0
            && UInt16(b[4]) << 8 | UInt16(b[5]) == identifier
            && UInt16(b[6]) << 8 | UInt16(b[7]) == sequence
    }

    // MARK: - Gateway

    /// Reads the kernel routing table (`sysctl NET_RT_FLAGS` for gateway routes) and returns the gateway of the
    /// default route. Unscoped default routes win over interface-scoped ones, which macOS keeps per interface.
    static func routingTableGateway() -> String? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var scoped: String?
        return buffer.withUnsafeBytes { raw -> String? in
            var offset = 0
            let headerSize = MemoryLayout<rt_msghdr>.size
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                let messageLength = Int(header.rtm_msglen)
                guard messageLength > 0, offset + messageLength <= length else { break }
                defer { offset += messageLength }
                guard header.rtm_flags & RTF_GATEWAY != 0, header.rtm_flags & RTF_UP != 0 else { continue }

                // Addresses follow the header in RTAX order, each padded to 4 bytes; absent ones are skipped.
                var cursor = offset + headerSize
                var addresses: [Int32: (family: Int32, bytes: [UInt8])] = [:]
                for index in 0..<RTAX_MAX where header.rtm_addrs & (1 << index) != 0 {
                    guard cursor < offset + messageLength else { break }
                    let saLen = Int(raw[cursor])
                    let family = Int32(raw[cursor + 1])
                    let end = min(cursor + max(saLen, 0), offset + messageLength)
                    addresses[index] = (family, Array(raw[cursor..<end]))
                    cursor += saLen > 0 ? (1 + ((saLen - 1) | 3)) : 4
                }
                guard let dst = addresses[RTAX_DST], dst.family == AF_INET,
                      let gateway = addresses[RTAX_GATEWAY], gateway.family == AF_INET, gateway.bytes.count >= 8 else { continue }
                // Default route: destination 0.0.0.0 and an empty (or all-zero) netmask.
                let dstAddr = dst.bytes.count >= 8 ? Array(dst.bytes[4..<8]) : [0, 0, 0, 0]
                let mask = addresses[RTAX_NETMASK].map { $0.bytes.count > 4 ? Array($0.bytes[4...]) : [] } ?? []
                guard dstAddr.allSatisfy({ $0 == 0 }), mask.allSatisfy({ $0 == 0 }) else { continue }
                let g = gateway.bytes
                let text = "\(g[4]).\(g[5]).\(g[6]).\(g[7])"
                if header.rtm_flags & RTF_IFSCOPE == 0 { return text }
                if scoped == nil { scoped = text }
            }
            return scoped
        }
    }

    static func routeCommandGateway() -> String? {
        guard let output = Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 2) else { return nil }
        return parseRouteOutput(output)
    }

    static func parseRouteOutput(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "gateway" else { continue }
            var probe = in_addr()
            return inet_pton(AF_INET, parts[1], &probe) == 1 ? parts[1] : nil
        }
        return nil
    }
}
