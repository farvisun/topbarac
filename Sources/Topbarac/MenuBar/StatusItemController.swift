import AppKit
import SwiftUI
import TopbaracCore

/// Owns the menu bar items: one per enabled widget, or a single merged item. Each opens a popover.
final class StatusItemController: NSObject, NSPopoverDelegate {
    private final class Item {
        let statusItem: NSStatusItem
        let panel = PanelView()
        let kinds: [WidgetKind]       // one kind, or every enabled kind in merged mode
        let merged: Bool
        let overview: Bool
        var popover: NSPopover?

        init(statusItem: NSStatusItem, kinds: [WidgetKind], merged: Bool, overview: Bool = false) {
            self.statusItem = statusItem
            self.kinds = kinds
            self.merged = merged
            self.overview = overview
        }
    }

    private var items: [String: Item] = [:]
    private let store = MonitorStore.shared
    private let settingsStore = SettingsStore.shared
    private var flashPhase = false
    private var openPopoverItem: Item?
    /// Selected tab in merged mode, kept across openings.
    private let mergedSelection = MergedSelection()

    override init() {
        super.init()
        rebuild()
        store.onFrame.append { [weak self] in self?.refresh() }
        settingsStore.observe { [weak self] old, new in
            guard let self else { return }
            let layoutChanged = old.mergedMode != new.mergedMode || old.enabledWidgets != new.enabledWidgets
                || old.showOverviewItem != new.showOverviewItem
            if layoutChanged { rebuild() } else { refresh() }
        }
    }

    // MARK: Building

    private func rebuild() {
        closePopover()
        for item in items.values { NSStatusBar.system.removeStatusItem(item.statusItem) }
        items.removeAll()
        let s = settingsStore.settings
        if s.mergedMode {
            make(id: "merged", kinds: s.enabledWidgets, merged: true)
        } else {
            // Created in reverse so the leftmost widget in settings ends up leftmost in the menu bar the first time.
            for kind in s.enabledWidgets.reversed() { make(id: kind.rawValue, kinds: [kind], merged: false) }
        }
        if items.isEmpty { make(id: "empty", kinds: [], merged: true) }
        // Rightmost of our items: created last. Merged mode has its own overview tab.
        if s.showOverviewItem && !s.mergedMode { make(id: "overview", kinds: [], merged: false, overview: true) }
        refresh()
    }

