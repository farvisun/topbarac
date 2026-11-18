import Foundation
import Testing
@testable import TopbaracCore

@Suite struct BluetoothBatteryTests {
    @Test func parsesConnectedDevicesOnly() throws {
        let url = try #require(Bundle.module.url(forResource: "bluetooth", withExtension: "json", subdirectory: "Fixtures"))
        let devices = BluetoothBatteryProbe.parseSystemProfiler(try Data(contentsOf: url))
        #expect(devices.map(\.name) == ["Sam’s AirPods Pro", "Studio Keyboard", "Xbox Wireless Controller"])
        let pods = devices[0]
        #expect(pods.kind == .headphones && pods.id == "a1:b2:c3:d4:e5:f6")
        #expect(pods.levels == [.init(label: "Left", fraction: 0.85), .init(label: "Right", fraction: 0.9),
                                .init(label: "Case", fraction: 0.55)])
        #expect(pods.lowest == 0.55)
        #expect(devices[1].kind == .keyboard && devices[1].levels == [.init(label: nil, fraction: 0.42)])
        #expect(devices[2].kind == .controller && devices[2].levels.first?.fraction == 0.07)
    }

    @Test func badInputIsEmpty() {
        #expect(BluetoothBatteryProbe.parseSystemProfiler(Data("nope".utf8)).isEmpty)
        #expect(BluetoothBatteryProbe.parseSystemProfiler(Data(#"{"SPBluetoothDataType": [{}]}"#.utf8)).isEmpty)
    }

    @Test func registryWinsWhenMerging() {
        let registry = [BluetoothBattery(id: "10:20:30:40:50:60", name: "Magic Keyboard", kind: .keyboard,
                                         levels: [.init(label: nil, fraction: 0.5)])]
        let profiler = [BluetoothBattery(id: "10:20:30:40:50:60", name: "Studio Keyboard", kind: .keyboard,
                                         levels: [.init(label: nil, fraction: 0.4)]),
                        BluetoothBattery(id: "x", name: "magic keyboard", kind: .keyboard, levels: []),
                        BluetoothBattery(id: "a1:b2", name: "AirPods", kind: .headphones, levels: [.init(label: "Left", fraction: 1)])]
        let merged = BluetoothBatteryProbe.merge(registry: registry, profiler: profiler)
        #expect(merged.map(\.name) == ["AirPods", "Magic Keyboard"])
        #expect(merged[1].levels.first?.fraction == 0.5)
    }

    @Test func helpers() {
        #expect(BluetoothBatteryProbe.percent("85%") == 0.85)
        #expect(BluetoothBatteryProbe.percent("100 %") == 1)
        #expect(BluetoothBatteryProbe.percent("n/a") == nil)
        #expect(BluetoothBatteryProbe.normalizedAddress("AA-BB-CC-DD-EE-FF") == "aa:bb:cc:dd:ee:ff")
        #expect(BluetoothBatteryProbe.normalizedAddress("short") == nil)
        #expect(BluetoothBatteryProbe.kind(name: "Magic Trackpad", minorType: nil) == .trackpad)
        #expect(BluetoothBatteryProbe.kind(name: "MX Master 3", minorType: "Mouse") == .mouse)
        #expect(BluetoothBatteryProbe.kind(name: "Desk Speaker", minorType: "Speaker") == .other)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TOPBARAC_LIVE"] == "1"))
struct LiveBluetoothBatteryTests {
    @Test func readsDevices() {
        let start = Date()
        let devices = BluetoothBatteryProbe.read()
        print("bluetooth", String(format: "%.2fs", Date().timeIntervalSince(start)),
              devices.map { "\($0.name) [\($0.kind.rawValue)] \($0.levels.map { "\($0.label ?? "-") \(Int($0.fraction * 100))%" })" })
        #expect(devices.allSatisfy { !$0.levels.isEmpty })
    }
}
