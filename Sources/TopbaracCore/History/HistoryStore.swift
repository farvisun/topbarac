import Foundation
import SQLite3

/// Averages a stream of (time, value) into fixed-width buckets aligned to the epoch.
public struct BucketAccumulator: Sendable {
    public let width: Int
    private var bucket: Int?
    private var sum = 0.0
    private var count = 0

    public init(width: Int) { self.width = width }

    /// Adds a value. Returns the previous bucket (start, average) when this value starts a new one.
    public mutating func add(_ value: Double, at time: Date) -> (start: Int, average: Double)? {
        let b = Int(time.timeIntervalSince1970) / width * width
        var completed: (Int, Double)?
        if let current = bucket, current != b {
            if count > 0 { completed = (current, sum / Double(count)) }
            sum = 0; count = 0
        }
        bucket = b
        sum += value
        count += 1
        return completed
    }

    /// Closes the open bucket (on quit).
    public mutating func drain() -> (start: Int, average: Double)? {
        guard let bucket, count > 0 else { return nil }
        defer { self.bucket = nil; sum = 0; count = 0 }
        return (bucket, sum / Double(count))
    }
}

/// Total CPU time and energy one app used over a period.
public struct AppUsage: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var cpuSeconds: Double
    public var energyJoules: Double
    public init(name: String, cpuSeconds: Double, energyJoules: Double) {
        self.name = name; self.cpuSeconds = cpuSeconds; self.energyJoules = energyJoules
    }
}

/// Opt-in on-disk history. Three tiers, each fed directly from live samples:
/// tier 0 = 10 s averages (kept 7 days), tier 1 = 1 min averages (kept 90 days), tier 2 = 10 min averages (kept for the
/// chosen retention, "forever" by default). Writes are batched once a minute.
public final class HistoryStore: @unchecked Sendable {
    public static let tiers: [(width: Int, keep: TimeInterval?)] = [(10, 7 * 86400), (60, 90 * 86400), (600, nil)]

    private let queue = DispatchQueue(label: "com.farvisun.topbarac.history", qos: .utility)
    private var db: OpaquePointer?
    private var accumulators: [SeriesKey: [BucketAccumulator]] = [:]
    private var pending: [(SeriesKey, Int, Int, Double)] = []   // series, tier, time, value
    /// Unflushed app usage per hourly bucket and app name: (cpu seconds, joules), added to the stored row on flush.
    private var pendingUsage: [UsageKey: (cpu: Double, energy: Double)] = [:]
    private struct UsageKey: Hashable { var bucket: Int; var name: String }
    public static let appUsageBucket = 3600
    private var lastFlush = Date()
    public let url: URL

