import Foundation
import Testing
@testable import TopbaracCore

@Suite struct SleepBlockerTests {
    // Pids far above any real one, so the name comes from the dictionary instead of the live process table.
    @Test func keepsRealBlockersAndDropsNoise() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let input: [Int32: [[String: Any]]] = [
            900_001: [["AssertType": "PreventUserIdleSystemSleep", "AssertName": "caffeinate command-line tool",
                       "Process Name": "caffeinate", "AssertionId": NSNumber(value: 11), "AssertLevel": NSNumber(value: 255),
                       "AssertStartWhen": start]],
            900_002: [["AssertType": "PreventUserIdleDisplaySleep", "AssertName": "Video Wake Lock",
                       "Process Name": "Safari", "AssertionId": NSNumber(value: 12), "AssertStartWhen": start + 60],
                      // Same reason twice (two tabs) shows once.
                      ["AssertType": "PreventUserIdleDisplaySleep", "AssertName": "Video Wake Lock",
                       "Process Name": "Safari", "AssertionId": NSNumber(value: 13)],
                      ["AssertType": "UserIsActive", "AssertName": "tickle", "Process Name": "Safari"]],
            900_003: [["AssertType": "PreventUserIdleSystemSleep", "AssertName": "Powerd - Prevent sleep while display is on",
                       "Process Name": "powerd"]],
            900_004: [["AssertType": "BackgroundTask", "AssertName": "backup", "Process Name": "backupd"],
                      ["AssertType": "ApplePushServiceTask", "AssertName": "push", "Process Name": "backupd"]],
            900_005: [["AssertType": "PreventDiskIdle", "HumanReadableReason": "Copying files", "Process Name": "Finder"]],
            900_006: [["AssertType": "NoIdleSleepAssertion", "AssertName": "released", "AssertLevel": NSNumber(value: 0),
                       "Process Name": "Old"]],
        ]
        let blockers = PowerAssertionProbe.parse(input)
        #expect(blockers.map(\.processName) == ["Safari", "caffeinate", "Finder"])
        #expect(blockers.map(\.kind) == [.display, .system, .other])
        #expect(blockers[0].reason == "Video Wake Lock" && blockers[0].id == "900002-12" && blockers[0].since == start + 60)
        #expect(blockers[1].pid == 900_001 && blockers[1].since == start)
        #expect(blockers[2].reason == "Copying files" && blockers[2].since == nil)
    }

    @Test func emptyInputIsEmpty() {
        #expect(PowerAssertionProbe.parse([:]).isEmpty)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TOPBARAC_LIVE"] == "1"))
struct LiveSleepBlockerTests {
    @Test func listsBlockers() {
        let blockers = PowerAssertionProbe.blockers()
        print("blockers", blockers.map { "\($0.processName) [\($0.kind.rawValue)] \($0.reason)" })
        #expect(!blockers.contains { $0.processName == "powerd" })
    }
}
