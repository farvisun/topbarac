import Darwin
import Foundation

public enum ProcessGrouping {
    /// Folds helper processes into the process responsible for them (Chrome renderers into Chrome), summing CPU,
    /// memory, disk, energy and network. Processes whose responsible process isn't in the list stay on their own.
    /// Groups of more than one keep their parts in `members` (busiest first) so the UI can expand them.
    public static func group(_ samples: [ProcessSample], responsible: [Int32: Int32]) -> [ProcessSample] {
        let byPid = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var groups: [Int32: ProcessSample] = [:]
        var members: [Int32: [ProcessSample]] = [:]
        for s in samples {
            var owner = s.pid
            if let r = responsible[s.pid], r != s.pid, byPid[r] != nil { owner = r }
            var g = groups[owner] ?? {
                var base = byPid[owner]!
                base.cpu = 0; base.memory = 0; base.diskReadBps = 0; base.diskWriteBps = 0
                base.netInBps = 0; base.netOutBps = 0; base.energyWatts = nil; base.groupCount = 0
                return base
            }()
            g.cpu += s.cpu; g.memory += s.memory; g.diskReadBps += s.diskReadBps; g.diskWriteBps += s.diskWriteBps
            g.netInBps += s.netInBps; g.netOutBps += s.netOutBps
            if let e = s.energyWatts { g.energyWatts = (g.energyWatts ?? 0) + e }
            g.groupCount += 1
            groups[owner] = g
            var member = s
            member.members = []
            members[owner, default: []].append(member)
        }
        return groups.values.map { g in
            guard g.groupCount > 1 else { return g }
            var g = g
            g.members = (members[g.pid] ?? []).sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.pid < $1.pid }
            return g
        }
    }
}

/// Per-process CPU, memory, disk I/O and energy.
/// Own processes: `proc_pid_rusage` deltas (exact). Other users' and root processes can't be read without root,
/// so they come from `/bin/ps` (setuid), which gives CPU % and resident memory.
public final class ProcessProbe {
    private struct Previous { var cpuNs: UInt64; var read: UInt64; var written: UInt64; var energy: UInt64 }
    private var previous: [Int32: Previous] = [:]
    private var previousTime: TimeInterval = 0
    private let timebase: Double = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()
    private let uid = getuid()
    private typealias Responsible = @convention(c) (Int32) -> Int32
    private let responsibleFn: Responsible? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: Responsible.self) }

    func reset() { previous = [:] }

    func sample(includeOtherUsers: Bool, network: [Int32: (Double, Double)]) -> [ProcessSample] {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = previousTime > 0 ? now - previousTime : 0
        var next: [Int32: Previous] = [:]
        var out: [ProcessSample] = []
        var responsible: [Int32: Int32] = [:]
        var owned = Set<Int32>()

        for pid in Self.allPids() where pid > 0 {
            var info = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            } == 0
            guard ok else { continue }
            owned.insert(pid)
            let cpuNs = UInt64(Double(info.ri_user_time + info.ri_system_time) * timebase)
            let cur = Previous(cpuNs: cpuNs, read: info.ri_diskio_bytesread, written: info.ri_diskio_byteswritten, energy: info.ri_energy_nj)
            next[pid] = cur
            var cpu = 0.0, read = 0.0, written = 0.0
            var energy: Double?
            if let p = previous[pid], dt > 0 {
                if cur.cpuNs >= p.cpuNs { cpu = Double(cur.cpuNs - p.cpuNs) / 1e9 / dt * 100 }
                if cur.read >= p.read { read = Double(cur.read - p.read) / dt }
                if cur.written >= p.written { written = Double(cur.written - p.written) / dt }
                if cur.energy >= p.energy, cur.energy > 0 { energy = Double(cur.energy - p.energy) / 1e9 / dt }
            }
            let path = Self.path(pid)
            var sample = ProcessSample(pid: pid, name: Self.name(pid, path: path), path: path, uid: uid, cpu: cpu,
                                       memory: info.ri_phys_footprint, diskReadBps: read, diskWriteBps: written,
                                       energyWatts: energy, isOwned: true)
            if let net = network[pid] { sample.netInBps = net.0; sample.netOutBps = net.1 }
            out.append(sample)
            if let responsibleFn { responsible[pid] = responsibleFn(pid) }
        }

        if includeOtherUsers {
            for row in Self.psRows() where !owned.contains(row.pid) {
                var sample = ProcessSample(pid: row.pid, name: Self.displayName(fromPath: row.command), path: row.command,
                                           uid: row.uid, cpu: row.cpu, memory: row.rss, diskReadBps: 0, diskWriteBps: 0,
                                           energyWatts: nil, isOwned: false)
                if let net = network[row.pid] { sample.netInBps = net.0; sample.netOutBps = net.1 }
                out.append(sample)
            }
        }
        previous = next
        previousTime = now
        return ProcessGrouping.group(out, responsible: responsible)
    }

    static func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(0, n))))
    }

    static func path(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cBuffer: buffer)
    }

    static func name(_ pid: Int32, path: String?) -> String {
        if let path { return displayName(fromPath: path) }
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        return String(cBuffer: buffer)
    }

    /// "…/Safari.app/Contents/MacOS/Safari" → "Safari". Plain executables keep their file name.
    public static func displayName(fromPath path: String) -> String {
        let components = path.split(separator: "/")
        if let app = components.last(where: { $0.hasSuffix(".app") }), components.last != app,
           components.lastIndex(of: app)! >= components.count - 4 {
            // Helper apps inside bundles: keep the innermost .app's name.
            return String(app.dropLast(4))
        }
        return components.last.map(String.init) ?? path
    }

    struct PSRow { var pid: Int32; var uid: UInt32; var cpu: Double; var rss: UInt64; var command: String }

    static func psRows() -> [PSRow] {
        guard let output = Shell.run("/bin/ps", ["-axo", "pid=,uid=,pcpu=,rss=,comm="], timeout: 2) else { return [] }
        return parsePS(output)
    }

    public static func parsePSForTesting(_ output: String) -> [(pid: Int32, uid: UInt32, cpu: Double, rss: UInt64, command: String)] {
        parsePS(output).map { ($0.pid, $0.uid, $0.cpu, $0.rss, $0.command) }
    }

    static func parsePS(_ output: String) -> [PSRow] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, let pid = Int32(parts[0]), let uid = UInt32(parts[1]),
                  let cpu = Double(parts[2]), let rss = UInt64(parts[3]) else { return nil }
            return PSRow(pid: pid, uid: uid, cpu: cpu, rss: rss * 1024, command: String(parts[4]))
        }
    }
}

/// Runs a command and returns stdout, or nil on failure or timeout.
public enum Shell {
    public static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        group.enter()
        nonisolated(unsafe) var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