    public init?(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
            CREATE TABLE IF NOT EXISTS samples (
              series TEXT NOT NULL, tier INTEGER NOT NULL, t INTEGER NOT NULL, v REAL NOT NULL,
              PRIMARY KEY (series, tier, t)) WITHOUT ROWID
            """)
        exec("""
            CREATE TABLE IF NOT EXISTS app_usage (
              bucket INTEGER NOT NULL, name TEXT NOT NULL, cpu_s REAL NOT NULL, energy_j REAL NOT NULL,
              PRIMARY KEY (bucket, name)) WITHOUT ROWID
            """)
    }

    deinit { sqlite3_close(db) }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Topbarac", isDirectory: true).appendingPathComponent("history.sqlite")
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    public func record(_ values: [SeriesKey: Double], at time: Date) {
        queue.async { [self] in
            for (key, value) in values where value.isFinite {
                var accs = accumulators[key] ?? Self.tiers.map { BucketAccumulator(width: $0.width) }
                for i in accs.indices {
                    if let done = accs[i].add(value, at: time) { pending.append((key, i, done.start, done.average)) }
                }
                accumulators[key] = accs
            }
            if time.timeIntervalSince(lastFlush) >= 60 { flushLocked() }
        }
    }

    /// Adds one process sample to the hourly per-app totals: CPU % × seconds becomes CPU seconds, watts × seconds
    /// becomes joules. Idle processes are skipped so the table holds apps that did something, not every daemon.
    /// `interval` is `SampleFrame.processInterval`. Written by the regular once-a-minute flush.
    public func recordAppUsage(_ processes: [ProcessSample], interval: TimeInterval, at time: Date) {
        guard interval > 0, interval.isFinite else { return }
        queue.async { [self] in
            let bucket = Int(time.timeIntervalSince1970) / Self.appUsageBucket * Self.appUsageBucket
            for p in processes {
                let energy = p.energyWatts.map { $0 * interval } ?? 0
                guard p.cpu >= 0.05 || energy > 0, p.cpu.isFinite, energy.isFinite else { continue }
                let key = UsageKey(bucket: bucket, name: p.name)
                let current = pendingUsage[key] ?? (0, 0)
                pendingUsage[key] = (current.cpu + max(0, p.cpu) / 100 * interval, current.energy + max(0, energy))
            }
            if time.timeIntervalSince(lastFlush) >= 60 { flushLocked() }
        }
    }

    /// Apps by CPU time since `since`, most first, including data not yet written.
    public func appUsage(since: Date, limit: Int) -> [AppUsage] {
        queue.sync { [self] in
            flushLocked()
            let sql = """
                SELECT name, SUM(cpu_s) AS cpu, SUM(energy_j) FROM app_usage WHERE bucket >= ?
                GROUP BY name ORDER BY cpu DESC, name LIMIT ?
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            // The bucket holding `since` counts: hourly rows can't be split.
            let first = Int64(since.timeIntervalSince1970) / Int64(Self.appUsageBucket) * Int64(Self.appUsageBucket)
            sqlite3_bind_int64(stmt, 1, first)
            sqlite3_bind_int64(stmt, 2, Int64(max(0, limit)))
            var out: [AppUsage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(AppUsage(name: String(cString: sqlite3_column_text(stmt, 0)),
                                    cpuSeconds: sqlite3_column_double(stmt, 1), energyJoules: sqlite3_column_double(stmt, 2)))
            }
            return out
        }
    }

    /// Writes everything buffered, including open buckets when `final` (app quitting or history turned off).
    public func flush(final: Bool = false) {
        queue.sync { [self] in
            if final {
                for (key, accs) in accumulators {
                    var accs = accs
                    for i in accs.indices { if let done = accs[i].drain() { pending.append((key, i, done.start, done.average)) } }
                    accumulators[key] = accs
                }
            }
            flushLocked()
        }
    }

    private func flushLocked() {
        lastFlush = Date()
        guard !pending.isEmpty || !pendingUsage.isEmpty else { return }
        exec("BEGIN")
        if !pendingUsage.isEmpty {
            var usage: OpaquePointer?
            let sql = """
                INSERT INTO app_usage (bucket, name, cpu_s, energy_j) VALUES (?, ?, ?, ?)
                ON CONFLICT(bucket, name) DO UPDATE SET cpu_s = cpu_s + excluded.cpu_s, energy_j = energy_j + excluded.energy_j
                """
            if sqlite3_prepare_v2(db, sql, -1, &usage, nil) == SQLITE_OK {
                for (key, value) in pendingUsage {
                    sqlite3_bind_int64(usage, 1, Int64(key.bucket))
                    sqlite3_bind_text(usage, 2, key.name, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_double(usage, 3, value.cpu)
                    sqlite3_bind_double(usage, 4, value.energy)
                    sqlite3_step(usage)
                    sqlite3_reset(usage)
                }
            }
            sqlite3_finalize(usage)
            pendingUsage.removeAll(keepingCapacity: true)
        }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO samples (series, tier, t, v) VALUES (?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK {
            for (key, tier, t, v) in pending {
                sqlite3_bind_text(stmt, 1, key.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 2, Int32(tier))
                sqlite3_bind_int64(stmt, 3, Int64(t))
                sqlite3_bind_double(stmt, 4, v)
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
        }
        sqlite3_finalize(stmt)
        exec("COMMIT")
        pending.removeAll(keepingCapacity: true)
    }

    /// Deletes rows older than each tier's limit and the user's retention.
    public func prune(retention: TimeInterval?, now: Date = Date()) {
        queue.async { [self] in
            for (i, tier) in Self.tiers.enumerated() {
                let limits = [tier.keep, retention].compactMap { $0 }
                guard let keep = limits.min() else { continue }
                let cutoff = Int64(now.timeIntervalSince1970 - keep)
                exec("DELETE FROM samples WHERE tier = \(i) AND t < \(cutoff)")
            }
            if let retention {
                exec("DELETE FROM app_usage WHERE bucket < \(Int64(now.timeIntervalSince1970 - retention))")
            }
        }
    }

    /// Points for a chart: picks the finest tier that still covers `since`, averages into at most `maxPoints`
    /// buckets and inserts gaps where data is missing for more than two buckets.
    public func query(_ key: SeriesKey, since: Date, until: Date = Date(), maxPoints: Int = 300) -> [SeriesPoint] {
        queue.sync { [self] in
            let span = until.timeIntervalSince(since)
            let tier = span <= 7 * 86400 ? 0 : (span <= 90 * 86400 ? 1 : 2)
            let bucket = max(Self.tiers[tier].width, Int(span) / max(1, maxPoints))
            let sql = """
                SELECT (t / \(bucket)) * \(bucket) AS b, AVG(v) FROM samples
                WHERE series = ? AND tier = ? AND t >= ? AND t <= ? GROUP BY b ORDER BY b
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(tier))
            sqlite3_bind_int64(stmt, 3, Int64(since.timeIntervalSince1970))
            sqlite3_bind_int64(stmt, 4, Int64(until.timeIntervalSince1970))
            var points: [SeriesPoint] = []
            var lastTime: Int64?
            while sqlite3_step(stmt) == SQLITE_ROW {
                let t = sqlite3_column_int64(stmt, 0)
                let v = sqlite3_column_double(stmt, 1)
                if let lastTime, t - lastTime > Int64(bucket * 2) {
                    points.append(SeriesPoint(time: Date(timeIntervalSince1970: TimeInterval(lastTime + Int64(bucket))), value: nil))
                }
                points.append(SeriesPoint(time: Date(timeIntervalSince1970: TimeInterval(t)), value: v))
                lastTime = t
            }
            return points
        }
    }

    /// Time of the oldest stored sample, for the "All" range.
    public func oldest() -> Date? {
        queue.sync { [self] in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT MIN(t) FROM samples", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 0)))
        }
    }

    public func sizeOnDisk() -> UInt64 {
        let fm = FileManager.default
        return [url.path, url.path + "-wal", url.path + "-shm"].reduce(0) { total, path in
            total + ((try? fm.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0)
        }
    }

    public func clear() {
        queue.sync { [self] in
            pending.removeAll()
            pendingUsage.removeAll()
            accumulators.removeAll()
            exec("DELETE FROM samples")
            exec("DELETE FROM app_usage")
            exec("VACUUM")
        }
    }

    /// CSV of the finest tier available for every series: `series,tier_seconds,time_iso8601,value`.
    public func exportCSV(to destination: URL) throws {
        try queue.sync { [self] in
            flushLocked()
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            handle.write("series,tier_seconds,time,value\n".data(using: .utf8)!)
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT series, tier, t, v FROM samples ORDER BY series, tier, t", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let iso = ISO8601DateFormatter()
            var buffer = ""
            while sqlite3_step(stmt) == SQLITE_ROW {
                let series = String(cString: sqlite3_column_text(stmt, 0))
                let tier = Int(sqlite3_column_int(stmt, 1))
                let t = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 2)))
                let v = sqlite3_column_double(stmt, 3)
                buffer += "\(series),\(Self.tiers[tier].width),\(iso.string(from: t)),\(v)\n"
                if buffer.utf8.count > 64_000 { handle.write(buffer.data(using: .utf8)!); buffer = "" }
            }
            handle.write(buffer.data(using: .utf8)!)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
