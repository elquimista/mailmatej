import AppKit
import Combine
import MailStore

/// A corner of the Dock icon that can show a counter, as in MailMate.
enum Corner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }

    /// The other corner on the same row.
    var rowPartner: Corner {
        switch self {
        case .topLeft: .topRight
        case .topRight: .topLeft
        case .bottomLeft: .bottomRight
        case .bottomRight: .bottomLeft
        }
    }
}

struct CounterConfig: Codable, Equatable {
    var showInDock: Bool
    /// A `MessageScope.key`: "role:inbox", "flagged", "mailbox:42", "account:<id>", "all".
    var source: String
    var unreadOnly: Bool
}

/// The four Dock counters, saved in user defaults. Changes take effect immediately.
@MainActor
final class CounterSettings: ObservableObject {
    static let shared = CounterSettings()
    private static let defaultsKey = "DockCounters"

    @Published var counters: [Corner: CounterConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(counters) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    private init() {
        var counters = Dictionary(uniqueKeysWithValues: Corner.allCases.map {
            ($0, CounterConfig(showInDock: false, source: MessageScope.role("inbox").key, unreadOnly: true))
        })
        counters[.topRight]?.showInDock = true  // Like the standard Dock badge: unread in all inboxes.
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
            let saved = try? JSONDecoder().decode([Corner: CounterConfig].self, from: data)
        {
            counters.merge(saved) { _, saved in saved }
        }
        self.counters = counters
    }
}

/// The Dock icon: the app icon plus a badge for each enabled, non-zero counter, laid out like MailMate's:
/// about a third of the tile tall, in the tile's corners, one color per corner.
final class DockTileView: NSView {
    var values: [Corner: Int] = [:]

    override func draw(_ dirtyRect: NSRect) {
        #if DEBUG
            if ProcessInfo.processInfo.environment["MMJ_DEBUG_DOCK"] != nil {
                NSLog("MMJ dock draw: bounds=\(NSStringFromRect(bounds)) tile=\(NSStringFromSize(NSApp.dockTile.size)) icon=\(NSStringFromSize(NSApp.applicationIconImage?.size ?? .zero)) ctx=\(NSGraphicsContext.current?.cgContext.width ?? 0)x\(NSGraphicsContext.current?.cgContext.height ?? 0)")
            }
        #endif
        NSApp.applicationIconImage?.draw(in: bounds)
        // Bottom row first, then top-left, then top-right on top (as MailMate overlaps them).
        for corner in [Corner.bottomLeft, .bottomRight, .topLeft, .topRight] {
            guard let value = values[corner], value > 0 else { continue }  // Zero counts aren't shown.
            drawBadge(value, at: corner, sharesRow: (values[corner.rowPartner] ?? 0) > 0)
        }
    }

    static func color(for corner: Corner) -> NSColor {
        switch corner {
        case .topLeft: NSColor(srgbRed: 0.04, green: 0.48, blue: 1.0, alpha: 1)  // blue
        case .topRight: NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)  // red
        case .bottomLeft: NSColor(srgbRed: 1.0, green: 0.78, blue: 0.0, alpha: 1)  // yellow
        case .bottomRight: NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)  // green
        }
    }

    /// Full number below 100,000; compact above ("123K", "1.2M") so the badge stays readable.
    static func label(for value: Int) -> String {
        value < 100_000 ? String(value) : compactLabel(for: value)
    }

    /// "12K", "123K", "1.2M", "12M".
    static func compactLabel(for value: Int) -> String {
        if value < 1000 { return String(value) }
        if value < 1_000_000 { return "\(value / 1000)K" }
        let millions = Double(value) / 1_000_000
        return millions < 10 ? String(format: "%.1fM", floor(millions * 10) / 10) : "\(value / 1_000_000)M"
    }

    /// - Parameter sharesRow: another badge is on the same row; each then gets about half the width,
    ///   so neither hides the other.
    private func drawBadge(_ value: Int, at corner: Corner, sharesRow: Bool) {
        let height = (bounds.height * 0.36).rounded()
        let maxWidth = bounds.width * (sharesRow ? 0.52 : 0.62)
        let padding = height * 0.5
        let minFont = height * 0.42

        // Full digits, shrunk if needed; if they can't fit at a readable size, the compact form.
        var fontSize = height * 0.56  // Digits about 8 px tall in a 19 px badge, as MailMate draws them.
        var label = Self.attributed(Self.label(for: value), size: fontSize)
        while label.size().width + padding > maxWidth && fontSize > minFont {
            fontSize -= 0.5
            label = Self.attributed(Self.label(for: value), size: fontSize)
        }
        if label.size().width + padding > maxWidth {
            fontSize = height * 0.56
            label = Self.attributed(Self.compactLabel(for: value), size: fontSize)
            while label.size().width + padding > maxWidth && fontSize > minFont {
                fontSize -= 0.5
                label = Self.attributed(Self.compactLabel(for: value), size: fontSize)
            }
        }
        let textSize = label.size()
        let width = min(maxWidth, max(height, textSize.width + padding))

        // In the tile's corner, as MailMate places them: flush with the top or bottom edge and the side.
        // Two badges on a row each keep to their own side (they may touch in the middle).
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let rect = NSRect(
            x: left ? bounds.minX : bounds.maxX - width,
            y: top ? bounds.maxY - height : bounds.minY,
            width: width, height: height)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -height * 0.03)
        shadow.shadowBlurRadius = height * 0.06
        shadow.set()
        Self.color(for: corner).setFill()
        NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()

        label.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
    }

    private static func attributed(_ text: String, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium), .foregroundColor: NSColor.white,
        ])
    }
}

/// Keeps the Dock icon's counters current.
@MainActor
final class DockCounters {
    private let store: MailStore
    private let view: DockTileView
    private var lastValues: [Corner: Int]?
    private var cancellable: AnyCancellable?

    init(store: MailStore) {
        self.store = store
        let size = NSApp.dockTile.size
        view = DockTileView(frame: NSRect(origin: .zero, size: size))
        cancellable = CounterSettings.shared.$counters.dropFirst().sink { [weak self] _ in
            // `$counters` fires before the property changes; update on the next turn.
            DispatchQueue.main.async { self?.update() }
        }
    }

    /// Recomputes the counters and redraws the Dock icon if anything changed.
    func update() {
        var values: [Corner: Int] = [:]
        for (corner, config) in CounterSettings.shared.counters where config.showInDock {
            guard let scope = MessageScope(key: config.source) else { continue }
            values[corner] = (try? store.count(scope: scope, unreadOnly: config.unreadOnly)) ?? 0
        }
        guard values != lastValues else { return }
        lastValues = values
        #if DEBUG
            if ProcessInfo.processInfo.environment["MMJ_DEBUG_DOCK"] != nil {
                NSLog("MMJ dock counters: \(values.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue)=\($0.value)" })")
            }
        #endif
        let tile = NSApp.dockTile
        tile.badgeLabel = nil
        if values.values.contains(where: { $0 > 0 }) {
            view.values = values
            if tile.contentView !== view { tile.contentView = view }
        } else {
            tile.contentView = nil
        }
        tile.display()
    }

    #if DEBUG
        /// Renders the Dock icon as it would look into a PNG at `path`.
        func debugRender(to path: String, values: [Corner: Int]? = nil) {
            let saved = view.values
            if let values { view.values = values }
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            view.values = saved
        }
    #endif
}
