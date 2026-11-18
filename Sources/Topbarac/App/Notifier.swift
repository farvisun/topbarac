import AppKit
import TopbaracCore
import UserNotifications

/// Alert notifications with "Quit <app>" and "Open" actions. Needs a real app bundle; under `swift run` it only logs.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private static let category = "topbarac.alert"
    private static let quitAction = "quit"
    private static let openAction = "open"

    var onOpen: ((WidgetKind) -> Void)?

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundlePath.hasSuffix(".app") ? UNUserNotificationCenter.current() : nil
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        let quit = UNNotificationAction(identifier: Self.quitAction, title: "Quit App", options: [.destructive])
        let open = UNNotificationAction(identifier: Self.openAction, title: "Open", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [quit, open], intentIdentifiers: [])])
    }

    func requestPermission() async -> Bool {
        guard let center else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center else { return .notDetermined }
        return await center.notificationSettings().authorizationStatus
    }

    func post(_ event: AlertEvent) {
        // Find the process to blame for CPU and memory alerts.
        let culprit: ProcessSample? = switch event.rule.metric {
        case .cpuUsage, .temperature: ProcessActions.topProcess(by: .cpu)
        case .memoryUsage, .memoryPressure: ProcessActions.topProcess(by: .memory)
        default: nil
        }
        let content = UNMutableNotificationContent()
        content.title = Self.title(for: event)
        var body = event.rule.summary
        if let culprit {
            body += "\nTop process: \(culprit.name)"
            content.userInfo["pid"] = Int(culprit.pid)
            content.userInfo["name"] = culprit.name
            content.categoryIdentifier = Self.category
        }
        content.userInfo["widget"] = event.rule.metric.widget.rawValue
        content.body = body
        content.sound = .default
        guard let center else {
            NSLog("Topbarac alert: %@ — %@", content.title, body)
            return
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func title(for event: AlertEvent) -> String {
        let v = event.value
        switch event.rule.metric {
        case .cpuUsage: return "CPU at \(Int(v))%"
        case .memoryUsage: return "Memory at \(Int(v))%"
        case .memoryPressure: return "Memory pressure is critical"
        case .diskFree: return String(format: "Only %.1f GB free on the startup disk", v)
        case .temperature: return "Running hot: \(Int(v))°C"
        case .gpuUsage: return "GPU at \(Int(v))%"
        case .batteryLevel: return "Battery at \(Int(v))%"
        case .networkDown: return String(format: "Downloading at %.0f MB/s", v)
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let pid = (info["pid"] as? Int).map(Int32.init)
        let widget = (info["widget"] as? String).flatMap(WidgetKind.init(rawValue:))
        await MainActor.run {
            if action == Self.quitAction, let pid {
                _ = ProcessActions.quit(pid: pid)
            } else if let widget {
                Notifier.shared.onOpen?(widget)
            }
        }
    }
}