    private func make(id: String, kinds: [WidgetKind], merged: Bool, overview: Bool = false) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "topbarac.\(id)"
        statusItem.behavior = [.removalAllowed]
        let item = Item(statusItem: statusItem, kinds: kinds, merged: merged, overview: overview)
        if let button = statusItem.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.setAccessibilityRole(.menuButton)
        }
        items[id] = item
    }

    // MARK: Refresh

    func refresh() {
        let s = settingsStore.settings
        flashPhase.toggle()
        for item in items.values {
            if item.overview {
                refreshOverview(item)
                continue
            }
            if item.kinds.isEmpty {
                item.panel.segments = []
                item.statusItem.length = 24
                item.statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Topbarac")
                continue
            }
            var segments: [PanelView.Segment] = []
            for kind in item.kinds {
                let value = PanelValue.make(kind, store: store, settings: s)
                // Hide widgets the Mac doesn't have (no battery, no supported GPU).
                if !value.available && (kind == .battery || kind == .gpu) { continue }
                var config = s.config(kind)
                if item.merged { config.showLabel = false }
                let showIcon = item.merged ? s.mergedShowsIcons : (config.style == .numbers && !config.showLabel && kind != .network)
                segments.append(.init(kind: kind, config: config, value: value, showIcon: showIcon))
            }
            item.panel.segments = segments
            let flashing = s.flashOnCritical && !store.activeAlertWidgets.isDisjoint(with: item.kinds)
            item.panel.dimmed = (flashing && flashPhase) || store.paused
            item.statusItem.isVisible = !segments.isEmpty || item.merged
            guard item.panel.contentChanged else { continue }
            let width = item.panel.preferredWidth
            if abs(item.statusItem.length - width) > 0.5 { item.statusItem.length = width }
            if let button = item.statusItem.button {
                button.image = item.panel.image(appearance: button.effectiveAppearance,
                                                scale: button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
            }
            item.statusItem.button?.setAccessibilityLabel(segments.map(\.value.accessibility).joined(separator: ", "))
        }
    }

    /// The overview item is a gauge glyph, tinted when any widget is past its threshold or an alert holds.
    private var overviewLevel: Level = .normal
    private var overviewDrawn = false

    private func refreshOverview(_ item: Item) {
        let s = settingsStore.settings
        var level = Level.normal
        for kind in WidgetKind.allCases where s.config(kind).enabled || store.openDetails.contains(kind) {
            level = max(level, PanelValue.make(kind, store: store, settings: s).level)
        }
        if !store.activeAlertWidgets.isEmpty { level = .critical }
        guard !overviewDrawn || level != overviewLevel else { return }
        overviewDrawn = true
        overviewLevel = level
        let symbol = level == .normal ? "gauge.with.dots.needle.33percent" : "gauge.with.dots.needle.100percent"
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        if let color = level.nsColor { config = config.applying(.init(paletteColors: [color])) }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Topbarac overview")?.withSymbolConfiguration(config)
        image?.isTemplate = level == .normal
        item.statusItem.length = 26
        item.statusItem.button?.image = image
        item.statusItem.button?.setAccessibilityLabel(level == .normal ? "Topbarac overview" : "Topbarac overview, \(level.title.lowercased())")
    }

    // MARK: Popover

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let id = sender.identifier?.rawValue, let item = items[id] else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(for: item)
            return
        }
        if openPopoverItem === item { closePopover(); return }
        closePopover()
        if item.kinds.isEmpty && !item.overview { AppDelegate.shared.openSettings(); return }
        show(item)
    }

    /// Global shortcut: the overview item, else the combined item, else the first widget. Pressing it again closes.
    func toggleMain() {
        if openPopoverItem != nil { closePopover(); return }
        let s = settingsStore.settings
        if let item = items["overview"] ?? items["merged"] ?? s.enabledWidgets.lazy.compactMap({ self.items[$0.rawValue] }).first {
            if item.merged { mergedSelection.showingOverview = true }
            show(item)
        }
    }

    func open(_ kind: WidgetKind) {
        guard let item = items[kind.rawValue] ?? items["merged"] else { return }
        if item.merged { mergedSelection.kind = kind; mergedSelection.showingOverview = false }
        closePopover()
        show(item)
    }

    private func show(_ item: Item) {
        guard let button = item.statusItem.button else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let root: AnyView = item.overview ? AnyView(OverviewPopover())
            : item.merged ? AnyView(MergedPopover(kinds: item.kinds, selection: mergedSelection))
            : AnyView(WidgetPopover(kind: item.kinds[0]))
        let host = NSHostingController(rootView: root.environment(store).environment(settingsStore))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        item.popover = popover
        openPopoverItem = item
        if item.overview {
            store.setOverview(open: true)
        } else if item.merged {
            if mergedSelection.showingOverview { store.setOverview(open: true) } else { store.openDetail(mergedSelection.kind ?? item.kinds.first ?? .cpu) }
        } else {
            store.openDetail(item.kinds[0])
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        openPopoverItem?.popover?.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let item = openPopoverItem else { return }
        for kind in WidgetKind.allCases where store.openDetails.contains(kind) { store.closeDetail(kind) }
        store.setOverview(open: false)
        item.popover?.contentViewController = nil
        item.popover = nil
        openPopoverItem = nil
    }

    /// Merged mode: switching tabs moves detail sampling to the new widget (nil = overview).
    func mergedTabChanged(to kind: WidgetKind?) {
        for k in store.openDetails where k != kind { store.closeDetail(k) }
        store.setOverview(open: kind == nil)
        if let kind { store.openDetail(kind) }
    }

    // MARK: Menu

    private func showMenu(for item: Item) {
        let menu = NSMenu()
        if let kind = item.kinds.first, !item.merged {
            let header = NSMenuItem(title: kind.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
        }
        let pause = NSMenuItem(title: store.paused ? "Resume Monitoring" : "Pause Monitoring", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        let am = NSMenuItem(title: "Open Activity Monitor", action: #selector(openActivityMonitor), keyEquivalent: "")
        am.target = self
        menu.addItem(am)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Topbarac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.statusItem.menu = menu
        item.statusItem.button?.performClick(nil)
        item.statusItem.menu = nil
    }

    @objc private func togglePause() { store.setPaused(!store.paused); refresh() }
    @objc private func openActivityMonitor() { ProcessActions.openActivityMonitor() }
    @objc private func openSettings() { AppDelegate.shared.openSettings() }
}

@Observable
final class MergedSelection {
    var kind: WidgetKind?
    /// The overview tab is what the combined item opens to first.
    var showingOverview = true
}
