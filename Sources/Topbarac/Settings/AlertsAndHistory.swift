import AppKit
import SwiftUI
import TopbaracCore
import UniformTypeIdentifiers
import UserNotifications

// MARK: Alerts

struct AlertsPane: View {
    @Environment(SettingsStore.self) private var settings
    @State private var editing: AlertRule?
    @State private var isNew = false
    @State private var permission: UNAuthorizationStatus = .notDetermined

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Alerts", isOn: $settings.settings.alertsEnabled)
                HStack {
                    Text("Notifications")
                    Spacer()
                    switch permission {
                    case .authorized, .provisional:
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .denied:
                        Button("Allow in System Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    default:
                        Button("Allow Notifications") { Task { _ = await Notifier.shared.requestPermission(); await refreshPermission() } }
                    }
                }
            } footer: {
                Text("A rule fires when its condition holds for the whole duration, then waits for the cooldown before it can fire again. CPU and memory alerts name the process to blame and offer to quit it.")
            }
            Section {
                if settings.settings.alertRules.isEmpty {
                    Text("No rules yet.").foregroundStyle(.secondary)
                }
                ForEach(settings.settings.alertRules) { rule in
                    HStack(spacing: 10) {
                        WidgetIcon(kind: rule.metric.widget, size: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.summary)
                            Text("Cooldown \(Format.duration(rule.cooldown))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { isNew = false; editing = rule }.buttonStyle(.link)
                        Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in
                            if let i = settings.settings.alertRules.firstIndex(where: { $0.id == rule.id }) { settings.settings.alertRules[i].enabled = on }
                        }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    .contextMenu {
                        Button("Edit") { isNew = false; editing = rule }
                        Button("Delete", role: .destructive) { settings.settings.alertRules.removeAll { $0.id == rule.id } }
                    }
                }
            } header: {
                HStack {
                    Text("Rules")
                    Spacer()
                    Button {
                        isNew = true
                        editing = AlertRule(metric: .cpuUsage, comparison: .above, threshold: 90, duration: 60)
                    } label: { Label("Add Rule", systemImage: "plus") }
                    .buttonStyle(.glass).controlSize(.small)
                }
            }
            Section {
                Button("Restore Default Rules") { settings.settings.alertRules = AlertRule.defaults }
            }
        }
        .formStyle(.grouped)
        .disabled(false)
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule, isNew: isNew) { saved in
                if let i = settings.settings.alertRules.firstIndex(where: { $0.id == saved.id }) {
                    settings.settings.alertRules[i] = saved
                } else {
                    settings.settings.alertRules.append(saved)
                }
            } onDelete: { id in
                settings.settings.alertRules.removeAll { $0.id == id }
            }
        }
        .task { await refreshPermission() }
    }

    private func refreshPermission() async { permission = await Notifier.shared.authorizationStatus() }
}

