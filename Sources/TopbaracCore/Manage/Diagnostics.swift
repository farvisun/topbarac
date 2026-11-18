import Foundation

/// One frame's worth of readings for the "Why is my Mac slow?" check. Any part may be missing; rules that need it
/// are skipped.
public struct DiagnosticInput: Sendable {
    public var cpu: CPUSnapshot?
    public var memory: MemorySnapshot?
    public var temperature: TemperatureSnapshot?
    public var disk: DiskSnapshot?
    public var battery: BatterySnapshot?
    /// Grouped processes (helpers folded into their app), as `ProcessProbe` delivers them.
    public var processes: [ProcessSample]

    public init(cpu: CPUSnapshot? = nil, memory: MemorySnapshot? = nil, temperature: TemperatureSnapshot? = nil,
                disk: DiskSnapshot? = nil, battery: BatterySnapshot? = nil, processes: [ProcessSample] = []) {
        self.cpu = cpu; self.memory = memory; self.temperature = temperature; self.disk = disk
        self.battery = battery; self.processes = processes
    }
}

public struct Finding: Sendable, Equatable, Identifiable {
    public var id: String
    public var severity: Severity
    public var title: String
    public var detail: String
    public var action: Action?

    public enum Severity: Int, Sendable, Comparable {
        case info, warning, critical
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    public enum Action: Sendable, Equatable {
        case quitProcess(pid: Int32, name: String)
        case freeMemory
        case openStorage
        /// Open the process list sorted by "cpu", "memory", "energy" or "disk".
        case showProcesses(metric: String)
    }

    public init(id: String, severity: Severity, title: String, detail: String, action: Action? = nil) {
        self.id = id; self.severity = severity; self.title = title; self.detail = detail; self.action = action
    }
}

/// Plain rules over one sample. Thresholds sit where a user would actually feel the slowdown, not where a
/// counter merely looks high: a single busy core is normal, sustained multi-core load, memory pressure, swap,
/// throttling and a nearly full disk are not.
public enum Diagnostics {
    public static let processCPUWarning = 80.0        // % of one core
    public static let processCPUCritical = 150.0
    public static let totalCPUWarning = 0.85
    public static let swapWarningFraction = 0.25      // of physical RAM
    public static let diskFreeFraction = 0.10
    public static let diskFreeBytes: UInt64 = 15_000_000_000
    public static let diskFreeCriticalBytes: UInt64 = 5_000_000_000
    public static let diskBusyWarning = 0.85
    public static let batteryLow = 0.15
    public static let batteryVeryLow = 0.08

