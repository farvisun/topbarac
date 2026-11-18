import AppKit
import TopbaracCore

/// Draws one or more widgets into a status item with Core Graphics. Cheap enough to redraw every second, and every
/// number is laid out against a fixed-width template so the menu bar never jitters.
final class PanelView: NSView {
    struct Segment {
        var kind: WidgetKind
        var config: WidgetConfig
        var value: PanelValue
        var showIcon: Bool          // merged mode and "numbers without label" show the widget's symbol
    }

    /// Redraws only when what is drawn actually changes: every redraw of a status item also makes macOS re-snapshot
    /// it for each display, which is most of the app's idle CPU.
    var segments: [Segment] = [] {
        didSet {
            let signature = Self.signature(segments) + (dimmed ? "D" : "")
            if signature != lastSignature { lastSignature = signature; contentChanged = true; needsDisplay = true }
        }
    }
    private var lastSignature = ""
    /// Set when the drawn content changed since the last `image()` call.
    private(set) var contentChanged = true

    /// Draw in black only, for template images (macOS tints them to match each display's menu bar).
    var templateMode = false

    /// Renders the content once into a bitmap for a status bar button. When nothing is past a threshold the image is
    /// a template, so macOS colors it per display and only composites it; otherwise it is drawn in color for the
    /// button's appearance.
    func image(appearance: NSAppearance, scale: CGFloat) -> NSImage {
        contentChanged = false
        let size = NSSize(width: preferredWidth, height: NSStatusBar.system.thickness)
        let template = segments.allSatisfy { $0.value.level == .normal } && !dimmed
        let renderer = PanelView(frame: NSRect(origin: .zero, size: size))
        renderer.segments = segments
        renderer.dimmed = dimmed
        renderer.templateMode = template
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage(size: size) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance { renderer.draw(NSRect(origin: .zero, size: size)) }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = template
        return image
    }

