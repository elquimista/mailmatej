// Draws the MailMateJ app icon and writes an .iconset folder for iconutil.
//   swift scripts/make-icon.swift <out.iconset> [--dev]
// scripts/make-icons.sh runs this for both variants and produces Resources/*.icns.
//
// A tilted, perforated postage stamp (a nod to MailMate) with a "J". The silhouette is not a
// rounded rectangle, so it stays recognizable among macOS's squircle icons. Release is blue-teal;
// Dev is orange with a large DEV label.
import AppKit

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: make-icon.swift <out.iconset> [--dev]")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
let isDev = args.contains("--dev")

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let panelColors: [NSColor] =
    isDev
    ? [color(232, 96, 22), color(247, 150, 40), color(255, 206, 84)]
    : [color(24, 78, 196), color(44, 140, 222), color(108, 214, 232)]
let ink = color(14, 26, 70)

/// Perforation holes along the edges of `rect`: circles centered on the edge line.
func perforations(_ rect: NSRect, radius: CGFloat, spacing: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    func edge(from a: NSPoint, to b: NSPoint) {
        let length = hypot(b.x - a.x, b.y - a.y)
        let count = max(1, Int((length / spacing).rounded()))
        for i in 0..<count {
            let t = (CGFloat(i) + 0.5) / CGFloat(count)
            let c = NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            path.appendOval(in: NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
        }
    }
    edge(from: NSPoint(x: rect.minX, y: rect.maxY), to: NSPoint(x: rect.maxX, y: rect.maxY))
    edge(from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.maxX, y: rect.minY))
    edge(from: NSPoint(x: rect.minX, y: rect.minY), to: NSPoint(x: rect.minX, y: rect.maxY))
    edge(from: NSPoint(x: rect.maxX, y: rect.minY), to: NSPoint(x: rect.maxX, y: rect.maxY))
    // Corner bites, like a real torn-off stamp.
    for corner in [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
                   NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY)] {
        path.appendOval(in: NSRect(x: corner.x - radius, y: corner.y - radius, width: radius * 2, height: radius * 2))
    }
    return path
}

func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    return font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? font
}

/// Draws the icon on a 1024×1024 canvas.
func drawIcon(in cg: CGContext) {
    let stamp = NSRect(x: 181, y: 113, width: 662, height: 798)  // Rotated, ~83% of the tile tall

    // Rotate around the center (opposite tilt to MailMate's).
    cg.saveGState()
    cg.translateBy(x: 512, y: 512)
    cg.rotate(by: 6 * .pi / 180)
    cg.translateBy(x: -512, y: -512)

    // Stamp paper: white with perforations punched out, drawn as one layer so the shadow follows the edge.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    NSGradient(starting: .white, ending: color(232, 236, 242))!.draw(in: stamp, angle: -90)
    cg.setBlendMode(.clear)
    perforations(stamp, radius: 26, spacing: 69).fill()
    cg.setBlendMode(.normal)
    cg.endTransparencyLayer()
    cg.restoreGState()

    // Picture panel.
    let panel = stamp.insetBy(dx: 77, dy: 79)
    cg.saveGState()
    NSBezierPath(rect: panel).addClip()
    NSGradient(colors: panelColors, atLocations: [0, 0.5, 1], colorSpace: .sRGB)!.draw(in: panel, angle: -90)

    // Faint line-art in the background, like MailMate's.
    NSColor.white.withAlphaComponent(0.22).setStroke()
    for (x, y, r) in [(panel.minX + 70, panel.maxY - 90, 120.0), (panel.maxX - 40, panel.minY + 110, 150.0),
                      (panel.maxX - 60, panel.maxY - 40, 70.0)] as [(CGFloat, CGFloat, CGFloat)] {
        let ring = NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        ring.lineWidth = 10
        ring.stroke()
    }
    let hex = NSBezierPath()
    for i in 0..<6 {
        let a = CGFloat(i) * .pi / 3
        let p = NSPoint(x: panel.midX + 40 + cos(a) * 190, y: panel.midY - 10 + sin(a) * 190)
        i == 0 ? hex.move(to: p) : hex.line(to: p)
    }
    hex.close()
    hex.lineWidth = 8
    hex.stroke()

    // Inner shadow along the panel's top edge, so it reads as printed into the paper.
    NSGradient(starting: NSColor.black.withAlphaComponent(0.22), ending: NSColor.black.withAlphaComponent(0))!
        .draw(in: NSRect(x: panel.minX, y: panel.maxY - 26, width: panel.width, height: 26), angle: -90)
    cg.restoreGState()

    NSColor.black.withAlphaComponent(0.12).setStroke()
    let frame = NSBezierPath(rect: panel)
    frame.lineWidth = 3
    frame.stroke()

    // The "J", embossed: a light offset copy under the ink.
    let j = "J"
    let font = roundedFont(500, .heavy)
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let size = NSAttributedString(string: j, attributes: [.font: font]).size()
    let jRect = NSRect(x: panel.minX, y: panel.midY - size.height / 2 + (isDev ? 40 : 6), width: panel.width, height: size.height)
    NSAttributedString(string: j, attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.45), .paragraphStyle: style])
        .draw(in: jRect.offsetBy(dx: 0, dy: -7))
    NSAttributedString(string: j, attributes: [.font: font, .foregroundColor: ink, .paragraphStyle: style])
        .draw(in: jRect)
    cg.restoreGState()

    // Dev label: upright, high contrast, large enough to read in the Dock.
    if isDev {
        let label = NSRect(x: 207, y: 104, width: 610, height: 231)
        let pill = NSBezierPath(roundedRect: label, xRadius: 52, yRadius: 52)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        color(22, 22, 26).setFill()
        pill.fill()
        cg.restoreGState()
        NSColor.white.setStroke()
        pill.lineWidth = 14
        pill.stroke()
        let text = NSAttributedString(string: "DEV", attributes: [
            .font: NSFont.systemFont(ofSize: 191, weight: .black),
            .foregroundColor: NSColor.white,
            .kern: 12,
            .paragraphStyle: style,
        ])
        let t = text.size()
        text.draw(in: NSRect(x: label.minX + 6, y: label.midY - t.height / 2, width: label.width, height: t.height))
    }
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    drawIcon(in: context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(pixels: points).write(to: outDir.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(pixels: points * 2).write(to: outDir.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
print("Wrote \(outDir.path)")
