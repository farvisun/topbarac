import AppKit
import SwiftUI
import TopbaracCore

enum Level: Int, Comparable {
    case normal, warning, critical
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self { case .normal: "Normal"; case .warning: "High"; case .critical: "Critical" }
    }

    var color: Color {
        switch self { case .normal: .green; case .warning: .yellow; case .critical: .red }
    }

    var nsColor: NSColor? {
        switch self { case .normal: nil; case .warning: .systemYellow; case .critical: .systemRed }
    }

    /// Level for a value against a widget's thresholds (inverted for battery: lower is worse).
    static func of(_ value: Double?, config: WidgetConfig, inverted: Bool) -> Level {
        guard config.thresholdsEnabled, let value else { return .normal }
        if inverted {
            if value <= config.critical { return .critical }
            if value <= config.warning { return .warning }
        } else {
            if value >= config.critical { return .critical }
            if value >= config.warning { return .warning }
        }
        return .normal
    }
}

extension WidgetKind {
    /// One accent per widget, used in popovers and charts (the menu bar stays monochrome unless a threshold is crossed).
    var accent: Color {
        switch self {
        case .cpu: Color(red: 0.25, green: 0.52, blue: 1.0)
        case .memory: Color(red: 0.62, green: 0.40, blue: 0.98)
        case .disk: Color(red: 0.12, green: 0.72, blue: 0.70)
        case .temperature: Color(red: 1.0, green: 0.55, blue: 0.20)
        case .gpu: Color(red: 0.93, green: 0.33, blue: 0.62)
        case .network: Color(red: 0.20, green: 0.70, blue: 0.95)
        case .battery: Color(red: 0.26, green: 0.80, blue: 0.42)
        }
    }

    var secondaryAccent: Color {
        switch self {
        case .disk: Color(red: 1.0, green: 0.62, blue: 0.25)
        case .network: Color(red: 0.98, green: 0.45, blue: 0.55)
        case .temperature: Color(red: 0.93, green: 0.33, blue: 0.62)
        default: accent.opacity(0.55)
        }
    }
}

enum Metrics {
    static let popoverWidth: CGFloat = 340
    static let corner: CGFloat = 14
    static let tileCorner: CGFloat = 12
}
