import Foundation
import Testing
@testable import TopbaracCore

@Suite struct WiFiTests {
    @Test func qualityFromRSSI() {
        #expect(WiFiProbe.quality(rssi: -95) == 0)
        #expect(WiFiProbe.quality(rssi: -90) == 0)
        #expect(WiFiProbe.quality(rssi: -70) == 0.5)
        #expect(WiFiProbe.quality(rssi: -50) == 1)
        #expect(WiFiProbe.quality(rssi: -30) == 1)
    }

    @Test func names() {
        #expect(WiFiProbe.phyModeName(6, band: "5 GHz") == "Wi\u{2011}Fi 6")
        #expect(WiFiProbe.phyModeName(6, band: "6 GHz") == "Wi\u{2011}Fi 6E")
        #expect(WiFiProbe.phyModeName(7, band: nil) == "Wi\u{2011}Fi 7")
        #expect(WiFiProbe.phyModeName(4, band: nil) == "802.11n")
        #expect(WiFiProbe.phyModeName(0, band: nil) == nil)
        #expect(WiFiProbe.bandName(1) == "2.4 GHz" && WiFiProbe.bandName(3) == "6 GHz" && WiFiProbe.bandName(0) == nil)
        #expect(WiFiProbe.widthMHz(3) == 80 && WiFiProbe.widthMHz(0) == nil)
        #expect(WiFiProbe.securityName(11) == "WPA3 Personal" && WiFiProbe.securityName(Int.max) == nil)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TOPBARAC_LIVE"] == "1"))
struct LiveWiFiTests {
    @Test func readsWiFi() {
        guard let wifi = WiFiProbe.read() else { print("wifi: off or not joined"); return }
        print("wifi", wifi)
        #expect(wifi.rssi < 0 && (0...1).contains(wifi.quality))
    }
}
