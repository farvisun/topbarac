import SwiftUI
import TopbaracCore

/// Spacing and type scale for popovers. One place, so every widget lines up.
enum DS {
    static let pad: CGFloat = 12          // popover edge
    static let gap: CGFloat = 8           // between sections
    static let inner: CGFloat = 10        // inside a section
    static let corner: CGFloat = 10
    static let rowHeight: CGFloat = 22

    static let caption = Font.system(size: 10, weight: .medium)
    static let label = Font.system(size: 11)
    static let body = Font.system(size: 11.5)
    static let value = Font.system(size: 11.5, weight: .semibold).monospacedDigit()
    static let stat = Font.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()
}

/// Content section: a quiet fill (the popover itself is glass, so no glass-on-glass).
struct Card<Content: View>: View {
    var padding: CGFloat = DS.inner
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.04), in: .rect(cornerRadius: DS.corner))
    }
}

/// Section header inside a card: small caps title, optional trailing detail or accessory.
struct SectionTitle<Trailing: View>: View {
    var title: String
    var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.3)
            Spacer(minLength: 4)
            trailing.font(.system(size: 10.5)).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(_ title: String) { self.init(title) { EmptyView() } }
}

extension SectionTitle where Trailing == Text {
    init(_ title: String, trailing: String?) { self.init(title) { Text(trailing ?? "") } }
}

/// One figure of a stat strip.
struct Stat: Identifiable {
    var label: String
    var value: String
    var detail: String?
    var tint: Color?
    var level: Level = .normal
    var id: String { label }
}

/// Key figures in one row, separated by hairlines. Replaces separate tiles: same information, half the height.
struct StatStrip: View {
    var stats: [Stat]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                if index > 0 {
                    Rectangle().fill(.primary.opacity(0.08)).frame(width: 1).padding(.vertical, 2)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(stat.label).font(DS.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(stat.value)
                        .font(DS.stat)
                        .foregroundStyle(stat.level != .normal ? stat.level.color : (stat.tint ?? .primary))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .contentTransition(.numericText())
                    Text(stat.detail ?? " ").font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1).monospacedDigit()
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.04), in: .rect(cornerRadius: DS.corner))
    }
}

/// Horizontal meter with rounded ends.
struct MeterBar: View {
    var fraction: Double
    var tint: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(tint)
                    .frame(width: max(height, geo.size.width * CGFloat(min(1, max(0, fraction)))))
                    .opacity(fraction > 0.001 ? 1 : 0)
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.35), value: fraction)
        .accessibilityValue(Format.percent(fraction))
    }
}

/// Label, meter and value on one line: "Renderer ▬▬▬▬▬▭▭ 42%".
struct MeterRow: View {
    var label: String
    var fraction: Double
    var value: String
    var tint: Color
    var labelWidth: CGFloat = 74

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(DS.label).foregroundStyle(.secondary).lineLimit(1).frame(width: labelWidth, alignment: .leading)
            MeterBar(fraction: fraction, tint: tint)
            Text(value).font(DS.value).frame(minWidth: 44, alignment: .trailing)
        }
        .frame(height: 16)
        .accessibilityElement(children: .combine)
    }
}

/// Stacked bar with a two-column legend underneath (memory breakdown and similar).
struct StackedBar: View {
    struct Part: Identifiable {
        var id: String { label }
        var label: String
        var value: Double
        var color: Color
        var text: String
    }
    var parts: [Part]
    var total: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(parts) { part in
                        Rectangle().fill(part.color)
                            .frame(width: max(0, geo.size.width * CGFloat(part.value / max(total, 1)) - 1))
                    }
                    Spacer(minLength: 0)
                }
                .background(.primary.opacity(0.08))
                .clipShape(.rect(cornerRadius: 3))
            }
            .frame(height: 8)
            .animation(.smooth(duration: 0.35), value: parts.map(\.value))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                ForEach(0..<(parts.count + 1) / 2, id: \.self) { row in
                    GridRow {
                        LegendDot(color: parts[row * 2].color, label: parts[row * 2].label, value: parts[row * 2].text)
                        if row * 2 + 1 < parts.count {
                            LegendDot(color: parts[row * 2 + 1].color, label: parts[row * 2 + 1].label, value: parts[row * 2 + 1].text)
                        }
                    }
                }
            }
        }
    }
}

struct LegendDot: View {
    var color: Color
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 7, height: 7)
            Text(label).font(DS.label).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(value).font(DS.value)
        }
        .frame(height: 16)
        .accessibilityElement(children: .combine)
    }
}

struct StatusPill: View {
    var level: Level
    var text: String?

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(level.color).frame(width: 5, height: 5)
            Text(text ?? level.title).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(level.color.opacity(0.14), in: .capsule)
        .foregroundStyle(level == .normal ? .secondary : .primary)
        .lineLimit(1)
        .fixedSize()
    }
}

/// "Label ........ value" on one compact line.
struct InfoRow: View {
    var label: String
    var value: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 13)
            }
            Text(label).font(DS.label).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).font(DS.value).lineLimit(1)
        }
        .frame(height: 16)
        .accessibilityElement(children: .combine)
    }
}

/// Short facts in two columns, so each doesn't take a full line.
struct InfoGrid: View {
    var items: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
            ForEach(0..<(items.count + 1) / 2, id: \.self) { row in
                GridRow {
                    InfoRow(label: items[row * 2].0, value: items[row * 2].1)
                    if row * 2 + 1 < items.count {
                        InfoRow(label: items[row * 2 + 1].0, value: items[row * 2 + 1].1)
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
            }
        }
    }
}

/// Small borderless icon button for headers and rows.
struct IconButton: View {
    var symbol: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .frame(width: 24, height: 22)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Transient message at the bottom of a popover ("Freed 1.2 GB", errors).
@Observable
final class ToastCenter {
    struct Toast: Equatable { var text: String; var isError: Bool; var id = UUID() }
    var current: Toast?

    func show(_ text: String, error: Bool = false) {
        let toast = Toast(text: text, isError: error)
        current = toast
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            if self.current?.id == toast.id { self.current = nil }
        }
    }

    func show(_ result: ProcessActionResult, success: String) {
        switch result {
        case .done: show(success)
        case .needsAdmin: show("That process belongs to another user.", error: true)
        case .failed(let message): show(message, error: message != "Cancelled.")
        }
    }
}

struct ToastView: View {
    var toast: ToastCenter.Toast

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? .yellow : .green)
            Text(toast.text).font(.system(size: 11.5, weight: .medium)).lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Icon in a tinted rounded square, used in popover headers and settings.
struct WidgetIcon: View {
    var kind: WidgetKind
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(kind.accent.gradient, in: .rect(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}
