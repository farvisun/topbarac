import AppKit
import SwiftUI
import TopbaracCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()

    private(set) var statusItems: StatusItemController?
    private var settingsWindow: WindowHost?
    private var processesWindow: WindowHost?
    private var processSort: ProcessSort = .cpu

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = MonitorStore.shared
        if Snapshotter.runIfRequested() { return }
        statusItems = StatusItemController()
        _ = AppUpdater.shared
        Notifier.shared.setUp()
        Notifier.shared.onOpen = { [weak self] kind in self?.statusItems?.open(kind) }
        observeSystem()
        if CommandLine.arguments.contains("--settings") { openSettings() }
        if let i = CommandLine.arguments.firstIndex(of: "--open"), i + 1 < CommandLine.arguments.count,
           let kind = WidgetKind(rawValue: CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.statusItems?.open(kind) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MonitorStore.shared.flushHistory()
    }

    /// Sleep, wake and clock changes leave a gap in the charts instead of a fake spike.
    private func observeSystem() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MonitorStore.shared.markGap() }
            }
        }
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MonitorStore.shared.markGap() }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MonitorStore.shared.refreshVolumes() }
            }
        }
    }

    func openSettings() {
        statusItems?.closePopover()
        if settingsWindow == nil {
            settingsWindow = WindowHost(title: "Topbarac Settings", autosave: "topbarac.settings", size: NSSize(width: 780, height: 600)) {
                AnyView(SettingsView().environment(MonitorStore.shared).environment(SettingsStore.shared))
            }
        }
        settingsWindow?.show()
    }

    func openProcesses(sort: ProcessSort) {
        statusItems?.closePopover()
        processSort = sort
        processesWindow?.close()
        processesWindow = WindowHost(title: "All Processes", autosave: "topbarac.processes", size: NSSize(width: 760, height: 520)) {
            AnyView(ProcessesWindow(sort: sort).environment(MonitorStore.shared).environment(SettingsStore.shared))
        }
        processesWindow?.show()
    }
}
