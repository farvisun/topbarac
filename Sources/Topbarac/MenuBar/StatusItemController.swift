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
        var popover: NSPopover?

        init(statusItem: NSStatusItem, kinds: [WidgetKind], merged: Bool) {
            self.statusItem = statusItem
            self.kinds = kinds
            self.merged = merged
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
        refresh()
    }

    private func make(id: String, kinds: [WidgetKind], merged: Bool) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "topbarac.\(id)"
        statusItem.behavior = [.removalAllowed]
        let item = Item(statusItem: statusItem, kinds: kinds, merged: merged)
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

    // MARK: Popover

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let id = sender.identifier?.rawValue, let item = items[id] else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(for: item)
            return
        }
        if openPopoverItem === item { closePopover(); return }
        closePopover()
        if item.kinds.isEmpty { AppDelegate.shared.openSettings(); return }
        show(item)
    }

    func open(_ kind: WidgetKind) {
        guard let item = items[kind.rawValue] ?? items["merged"] else { return }
        if item.merged { mergedSelection.kind = kind }
        closePopover()
        show(item)
    }

    private func show(_ item: Item) {
        guard let button = item.statusItem.button else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let root: AnyView = item.merged
            ? AnyView(MergedPopover(kinds: item.kinds, selection: mergedSelection))
            : AnyView(WidgetPopover(kind: item.kinds[0]))
        let host = NSHostingController(rootView: root.environment(store).environment(settingsStore))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        item.popover = popover
        openPopoverItem = item
        if item.merged { store.openDetail(mergedSelection.kind ?? item.kinds.first ?? .cpu) } else { store.openDetail(item.kinds[0]) }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func closePopover() {
        openPopoverItem?.popover?.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let item = openPopoverItem else { return }
        for kind in WidgetKind.allCases where store.openDetails.contains(kind) { store.closeDetail(kind) }
        item.popover?.contentViewController = nil
        item.popover = nil
        openPopoverItem = nil
    }

    /// Merged mode: switching tabs moves detail sampling to the new widget.
    func mergedTabChanged(to kind: WidgetKind) {
        for k in store.openDetails where k != kind { store.closeDetail(k) }
        store.openDetail(kind)
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
}
