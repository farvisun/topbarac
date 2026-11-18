// Renders the Topbarac app icon into an .iconset (run by build-app.sh).
// A dark rounded square with a frosted menu bar strip and a glowing usage chart below it.
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let bg = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // Body with a soft drop shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = s * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.set()
    NSGradient(colors: [color(0.05, 0.07, 0.16), color(0.13, 0.12, 0.30)])!.draw(in: bg, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    bg.addClip()

    // Ambient glow behind the chart.
    let glow = NSGradient(colors: [color(0.35, 0.45, 1.0, 0.45), color(0.35, 0.45, 1.0, 0)])!
    glow.draw(fromCenter: NSPoint(x: body.midX, y: body.minY + body.height * 0.3), radius: 0,
              toCenter: NSPoint(x: body.midX, y: body.minY + body.height * 0.3), radius: body.width * 0.7, options: [])

    // Menu bar strip.
    let barH = body.height * 0.17
    let bar = NSRect(x: body.minX, y: body.maxY - barH, width: body.width, height: barH)
    color(1, 1, 1, 0.12).setFill()
    NSBezierPath(rect: bar).fill()
    color(1, 1, 1, 0.22).setFill()
    NSBezierPath(rect: NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: max(1, s * 0.004))).fill()

    // Three mini widgets in the strip: ring, bars, meter.
    let cy = bar.midY
    let unit = barH * 0.5
    let ringCenter = NSPoint(x: body.maxX - body.width * 0.16, y: cy)
    let ring = NSBezierPath()
    ring.appendArc(withCenter: ringCenter, radius: unit * 0.55, startAngle: 0, endAngle: 360)
    ring.lineWidth = unit * 0.22
    color(1, 1, 1, 0.25).setStroke()
    ring.stroke()
    let arc = NSBezierPath()
    arc.appendArc(withCenter: ringCenter, radius: unit * 0.55, startAngle: 90, endAngle: 90 - 250, clockwise: true)
    arc.lineWidth = unit * 0.22
    arc.lineCapStyle = .round
    color(1.0, 0.62, 0.25).setStroke()
    arc.stroke()
    let heights: [CGFloat] = [0.35, 0.6, 0.45, 0.8, 0.55, 0.95]
    let barsX = body.maxX - body.width * 0.48
    for (i, h) in heights.enumerated() {
        let w = unit * 0.2
        let r = NSRect(x: barsX + CGFloat(i) * w * 1.7, y: cy - unit * 0.5, width: w, height: unit * h)
        color(0.62, 0.70, 1.0).setFill()
        NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
    }
    let meter = NSRect(x: body.minX + body.width * 0.14, y: cy - unit * 0.5, width: unit * 0.24, height: unit)
    color(1, 1, 1, 0.22).setFill()
    NSBezierPath(roundedRect: meter, xRadius: meter.width / 2, yRadius: meter.width / 2).fill()
    color(0.35, 0.85, 0.55).setFill()
    NSBezierPath(roundedRect: NSRect(x: meter.minX, y: meter.minY, width: meter.width, height: meter.height * 0.65),
                 xRadius: meter.width / 2, yRadius: meter.width / 2).fill()

    // Area chart.
    let values: [CGFloat] = [0.18, 0.26, 0.22, 0.4, 0.34, 0.55, 0.47, 0.72, 0.6, 0.66, 0.52, 0.78, 0.7]
    let chart = NSRect(x: body.minX, y: body.minY + body.height * 0.1, width: body.width, height: body.height * 0.5)
    let points = values.enumerated().map { i, v in
        NSPoint(x: chart.minX + chart.width * CGFloat(i) / CGFloat(values.count - 1), y: chart.minY + chart.height * v)
    }
    func smoothPath(_ pts: [NSPoint]) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: pts[0])
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let mx = (a.x + b.x) / 2
            p.curve(to: b, controlPoint1: NSPoint(x: mx, y: a.y), controlPoint2: NSPoint(x: mx, y: b.y))
        }
        return p
    }
    let area = smoothPath(points)
    area.line(to: NSPoint(x: chart.maxX, y: body.minY))
    area.line(to: NSPoint(x: chart.minX, y: body.minY))
    area.close()
    NSGradient(colors: [color(0.40, 0.55, 1.0, 0.75), color(0.62, 0.40, 0.98, 0.15)])!.draw(in: area, angle: -90)
    let line = smoothPath(points)
    line.lineWidth = s * 0.022
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let lineGlow = NSShadow()
    lineGlow.shadowBlurRadius = s * 0.025
    lineGlow.shadowColor = color(0.55, 0.65, 1.0, 0.9)
    lineGlow.set()
    NSGradient(colors: [color(0.45, 0.80, 1.0), color(0.70, 0.50, 1.0), color(1.0, 0.60, 0.35)])!.draw(in: line.strokedPath(width: s * 0.022), angle: 0)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    // Hairline edge highlight.
    color(1, 1, 1, 0.12).setStroke()
    bg.lineWidth = max(1, s * 0.004)
    bg.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

extension NSBezierPath {
    func strokedPath(width: CGFloat) -> NSBezierPath {
        let cg = self.cgPath.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return NSBezierPath(cgPath: cg)
    }
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