struct RuleEditor: View {
    @State var rule: AlertRule
    var isNew: Bool
    var onSave: (AlertRule) -> Void
    var onDelete: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isNew ? "New Alert Rule" : "Edit Alert Rule").font(.headline)
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            Form {
                Picker("When", selection: $rule.metric) {
                    ForEach(AlertMetric.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: rule.metric) { _, m in applyDefaults(for: m) }
                if rule.metric == .memoryPressure {
                    LabeledContent("Is", value: "Critical")
                } else {
                    Picker("Is", selection: $rule.comparison) {
                        Text("Above").tag(Comparison.above)
                        Text("Below").tag(Comparison.below)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Threshold") {
                        HStack {
                            TextField("", value: $rule.threshold, format: .number.precision(.fractionLength(0...1)))
                                .multilineTextAlignment(.trailing).frame(width: 80)
                            Text(rule.metric.unit).foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("For at least", selection: $rule.duration) {
                    ForEach([5.0, 15, 30, 60, 120, 300, 600], id: \.self) { Text(label($0)).tag($0) }
                }
                Picker("Then wait", selection: $rule.cooldown) {
                    ForEach([60.0, 300, 600, 1800, 3600, 4 * 3600], id: \.self) { Text(Format.duration($0)).tag($0) }
                }
                Toggle("Enabled", isOn: $rule.enabled)
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button("Delete Rule", role: .destructive) { onDelete(rule.id); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Rule" : "Save") { onSave(rule); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
            .padding(20)
        }
        .frame(width: 460)
    }

    private func label(_ seconds: Double) -> String { seconds < 60 ? "\(Int(seconds)) seconds" : Format.duration(seconds) }

    private func applyDefaults(for metric: AlertMetric) {
        switch metric {
        case .cpuUsage, .gpuUsage: rule.comparison = .above; rule.threshold = 90
        case .memoryUsage: rule.comparison = .above; rule.threshold = 90
        case .memoryPressure: rule.comparison = .above; rule.threshold = 1.5
        case .diskFree: rule.comparison = .below; rule.threshold = 10
        case .temperature: rule.comparison = .above; rule.threshold = 95
        case .batteryLevel: rule.comparison = .below; rule.threshold = 15
        case .networkDown: rule.comparison = .above; rule.threshold = 50
        }
    }
}

// MARK: History

struct HistoryPane: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(MonitorStore.self) private var store
    @State private var size: UInt64 = 0
    @State private var oldest: Date?
    @State private var message: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Keep history on disk", isOn: $settings.settings.historyEnabled)
            } footer: {
                Text("Off by default. Without it, charts keep the last hour in memory and forget it when Topbarac quits. With it, averages of the widgets you have turned on are saved on this Mac only, so charts can show days, months or everything since you turned it on. Nothing ever leaves your Mac.")
            }
            if settings.settings.historyEnabled {
                Section("Storage") {
                    Picker("Keep", selection: $settings.settings.historyRetention) {
                        ForEach(HistoryRetention.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Detail", value: "10 s for 7 days, 1 min for 90 days, 10 min after that")
                    LabeledContent("Recording since", value: oldest.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Just started")
                    LabeledContent("Size on disk", value: Format.bytes(size))
                    LabeledContent("Location") {
                        Button("Show in Finder") { SystemActions.reveal(HistoryStore.defaultURL) }.buttonStyle(.link)
                    }
                }
                Section {
                    HStack {
                        Button("Export CSV…") { export() }
                        Spacer()
                        Button("Clear History…", role: .destructive) { clear() }
                    }
                    if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: settings.settings.historyEnabled) { await refresh() }
    }

    private func refresh() async {
        guard let h = store.historyStore else { size = 0; oldest = nil; return }
        let result = await Task.detached { (h.sizeOnDisk(), h.oldest()) }.value
        size = result.0
        oldest = result.1
    }

    private func export() {
        guard let h = store.historyStore else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Topbarac history \(Date().formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await Task.detached { try h.exportCSV(to: url) }.value
                message = "Exported to \(url.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                message = "Couldn't export: \(error.localizedDescription)"
            }
        }
    }

    private func clear() {
        let alert = NSAlert()
        alert.messageText = "Clear all saved history?"
        alert.informativeText = "Every saved sample is deleted. This can't be undone. Recording continues."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn, let h = store.historyStore else { return }
        Task {
            await Task.detached { h.clear() }.value
            message = "History cleared."
            await refresh()
        }
    }
}

// MARK: About

struct AboutPane: View {
    @State private var autoUpdate = AppUpdater.shared.automaticallyChecks

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Topbarac").font(.title2.weight(.semibold))
                        Text("Version \(AppInfo.version) (\(AppInfo.build))").foregroundStyle(.secondary)
                        Text("Your whole Mac, one glance up.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) { _, v in AppUpdater.shared.automaticallyChecks = v }
                    .disabled(!AppUpdater.isAvailable)
                Button("Check Now") { AppUpdater.shared.checkNow() }.disabled(!AppUpdater.shared.canCheck)
            }
            Section {
                LabeledContent("Network", value: "Only the update check, once a day")
                LabeledContent("Data", value: "Stays on this Mac")
                LabeledContent("Permissions", value: "No root, no helper")
            } header: {
                Text("Privacy")
            } footer: {
                Text("Topbarac reads system counters and sensors. History is saved only if you turn it on. Admin prompts appear only when you ask to free memory or stop another user's process.")
            }
            Section {
                Link("Website", destination: URL(string: "https://farvisun.github.io/topbarac/")!)
                Link("Source code", destination: URL(string: "https://github.com/farvisun/topbarac")!)
                Link("Report an issue", destination: URL(string: "https://github.com/farvisun/topbarac/issues")!)
            }
        }
        .formStyle(.grouped)
    }
}

enum AppInfo {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0" }
}
