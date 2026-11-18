import Foundation
import Testing
@testable import TopbaracCore

@Suite struct StorageScannerTests {
    @Test func childrenAreMeasuredAndSorted() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("topbarac-storage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let big = root.appendingPathComponent("big", isDirectory: true)
        let nested = big.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: big.appendingPathComponent("a.bin"))
        try Data(count: 200_000).write(to: nested.appendingPathComponent("b.bin"))
        try Data(count: 100_000).write(to: root.appendingPathComponent("file.bin"))
        try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        // A link back to the root must not be followed (it would count everything twice, or loop).
        try fm.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)

        let items = await StorageScanner.children(of: root)
        #expect(items.map(\.name).prefix(2) == ["big", "file.bin"])
        let bigItem = try #require(items.first { $0.name == "big" })
        #expect(bigItem.isDirectory && bigItem.size >= 500_000 && bigItem.size < 1_000_000)
        let file = try #require(items.first { $0.name == "file.bin" })
        #expect(!file.isDirectory && file.size >= 100_000)
        let link = try #require(items.first { $0.name == "loop" })
        #expect(!link.isDirectory && link.size < 100_000)
        #expect(items.first { $0.name == "empty" }?.size == 0)
        #expect(StorageScanner.size(of: root.appendingPathComponent("missing")) == nil)
        #expect(await StorageScanner.children(of: root.appendingPathComponent("missing")).isEmpty)
    }

    @Test func knownLocationsHaveNotes() {
        #expect(StorageScanner.knownLocationPaths.allSatisfy { !$0.note.isEmpty && !$0.path.hasPrefix("/") })
        #expect(Set(StorageScanner.knownLocationPaths.map(\.path)).count == StorageScanner.knownLocationPaths.count)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TOPBARAC_LIVE"] == "1"))
struct LiveStorageScannerTests {
    @Test func scansKnownLocations() async {
        let start = Date()
        let items = await StorageScanner.knownLocations()
        print("storage", String(format: "%.1fs", Date().timeIntervalSince(start)),
              items.map { "\($0.name) \(Format.bytes($0.size))" })
        #expect(items.allSatisfy { $0.size > 0 && $0.note != nil })
        #expect(zip(items, items.dropFirst()).allSatisfy { $0.size >= $1.size })
    }
}
