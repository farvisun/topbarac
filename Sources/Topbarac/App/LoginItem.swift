import ServiceManagement

/// Open at login through SMAppService (macOS 13+). Needs the app to run from a bundle.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // Usually "requires approval": send the user to Login Items.
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
