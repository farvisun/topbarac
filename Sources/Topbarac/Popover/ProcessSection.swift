import SwiftUI
import TopbaracCore

/// Top processes for the widget's metric, with quit, force quit and more. Helpers are folded into their app.
struct ProcessSection: View {
    var kind: WidgetKind
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        let sort = ProcessSort.for(kind)
        let list = store.processes.sorted { sort.value($0) > sort.value($1) }.prefix(6)
        let top = list.first.map { sort.value($0) } ?? 1
        Card(padding: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionTitle(title(sort))
                    Button("Show All") { AppDelegate.shared.openProcesses(sort: sort) }
                        .buttonStyle(.borderless).controlSize(.small).font(.system(size: 11))
                }
                .padding(.horizontal, 2)
                if store.processes.isEmpty {
                    ForEach(0..<4, id: \.self) { _ in ProcessRowSkeleton() }
                } else if kind == .network && list.allSatisfy({ sort.value($0) == 0 }) {
                    Text("Measuring per-app traffic…").font(.system(size: 11)).foregroundStyle(.tertiary).padding(4)
                } else {
                    ForEach(Array(list)) { p in
                        ProcessRow(process: p, sort: sort, fraction: top > 0 ? sort.value(p) / top : 0,
                                   bits: settings.settings.networkUnit == .bits)
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
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.07)).frame(width: 20, height: 20)
            RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.07)).frame(width: 120, height: 9)
            Spacer()
            RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.07)).frame(width: 36, height: 9)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

struct ProcessRow: View {
    var process: ProcessSample
    var sort: ProcessSort
    var fraction: Double
    var bits: Bool
    var compact = true

    @Environment(ToastCenter.self) private var toasts
    @State private var hovering = false
    @State private var confirm: Confirm?

    enum Confirm { case forceQuit, adminKill }

    private var name: String { ProcessIcons.displayName(for: process) }
    private var isProtected: Bool { ProcessActions.isProtected(process) }
    private var isApp: Bool { ProcessActions.app(for: process.pid)?.activationPolicy == .regular }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(nsImage: ProcessIcons.icon(for: process)).resizable().frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if process.groupCount > 1 {
                            Text("×\(process.groupCount)").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(.primary.opacity(0.07), in: .capsule)
                                .help("\(process.groupCount) processes")
                        }
                        if !process.isOwned {
                            Image(systemName: "person.badge.key").font(.system(size: 9)).foregroundStyle(.tertiary)
                                .help("Runs as another user")
                        }
                    }
                    MeterBar(fraction: fraction, tint: .primary.opacity(0.35), height: 3)
                }
                Spacer(minLength: 6)
                if hovering && confirm == nil && !isProtected {
                    Button {
                        quit()
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(isApp ? "Quit \(name)" : "Terminate \(name)")
                    .accessibilityLabel(isApp ? "Quit \(name)" : "Terminate \(name)")
                }
                Text(sort.format(process, bits: bits))
                    .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    .frame(minWidth: 52, alignment: .trailing)
            }
            if let confirm { confirmBar(confirm) }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(hovering ? 0.05 : 0), in: .rect(cornerRadius: 7))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: isApp ? "Quit" : "Terminate") { quit() }
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
