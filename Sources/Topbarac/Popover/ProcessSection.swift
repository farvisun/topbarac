import SwiftUI
import TopbaracCore

/// Top processes for the widget's metric, with quit, force quit and more. Helpers are folded into their app.
struct ProcessSection: View {
    var kind: WidgetKind
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let sort = ProcessSort.for(kind)
        let list = store.processes.sorted { sort.value($0) > sort.value($1) }.prefix(5)
        let top = max(list.first.map { sort.value($0) } ?? 1, 1e-9)
        Card(padding: 8) {
            VStack(alignment: .leading, spacing: 2) {
                SectionTitle(title(sort)) {
                    Button("Show All") { AppDelegate.shared.openProcesses(sort: sort) }
                        .buttonStyle(.borderless).font(.system(size: 10.5, weight: .medium))
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
                if store.processes.isEmpty {
                    ForEach(0..<5, id: \.self) { _ in ProcessRowSkeleton() }
                } else if kind == .network && list.allSatisfy({ sort.value($0) == 0 }) {
                    Text("Measuring per-app traffic…").font(DS.label).foregroundStyle(.tertiary).frame(height: DS.rowHeight).padding(.horizontal, 4)
                } else {
                    ForEach(Array(list)) { p in
                        ProcessRow(process: p, sort: sort, fraction: max(0, sort.value(p)) / top,
                                   tint: kind.accent, bits: settings.settings.networkUnit == .bits)
                    }
                }
            }
        }
    }

    private func title(_ sort: ProcessSort) -> String {
        switch sort {
        case .cpu: "Top CPU"
        case .memory: "Top memory"
        case .disk: "Top disk activity"
        case .network: "Top network"
        case .energy: "Top energy"
        }
    }
}

struct ProcessRowSkeleton: View {
    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.07)).frame(width: 16, height: 16)
            RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.07)).frame(width: 110, height: 8)
            Spacer()
            RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.07)).frame(width: 34, height: 8)
        }
        .padding(.horizontal, 4)
        .frame(height: DS.rowHeight)
        .accessibilityHidden(true)
    }
}

struct ProcessRow: View {
    var process: ProcessSample
    var sort: ProcessSort
    var fraction: Double
    var tint: Color = .accentColor
    var bits: Bool

    @Environment(ToastCenter.self) private var toasts
    @State private var hovering = false
    @State private var confirm: Confirm?

    enum Confirm { case forceQuit, adminKill }

    private var name: String { ProcessIcons.displayName(for: process) }
    private var isProtected: Bool { ProcessActions.isProtected(process) }
    private var isApp: Bool { ProcessActions.app(for: process.pid)?.activationPolicy == .regular }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 7) {
                Image(nsImage: ProcessIcons.icon(for: process)).resizable().frame(width: 16, height: 16)
                Text(name).font(DS.body).lineLimit(1).truncationMode(.middle)
                if process.groupCount > 1 {
                    Text("×\(process.groupCount)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .help("\(process.groupCount) processes")
                }
                if !process.isOwned {
                    Image(systemName: "person.badge.key").font(.system(size: 8.5)).foregroundStyle(.tertiary)
                        .help("Runs as another user")
                }
                Spacer(minLength: 4)
                if hovering && confirm == nil && !isProtected {
                    Button { quit() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(isApp ? "Quit \(name)" : "Terminate \(name)")
                    .accessibilityLabel(isApp ? "Quit \(name)" : "Terminate \(name)")
                }
                Text(sort.format(process, bits: bits)).font(DS.value).frame(minWidth: 48, alignment: .trailing)
            }
            .padding(.horizontal, 4)
            .frame(height: DS.rowHeight)
            // The row itself is the bar: its fill shows the share of the busiest process.
            .background(alignment: .leading) {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 5).fill(tint.opacity(hovering ? 0.2 : 0.12))
                        .frame(width: max(0, geo.size.width * CGFloat(min(1, fraction))))
                }
            }
            .background(Color.primary.opacity(hovering ? 0.05 : 0), in: .rect(cornerRadius: 5))
            if let confirm { confirmBar(confirm) }
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: isApp ? "Quit" : "Terminate") { quit() }
        .animation(.smooth(duration: 0.3), value: fraction)
        .animation(.smooth(duration: 0.2), value: confirm)
    }

    @ViewBuilder
    private var menu: some View {
        if isProtected {
            Text("\(name) is a system process and is protected")
        } else {
            Button(isApp ? "Quit \(name)" : "Terminate \(name)") { quit() }
            Button(isApp ? "Force Quit \(name)…" : "Kill \(name)…") { confirm = .forceQuit }
        }
        Divider()
        Button("Show in Finder") { ProcessActions.reveal(process) }.disabled(process.path == nil)
        Button("Open Activity Monitor") { ProcessActions.openActivityMonitor() }
        Button("Copy PID (\(process.pid))") { ProcessActions.copyPID(process) }
    }

    private func confirmBar(_ kind: Confirm) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.system(size: 11))
            Text(kind == .adminKill ? "Owned by another user. Kill as admin?" : "Unsaved work in \(name) will be lost.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 4)
            Button("Cancel") { confirm = nil }.buttonStyle(.borderless)
            Button(kind == .adminKill ? "Kill…" : (isApp ? "Force Quit" : "Kill")) {
                kind == .adminKill ? killAsAdmin() : forceQuit()
            }
            .buttonStyle(.glassProminent).tint(.red)
        }
        .controlSize(.mini)
        .padding(6)
        .background(.yellow.opacity(0.08), in: .rect(cornerRadius: 6))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func quit() {
        let result = ProcessActions.quit(pid: process.pid)
        if result == .needsAdmin { confirm = .adminKill; return }
        toasts.show(result, success: isApp ? "Asked \(name) to quit" : "Terminated \(name)")
    }

    private func forceQuit() {
        confirm = nil
        let result = ProcessActions.forceQuit(pid: process.pid)
        if result == .needsAdmin { confirm = .adminKill; return }
        toasts.show(result, success: "Force quit \(name)")
    }

    private func killAsAdmin() {
        confirm = nil
        let pid = process.pid
        let label = name
        Task {
            let result = await ProcessActions.killAsAdmin(pid: pid, force: true)
            toasts.show(result, success: "Killed \(label)")
        }
    }
}