    /// Findings sorted most severe first. Empty means nothing looks wrong.
    public static func run(_ input: DiagnosticInput) -> [Finding] {
        var findings: [Finding] = []
        let byCPU = input.processes.sorted { $0.cpu > $1.cpu }

        // A runaway app. At most three, so a build storm doesn't flood the list.
        for p in byCPU.prefix(3) where p.cpu >= processCPUWarning {
            let critical = p.cpu >= processCPUCritical
            let cores = p.cpu / 100
            let detail: String
            let action: Finding.Action
            if p.name == "kernel_task" {
                // kernel_task "uses" CPU to keep other work off the cores when the Mac is hot. Can't be quit.
                detail = "macOS is holding the CPU back to cool down. Close heavy apps or improve airflow."
                action = .showProcesses(metric: "cpu")
            } else if p.isOwned {
                detail = cores >= 1.5
                    ? String(format: "That's about %.1f cores of work. Quit it if you don't need it right now.", cores)
                    : "Quit it if you don't need it right now."
                action = .quitProcess(pid: p.pid, name: p.name)
            } else {
                // Other users' and system processes can't be quit without an admin password.
                detail = "It runs as a system process, so it usually settles on its own."
                action = .showProcesses(metric: "cpu")
            }
            findings.append(Finding(id: "process-cpu-\(p.pid)", severity: critical ? .critical : .warning,
                                    title: "\(p.name) is using \(Int(p.cpu.rounded()))% CPU", detail: detail, action: action))
        }

        if let cpu = input.cpu, cpu.usage >= totalCPUWarning {
            var detail = "Everything you do now competes for the processor."
            if let top = byCPU.first, top.cpu > 0 { detail = "\(top.name) uses the most (\(Int(top.cpu.rounded()))%)." }
            findings.append(Finding(id: "cpu-total", severity: .warning, title: "CPU is \(Format.percent(cpu.usage)) busy",
                                    detail: detail, action: .showProcesses(metric: "cpu")))
        }

        if let memory = input.memory {
            if memory.pressure >= .warning {
                var detail = "Apps are being compressed and swapped to make room."
                if let big = input.processes.max(by: { $0.memory < $1.memory }), big.memory > 0 {
                    detail = "\(big.name) uses the most memory (\(Format.memory(big.memory)))."
                }
                findings.append(Finding(id: "memory-pressure", severity: memory.pressure == .critical ? .critical : .warning,
                                        title: "Memory is running low", detail: detail, action: .freeMemory))
            }
            if memory.total > 0, Double(memory.swapUsed) > Double(memory.total) * swapWarningFraction {
                findings.append(Finding(id: "swap", severity: .warning, title: "Heavy swap use",
                                        detail: "\(Format.memory(memory.swapUsed)) of memory is on disk. Apps slow down when they need it back.",
                                        action: .showProcesses(metric: "memory")))
            }
        }

        if let temperature = input.temperature, temperature.thermalState >= 2 {
            let detail = temperature.hottest.map { String(format: "Hottest sensor: %.0f °C.", $0) }
                ?? "macOS lowered the CPU speed to protect the hardware."
            findings.append(Finding(id: "thermal", severity: temperature.thermalState >= 3 ? .critical : .warning,
                                    title: "Mac is throttling to cool down", detail: detail, action: .showProcesses(metric: "cpu")))
        }

        if let disk = input.disk {
            if let root = disk.root, root.total > 0 {
                let free = root.available
                if free < diskFreeCriticalBytes || free < diskFreeBytes || Double(free) < Double(root.total) * diskFreeFraction {
                    findings.append(Finding(id: "disk-space", severity: free < diskFreeCriticalBytes ? .critical : .warning,
                                            title: "Startup disk is almost full",
                                            detail: "\(Format.bytes(free)) free. macOS needs room for swap and updates.",
                                            action: .openStorage))
                }
            }
            if disk.busy >= diskBusyWarning {
                var detail = "Apps wait on reads and writes."
                if let top = input.processes.max(by: { $0.diskReadBps + $0.diskWriteBps < $1.diskReadBps + $1.diskWriteBps }),
                   top.diskReadBps + top.diskWriteBps > 0 {
                    detail = "\(top.name) is the busiest (\(Format.rate(top.diskReadBps + top.diskWriteBps)))."
                }
                findings.append(Finding(id: "disk-busy", severity: .warning, title: "Disk is \(Format.percent(disk.busy)) busy",
                                        detail: detail, action: .showProcesses(metric: "disk")))
            }
        }

        if let battery = input.battery, battery.present, !battery.charging, !battery.onAC, battery.percent < batteryLow {
            let left = battery.minutesToEmpty.map { " About \(Format.duration(TimeInterval($0 * 60))) left." } ?? ""
            findings.append(Finding(id: "battery-low", severity: battery.percent < batteryVeryLow ? .warning : .info,
                                    title: "Battery is at \(Format.percent(battery.percent))",
                                    detail: "Plug in soon; Low Power Mode may slow things down.\(left)",
                                    action: .showProcesses(metric: "energy")))
        }

        // Stable order: severity, then the order rules were written in.
        return findings.enumerated()
            .sorted { $0.element.severity != $1.element.severity ? $0.element.severity > $1.element.severity : $0.offset < $1.offset }
            .map(\.element)
    }
}
