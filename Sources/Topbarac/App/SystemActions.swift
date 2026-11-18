import AppKit
import TopbaracCore

/// Memory and disk tools. Nothing here deletes files on its own: emptying the Trash goes through Finder and asks first.
enum SystemActions {
    /// Runs `purge` with an administrator prompt. Returns bytes of memory freed (difference in free + cached pages).
    static func purgeMemory() async -> (ProcessActionResult, freed: UInt64) {
        let before = MonitorStore.shared.memory?.used ?? 0
        let result = await AdminScript.run("do shell script \"/usr/sbin/purge\" with administrator privileges")
        try? await Task.sleep(for: .seconds(1.5))
        let after = MonitorStore.shared.memory?.used ?? before
        return (result, before > after ? before - after : 0)
    }

    static func eject(_ volume: VolumeInfo) async -> ProcessActionResult {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: volume.path))
            MonitorStore.shared.refreshVolumes()
            return .done
        } catch {
            return .failed("Couldn't eject \(volume.name): \((error as NSError).localizedDescription)")
        }
    }

    static func open(_ volume: VolumeInfo) {
        NSWorkspace.shared.open(URL(fileURLWithPath: volume.path))
    }

    static var trashURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") }
    static var cachesURL: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }

    /// Allocated size of a folder. Nil when the folder can't be read (the Trash needs Full Disk Access).
    static func folderSize(_ url: URL) async -> UInt64? {
        await Task.detached(priority: .utility) { measureSync(url) }.value
    }

    nonisolated private static func measureSync(_ url: URL) -> UInt64? {
        let fm = FileManager.default
        guard (try? fm.contentsOfDirectory(atPath: url.path)) != nil else { return nil }
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return nil }
        var total: UInt64 = 0
        while let file = e.nextObject() as? URL {
            if let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true {
                total += UInt64(v.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// Empties the Trash through Finder (macOS asks for Automation permission the first time).
    static func emptyTrash() async -> ProcessActionResult {
        let result = await AdminlessScript.run("tell application \"Finder\" to empty trash")
        MonitorStore.shared.refreshVolumes()
        return result
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    static func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
}

enum AdminlessScript {
    static func run(_ source: String) async -> ProcessActionResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                    let message = code == -1743
                        ? "Topbarac isn't allowed to control Finder. Allow it in System Settings → Privacy & Security → Automation."
                        : (error[NSAppleScript.errorMessage] as? String ?? "Failed.")
                    continuation.resume(returning: .failed(message))
                } else {
                    continuation.resume(returning: .done)
                }
            }
        }
    }
}
