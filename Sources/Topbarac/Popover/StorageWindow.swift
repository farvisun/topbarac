import SwiftUI
import TopbaracCore

/// Where the disk space went: known space hogs (developer caches, Docker, Downloads) or the home folder, drillable.
/// Read-only: it shows and reveals, deleting stays a decision made in Finder.
struct StorageWindow: View {
    enum Mode: String, CaseIterable, Identifiable {
        case known = "Usual suspects", home = "Home folder"
        var id: String { rawValue }
    }

    @Environment(MonitorStore.self) private var store
    @State private var mode: Mode = .known
    @State private var path: [URL] = []
    /// nil until the first measurement of the current view arrives.
    @State private var items: [StorageItem]?
    @State private var loading = false
    @State private var cache: [URL: [StorageItem]] = [:]

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var current: URL { path.last ?? home }

    var body: some View {
        VStack(spacing: 0) {
            if mode == .home { breadcrumb }
            if let items, !items.isEmpty {
                List(items) { item in row(item) }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
            } else if items == nil {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(mode == .known ? "Measuring caches and app data…" : "Measuring \(current.lastPathComponent)…")
                        .foregroundStyle(.secondary)
                    Text("Large folders can take a minute.").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Nothing to show", systemImage: "externaldrive",
                                       description: Text("This folder is empty or can't be read without Full Disk Access."))
            }
            footer
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Button { load(force: true) } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .disabled(loading)
                    .help("Measure again")
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .task(id: "\(mode.rawValue)|\(current.path)") { load(force: false) }
    }

    private var breadcrumb: some View {
        HStack(spacing: 3) {
            Button("Home") { path = [] }.buttonStyle(.link)
            ForEach(Array(path.enumerated()), id: \.offset) { index, url in
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                Button(url.lastPathComponent) { path = Array(path.prefix(index + 1)) }
                    .buttonStyle(.link).disabled(index == path.count - 1)
            }
            Spacer()
            if loading { ProgressView().controlSize(.mini) }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func row(_ item: StorageItem) -> some View {
        let largest = Double(max(1, items?.first?.size ?? 1))
        return HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                if let note = item.note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(minWidth: 160, alignment: .leading)
            Spacer(minLength: 8)
            MeterBar(fraction: Double(item.size) / largest, tint: WidgetKind.disk.accent, height: 5).frame(width: 120)
            Text(Format.bytes(item.size)).monospacedDigit().fontWeight(.medium).frame(width: 74, alignment: .trailing)
            Button { SystemActions.reveal(item.url) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).help("Show in Finder")
            if mode == .home && item.isDirectory {
                Button { path.append(item.url) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).help("Open \(item.name)")
            } else {
                Color.clear.frame(width: 14)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onTapGesture(count: 2) { if mode == .home && item.isDirectory { path.append(item.url) } }
        .contextMenu {
            Button("Show in Finder") { SystemActions.reveal(item.url) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
        }
    }

    private var footer: some View {
        HStack {
            if mode == .known {
                Text("Caches overlap (Homebrew and pip live inside Caches), so sizes don't add up.")
            } else {
                Text(items.map { "\($0.count) items · \(Format.bytes($0.reduce(0) { $0 + $1.size }))" } ?? " ")
            }
            Spacer()
            if let root = store.disk?.root {
                Text("\(root.name): \(Format.bytes(root.available)) free of \(Format.bytes(root.total))")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func load(force: Bool) {
        let key = mode == .known ? URL(fileURLWithPath: "/known") : current
        if !force, let cached = cache[key] { items = cached; return }
        if !force { items = nil }
        loading = true
        let mode = self.mode
        let url = current
        Task {
            let result = mode == .known ? await StorageScanner.knownLocations() : await StorageScanner.children(of: url)
            cache[key] = result
            // Ignore results for a folder the user already left.
            if self.mode == mode && (mode == .known || self.current == url) { items = result }
            loading = false
        }
    }
}
