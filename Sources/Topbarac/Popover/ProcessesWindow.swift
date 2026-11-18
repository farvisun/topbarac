import SwiftUI
import TopbaracCore

/// "Show All" window: every process (helpers folded into their app), searchable and sortable, with actions.
struct ProcessesWindow: View {
    @State var sort: ProcessSort
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @State private var search = ""
    @State private var selection: Int32?
    @State private var toasts = ToastCenter()
    @State private var confirmForce = false
    @State private var order: [KeyPathComparator<ProcessRowModel>] = []
    /// nil = live table; otherwise how far back the usage history goes.
    @State private var usageDays: Int?

    private var rows: [ProcessRowModel] {
        let filtered = search.isEmpty ? store.processes : store.processes.filter {
            ProcessIcons.displayName(for: $0).localizedCaseInsensitiveContains(search) || String($0.pid).hasPrefix(search)
        }
        let comparators = order.isEmpty ? [ProcessRowModel.comparator(sort)] : order
        return filtered.map { p in
            let members = p.members.map { ProcessRowModel($0, name: $0.name) }.sorted(using: comparators)
            return ProcessRowModel(p, name: ProcessIcons.displayName(for: p), children: members.isEmpty ? nil : members)
        }
        .sorted(using: comparators)
    }

    private var selected: ProcessSample? { store.processes.first { $0.pid == selection } }

