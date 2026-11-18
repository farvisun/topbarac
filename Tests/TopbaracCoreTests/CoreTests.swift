import Foundation
import Testing
@testable import TopbaracCore

@Suite struct RingBufferTests {
    @Test func dropsOldestPastCapacity() {
        var r = RingBuffer<Int>(capacity: 3)
        for i in 1...5 { r.append(i) }
        #expect(Array(r) == [3, 4, 5])
        #expect(r.first == 3 && r.last == 5 && r.count == 3)
        #expect(r.suffix(2) == [4, 5])
    }

    @Test func seriesNeverStoresTwoGapsInARow() {
        var s = SeriesHistory(capacity: 10)
        let t = Date()
        s.append(1, at: t)
        s.append(nil, at: t + 1)
        s.append(nil, at: t + 2)
        s.append(2, at: t + 3)
        #expect(s.points.count == 3)
    }

    @Test func downsampleKeepsGapBuckets() {
        let t = Date()
        var points = (0..<100).map { SeriesPoint(time: t + Double($0), value: 1) }
        for i in 40..<60 { points[i].value = nil }
        let out = SeriesHistory.downsample(points, maxPoints: 10)
        #expect(out.count == 10)
        #expect(out.contains { $0.value == nil })
        #expect(out.first?.value == 1)
    }
}

@Suite struct ProbeMathTests {
    @Test func cpuUsageFromTicks() {
        let a = [CoreTicks(user: 100, system: 50, idle: 850, nice: 0), CoreTicks(user: 0, system: 0, idle: 1000, nice: 0)]
        let b = [CoreTicks(user: 150, system: 100, idle: 900, nice: 0), CoreTicks(user: 0, system: 0, idle: 1100, nice: 0)]
        let r = try! #require(CPUMath.usage(previous: a, current: b))
        #expect(r.cores == [Double(100) / 150, 0])
        #expect(abs(r.user + r.system - 100.0 / 250) < 1e-9)
    }

    @Test func cpuCounterResetIsAGap() {
        let a = [CoreTicks(user: 100, system: 50, idle: 850, nice: 0)]
        let b = [CoreTicks(user: 10, system: 50, idle: 900, nice: 0)]
        #expect(CPUMath.usage(previous: a, current: b) == nil)
        #expect(CPUMath.usage(previous: a, current: a + a) == nil)
    }

    @Test func memoryMatchesActivityMonitorFormula() throws {
        let url = try #require(Bundle.module.url(forResource: "vm_counts", withExtension: "json", subdirectory: "Fixtures"))
        let counts = try JSONDecoder().decode(VMCounts.self, from: Data(contentsOf: url))
        let page: UInt64 = 16384
        let s = MemoryMath.snapshot(counts: counts, pageSize: page, total: 18 * 1_073_741_824)
        #expect(s.app == (counts.internal - counts.purgeable) * page)
        #expect(s.cached == (counts.external + counts.purgeable) * page)
        #expect(s.used == s.app + s.wired + s.compressed)
        #expect(s.usage > 0 && s.usage < 1)
    }

    @Test func diskRatesSkipResetDisks() {
        let a = ["disk0": BlockCounters(bytesRead: 1000, bytesWritten: 0, timeRead: 0, timeWritten: 0),
                 "disk4": BlockCounters(bytesRead: 5000, bytesWritten: 0, timeRead: 0, timeWritten: 0)]
        let b = ["disk0": BlockCounters(bytesRead: 3000, bytesWritten: 1000, timeRead: 500_000_000, timeWritten: 0),
                 "disk4": BlockCounters(bytesRead: 10, bytesWritten: 0, timeRead: 0, timeWritten: 0)]
        let r = DiskMath.rates(previous: a, current: b, seconds: 2)
        #expect(r.read == 1000 && r.write == 500)
        #expect(r.busy == 0.25 && r.busiest == "disk0")
    }

    @Test func networkDeltasAndVirtualInterfaces() {
        let d = NetworkMath.deltas(previous: ["en0": .init(bytesIn: 100, bytesOut: 50)],
                                   current: ["en0": .init(bytesIn: 300, bytesOut: 60), "en1": .init(bytesIn: 5, bytesOut: 5)])
        #expect(d["en0"]!!.inBytes == 200 && d["en0"]!!.outBytes == 10)
        #expect(d["en1"]!!.inBytes == 0)
        let reset = NetworkMath.deltas(previous: ["en0": .init(bytesIn: 100, bytesOut: 50)], current: ["en0": .init(bytesIn: 1, bytesOut: 1)])
        #expect(reset["en0"]! == nil)
        #expect(NetworkMath.isVirtual("utun3") && NetworkMath.isVirtual("lo0") && !NetworkMath.isVirtual("en0"))
    }

    @Test func sensorNames() {
        #expect(SensorNaming.classify("PMU tdie3")! == ("CPU die 3", .cpu))
        #expect(SensorNaming.classify("PMU tcal") == nil)
        #expect(SensorNaming.classify("NAND CH0 temp")!.group == .ssd)
        #expect(SensorNaming.classify("gas gauge battery")! == ("Battery", .battery))
    }

