import AppKit

/// The sidebar's bottom strip while the selected mailbox downloads, in the place, size and green of
/// MailMate's storage bar (measured at 1x): a 22 pt strip under a 1 pt line, its bar 16 pt tall, 3 pt
/// below the line and 8 pt in from the left, over a grey track; its corners rounded (4 pt), the fill's
/// leading end too. What's under way is written across the bar in 10 pt digits that don't jitter,
/// dark over the green and in the text color over the track, so it reads on both; in a narrow sidebar
/// a shorter wording is used. The fill eases to each new amount.
final class SyncProgressBar: NSView {
    static let height: CGFloat = 22
    private static let radius: CGFloat = 4

    /// Done so far, 0...1.
    var fraction = 0.0 {
        didSet {
            guard fraction != oldValue else { return }
            updateTimer()
            needsDisplay = true
        }
    }

    /// Written across the bar ("Downloading 120 of 560"), longest first: the first that fits is used
    /// ("120 of 560" in a narrow sidebar).
    var texts: [String] = [] {
        didSet { if texts != oldValue { needsDisplay = true } }
    }

    /// The fraction drawn: eases toward `fraction`.
    private var shown = 0.0
    private var timer: Timer?

    private static let track = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 60 / 255, green: 63 / 255, blue: 64 / 255, alpha: 1) : NSColor(white: 0, alpha: 0.1)
    }

    /// The line over the strip: lighter than the sidebar in dark mode, as MailMate's.
    private static let line = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 62 / 255, green: 65 / 255, blue: 66 / 255, alpha: 1) : .separatorColor
    }

    /// MailMate's green in dark mode (52, 218, 93 on screen); the system green in light mode.
    private static let green = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 48 / 255, green: 215 / 255, blue: 75 / 255, alpha: 1) : .systemGreen
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
    private static let trackText = NSColor(name: nil) { appearance in
        NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 1 : 0, alpha: 0.75)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Self.line.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let bar = NSRect(x: 8, y: 4, width: max(0, bounds.width - 16), height: 16)
        let track = NSBezierPath(roundedRect: bar, xRadius: Self.radius, yRadius: Self.radius)
        Self.track.setFill()
        track.fill()

        // At least as wide as its rounded ends, so a sliver of progress still shows as a rounded cap.
        let width = shown > 0 ? max(Self.radius * 2, (bar.width * min(shown, 1)).rounded()) : 0
        let fill = NSRect(x: bar.minX, y: bar.minY, width: width, height: bar.height)
        if width > 0 {
            let path = NSBezierPath(roundedRect: fill, xRadius: Self.radius, yRadius: Self.radius)
            Self.green.setFill()
            path.fill()
            // MailMate's fill has a 1 pt rim a shade darker than its inside.
            (Self.green.blended(withFraction: 0.12, of: .black) ?? Self.green).setStroke()
            let rim = NSBezierPath(
                roundedRect: fill.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.radius - 0.5, yRadius: Self.radius - 0.5)
            rim.lineWidth = 1
            rim.stroke()
        }
        drawText(in: bar, track: track, fill: width > 0 ? NSBezierPath(roundedRect: fill, xRadius: Self.radius, yRadius: Self.radius) : nil)
    }

    /// The text centered on the bar: in the text color over the track, dark over the green (each
    /// clipped to its part).
    private func drawText(in bar: NSRect, track: NSBezierPath, fill: NSBezierPath?) {
        // The longest wording that fits with 6 pt to spare at either end, else the shortest.
        let width = { (text: String) in (text as NSString).size(withAttributes: [.font: Self.font]).width }
        guard let text = texts.first(where: { width($0) <= bar.width - 12 }) ?? texts.last, !text.isEmpty else { return }
        let size = (text as NSString).size(withAttributes: [.font: Self.font])
        let origin = backingAlignedRect(
            NSRect(x: bar.midX - size.width / 2, y: bar.midY - size.height / 2, width: size.width, height: size.height),
            options: .alignAllEdgesNearest
        ).origin
        for (color, clip) in [(Self.trackText, track), (NSColor(white: 0, alpha: 0.78), fill)] {
            guard let clip else { continue }
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            (text as NSString).draw(at: origin, withAttributes: [.font: Self.font, .foregroundColor: color])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Runs while the fill eases toward its amount.
    private func updateTimer() {
        let needed = window != nil && !isHidden && abs(fraction - shown) > 0.0005
        if needed, timer == nil {
            let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needed {
            if isHidden { shown = fraction }  // shown again: from where it is, not easing from the past
            timer?.invalidate()
            timer = nil
        }
    }

    private func tick() {
        shown += (fraction - shown) * 0.18  // eases out over about a quarter of a second
        if abs(fraction - shown) < 0.0005 { shown = fraction }
        needsDisplay = true
        updateTimer()
    }

    override var isHidden: Bool {
        didSet { updateTimer() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }
}
