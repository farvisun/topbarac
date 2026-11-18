import AppKit
import SwiftUI
import TopbaracCore

/// Development aid: `Topbarac --snapshot <dir> [--wait <seconds>]` samples live data for a while, renders every
/// popover, the panel styles and the settings window offscreen to PNG (light and dark), then quits. Used for the
/// landing page screenshots and for checking layouts without screen recording permission.
enum Snapshotter {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        let wait = args.firstIndex(of: "--wait").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 20
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = MonitorStore.shared
        for kind in WidgetKind.allCases { store.openDetail(kind) }
        store.setOverview(open: true)
        store.setProcessWindow(open: true)
        // A run loop timer, not a main-queue block: the capture spins nested run loops while async views load, and
        // the main queue isn't drained re-entrantly from inside one of its own blocks.
        Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { _ in
            MainActor.assumeIsolated {
                captureAll(to: dir)
                NSApp.terminate(nil)
            }
        }
        return true
    }

    private static func captureAll(to dir: URL) {
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
            let ap = NSAppearance(named: appearance)!
            for kind in WidgetKind.allCases {
                capture(PopoverChrome { WidgetContent(kind: kind).padding(DS.pad) }, appearance: ap,
                        to: dir.appendingPathComponent("\(kind.rawValue)-\(name).png"), settle: kind == .network ? 5 : 0.6)
            }
            capture(PopoverChrome { OverviewContent { _ in }.padding(DS.pad) }, appearance: ap,
                    to: dir.appendingPathComponent("overview-\(name).png"), settle: 3)
            capture(WelcomeView {}, appearance: ap, to: dir.appendingPathComponent("welcome-\(name).png"))
            capture(ProcessesWindow(sort: .cpu).frame(width: 760, height: 420), appearance: ap,
                    to: dir.appendingPathComponent("processes-\(name).png"))
            capture(StorageWindow().frame(width: 680, height: 460), appearance: ap,
                    to: dir.appendingPathComponent("storage-\(name).png"), settle: 8)
            capture(StylesSheet(), appearance: ap, to: dir.appendingPathComponent("styles-\(name).png"))
            capture(SettingsView().frame(width: 780, height: 600), appearance: ap, to: dir.appendingPathComponent("settings-\(name).png"))
        }
    }

    @MainActor
    private static func capture<V: View>(_ view: V, appearance: NSAppearance, to url: URL, settle: TimeInterval = 0.6) {
        let root = view
            .environment(MonitorStore.shared)
            .environment(SettingsStore.shared)
            .environment(ToastCenter())
        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        host.display()
        RunLoop.current.run(until: Date().addingTimeInterval(settle))
        // Views that loaded data while settling may have grown.
        let grown = host.fittingSize
        if grown != host.frame.size {
            host.frame = NSRect(origin: .zero, size: grown)
            window.setContentSize(grown)
            host.layoutSubtreeIfNeeded()
            host.display()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}

/// Popover-like surface for snapshots (the real popover draws its own glass).
private struct PopoverChrome<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .frame(width: Metrics.popoverWidth)
            .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.96))
    }
}

/// Every widget in every panel style, as the menu bar would draw them.
private struct StylesSheet: View {
    @Environment(MonitorStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(PanelStyle.allCases) { style in
                HStack(spacing: 14) {
                    Text(style.title).font(.system(size: 12, weight: .medium)).frame(width: 90, alignment: .leading)
                    HStack(spacing: 4) {
                        ForEach([WidgetKind.cpu, .memory, .temperature, .gpu, .battery]) { kind in
                            PanelPreview(segments: [segment(kind, style)])
                        }
                    }
                    .frame(height: 26)
                    .padding(.horizontal, 8)
                    .background(scheme == .dark ? Color(white: 0.18) : Color(white: 0.92), in: .rect(cornerRadius: 6))
                }
            }
        }
        .padding(16)
        .background(scheme == .dark ? Color(white: 0.1) : .white)
    }

    private func segment(_ kind: WidgetKind, _ style: PanelStyle) -> PanelView.Segment {
        var config = settings.config(kind)
        config.style = style
        config.showValue = true
        config.showLabel = style != .numbers
        if kind == .temperature { config.metric = .tempHottest }
        return .init(kind: kind, config: config, value: PanelValue.make(kind, store: store, settings: settings.settings), showIcon: style == .numbers)
    }
}
