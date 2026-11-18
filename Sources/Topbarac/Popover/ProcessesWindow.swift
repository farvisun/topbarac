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

    private var rows: [ProcessSample] {
        let filtered = search.isEmpty ? store.processes : store.processes.filter {
            ProcessIcons.displayName(for: $0).localizedCaseInsensitiveContains(search) || String($0.pid).hasPrefix(search)
        }
        return filtered.sorted { sort.value($0) > sort.value($1) }
    }

    private var selected: ProcessSample? { store.processes.first { $0.pid == selection } }

    var body: some View {
        let bits = settings.settings.networkUnit == .bits
        VStack(spacing: 0) {
            if store.processes.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading processes…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(rows, selection: $selection) { p in
                    HStack(spacing: 10) {
                        Image(nsImage: ProcessIcons.icon(for: p)).resizable().frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(ProcessIcons.displayName(for: p)).lineLimit(1)
                                if p.groupCount > 1 { Text("×\(p.groupCount)").font(.caption2).foregroundStyle(.secondary) }
                            }
                            Text("PID \(p.pid)\(p.isOwned ? "" : " · other user")").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        ForEach(ProcessSort.allCases) { column in
                            Text(column.format(p, bits: bits))
                                .font(.system(size: 11.5, weight: column == sort ? .semibold : .regular))
                                .foregroundStyle(column == sort ? .primary : .secondary)
                                .monospacedDigit()
                                .frame(width: 66, alignment: .trailing)
                        }
                    }
                    .tag(p.pid)
                    .contextMenu { contextMenu(p) }
                }
                .listStyle(.inset)
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
        }
        .overlay(alignment: .bottom) {
            if let toast = toasts.current { ToastView(toast: toast).padding(16) }
        }
        .animation(.smooth(duration: 0.25), value: toasts.current)
        .searchable(text: $search, placement: .toolbar, prompt: "Search processes")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Sort by", selection: $sort) {
                    ForEach(ProcessSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
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
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .environment(toasts)
        .onAppear { store.setProcessWindow(open: true) }
        .onDisappear { store.setProcessWindow(open: false) }
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
