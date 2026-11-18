import AppKit

// Menu bar app: no Dock icon, no main window.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate.shared
app.delegate = delegate
app.run()