    @Test func frequencyFromResidency() {
        let states: [(String, Double)] = [("IDLE", 50), ("V0P5", 25), ("V1P4", 25)]
        let r = try! #require(IOReportProbe.averageFrequency(states, table: [1000, 3000]))
        #expect(r.mhz == 2000 && r.active == 0.5)
        #expect(IOReportProbe.joules(1500, unit: "mJ") == 1.5)
    }

    @Test func smcStructLayoutMatchesKernel() {
        #expect(SMC.fourCC("F0Ac") == 0x4630_4163)
        #expect(SMC.string(0x4630_4163) == "F0Ac")
        #expect(SMC.Value(type: "flt ", bytes: [0, 0, 0x48, 0x42]).number == 50)
        #expect(SMC.Value(type: "fpe2", bytes: [0x17, 0x70]).number == 1500)
    }
}

@Suite struct ProcessTests {
    func sample(_ pid: Int32, cpu: Double, mem: UInt64) -> ProcessSample {
        ProcessSample(pid: pid, name: "p\(pid)", path: nil, uid: 501, cpu: cpu, memory: mem, diskReadBps: 0,
                      diskWriteBps: 0, energyWatts: nil, isOwned: true)
    }

    @Test func helpersFoldIntoTheirApp() {
        let list = [sample(20, cpu: 5, mem: 10), sample(10, cpu: 10, mem: 100), sample(21, cpu: 1, mem: 1), sample(30, cpu: 2, mem: 2)]
        let grouped = ProcessGrouping.group(list, responsible: [20: 10, 21: 10, 10: 10, 30: 99])
        let app = try! #require(grouped.first { $0.pid == 10 })
        #expect(app.cpu == 16 && app.memory == 111 && app.groupCount == 3 && app.name == "p10")
        #expect(grouped.count == 2)
    }

    @Test func parsesPS() {
        let rows = ProcessProbe.parsePSForTesting("  666   88  43.2  73312 /System/Library/WindowServer\n    1    0   0.0  1000 /sbin/launchd\nbad line\n")
        #expect(rows.count == 2)
        #expect(rows[0].pid == 666 && rows[0].cpu == 43.2 && rows[0].rss == 73312 * 1024)
    }

    @Test func displayNames() {
        #expect(ProcessProbe.displayName(fromPath: "/Applications/Safari.app/Contents/MacOS/Safari") == "Safari")
        #expect(ProcessProbe.displayName(fromPath: "/usr/sbin/cfprefsd") == "cfprefsd")
    }

    @Test func parsesNettop() {
        let out = ",bytes_in,bytes_out,\nSafari.10,500,100,\n,bytes_in,bytes_out,\nSafari.10,2000,400,\nmDNSResponder.709,10,0,\n"
        let r = NetTopParser.parse(out, seconds: 2)
        #expect(r[10]!.0 == 1000 && r[10]!.1 == 200)
        #expect(r[709]!.0 == 5)
        let rates = NetTopParser.rates(previous: [1: (100, 10)], current: [1: (300, 30), 2: (50, 0)], seconds: 2)
        #expect(rates[1]!.0 == 100 && rates[1]!.1 == 10)
        #expect(rates[2]!.0 == 0)
    }
}

@Suite struct AlertTests {
    func frame(cpu: Double, at t: Date) -> SampleFrame {
        var f = SampleFrame(time: t)
        var c = CPUSnapshot()
        c.usage = cpu
        f.cpu = c
        return f
    }

    @Test func firesAfterDurationThenCoolsDown() {
        var engine = AlertEngine()
        let rule = AlertRule(metric: .cpuUsage, comparison: .above, threshold: 90, duration: 10, cooldown: 60)
        let t = Date()
        #expect(engine.evaluate(frame(cpu: 0.95, at: t), rules: [rule]).isEmpty)
        #expect(engine.evaluate(frame(cpu: 0.95, at: t + 5), rules: [rule]).isEmpty)
        #expect(engine.evaluate(frame(cpu: 0.95, at: t + 10), rules: [rule]).count == 1)
        #expect(engine.active.contains(rule.id))
        #expect(engine.evaluate(frame(cpu: 0.95, at: t + 30), rules: [rule]).isEmpty)       // cooldown
        #expect(engine.evaluate(frame(cpu: 0.95, at: t + 71), rules: [rule]).count == 1)
    }

    @Test func dropBelowRestartsTheClock() {
        var engine = AlertEngine()
        let rule = AlertRule(metric: .cpuUsage, comparison: .above, threshold: 90, duration: 10)
        let t = Date()
        _ = engine.evaluate(frame(cpu: 0.95, at: t), rules: [rule])
        _ = engine.evaluate(frame(cpu: 0.50, at: t + 5), rules: [rule])
        #expect(engine.evaluate(frame(cpu: 0.95, at: t + 11), rules: [rule]).isEmpty)
        #expect(engine.active.isEmpty)
    }

    @Test func disabledRulesNeverFire() {
        var engine = AlertEngine()
        let rule = AlertRule(enabled: false, metric: .cpuUsage, comparison: .above, threshold: 0, duration: 0)
        #expect(engine.evaluate(frame(cpu: 1, at: Date()), rules: [rule]).isEmpty)
    }
}

