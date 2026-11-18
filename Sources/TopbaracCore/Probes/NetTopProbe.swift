import Foundation

public enum NetTopParser {
    /// Parses `nettop -P -d -x -J bytes_in,bytes_out` CSV. Two samples come back; the second is the delta over the
    /// sample interval. Rows look like `Google Chrome H.1220,1234,567,`. Returns pid → (in, out) bytes of the last block.
    public static func parse(_ output: String, seconds: Double) -> [Int32: (Double, Double)] {
        var blocks: [[Int32: (Double, Double)]] = []
        var current: [Int32: (Double, Double)]?
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix(",") || line.hasPrefix("time,") {   // header starts a new sample block
                if let current { blocks.append(current) }
                current = [:]
                continue
            }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."),
                  let pid = Int32(fields[0][fields[0].index(after: dot)...]),
                  let bytesIn = Double(fields[1]), let bytesOut = Double(fields[2]) else { continue }
            current?[pid] = (bytesIn / seconds, bytesOut / seconds)
        }
        if let current { blocks.append(current) }
        return blocks.last ?? [:]
    }
}

/// Per-process network rates from one long-running `nettop` (it needs seconds to start, so it is not run per sample).
/// Streams cumulative byte counts every two seconds while the Network popover is open; rates are the difference
/// between consecutive blocks.
final class NetTopProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [Int32: (Double, Double)] = [:]
    private var process: Process?
    private var buffer = ""
    private var block: [Int32: (Double, Double)] = [:]
    private var previousBlock: [Int32: (Double, Double)]?
    private var previousBlockTime: TimeInterval = 0
    private let interval = 2

    var rates: [Int32: (Double, Double)] { lock.withLock { latest } }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard process == nil else { return }
        let p = Process()
        // Through `script` so nettop sees a terminal and writes each line at once (into a pipe it buffers 4 KB).
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", "/usr/bin/nettop", "-P", "-x", "-L", "0", "-s", String(interval), "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.consume(text)
        }
        do { try p.run(); process = p } catch { pipe.fileHandleForReading.readabilityHandler = nil }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let process {
            (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
        }
        process = nil
        buffer = ""
        block = [:]
        previousBlock = nil
        latest = [:]
    }

    private func consume(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        // The pty ends lines with CRLF, which Swift treats as one Character; drop the CR so "\n" matches.
        buffer += text.replacingOccurrences(of: "\r", with: "")
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.contains("bytes_in") {   // header (the first one may carry terminal control characters)
                finishBlock()
                continue
            }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."),
                  let pid = Int32(fields[0][fields[0].index(after: dot)...]),
                  let bytesIn = Double(fields[1]), let bytesOut = Double(fields[2]) else { continue }
            block[pid] = (bytesIn, bytesOut)
        }
    }

    /// A header line starts a new block, so the block collected so far is complete.
    private func finishBlock() {
        defer { block = [:] }
        guard !block.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let previousBlock {
            let seconds = max(0.5, now - previousBlockTime)
            latest = NetTopParser.rates(previous: previousBlock, current: block, seconds: seconds)
        }
        previousBlock = block
        previousBlockTime = now
    }
}

extension NetTopParser {
    /// Byte rates per pid between two cumulative blocks. A counter that went backwards counts from zero.
    public static func rates(previous: [Int32: (Double, Double)], current: [Int32: (Double, Double)], seconds: Double)
        -> [Int32: (Double, Double)] {
        var out: [Int32: (Double, Double)] = [:]
        for (pid, b) in current {
            let a = previous[pid] ?? b
            let dIn = b.0 >= a.0 ? b.0 - a.0 : b.0
            let dOut = b.1 >= a.1 ? b.1 - a.1 : b.1
            out[pid] = (dIn / seconds, dOut / seconds)
        }
        return out
    }
}
