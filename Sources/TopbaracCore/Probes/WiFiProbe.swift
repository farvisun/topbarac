import CoreWLAN
import Foundation

/// The current Wi‑Fi link as CoreWLAN reports it.
public struct WiFiInfo: Sendable, Equatable {
    public var interface: String
    /// Needs Location Services permission on modern macOS, so it is usually nil. The app doesn't ask for it.
    public var ssid: String?
    public var rssi: Int                  // dBm
    public var noise: Int                 // dBm
    public var channel: Int?
    public var band: String?              // "2.4 GHz", "5 GHz", "6 GHz"
    public var channelWidthMHz: Int?
    public var txRateMbps: Double
    public var phyMode: String?           // "Wi‑Fi 6E", "802.11n", …
    public var security: String?
    /// 0...1 from RSSI: −90 dBm or worse is 0, −50 dBm or better is 1.
    public var quality: Double

    public init(interface: String, ssid: String?, rssi: Int, noise: Int, channel: Int?, band: String?,
                channelWidthMHz: Int?, txRateMbps: Double, phyMode: String?, security: String?, quality: Double) {
        self.interface = interface; self.ssid = ssid; self.rssi = rssi; self.noise = noise; self.channel = channel
        self.band = band; self.channelWidthMHz = channelWidthMHz; self.txRateMbps = txRateMbps; self.phyMode = phyMode
        self.security = security; self.quality = quality
    }

    /// Signal to noise ratio in dB, the number that actually predicts throughput.
    public var snr: Int? { noise < 0 && rssi < 0 ? rssi - noise : nil }
}

public enum WiFiProbe {
    /// Nil when there is no Wi‑Fi interface, it is off, or it isn't joined to a network (CoreWLAN then reports an
    /// RSSI of 0, which no real link has).
    public static func read() -> WiFiInfo? {
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn() else { return nil }
        let rssi = iface.rssiValue()
        guard rssi < 0 else { return nil }
        let channel = iface.wlanChannel()
        let band = channel.flatMap { bandName($0.channelBand.rawValue) }
        return WiFiInfo(
            interface: iface.interfaceName ?? "en0",
            ssid: iface.ssid(),
            rssi: rssi,
            noise: iface.noiseMeasurement(),
            channel: channel.map(\.channelNumber).flatMap { $0 > 0 ? $0 : nil },
            band: band,
            channelWidthMHz: channel.flatMap { widthMHz($0.channelWidth.rawValue) },
            txRateMbps: iface.transmitRate(),
            phyMode: phyModeName(iface.activePHYMode().rawValue, band: band),
            security: securityName(iface.security().rawValue),
            quality: quality(rssi: rssi))
    }

    public static func quality(rssi: Int) -> Double {
        max(0, min(1, Double(rssi + 90) / 40))
    }

    // Raw values instead of enum cases so values added in newer SDKs (320 MHz, 802.11be) don't break the switch.

    static func bandName(_ raw: Int) -> String? {
        switch raw { case 1: "2.4 GHz"; case 2: "5 GHz"; case 3: "6 GHz"; default: nil }
    }

    static func widthMHz(_ raw: Int) -> Int? {
        switch raw { case 1: 20; case 2: 40; case 3: 80; case 4: 160; case 5: 320; default: nil }
    }

    /// Marketing names for the generations people know (Wi‑Fi 4 onwards), IEEE names for the older ones.
    /// 802.11ax on the 6 GHz band is Wi‑Fi 6E.
    static func phyModeName(_ raw: Int, band: String?) -> String? {
        switch raw {
        case 1: "802.11a"
        case 2: "802.11b"
        case 3: "802.11g"
        case 4: "802.11n"
        case 5: "Wi\u{2011}Fi 5"
        case 6: band == "6 GHz" ? "Wi\u{2011}Fi 6E" : "Wi\u{2011}Fi 6"
        case 7: "Wi\u{2011}Fi 7"
        default: nil
        }
    }

    static func securityName(_ raw: Int) -> String? {
        switch raw {
        case 0: "None"
        case 1: "WEP"
        case 2: "WPA Personal"
        case 3: "WPA/WPA2 Personal"
        case 4: "WPA2 Personal"
        case 5: "Personal"
        case 6: "Dynamic WEP"
        case 7: "WPA Enterprise"
        case 8: "WPA/WPA2 Enterprise"
        case 9: "WPA2 Enterprise"
        case 10: "Enterprise"
        case 11: "WPA3 Personal"
        case 12: "WPA3 Enterprise"
        case 13: "WPA2/WPA3 Personal"
        case 14: "OWE"
        case 15: "OWE Transition"
        default: nil
        }
    }
}
