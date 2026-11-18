import SwiftUI
import TopbaracCore

/// Card surface for content inside the (already glass) popover: a quiet fill, no glass-on-glass.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.045), in: .rect(cornerRadius: Metrics.tileCorner))
            .overlay(RoundedRectangle(cornerRadius: Metrics.tileCorner).strokeBorder(.primary.opacity(0.06)))
    }
}

struct SectionTitle: View {
    var title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) { self.title = title; self.trailing = trailing }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).tracking(0.4)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit() }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Small stat: label on top, big number, optional caption.
struct StatTile: View {
    var label: String
    var value: String
    var caption: String?
    var tint: Color = .primary
    var level: Level = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(level == .normal ? tint : level.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            // Always reserve the caption line so tiles in a row share one height.
            Text(caption ?? " ").font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).monospacedDigit()
                .accessibilityHidden(caption == nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.primary.opacity(0.045), in: .rect(cornerRadius: Metrics.tileCorner))
        .accessibilityElement(children: .combine)
    }
}

/// Horizontal meter with rounded ends.
struct MeterBar: View {
    var fraction: Double
    var tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(tint.gradient)
                    .frame(width: max(height, geo.size.width * CGFloat(min(1, max(0, fraction)))))
                    .opacity(fraction > 0.001 ? 1 : 0)
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.35), value: fraction)
        .accessibilityValue(Format.percent(fraction))
    }
}

/// Stacked bar for memory and similar breakdowns.
struct StackedBar: View {
    struct Part: Identifiable {
        var id: String { label }
        var label: String
        var value: Double
        var color: Color
    }
    var parts: [Part]
    var total: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(parts) { part in
                        Rectangle().fill(part.color.gradient)
                            .frame(width: max(0, geo.size.width * CGFloat(part.value / max(total, 1)) - 1.5))
                    }
                    Spacer(minLength: 0)
                }
                .background(.primary.opacity(0.08))
                .clipShape(.rect(cornerRadius: 4))
            }
            .frame(height: 12)
            .animation(.smooth(duration: 0.35), value: parts.map(\.value))
        }
    }
}

struct LegendDot: View {
    var color: Color
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct StatusPill: View {
    var level: Level
    var text: String?

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(level.color).frame(width: 6, height: 6)
            Text(text ?? level.title).font(.system(size: 10.5, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(level.color.opacity(0.14), in: .capsule)
        .foregroundStyle(level == .normal ? .secondary : .primary)
    }
}

/// One labelled row: "Label ............ value".
struct InfoRow: View {
    var label: String
    var value: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14) }
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit().lineLimit(1)
        }
        .accessibilityElement(children: .combine)
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
        HStack(spacing: 8) {
            Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? .yellow : .green)
            Text(toast.text).font(.system(size: 12, weight: .medium)).lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Icon in a tinted rounded square, used in popover headers.
struct WidgetIcon: View {
    var kind: WidgetKind
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(kind.accent.gradient, in: .rect(cornerRadius: size * 0.3))
            .accessibilityHidden(true)
    }
}
