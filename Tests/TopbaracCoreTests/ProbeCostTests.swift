import Foundation
import Testing
@testable import TopbaracCore

/// CPU time per call of each probe (user + system). Opt in with TOPBARAC_LIVE=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TOPBARAC_LIVE"] == "1"))
struct ProbeCostTests {
    func cpuTime() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1000 + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1000
    }

    func measure(_ name: String, _ n: Int = 50, _ body: () -> Void) {
        body()
        let start = cpuTime()
        for _ in 0..<n { body() }
        print(String(format: "cost %-12@ %.3f ms/call", name as NSString, (cpuTime() - start) / Double(n)))
    }

    @Test func probeCosts() {
        let cpu = CPUProbe(), mem = MemoryProbe(), disk = DiskProbe(), net = NetworkProbe(), bat = BatteryProbe()
        let gpu = GPUProbe(), temp = TemperatureProbe(), io = IOReportProbe(), hid = HIDTemperature()
        measure("cpu") { _ = cpu.sample() }
        measure("memory") { _ = mem.sample() }
        measure("disk") { _ = disk.sample(volumeRefreshInterval: 1e9) }
        measure("network") { _ = net.sample() }
        measure("battery") { _ = bat.sample() }
        measure("gpu") { _ = gpu.sample() }
        measure("hid") { _ = hid.read() }
        measure("temperature", 20) { _ = temp.sample() }
        measure("ioreport", 20) { _ = io.sample() }
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TOPBARAC_LIVE"] == "1"))
struct NetTopLiveTests {
    @Test func nettopStreamsRates() async throws {
        let probe = NetTopProbe()
        probe.start()
        try await Task.sleep(for: .seconds(12))
        print("nettop pids", probe.rates.count)
        #expect(!probe.rates.isEmpty)
        probe.stop()
    }
}
