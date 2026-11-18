import Foundation
import Testing
@testable import TopbaracCore

@Suite struct AppUsageTests {
    func process(_ name: String, cpu: Double, watts: Double? = nil) -> ProcessSample {
        ProcessSample(pid: 1, name: name, path: nil, uid: 501, cpu: cpu, memory: 0, diskReadBps: 0, diskWriteBps: 0,
                      energyWatts: watts, isOwned: true)
    }

    @Test func recordsFlushesAndQueries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("topbarac-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(HistoryStore(url: dir.appendingPathComponent("h.sqlite")))
        let hour = Date(timeIntervalSince1970: 1_700_000_000 / 3600 * 3600)

        // 50 % for 30 s = 15 CPU seconds; 2 W for 30 s = 60 J. Twice in the same hour, once in the next.
        let frame = [process("Xcode", cpu: 50, watts: 2), process("Safari", cpu: 100), process("idle", cpu: 0.01)]
        store.recordAppUsage(frame, interval: 30, at: hour + 10)
        store.recordAppUsage(frame, interval: 30, at: hour + 40)
        store.flush()
        store.recordAppUsage([process("Xcode", cpu: 200)], interval: 30, at: hour + 3700)   // not flushed yet

        let all = store.appUsage(since: hour, limit: 10)
        #expect(all.map(\.name) == ["Xcode", "Safari"])
        #expect(all[0].cpuSeconds == 30 + 60 && all[0].energyJoules == 120)
        #expect(all[1].cpuSeconds == 60 && all[1].energyJoules == 0)
        #expect(store.appUsage(since: hour, limit: 1).count == 1)
        // Only the second hour.
        #expect(store.appUsage(since: hour + 3600, limit: 10) == [AppUsage(name: "Xcode", cpuSeconds: 60, energyJoules: 0)])

        store.prune(retention: 3600, now: hour + 3600 + 1800)
        #expect(store.appUsage(since: hour, limit: 10).map(\.name) == ["Xcode"])
        store.clear()
        #expect(store.appUsage(since: hour, limit: 10).isEmpty)
    }

    @Test func ignoresBadIntervals() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("topbarac-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(HistoryStore(url: dir.appendingPathComponent("h.sqlite")))
        store.recordAppUsage([process("Xcode", cpu: 50)], interval: 0, at: Date())
        store.recordAppUsage([process("Xcode", cpu: 50)], interval: .infinity, at: Date())
        #expect(store.appUsage(since: .distantPast, limit: 10).isEmpty)
    }
}
