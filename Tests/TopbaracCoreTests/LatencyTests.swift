import Foundation
import Testing
@testable import TopbaracCore

@Suite struct LatencyTests {
    @Test func checksumMatchesRFC1071() {
        // Example from RFC 1071 section 3: words 0001 f203 f4f5 f6f7 sum to ddf2, checksum is its complement.
        #expect(LatencyProbe.checksum([0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7]) == ~UInt16(0xddf2))
        let packet = LatencyProbe.echoRequest(identifier: 0x1234, sequence: 7)
        #expect(packet.count == 24 && packet[0] == 8)
        #expect(LatencyProbe.checksum(packet) == 0)          // a correct checksum makes the whole packet sum to zero
    }

    @Test func matchesRepliesWithAndWithoutIPHeader() {
        var reply = LatencyProbe.echoRequest(identifier: 0x1234, sequence: 7)
        reply[0] = 0
        let ipHeader: [UInt8] = [0x45] + [UInt8](repeating: 0, count: 19)
        #expect(LatencyProbe.isEchoReply(ArraySlice(reply), identifier: 0x1234, sequence: 7))
        #expect(LatencyProbe.isEchoReply(ArraySlice(ipHeader + reply), identifier: 0x1234, sequence: 7))
        #expect(!LatencyProbe.isEchoReply(ArraySlice(ipHeader + reply), identifier: 0x1234, sequence: 8))
        #expect(!LatencyProbe.isEchoReply(ArraySlice(ipHeader + reply), identifier: 0x4321, sequence: 7))
        #expect(!LatencyProbe.isEchoReply(ArraySlice(LatencyProbe.echoRequest(identifier: 0x1234, sequence: 7)),
                                          identifier: 0x1234, sequence: 7))   // our own request isn't a reply
    }

    @Test func parsesRouteOutput() {
        let out = "   route to: default\ndestination: default\n       mask: default\n    gateway: 192.168.1.1\n  interface: en0\n"
        #expect(LatencyProbe.parseRouteOutput(out) == "192.168.1.1")
        #expect(LatencyProbe.parseRouteOutput("route: writing to routing socket: not in table") == nil)
    }

    @Test func rejectsBadAddresses() {
        #expect(LatencyProbe().ping("not an ip", timeout: 0.1) == nil)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TOPBARAC_LIVE"] == "1"))
struct LiveLatencyTests {
    @Test func pingsGatewayAndInternet() throws {
        let gateway = try #require(LatencyProbe.defaultGateway())
        #expect(LatencyProbe.routingTableGateway() == LatencyProbe.routeCommandGateway())
        let probe = LatencyProbe()
        let gw = probe.ping(gateway, timeout: 1)
        // Best of three: one lost packet on a busy network shouldn't fail the run.
        let internet = (0..<3).lazy.compactMap { _ in probe.ping("1.1.1.1", timeout: 2) }.first
        print("latency gateway", gateway, gw.map { String(format: "%.2f ms", $0) } ?? "timeout",
              "1.1.1.1", internet.map { String(format: "%.2f ms", $0) } ?? "timeout")
        #expect(gw != nil || internet != nil)
    }
}
