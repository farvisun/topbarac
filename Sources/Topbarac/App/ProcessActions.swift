import AppKit
import TopbaracCore

enum ProcessSort: String, CaseIterable, Identifiable {
    case cpu, memory, disk, network, energy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .energy: "Energy"
        }
    }

    static func `for`(_ kind: WidgetKind) -> ProcessSort {
        switch kind {
        case .cpu, .temperature, .gpu: .cpu
        case .memory: .memory
        case .disk: .disk
        case .network: .network
        case .battery: .energy
        }
    }

    func value(_ p: ProcessSample) -> Double {
        switch self {
        case .cpu: p.cpu
        case .memory: Double(p.memory)
        case .disk: p.diskReadBps + p.diskWriteBps
        case .network: p.netInBps + p.netOutBps
        // Energy is only measurable for your own processes; others sink to the bottom instead of mixing units.
        case .energy: p.energyWatts ?? -1
        }
    }

    func format(_ p: ProcessSample, bits: Bool) -> String {
        switch self {
        case .cpu: String(format: p.cpu < 10 ? "%.1f%%" : "%.0f%%", p.cpu)
        case .memory: Format.memory(p.memory)
        case .disk: Format.rate(p.diskReadBps + p.diskWriteBps)
        case .network: Format.rate(p.netInBps + p.netOutBps, bits: bits)
        case .energy: p.energyWatts.map { Format.watts($0) } ?? "—"
        }
    }
}

enum ProcessActionResult: Equatable {
    case done
    case needsAdmin
    case failed(String)
}

/// Quit, force quit and kill processes. System-critical processes are protected.
enum ProcessActions {
    static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "logind", "opendirectoryd", "securityd", "configd",
        "powerd", "mds", "coreservicesd", "SystemUIServer", "Dock", "Finder", "Topbarac", "fseventsd", "diskarbitrationd",
    ]

    static func isProtected(_ p: ProcessSample) -> Bool {
        guard SettingsStore.shared.settings.protectSystemProcesses else { return p.pid <= 1 || p.pid == getpid() }
        return p.pid <= 1 || p.pid == getpid() || protectedNames.contains(p.name)
    }

    static func app(for pid: Int32) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited || app.bundleURL != nil else { return nil }
        return app
    }

    /// Polite quit: asks a GUI app to quit (it may ask to save documents); sends SIGTERM to anything else.
    @discardableResult
    static func quit(pid: Int32) -> ProcessActionResult {
        if let app = NSRunningApplication(processIdentifier: pid), app.bundleURL != nil, app.activationPolicy == .regular {
            return app.terminate() ? .done : .failed("\(app.localizedName ?? "The app") didn't quit.")
        }
        return signal(pid, SIGTERM)
    }

    @discardableResult
    static func forceQuit(pid: Int32) -> ProcessActionResult {
        if let app = NSRunningApplication(processIdentifier: pid), app.bundleURL != nil, app.activationPolicy == .regular {
            return app.forceTerminate() ? .done : signal(pid, SIGKILL)
        }
        return signal(pid, SIGKILL)
    }

    private static func signal(_ pid: Int32, _ sig: Int32) -> ProcessActionResult {
        if kill(pid, sig) == 0 { return .done }
        return errno == EPERM ? .needsAdmin : .failed(String(cString: strerror(errno)))
    }

    /// Kills a process owned by another user after an administrator password prompt.
    static func killAsAdmin(pid: Int32, force: Bool) async -> ProcessActionResult {
        let script = "do shell script \"/bin/kill -\(force ? 9 : 15) \(pid)\" with administrator privileges"
        return await AdminScript.run(script)
    }

    static func reveal(_ p: ProcessSample) {
        guard let path = p.path else { return }
        let url = URL(fileURLWithPath: path)
        // Reveal the .app bundle rather than the binary inside it.
        var bundle = url
        while bundle.pathComponents.count > 1 && bundle.pathExtension != "app" { bundle.deleteLastPathComponent() }
        NSWorkspace.shared.activateFileViewerSelecting([bundle.pathExtension == "app" ? bundle : url])
    }

    static func openActivityMonitor() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func copyPID(_ p: ProcessSample) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(p.pid), forType: .string)
    }

    /// Top process from `ps` (no warm-up sample needed), used to name the culprit in alerts.
    static func topProcess(by sort: ProcessSort) -> ProcessSample? {
        guard let out = Shell.run("/bin/ps", ["-axo", "pid=,uid=,pcpu=,rss=,comm="], timeout: 2) else { return nil }
        let rows = ProcessProbe.parsePSForTesting(out)
        let best = sort == .memory ? rows.max { $0.rss < $1.rss } : rows.max { $0.cpu < $1.cpu }
        guard let row = best else { return nil }
        let name = NSRunningApplication(processIdentifier: row.pid)?.localizedName ?? ProcessProbe.displayName(fromPath: row.command)
        return ProcessSample(pid: row.pid, name: name, path: row.command, uid: row.uid, cpu: row.cpu, memory: row.rss,
                             diskReadBps: 0, diskWriteBps: 0, energyWatts: nil, isOwned: row.uid == getuid())
    }
}

/// Runs AppleScript off the main thread (the admin prompt is modal for the script, not for the app).
enum AdminScript {
    static func run(_ source: String) async -> ProcessActionResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                _ = script?.executeAndReturnError(&error)
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                    // -128: the user cancelled the password prompt.
                    continuation.resume(returning: code == -128 ? .failed("Cancelled.") : .failed(error[NSAppleScript.errorMessage] as? String ?? "Failed."))
                } else {
                    continuation.resume(returning: .done)
                }
            }
        }
    }
}

/// Small cache of process icons keyed by pid and path.
enum ProcessIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for p: ProcessSample) -> NSImage {
        let key = "\(p.pid):\(p.path ?? p.name)"
        if let cached = cache[key] { return cached }
        let image: NSImage
        if let app = NSRunningApplication(processIdentifier: p.pid), let icon = app.icon {
            image = icon
        } else if let path = p.path, let range = path.range(of: ".app/") {
            image = NSWorkspace.shared.icon(forFile: String(path[..<range.lowerBound]) + ".app")
        } else {
            image = NSWorkspace.shared.icon(for: .unixExecutable)
        }
        if cache.count > 500 { cache.removeAll() }
        cache[key] = image
        return image
    }

    static func displayName(for p: ProcessSample) -> String {
        NSRunningApplication(processIdentifier: p.pid)?.localizedName ?? p.name
    }
}
