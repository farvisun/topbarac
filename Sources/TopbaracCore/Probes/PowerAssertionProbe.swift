import Darwin
import Foundation
import IOKit.pwr_mgt

/// One power assertion that keeps the Mac (or its display) awake.
public struct SleepBlocker: Sendable, Equatable, Identifiable {
    public var id: String
    public var pid: Int32
    public var processName: String
    public var reason: String
    public var kind: Kind
    public var since: Date?

    public enum Kind: String, Sendable {
        /// The Mac won't idle-sleep (the display may still turn off).
        case system
        /// The display stays on, which also keeps the Mac awake.
        case display
        /// Some other assertion type that still holds power (disk idle and the like).
        case other
    }

    public init(id: String, pid: Int32, processName: String, reason: String, kind: Kind, since: Date?) {
        self.id = id; self.pid = pid; self.processName = processName; self.reason = reason; self.kind = kind; self.since = since
    }
}

/// "What keeps my Mac awake", the same list `pmset -g assertions` prints under "Listed by owning process".
/// Uses the public `IOPMCopyAssertionsByProcess`, which any user process may call.
public enum PowerAssertionProbe {
    static let systemTypes: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion"]
    static let displayTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
    /// Assertions that exist for bookkeeping (user activity, push and update windows, powerd's own proxies) and
    /// don't keep the Mac awake on behalf of an app. Showing them would blame the wrong process.
    static let ignoredTypes: Set<String> = [
        "UserIsActive", "BackgroundTask", "ApplePushServiceTask", "InteractivePushServiceTask", "SoftwareUpdateTask",
        "NetworkClientActive", "PreventSystemSleepSecurityIndicator", "InternalPreventDisplaySleep",
        "InternalPreventSleep", "ExternalMedia", "SystemIsActive",
    ]
    /// powerd holds "prevent sleep while display is on" all day; the kernel holds USB and similar. Neither is
    /// something the user can act on.
    static let ignoredProcesses: Set<String> = ["powerd", "kernel_task"]

    public static func blockers() -> [SleepBlocker] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let raw = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var byProcess: [Int32: [[String: Any]]] = [:]
        for (pid, list) in raw { byProcess[pid.int32Value] = list }
        return parse(byProcess)
    }

    /// Turns the dictionary from `IOPMCopyAssertionsByProcess` into blockers: drops released and non-blocking
    /// assertions, merges duplicates (same process, kind and reason), and lists system/display blockers first,
    /// oldest first.
    public static func parse(_ byProcess: [Int32: [[String: Any]]]) -> [SleepBlocker] {
        var out: [SleepBlocker] = []
        var seen = Set<String>()
        for (pid, assertions) in byProcess where pid > 0 {
            let name = processName(pid: pid, reported: assertions.lazy.compactMap { $0["Process Name"] as? String }.first)
            guard !ignoredProcesses.contains(name) else { continue }
            for (index, a) in assertions.enumerated() {
                guard let type = a["AssertType"] as? String ?? a["AssertionTrueType"] as? String,
                      !ignoredTypes.contains(type) else { continue }
                // Level 0 means the assertion was released but the record lingers.
                if let level = (a["AssertLevel"] as? NSNumber)?.intValue, level == 0 { continue }
                let kind: SleepBlocker.Kind = systemTypes.contains(type) ? .system : displayTypes.contains(type) ? .display : .other
                let reason = [a["AssertName"], a["HumanReadableReason"], a["Details"]]
                    .lazy.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? type
                guard seen.insert("\(pid)|\(kind.rawValue)|\(reason)").inserted else { continue }
                let assertionID = (a["AssertionId"] as? NSNumber) ?? (a["GlobalUniqueID"] as? NSNumber)
                out.append(SleepBlocker(id: "\(pid)-\(assertionID.map { "\($0)" } ?? "i\(index)")", pid: pid,
                                        processName: name, reason: reason, kind: kind, since: a["AssertStartWhen"] as? Date))
            }
        }
        let rank: [SleepBlocker.Kind: Int] = [.display: 0, .system: 1, .other: 2]
        return out.sorted {
            if $0.kind != $1.kind { return rank[$0.kind]! < rank[$1.kind]! }
            return ($0.since ?? .distantFuture, $0.id) < ($1.since ?? .distantFuture, $1.id)
        }
    }

    /// The app name the user recognises: bundle name from the executable path, then what powerd recorded,
    /// then the kernel's short name.
    static func processName(pid: Int32, reported: String?) -> String {
        if let path = ProcessProbe.path(pid) { return ProcessProbe.displayName(fromPath: path) }
        if let reported, !reported.isEmpty { return reported }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "pid \(pid)" }
        return String(cBuffer: buffer)
    }
}