@Suite struct HistoryTests {
    @Test func bucketsAverageAndClose() {
        var acc = BucketAccumulator(width: 10)
        let t = Date(timeIntervalSince1970: 1000)
        #expect(acc.add(1, at: t) == nil)
        #expect(acc.add(3, at: t + 5) == nil)
        let closed = try! #require({ acc.add(10, at: t + 10) }())
        #expect(closed.start == 1000 && closed.average == 2)
        #expect(acc.drain()!.average == 10)
        #expect(acc.drain() == nil)
    }

    @Test func storeRoundTripAndGaps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("topbarac-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(HistoryStore(url: dir.appendingPathComponent("h.sqlite")))
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<120 { store.record([.cpuUsage: 0.5], at: start + Double(i)) }
        // Ten minutes of nothing (sleep), then more data.
        for i in 0..<60 { store.record([.cpuUsage: 1.0], at: start + 720 + Double(i)) }
        store.flush(final: true)
        let points = store.query(.cpuUsage, since: start, until: start + 800, maxPoints: 1000)
        #expect(points.contains { $0.value == nil })
        #expect(points.first?.value == 0.5)
        #expect(points.last?.value == 1.0)
        #expect(store.oldest()! <= start)
        let csv = dir.appendingPathComponent("out.csv")
        try store.exportCSV(to: csv)
        #expect(try String(contentsOf: csv, encoding: .utf8).hasPrefix("series,tier_seconds,time,value\ncpu,"))
        store.prune(retention: 60, now: start + 800)
        store.flush()
        #expect(store.query(.cpuUsage, since: start, until: start + 700).isEmpty)
        store.clear()
        #expect(store.oldest() == nil)
    }
}

@Suite struct SettingsAndFormatTests {
    @Test func decodesOldSettingsWithMissingKeys() throws {
        let json = #"{"refreshInterval": 3, "widgets": {"cpu": {"enabled": false, "style": "ring", "showValue": true, "showLabel": true, "metric": "cpuPower", "warning": 50, "critical": 60, "thresholdsEnabled": true}}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(s.refreshInterval == 3)
        #expect(s.config(.cpu).style == .ring && !s.config(.cpu).enabled)
        #expect(s.config(.memory) == .defaults(for: .memory))
        #expect(s.order == WidgetKind.allCases)
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(again == s)
    }

    @Test func formats() {
        #expect(Format.percent(0.426) == "43%")
        #expect(Format.bytes(Double(1_500_000_000)) == "1.5 GB")
        #expect(Format.rate(2_500_000) == "2.5 MB/s")
        #expect(Format.rate(2_500_000, bits: true) == "20 Mb/s")
        #expect(Format.rate(512, compact: true) == "512B")
        #expect(Format.temperature(100, fahrenheit: true) == "212°")
        #expect(Format.minutes(96) == "1:36")
        #expect(Format.duration(90061) == "1d 1h")
        #expect(Format.memory(8 * 1_073_741_824) == "8.00 GB")
    }
}

/// Reads the real hardware. Opt in with TOPBARAC_LIVE=1 (CI machines lack sensors and batteries).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TOPBARAC_LIVE"] == "1"))
struct LiveProbeTests {
    @Test func probesReturnPlausibleValues() throws {
        let cpu = CPUProbe()
        _ = cpu.sample()
        Thread.sleep(forTimeInterval: 0.5)
        let c = try #require(cpu.sample())
        #expect(c.perCore.count == ProcessInfo.processInfo.activeProcessorCount)
        let m = try #require(MemoryProbe().sample())
        #expect(m.used > 0 && m.used < m.total)
        #expect(!DiskProbe.readVolumes().isEmpty)
        #expect(!DiskProbe.readCounters().isEmpty)
        #expect(!NetworkProbe.readCounters().isEmpty)
        let t = TemperatureProbe().sample()
        print("sensors", t.sensors.count, "cpu", t.cpu as Any, "gpu", t.gpu as Any, "fans", t.fans)
        let g = GPUProbe().sample()
        print("gpu", g.name, g.utilization, g.memoryUsed)
        let io = IOReportProbe()
        _ = io.sample()
        Thread.sleep(forTimeInterval: 0.5)
        let r = io.sample()
        print("ioreport", io.isAvailable, r?.cpuPowerW as Any, r?.pFrequencyMHz as Any, r?.eFrequencyMHz as Any, r?.gpuFrequencyMHz as Any)
        let b = BatteryProbe().sample()
        print("battery", b.present, b.percent, b.health as Any, b.cycleCount as Any, b.batteryWatts as Any, b.systemPowerWatts as Any)
        let p = ProcessProbe()
        _ = p.sample(includeOtherUsers: true, network: [:])
        Thread.sleep(forTimeInterval: 0.5)
        let list = p.sample(includeOtherUsers: true, network: [:])
        #expect(list.count > 20)
        print("top cpu", list.sorted { $0.cpu > $1.cpu }.prefix(3).map { "\($0.name) \($0.cpu) x\($0.groupCount)" })
    }
}
