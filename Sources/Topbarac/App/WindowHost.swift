import AppKit
import SwiftUI

/// Hosts a SwiftUI view in a regular window (settings, all processes). The app has no Dock icon, so the window
/// activates the app when shown and the content is released when it closes.
final class WindowHost: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let title: String
    private let autosave: String
    private let size: NSSize
    private let makeContent: () -> AnyView

    init(title: String, autosave: String, size: NSSize, content: @escaping () -> AnyView) {
        self.title = title
        self.autosave = autosave
        self.size = size
        self.makeContent = content
    }

    var isOpen: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = title
            w.isReleasedWhenClosed = false
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.delegate = self
            w.contentViewController = NSHostingController(rootView: makeContent())
            w.setContentSize(size)
            if !w.setFrameUsingName(autosave) { w.center() }
            w.setFrameAutosaveName(autosave)
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        // Drop the SwiftUI tree so it stops observing the store.
        window?.contentViewController = nil
        window = nil
    }
}
