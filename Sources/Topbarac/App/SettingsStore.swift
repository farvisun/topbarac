import Foundation
import Observation
import TopbaracCore

/// Persisted settings (JSON in UserDefaults). Every change is saved and broadcast to the menu bar and sampler.
@Observable
final class SettingsStore {
    static let shared = SettingsStore()
    private static let key = "settings.v1"

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            for observer in observers.values { observer(oldValue, settings) }
        }
    }

    @ObservationIgnored private var observers: [UUID: (AppSettings, AppSettings) -> Void] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    @discardableResult
    func observe(_ handler: @escaping (_ old: AppSettings, _ new: AppSettings) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    func config(_ kind: WidgetKind) -> WidgetConfig { settings.config(kind) }

    func update(_ kind: WidgetKind, _ change: (inout WidgetConfig) -> Void) {
        var c = settings.config(kind)
        change(&c)
        settings.widgets[kind] = c
    }

    func resetAll() { settings = AppSettings() }
}
