import AppKit
import Carbon.HIToolbox
import SwiftUI
import TopbaracCore

/// One global shortcut through Carbon's `RegisterEventHotKey`: works in every app and needs no Accessibility
/// permission (unlike an NSEvent global monitor).
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var current: Hotkey?

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { AppDelegate.shared.statusItems?.toggleMain() }
            return noErr
        }, 1, &spec, nil, &handler)
        apply(SettingsStore.shared.settings.hotkey)
        SettingsStore.shared.observe { [weak self] old, new in
            if old.hotkey != new.hotkey { self?.apply(new.hotkey) }
        }
    }

    func start() {}

    private func apply(_ hotkey: Hotkey?) {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        current = hotkey
        guard let hotkey else { return }
        let id = EventHotKeyID(signature: OSType(0x5442_4143), id: 1) // "TBAC"
        RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    /// Carbon modifier flags and a "⌃⌥⇧⌘K" label for a key event.
    static func hotkey(from event: NSEvent) -> Hotkey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // A global shortcut needs ⌘, ⌃ or ⌥; Shift alone would steal ordinary typing.
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        var label = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); label += "⌘" }
        label += keyName(event)
        return Hotkey(keyCode: UInt32(event.keyCode), modifiers: carbon, display: label)
    }

    private static func keyName(_ event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: "Space"
        case kVK_Return: "↩"
        case kVK_Tab: "⇥"
        case kVK_Delete: "⌫"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        default: (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }
}

/// Settings control: click, press the shortcut, done. Esc cancels, ⌫ clears.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press shortcut…" : (hotkey?.display ?? "Record Shortcut"))
                    .monospacedDigit()
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            if hotkey != nil && !recording {
                Button { hotkey = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Remove shortcut")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if event.keyCode == UInt16(kVK_Delete) && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                hotkey = nil; stop(); return nil
            }
            if let key = HotkeyCenter.hotkey(from: event) {
                hotkey = key
                stop()
            } else {
                hint = "Add ⌘, ⌃ or ⌥"
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
