import Foundation
import Testing
@testable import TopbaracCore

@Suite struct DiagnosticsTests {
    let gb: UInt64 = 1_000_000_000

    func process(_ pid: Int32, _ name: String, cpu: Double = 1, memory: UInt64 = 100_000_000, disk: Double = 0,
                 owned: Bool = true) -> ProcessSample {
        ProcessSample(pid: pid, name: name, path: nil, uid: owned ? 501 : 0, cpu: cpu, memory: memory, diskReadBps: disk,
                      diskWriteBps: 0, energyWatts: nil, isOwned: owned)
    }

    var healthy: DiagnosticInput {
        var cpu = CPUSnapshot(); cpu.usage = 0.2
        var memory = MemorySnapshot(); memory.total = 16 * 1_073_741_824; memory.swapUsed = 1_073_741_824
        var temperature = TemperatureSnapshot(); temperature.thermalState = 0
        var disk = DiskSnapshot()
        disk.volumes = [VolumeInfo(name: "Macintosh HD", path: "/", total: 500 * gb, available: 200 * gb, freeStrict: 190 * gb,
                                   isInternal: true, isEjectable: false, isRoot: true)]
        disk.busy = 0.1
        var battery = BatterySnapshot(); battery.present = true; battery.percent = 0.8
        return DiagnosticInput(cpu: cpu, memory: memory, temperature: temperature, disk: disk, battery: battery,
                               processes: [process(10, "Safari", cpu: 12), process(11, "Mail", cpu: 2)])
    }

    @Test func healthyMacHasNoFindings() {
        #expect(Diagnostics.run(healthy).isEmpty)
        #expect(Diagnostics.run(DiagnosticInput()).isEmpty)
    }

    @Test func runawayProcess() throws {
        var input = healthy
        input.processes = [process(42, "Xcode", cpu: 95), process(43, "Chrome", cpu: 180), process(44, "mds", cpu: 90, owned: false)]
        let findings = Diagnostics.run(input)
        #expect(findings.count == 3)
        #expect(findings[0].severity == .critical && findings[0].action == .quitProcess(pid: 43, name: "Chrome"))
        #expect(findings[0].title == "Chrome is using 180% CPU")
        let xcode = try #require(findings.first { $0.id == "process-cpu-42" })
        #expect(xcode.severity == .warning && xcode.action == .quitProcess(pid: 42, name: "Xcode"))
        // A root process can't be quit from the app; point at the list instead.
        #expect(findings.first { $0.id == "process-cpu-44" }?.action == .showProcesses(metric: "cpu"))
        input.processes = [process(42, "Xcode", cpu: 79)]
        #expect(Diagnostics.run(input).isEmpty)
    }

    @Test func busyCPUNamesTheLeader() throws {
        var input = healthy
        input.cpu?.usage = 0.9
        let f = try #require(Diagnostics.run(input).first)
        #expect(f.id == "cpu-total" && f.severity == .warning && f.detail.contains("Safari"))
        #expect(f.action == .showProcesses(metric: "cpu"))
    }

    @Test func memoryPressure() throws {
        var input = healthy
        input.processes.append(process(12, "Photoshop", memory: 6 * gb))
        input.memory?.pressure = .warning
        var f = try #require(Diagnostics.run(input).first)
        #expect(f.id == "memory-pressure" && f.severity == .warning && f.action == .freeMemory && f.detail.contains("Photoshop"))
        input.memory?.pressure = .critical
        f = try #require(Diagnostics.run(input).first)
        #expect(f.severity == .critical)
    }

    @Test func heavySwap() throws {
        var input = healthy
        input.memory?.swapUsed = 5 * 1_073_741_824          // > 25 % of 16 GB
        let f = try #require(Diagnostics.run(input).first)
        #expect(f.id == "swap" && f.severity == .warning && f.action == .showProcesses(metric: "memory"))
    }

    @Test func throttling() throws {
        var input = healthy
        input.temperature?.thermalState = 2
        input.temperature?.sensors = [SensorReading(name: "CPU die 1", group: .cpu, celsius: 101.4, min: 40, max: 102)]
        var f = try #require(Diagnostics.run(input).first)
        #expect(f.title == "Mac is throttling to cool down" && f.severity == .warning && f.detail.contains("101 °C"))
        input.temperature?.thermalState = 3
        f = try #require(Diagnostics.run(input).first)
        #expect(f.severity == .critical)
        input.temperature?.thermalState = 1
        #expect(Diagnostics.run(input).isEmpty)
    }

    @Test func lowDiskSpace() throws {
        var input = healthy
        input.disk?.volumes[0].available = 12 * gb             // under 15 GB
        var f = try #require(Diagnostics.run(input).first)
        #expect(f.id == "disk-space" && f.severity == .warning && f.action == .openStorage)
        input.disk?.volumes[0].available = 4 * gb
        f = try #require(Diagnostics.run(input).first)
        #expect(f.severity == .critical)
        // Under 10 % on a big disk counts even with plenty of gigabytes.
        input.disk?.volumes[0] = VolumeInfo(name: "HD", path: "/", total: 4000 * gb, available: 300 * gb, freeStrict: 300 * gb,
                                            isInternal: true, isEjectable: false, isRoot: true)
        #expect(Diagnostics.run(input).first?.id == "disk-space")
    }

    @Test func busyDisk() throws {
        var input = healthy
        input.disk?.busy = 0.9
        input.processes.append(process(50, "backupd", disk: 80_000_000, owned: false))
        let f = try #require(Diagnostics.run(input).first)
        #expect(f.id == "disk-busy" && f.detail.contains("backupd") && f.action == .showProcesses(metric: "disk"))
    }

    @Test func lowBattery() throws {
        var input = healthy
        input.battery?.percent = 0.12
        var f = try #require(Diagnostics.run(input).first)
        #expect(f.id == "battery-low" && f.severity == .info)
        input.battery?.percent = 0.05
        f = try #require(Diagnostics.run(input).first)
        #expect(f.severity == .warning)
        input.battery?.charging = true
        #expect(Diagnostics.run(input).isEmpty)
    }

    @Test func mostSevereFirst() {
        var input = healthy
        input.battery?.percent = 0.12                           // info
        input.memory?.swapUsed = 5 * 1_073_741_824              // warning
        input.disk?.volumes[0].available = 2 * gb               // critical
        #expect(Diagnostics.run(input).map(\.severity) == [.critical, .warning, .info])
    }
}
