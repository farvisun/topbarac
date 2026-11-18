import Foundation
import TopbaracCore

/// What one menu bar item shows right now: text (one or two lines), a fraction for gauges, a short normalized history
/// for sparklines and bars, and the threshold level.
struct PanelValue {
    var lines: [String] = []
    /// Widest text these lines can take, measured once so the item never changes width as digits change.
    var templates: [String] = []
    var fraction: Double?
    var history: [Double?] = []
    var level: Level = .normal
    var available = true
    var accessibility = ""

    static func make(_ kind: WidgetKind, store: MonitorStore, settings: AppSettings) -> PanelValue {
        let config = settings.config(kind)
        let fahrenheit = settings.temperatureUnit == .fahrenheit
        let bits = settings.networkUnit == .bits
        var v = PanelValue()

        func normalizedHistory(_ key: SeriesKey, scale: Double? = nil, count: Int = 40) -> [Double?] {
            guard let s = store.series(key) else { return [] }
            let raw = s.points.suffix(count).map(\.value)
            let maxValue = scale ?? max(raw.compactMap { $0 }.max() ?? 1, 1e-9)
            return raw.map { $0.map { min(1, max(0, $0 / maxValue)) } }
        }

        switch kind {
        case .cpu:
            guard let c = store.cpu else { return .placeholder(kind, "––%") }
            if config.metric == .cpuPower, let w = c.powerWatts {
                v.lines = [String(format: "%.1fW", w)]; v.templates = ["88.8W"]
                v.fraction = min(1, w / 40)
                v.history = normalizedHistory(.cpuPower, scale: 40)
            } else {
                v.lines = [Format.percent(c.usage)]; v.templates = ["100%"]
                v.fraction = c.usage
                v.history = normalizedHistory(.cpuUsage, scale: 1)
            }
            v.level = Level.of(c.usage * 100, config: config, inverted: false)
            v.accessibility = "CPU \(Format.percent(c.usage))"

        case .memory:
            guard let m = store.memory else { return .placeholder(kind, "––%") }
            switch config.metric {
            case .memoryUsed:
                v.lines = [String(format: "%.1fG", Double(m.used) / 1_073_741_824)]; v.templates = ["88.8G"]
            case .memoryPressure:
                v.lines = [m.pressure.title]; v.templates = ["Critical"]
            default:
                v.lines = [Format.percent(m.usage)]; v.templates = ["100%"]
            }
            v.fraction = m.usage
            v.history = normalizedHistory(.memUsage, scale: 1)
            v.level = max(Level.of(m.usage * 100, config: config, inverted: false),
                          m.pressure == .critical ? .critical : (m.pressure == .warning ? .warning : .normal))
            v.accessibility = "Memory \(Format.percent(m.usage)) used, pressure \(m.pressure.title)"

        case .disk:
            guard let d = store.disk else { return .placeholder(kind, "––%") }
            let root = d.root
            switch config.metric {
            case .diskBusy:
                v.lines = [Format.percent(d.busy)]; v.templates = ["100%"]
                v.fraction = d.busy
                v.history = normalizedHistory(.diskBusy, scale: 1)
            case .diskSpeed:
                v.lines = ["R " + Format.rate(d.readBps, compact: true), "W " + Format.rate(d.writeBps, compact: true)]
                v.templates = ["W 888MB", "W 888MB"]
                v.fraction = min(1, d.busy)
                v.history = normalizedHistory(.diskRead)
            default:
                v.lines = [Format.percent(root?.usage ?? 0)]; v.templates = ["100%"]
                v.fraction = root?.usage
                v.history = normalizedHistory(.diskUsed, scale: 1)
            }
            v.level = Level.of((root?.usage ?? 0) * 100, config: config, inverted: false)
            v.accessibility = "Disk \(Format.percent(root?.usage ?? 0)) used"

        case .temperature:
            guard let t = store.temperature else { return .placeholder(kind, "––°") }
            if config.metric == .fanSpeed {
                let rpm = t.fans.map(\.rpm).max() ?? 0
                v.lines = [rpm < 1 ? "Off" : String(format: "%.0f", rpm)]; v.templates = ["8888"]
                v.fraction = t.fans.map(\.fraction).max()
                v.history = normalizedHistory(.fan, scale: t.fans.map(\.maxRPM).max())
            } else {
                let (value, key): (Double?, SeriesKey) = switch config.metric {
                case .tempCPU: (t.cpu, .tempCPU)
                case .tempGPU: (t.gpu, .tempGPU)
                case .tempSSD: (t.ssd, .tempSSD)
                default: (t.hottest, .tempHottest)
                }
                guard let value else { return .placeholder(kind, "––°") }
                v.lines = [Format.temperature(value, fahrenheit: fahrenheit)]; v.templates = [fahrenheit ? "188°" : "108°"]
                v.fraction = min(1, max(0, (value - 25) / 80))
                if let s = store.series(key) {
                    v.history = s.points.suffix(40).map { $0.value.map { min(1, max(0, ($0 - 25) / 80)) } }
                }
            }
            v.level = Level.of(t.hottest, config: config, inverted: false)
            v.accessibility = "Temperature \(t.hottest.map { Format.temperature($0, fahrenheit: fahrenheit) } ?? "unknown")"

        case .gpu:
            guard let g = store.gpu, g.available else { var p = PanelValue.placeholder(kind, "––%"); p.available = store.gpu == nil; return p }
            switch config.metric {
            case .gpuMemory:
                v.lines = [String(format: "%.1fG", Double(g.memoryUsed) / 1_073_741_824)]; v.templates = ["88.8G"]
                v.fraction = g.memoryAllocated > 0 ? Double(g.memoryUsed) / Double(g.memoryAllocated) : nil
            case .gpuPower:
                v.lines = [String(format: "%.1fW", g.powerWatts ?? 0)]; v.templates = ["88.8W"]
                v.fraction = min(1, (g.powerWatts ?? 0) / 30)
            default:
                v.lines = [Format.percent(g.utilization)]; v.templates = ["100%"]
                v.fraction = g.utilization
            }
            v.history = normalizedHistory(.gpuUsage, scale: 1)
            v.level = Level.of(g.utilization * 100, config: config, inverted: false)
            v.accessibility = "GPU \(Format.percent(g.utilization))"

        case .network:
            guard let n = store.network else { return .placeholder(kind, "––") }
            let down = Format.rate(n.downBps, bits: bits, compact: true)
            let up = Format.rate(n.upBps, bits: bits, compact: true)
            switch config.metric {
            case .netDown: v.lines = ["↓ " + down]; v.templates = ["↓ 888MB"]
            case .netUp: v.lines = ["↑ " + up]; v.templates = ["↑ 888MB"]
            default: v.lines = ["↑ " + up, "↓ " + down]; v.templates = ["↑ 888MB", "↓ 888MB"]
            }
            let peak = max(store.series(.netDown)?.points.suffix(60).compactMap(\.value).max() ?? 0, 125_000)
            v.fraction = min(1, n.downBps / peak)
            v.history = normalizedHistory(config.metric == .netUp ? .netUp : .netDown, scale: peak)
            v.level = Level.of(n.downBps / 1e6, config: config, inverted: false)
            v.accessibility = "Network down \(Format.rate(n.downBps, bits: bits)), up \(Format.rate(n.upBps, bits: bits))"

        case .battery:
            guard let b = store.battery else { return .placeholder(kind, "––%") }
            guard b.present else { var p = PanelValue.placeholder(kind, "––%"); p.available = false; return p }
            switch config.metric {
            case .batteryWatts:
                let w = b.batteryWatts ?? 0
                v.lines = [String(format: "%+.1fW", w)]; v.templates = ["+88.8W"]
            case .batteryTime:
                let m = b.charging ? b.minutesToFull : b.minutesToEmpty
                v.lines = [m.map(Format.minutes) ?? (b.onAC ? "AC" : "–:––")]; v.templates = ["88:88"]
            default:
                v.lines = [(b.charging ? "⚡︎" : "") + Format.percent(b.percent)]; v.templates = ["⚡︎100%"]
            }
            v.fraction = b.percent
            v.history = normalizedHistory(.battery, scale: 1)
            v.level = b.onAC ? .normal : Level.of(b.percent * 100, config: config, inverted: true)
            v.accessibility = "Battery \(Format.percent(b.percent))\(b.charging ? ", charging" : "")"
        }
        return v
    }

    static func placeholder(_ kind: WidgetKind, _ text: String) -> PanelValue {
        var v = PanelValue()
        v.lines = [text]
        v.templates = [kind == .network ? "↓ 888MB" : "100%"]
        v.accessibility = "\(kind.title) not available yet"
        return v
    }
}
