import Foundation

/// A file or folder with its allocated size on disk.
public struct StorageItem: Sendable, Equatable, Identifiable {
    public var id: URL { url }
    public var url: URL
    public var name: String
    public var size: UInt64
    public var isDirectory: Bool
    /// Why this place tends to grow and whether it is safe to clear (known locations only).
    public var note: String?

    public init(url: URL, name: String, size: UInt64, isDirectory: Bool, note: String? = nil) {
        self.url = url; self.name = name; self.size = size; self.isDirectory = isDirectory; self.note = note
    }
}

/// "What is using my disk": folder sizes the way Finder's "Calculate all sizes" counts them (allocated bytes,
/// hard links and clones counted per file). Symlinks are not followed, so nothing is counted twice through a link
/// and a scan can't escape into another volume. Unreadable items (TCC-protected folders) are skipped silently.
public enum StorageScanner {
    static let concurrency = 4

    /// Direct children of `url`, biggest first. Folders are measured in parallel, a few at a time, because a
    /// single deep tree (DerivedData, node_modules) shouldn't hold up the rest and unbounded parallelism thrashes
    /// the disk.
    public static func children(of url: URL) async -> [StorageItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: []) else {
            return []
        }
        return await measure(entries.map { Target(url: $0, name: $0.lastPathComponent, note: nil) })
    }

    /// Caches and leftovers that commonly grow to many gigabytes. Only places that exist and aren't empty.
    public static func knownLocations() async -> [StorageItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = knownLocationPaths
            .map { Target(url: home.appendingPathComponent($0.path, isDirectory: true), name: $0.name, note: $0.note) }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
        return await measure(candidates).filter { $0.size > 0 }
    }

    /// Total allocated size of a file or folder tree, nil when it can't be read at all.
    public static func size(of url: URL) -> UInt64? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        if values.isSymbolicLink == true { return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) }
        guard values.isDirectory == true else { return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) }
        // Opening a directory we may not list (e.g. another app's container) yields nil; report that, not 0.
        guard (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil else { return nil }
        let fileKeys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: fileKeys, options: [],
                                                              errorHandler: { _, _ in true }) else { return nil }
        var total: UInt64 = 0
        for case let item as URL in enumerator {
            guard let v = try? item.resourceValues(forKeys: Set(fileKeys)) else { continue }
            // Directories themselves take a few KB; Finder ignores them too.
            if v.isRegularFile == true { total += UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0) }
        }
        return total
    }

    private struct Target: Sendable { var url: URL; var name: String; var note: String? }

    private static func measure(_ items: [Target]) async -> [StorageItem] {
        await withTaskGroup(of: StorageItem?.self) { group in
            var results: [StorageItem] = []
            var iterator = items.makeIterator()
            func addNext() -> Bool {
                guard let target = iterator.next() else { return false }
                group.addTask {
                    let url = target.url
                    guard let size = size(of: url) else { return nil }
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
                    return StorageItem(url: url, name: target.name, size: size, isDirectory: isDirectory, note: target.note)
                }
                return true
            }
            for _ in 0..<concurrency where addNext() {}
            while let next = await group.next() {
                if let next { results.append(next) }
                _ = addNext()
            }
            return results.sorted { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
        }
    }

    /// Paths relative to the home folder, the name to show (the last path component is often just "Data") and a
    /// one-line note. "Caches" overlaps the package caches listed before it on purpose: it answers a different
    /// question ("how much is cache in total").
    static let knownLocationPaths: [(path: String, name: String, note: String)] = [
        ("Library/Developer/Xcode/DerivedData", "Xcode DerivedData", "Xcode build products. Safe to delete; Xcode rebuilds them."),
        ("Library/Developer/Xcode/Archives", "Xcode Archives", "App archives from Product > Archive. Keep the ones you may need to resubmit."),
        ("Library/Developer/Xcode/iOS DeviceSupport", "iOS DeviceSupport", "Debug symbols per iOS version. Old versions are safe to delete."),
        ("Library/Developer/CoreSimulator/Devices", "Simulator devices", "Simulator devices and their apps. Remove unused ones in Xcode."),
        ("Library/Containers/com.docker.docker/Data", "Docker Desktop data", "Docker images, containers and volumes. Prune them in Docker."),
        ("Library/Caches/Homebrew", "Homebrew cache", "Homebrew downloads. Run brew cleanup."),
        (".npm", "npm cache", "npm package cache. Run npm cache clean --force."),
        ("Library/pnpm/store", "pnpm store", "pnpm package store. Run pnpm store prune."),
        ("Library/Caches/Yarn", "Yarn cache", "Yarn package cache. Run yarn cache clean."),
        ("Library/Caches/pip", "pip cache", "pip package cache. Run pip cache purge."),
        (".gradle/caches", "Gradle caches", "Gradle build and dependency caches. Rebuilt when needed."),
        ("Library/Caches/CocoaPods", "CocoaPods cache", "CocoaPods spec and pod cache. Run pod cache clean --all."),
        ("Library/Caches", "Caches", "App caches. Apps recreate them, but quit apps before clearing."),
        ("Downloads", "Downloads", "Your downloads. Old installers and archives add up."),
        (".Trash", "Trash", "Items in the Trash still use space until you empty it."),
        ("Library/Containers/com.apple.mail/Data/Library/Mail Downloads", "Mail downloads", "Attachments Mail opened. Safe to delete."),
        ("Library/Application Support/MobileSync/Backup", "iOS backups", "iPhone and iPad backups. Manage them in Finder."),
    ]
}