    var body: some View {
        let bits = settings.settings.networkUnit == .bits
        let rows = self.rows
        VStack(spacing: 0) {
            if let usageDays {
                AppUsageList(days: usageDays)
            } else if store.processes.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading processes…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                Table(rows, children: \.children, selection: $selection, sortOrder: $order) {
                    TableColumn("Name", value: \.name) { row in
                        HStack(spacing: 7) {
                            Image(nsImage: ProcessIcons.icon(for: row.sample)).resizable().frame(width: 16, height: 16)
                            Text(row.name).lineLimit(1).truncationMode(.middle)
                            if row.sample.groupCount > 1 {
                                Text("×\(row.sample.groupCount)").font(.caption2).foregroundStyle(.secondary)
                            }
                            if !row.sample.isOwned {
                                Image(systemName: "person.badge.key").font(.caption2).foregroundStyle(.tertiary).help("Runs as another user")
                            }
                        }
                        .contextMenu { contextMenu(row.sample) }
                    }
                    .width(min: 180, ideal: 240)
                    TableColumn("Last minute") { row in
                        ProcessSparkline(values: store.cpuTrail(row.id))
                    }
                    .width(min: 70, ideal: 80, max: 110)
                    TableColumn("CPU", value: \.cpu) { row in metric(ProcessSort.cpu.format(row.sample, bits: bits), .cpu) }
                        .width(min: 54, ideal: 62).alignment(.trailing)
                    TableColumn("Memory", value: \.memory) { row in metric(ProcessSort.memory.format(row.sample, bits: bits), .memory) }
                        .width(min: 64, ideal: 74).alignment(.trailing)
                    TableColumn("Energy", value: \.energy) { row in metric(ProcessSort.energy.format(row.sample, bits: bits), .energy) }
                        .width(min: 54, ideal: 62).alignment(.trailing)
                    TableColumn("Disk", value: \.disk) { row in metric(ProcessSort.disk.format(row.sample, bits: bits), .disk) }
                        .width(min: 64, ideal: 76).alignment(.trailing)
                    TableColumn("Network", value: \.network) { row in metric(ProcessSort.network.format(row.sample, bits: bits), .network) }
                        .width(min: 64, ideal: 76).alignment(.trailing)
                    TableColumn("PID", value: \.pid) { row in
                        Text(String(row.pid)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 44, ideal: 54).alignment(.trailing)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .onChange(of: order) { _, new in
                    if let first = new.first, let s = ProcessRowModel.sort(for: first) { sort = s }
                }
            }
            if confirmForce, let p = selected {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("Force quit \(ProcessIcons.displayName(for: p))? Unsaved work will be lost.")
                    Spacer()
                    Button("Cancel") { confirmForce = false }
                    Button("Force Quit") { forceQuit(p) }.buttonStyle(.glassProminent).tint(.red)
                }
                .padding(10)
                .background(.yellow.opacity(0.08))
            }
            StatusFooter(count: store.processes.reduce(0) { $0 + $1.groupCount }, apps: store.processes.count)
        }
        .overlay(alignment: .bottom) {
            if let toast = toasts.current { ToastView(toast: toast).padding(.bottom, 36) }
        }
        .animation(.smooth(duration: 0.25), value: toasts.current)
        .searchable(text: $search, placement: .toolbar, prompt: "Search processes")
        .toolbar {
            if settings.settings.historyEnabled {
                ToolbarItem(placement: .navigation) {
                    Picker("Show", selection: $usageDays) {
                        Text("Now").tag(Int?.none)
                        Text("Today").tag(Int?.some(1))
                        Text("7 Days").tag(Int?.some(7))
                        Text("30 Days").tag(Int?.some(30))
                    }
                    .pickerStyle(.segmented)
                    .help("Live processes, or which apps used the most CPU and energy over time")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    if let p = selected { quit(p) }
                } label: { Label("Quit", systemImage: "xmark.circle") }
                    .disabled(selected.map(ProcessActions.isProtected) ?? true)
                    .help("Quit the selected process")
                Button {
                    confirmForce = true
                } label: { Label("Force Quit", systemImage: "bolt.horizontal.circle") }
                    .disabled(selected.map(ProcessActions.isProtected) ?? true)
                    .help("Force quit the selected process")
                Button {
                    if let p = selected { ProcessActions.reveal(p) }
                } label: { Label("Show in Finder", systemImage: "folder") }
                    .disabled(selected?.path == nil)
                    .help("Show the selected app in Finder")
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .environment(toasts)
        .onAppear {
            order = [ProcessRowModel.comparator(sort)]
            store.setProcessWindow(open: true)
        }
        .onDisappear { store.setProcessWindow(open: false) }
    }

    private func metric(_ text: String, _ column: ProcessSort) -> some View {
        Text(text).monospacedDigit()
            .fontWeight(column == sort ? .semibold : .regular)
            .foregroundStyle(column == sort ? .primary : .secondary)
    }

    @ViewBuilder
    private func contextMenu(_ p: ProcessSample) -> some View {
        if !ProcessActions.isProtected(p) {
            Button("Quit") { quit(p) }
            Button("Force Quit…") { selection = p.pid; confirmForce = true }
            Divider()
        }
        Button("Show in Finder") { ProcessActions.reveal(p) }.disabled(p.path == nil)
        Button("Copy PID") { ProcessActions.copyPID(p) }
    }

    private func quit(_ p: ProcessSample) {
        let name = ProcessIcons.displayName(for: p)
        let result = ProcessActions.quit(pid: p.pid)
        if result == .needsAdmin {
            Task { toasts.show(await ProcessActions.killAsAdmin(pid: p.pid, force: false), success: "Terminated \(name)") }
        } else {
            toasts.show(result, success: "Asked \(name) to quit")
        }
    }

    private func forceQuit(_ p: ProcessSample) {
        confirmForce = false
        let name = ProcessIcons.displayName(for: p)
        let result = ProcessActions.forceQuit(pid: p.pid)
        if result == .needsAdmin {
            Task { toasts.show(await ProcessActions.killAsAdmin(pid: p.pid, force: true), success: "Killed \(name)") }
        } else {
            toasts.show(result, success: "Force quit \(name)")
        }
    }
}

/// Table row: flattened, comparable values for sortable columns.
nonisolated struct ProcessRowModel: Identifiable, Sendable {
    var sample: ProcessSample
    var id: Int32 { sample.pid }
    var pid: Int32 { sample.pid }
    var name: String
    var cpu: Double { sample.cpu }
    var memory: UInt64 { sample.memory }
    var energy: Double { sample.energyWatts ?? -1 }
    var disk: Double { sample.diskReadBps + sample.diskWriteBps }
    var network: Double { sample.netInBps + sample.netOutBps }
    /// Helper processes folded into this app, shown as an expandable tree.
    var children: [ProcessRowModel]?

    init(_ sample: ProcessSample, name: String, children: [ProcessRowModel]? = nil) {
        self.sample = sample
        self.name = name
        self.children = children
    }

    static func comparator(_ sort: ProcessSort) -> KeyPathComparator<ProcessRowModel> {
        switch sort {
        case .cpu: KeyPathComparator(\.cpu, order: .reverse)
        case .memory: KeyPathComparator(\.memory, order: .reverse)
        case .disk: KeyPathComparator(\.disk, order: .reverse)
        case .network: KeyPathComparator(\.network, order: .reverse)
        case .energy: KeyPathComparator(\.energy, order: .reverse)
        }
    }

    static func sort(for comparator: KeyPathComparator<ProcessRowModel>) -> ProcessSort? {
        ProcessSort.allCases.first { comparator.keyPath == Self.comparator($0).keyPath }
    }
}

/// CPU over the last minute for one row (scaled to its own peak, at least one full core).
struct ProcessSparkline: View {
    var values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let peak = max(100, values.max() ?? 100)
            var path = Path()
            for (i, v) in values.enumerated() {
                let point = CGPoint(x: CGFloat(i) / CGFloat(max(1, values.count - 1)) * size.width,
                                    y: size.height - CGFloat(v / peak) * (size.height - 2) - 1)
                i == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            context.stroke(path, with: .color(WidgetKind.cpu.accent), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

/// Bottom bar: totals so the table has context.
private struct StatusFooter: View {
    var count: Int
    var apps: Int
    @Environment(MonitorStore.self) private var store

    var body: some View {
        HStack(spacing: 14) {
            Text("\(count) processes in \(apps) rows (helpers folded into their app)")
            Spacer()
            if let c = store.cpu { Label(Format.percent(c.usage), systemImage: "cpu") }
            if let m = store.memory { Label("\(Format.memory(m.used)) of \(Format.memory(m.total))", systemImage: "memorychip") }
        }
        .font(.system(size: 11)).monospacedDigit()
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Which apps used the most CPU time and energy over the last day(s), from the on-disk history.
private struct AppUsageList: View {
    var days: Int
    @Environment(MonitorStore.self) private var store
    @State private var rows: [AppUsage]?

    var body: some View {
        Group {
            if let rows, rows.isEmpty {
                ContentUnavailableView("No usage recorded yet", systemImage: "clock",
                                       description: Text("Topbarac samples apps every 30 seconds while History is on."))
            } else if let rows {
                let peak = max(1, rows.first?.cpuSeconds ?? 1)
                List(rows) { row in
                    HStack(spacing: 10) {
                        Image(nsImage: icon(row.name)).resizable().frame(width: 18, height: 18)
                        Text(row.name).lineLimit(1)
                        Spacer(minLength: 8)
                        MeterBar(fraction: row.cpuSeconds / peak, tint: WidgetKind.cpu.accent, height: 5).frame(width: 140)
                        Text(cpuTime(row.cpuSeconds)).monospacedDigit().fontWeight(.medium).frame(width: 78, alignment: .trailing)
                            .help("CPU time: one core fully busy for this long")
                        Text(row.energyJoules > 0 ? energy(row.energyJoules) : "—").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                            .help("Energy used (your own apps only)")
                    }
                    .padding(.vertical, 1)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        Text("App"); Spacer()
                        Text("CPU time").frame(width: 78, alignment: .trailing)
                        Text("Energy").frame(width: 70, alignment: .trailing)
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 22).padding(.vertical, 5)
                    .background(.bar)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: days) {
            guard let historyStore = store.historyStore else { rows = []; return }
            let since = Date().addingTimeInterval(-Double(days) * 86400)
            rows = await Task.detached(priority: .userInitiated) { historyStore.appUsage(since: since, limit: 100) }.value
        }
    }

    private func icon(_ name: String) -> NSImage {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }), let icon = app.icon { return icon }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }

    private func cpuTime(_ s: Double) -> String {
        let total = Int(s.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }

    private func energy(_ joules: Double) -> String {
        let wh = joules / 3600
        return wh >= 1 ? String(format: "%.1f Wh", wh) : String(format: "%.0f mWh", wh * 1000)
    }
}