    var dimmed = false { didSet { if dimmed != oldValue { contentChanged = true; needsDisplay = true } } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
    private static let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private static let labelFont = NSFont.systemFont(ofSize: 8.5, weight: .bold)
    private static let padding: CGFloat = 5
    private static let gap: CGFloat = 4
    private static let segmentGap: CGFloat = 10
    private static var widthCache: [String: CGFloat] = [:]
    private static var symbolCache: [String: NSImage] = [:]

    private static func signature(_ segments: [Segment]) -> String {
        segments.map { s in
            var parts = [s.kind.rawValue, s.config.style.rawValue, s.config.showLabel ? "L" : "", s.config.showValue ? "V" : "",
                         s.showIcon ? "I" : "", "\(s.value.level.rawValue)", s.value.available ? "" : "U"]
            parts += s.value.lines
            switch s.config.style {
            case .ring, .meter: parts.append("\(Int(((s.value.fraction ?? 0) * 100).rounded()))")
            case .sparkline, .bars:
                let count = s.config.style == .bars ? 8 : 40
                parts.append(s.value.history.suffix(count).map { $0.map { String(Int(($0 * 30).rounded())) } ?? "_" }.joined(separator: ","))
            case .numbers: break
            }
            return parts.joined(separator: "|")
        }.joined(separator: "#")
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the status bar button

    // MARK: Layout

    private static func textWidth(_ s: String, font: NSFont) -> CGFloat {
        let key = "\(font.pointSize):\(s)"
        if let w = widthCache[key] { return w }
        let w = ceil((s as NSString).size(withAttributes: [.font: font]).width)
        widthCache[key] = w
        return w
    }

    private static func graphicWidth(_ style: PanelStyle) -> CGFloat {
        switch style {
        case .numbers: 0
        case .sparkline: 30
        case .bars: 26
        case .ring: 15
        case .meter: 6
        }
    }

    private static func valueWidth(_ v: PanelValue) -> CGFloat {
        let font = v.templates.count > 1 ? smallFont : valueFont
        let texts = v.templates + v.lines
        return texts.map { textWidth($0, font: font) }.max() ?? 0
    }

    private static func showsValue(_ s: Segment) -> Bool { s.config.showValue || s.config.style == .numbers }

    static func width(of s: Segment) -> CGFloat {
        var parts: [CGFloat] = []
        if s.config.showLabel { parts.append(textWidth(s.kind.shortLabel, font: labelFont)) }
        else if s.showIcon { parts.append(14) }
        if s.config.style != .numbers { parts.append(graphicWidth(s.config.style)) }
        if showsValue(s) { parts.append(valueWidth(s.value)) }
        return parts.reduce(0, +) + gap * CGFloat(max(0, parts.count - 1))
    }

    var preferredWidth: CGFloat {
        guard !segments.isEmpty else { return 22 }
        let content = segments.map(Self.width(of:)).reduce(0, +) + Self.segmentGap * CGFloat(segments.count - 1)
        return ceil(content + Self.padding * 2)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        var x = Self.padding
        let midY = bounds.midY
        for s in segments {
            let base = templateMode ? NSColor.black : NSColor.labelColor
            var color = s.value.level.nsColor ?? base
            if dimmed { color = color.withAlphaComponent(0.35) }
            if !s.value.available { color = color.withAlphaComponent(0.4) }

            if s.config.showLabel {
                let w = Self.textWidth(s.kind.shortLabel, font: Self.labelFont)
                drawText(s.kind.shortLabel, font: Self.labelFont, color: templateMode ? NSColor.black.withAlphaComponent(0.6) : .secondaryLabelColor, x: x, midY: midY)
                x += w + Self.gap
            } else if s.showIcon {
                drawSymbol(s.kind.symbol, color: base.withAlphaComponent(dimmed ? 0.35 : 0.85), in: NSRect(x: x, y: midY - 7, width: 14, height: 14))
                x += 14 + Self.gap
            }

            let gw = Self.graphicWidth(s.config.style)
            if s.config.style != .numbers {
                let rect = NSRect(x: x, y: midY - 7.5, width: gw, height: 15)
                switch s.config.style {
                case .sparkline: drawSparkline(s.value.history, color: color, in: rect)
                case .bars: drawBars(s.value.history, color: color, in: rect)
                case .ring: drawRing(s.value.fraction ?? 0, color: color, in: rect)
                case .meter: drawMeter(s.value.fraction ?? 0, color: color, in: rect)
                case .numbers: break
                }
                x += gw + Self.gap
            }

            if Self.showsValue(s) {
                let vw = Self.valueWidth(s.value)
                if s.value.lines.count > 1 {
                    let lineHeight: CGFloat = 10
                    for (i, line) in s.value.lines.prefix(2).enumerated() {
                        let y = midY + (i == 0 ? lineHeight / 2 : -lineHeight / 2)
                        drawText(line, font: Self.smallFont, color: color, x: x, midY: y, width: vw, alignRight: true)
                    }
                } else {
                    drawText(s.value.lines.first ?? "", font: Self.valueFont, color: color, x: x, midY: midY, width: vw, alignRight: true)
                }
                x += vw
            } else if s.config.style != .numbers {
                x -= Self.gap
            }
            x += Self.segmentGap
        }
    }

    private func drawText(_ text: String, font: NSFont, color: NSColor, x: CGFloat, midY: CGFloat, width: CGFloat? = nil, alignRight: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        var drawX = x
        if alignRight, let width { drawX = x + width - size.width }
        // Center on the cap height, not the line box, so digits sit visually centered.
        let y = midY - (font.capHeight / 2) + font.descender
        (text as NSString).draw(at: NSPoint(x: drawX, y: y.rounded()), withAttributes: attrs)
    }

    private func drawSymbol(_ name: String, color: NSColor, in rect: NSRect) {
        // Resolve the dynamic color now (menu bar appearance) and cache the tinted bitmap per color.
        let resolved = color.usingColorSpace(.sRGB) ?? color   // resolved against the current drawing appearance
        let key = "\(name)-\(resolved.redComponent)-\(resolved.greenComponent)-\(resolved.blueComponent)-\(resolved.alphaComponent)"
        let tinted: NSImage
        if let cached = Self.symbolCache[key] {
            tinted = cached
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [resolved]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
            if Self.symbolCache.count > 64 { Self.symbolCache.removeAll() }
            Self.symbolCache[key] = image
            tinted = image
        }
        let image = tinted
        let s = image.size
        let scale = min(rect.width / s.width, rect.height / s.height, 1)
        let size = NSSize(width: s.width * scale, height: s.height * scale)
        tinted.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    private func drawSparkline(_ values: [Double?], color: NSColor, in rect: NSRect) {
        let track = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        color.withAlphaComponent(0.08).setFill()
        track.fill()
        guard values.count > 1 else { return }
        let inset = rect.insetBy(dx: 1, dy: 1.5)
        let step = inset.width / CGFloat(max(1, values.count - 1))
        var segments: [[NSPoint]] = [[]]
        for (i, v) in values.enumerated() {
            guard let v else { if !(segments.last?.isEmpty ?? true) { segments.append([]) }; continue }
            segments[segments.count - 1].append(NSPoint(x: inset.minX + CGFloat(i) * step, y: inset.minY + CGFloat(v) * inset.height))
        }
        for points in segments where points.count > 1 {
            let fill = NSBezierPath()
            fill.move(to: NSPoint(x: points[0].x, y: inset.minY))
            for p in points { fill.line(to: p) }
            fill.line(to: NSPoint(x: points.last!.x, y: inset.minY))
            fill.close()
            color.withAlphaComponent(0.3).setFill()
            fill.fill()
            let line = NSBezierPath()
            line.move(to: points[0])
            for p in points.dropFirst() { line.line(to: p) }
            line.lineWidth = 1.2
            line.lineJoinStyle = .round
            color.setStroke()
            line.stroke()
        }
    }

    private func drawBars(_ values: [Double?], color: NSColor, in rect: NSRect) {
        let count = 8
        let barWidth: CGFloat = 2.5
        let spacing = (rect.width - barWidth * CGFloat(count)) / CGFloat(count - 1)
        let recent = Array(values.suffix(count))
        let padded = Array(repeating: Double?.none, count: count - recent.count) + recent
        for (i, v) in padded.enumerated() {
            let x = rect.minX + CGFloat(i) * (barWidth + spacing)
            let trackRect = NSRect(x: x, y: rect.minY, width: barWidth, height: rect.height)
            color.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: trackRect, xRadius: 1, yRadius: 1).fill()
            guard let v else { continue }
            let h = max(1.5, CGFloat(v) * rect.height)
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: rect.minY, width: barWidth, height: h), xRadius: 1, yRadius: 1).fill()
        }
    }

    private func drawRing(_ fraction: Double, color: NSColor, in rect: NSRect) {
        let d = min(rect.width, rect.height) - 2
        let r = NSRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
        let track = NSBezierPath(ovalIn: r.insetBy(dx: 1.25, dy: 1.25))
        track.lineWidth = 2.5
        color.withAlphaComponent(0.18).setStroke()
        track.stroke()
        let f = min(1, max(0, fraction))
        guard f > 0.005 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: d / 2 - 1.25, startAngle: 90, endAngle: 90 - 360 * CGFloat(f), clockwise: true)
        arc.lineWidth = 2.5
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }

    private func drawMeter(_ fraction: Double, color: NSColor, in rect: NSRect) {
        let track = NSRect(x: rect.midX - 2.5, y: rect.minY, width: 5, height: rect.height)
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        let h = max(2, CGFloat(min(1, max(0, fraction))) * track.height)
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width, height: h), xRadius: 2.5, yRadius: 2.5).fill()
    }
}
