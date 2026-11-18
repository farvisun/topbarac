import Foundation

/// Every chartable series. Values use natural units: fractions (0...1) for usage, bytes per second, °C, W, RPM.
/// Raw values are stored in the history database, so never rename them.
public enum SeriesKey: String, CaseIterable, Sendable, Codable {
    case cpuUsage = "cpu", cpuP = "cpu.p", cpuE = "cpu.e", cpuPower = "cpu.power", cpuUser = "cpu.user", cpuSystem = "cpu.sys"
    case memUsage = "mem", memSwap = "mem.swap", memApp = "mem.app", memWired = "mem.wired", memCompressed = "mem.comp"
    case diskRead = "disk.read", diskWrite = "disk.write", diskBusy = "disk.busy", diskUsed = "disk.used"
    case tempCPU = "temp.cpu", tempGPU = "temp.gpu", tempSSD = "temp.ssd", tempHottest = "temp.max", fan = "fan"
    case gpuUsage = "gpu", gpuMemory = "gpu.mem", gpuPower = "gpu.power"
    case netDown = "net.down", netUp = "net.up"
    case battery = "bat", batteryWatts = "bat.w"

    public var widget: WidgetKind {
        switch self {
        case .cpuUsage, .cpuP, .cpuE, .cpuPower, .cpuUser, .cpuSystem: .cpu
        case .memUsage, .memSwap, .memApp, .memWired, .memCompressed: .memory
        case .diskRead, .diskWrite, .diskBusy, .diskUsed: .disk
        case .tempCPU, .tempGPU, .tempSSD, .tempHottest, .fan: .temperature
        case .gpuUsage, .gpuMemory, .gpuPower: .gpu
        case .netDown, .netUp: .network
        case .battery, .batteryWatts: .battery
        }
    }

    public static func values(in frame: SampleFrame) -> [SeriesKey: Double] {
        var v: [SeriesKey: Double] = [:]
        if let c = frame.cpu {
            v[.cpuUsage] = c.usage
            v[.cpuP] = c.pClusterUsage
            v[.cpuE] = c.eClusterUsage
            v[.cpuPower] = c.powerWatts
            v[.cpuUser] = c.user
            v[.cpuSystem] = c.system
        }
        if let m = frame.memory {
            v[.memUsage] = m.usage
            v[.memSwap] = Double(m.swapUsed)
            if m.total > 0 {
                let t = Double(m.total)
                v[.memApp] = Double(m.app) / t
                v[.memWired] = Double(m.wired) / t
                v[.memCompressed] = Double(m.compressed) / t
            }
        }
        if let d = frame.disk {
            v[.diskRead] = d.readBps
            v[.diskWrite] = d.writeBps
            v[.diskBusy] = d.busy
            v[.diskUsed] = d.root?.usage
        }
        if let t = frame.temperature {
            v[.tempCPU] = t.cpu
            v[.tempGPU] = t.gpu
            v[.tempSSD] = t.ssd
            v[.tempHottest] = t.hottest
            if !t.fans.isEmpty { v[.fan] = t.fans.map(\.rpm).max() }
        }
        if let g = frame.gpu, g.available {
            v[.gpuUsage] = g.utilization
            v[.gpuMemory] = Double(g.memoryUsed)
            v[.gpuPower] = g.powerWatts
        }
        if let n = frame.network {
            v[.netDown] = n.downBps
            v[.netUp] = n.upBps
        }
        if let b = frame.battery, b.present {
            v[.battery] = b.percent
            v[.batteryWatts] = b.batteryWatts
        }
        return v
    }
}
