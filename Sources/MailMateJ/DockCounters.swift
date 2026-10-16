import AppKit
import Combine
import MailStore

/// A corner of the Dock icon that can show a counter, as in MailMate.
enum Corner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
}

/// MailMate's "Count" choices, except Outgoing and Pending & Outgoing, which wait for sending, and
/// Recent, which has no clear meaning in JMAP.
enum CountKind: String, Codable, CaseIterable, Identifiable {
    case all, unread, flagged, unreplied
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .unread: "Unread"
        case .flagged: "Flagged"
        case .unreplied: "Unreplied"
        }
    }
}

struct CounterConfig: Codable, Equatable {
    var showInDock: Bool
    /// A `MessageScope.key`: "role:inbox", "flagged", "mailbox:42", "account:<id>", "all".
    var source: String
    var count: CountKind

    init(showInDock: Bool, source: String, count: CountKind) {
        self.showInDock = showInDock
        self.source = source
        self.count = count
    }

    private enum CodingKeys: String, CodingKey { case showInDock, source, count, unreadOnly }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showInDock = try c.decode(Bool.self, forKey: .showInDock)
        source = try c.decode(String.self, forKey: .source)
        if let count = try? c.decode(CountKind.self, forKey: .count) {
            self.count = count
        } else {  // Saved before the Count menu had more than Unread and All.
            count = (try? c.decode(Bool.self, forKey: .unreadOnly)) == false ? .all : .unread
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(showInDock, forKey: .showInDock)
        try c.encode(source, forKey: .source)
        try c.encode(count, forKey: .count)
    }
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
            ($0, CounterConfig(showInDock: false, source: MessageScope.role("inbox").key, count: .unread))
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
    /// Draw zero counts too (while previewing the corners in Settings).
    var showsZeros = false

    override func draw(_ dirtyRect: NSRect) {
        #if DEBUG
            if ProcessInfo.processInfo.environment["MMJ_DEBUG_DOCK"] != nil {
                NSLog("MMJ dock draw: bounds=\(NSStringFromRect(bounds)) tile=\(NSStringFromSize(NSApp.dockTile.size)) icon=\(NSStringFromSize(NSApp.applicationIconImage?.size ?? .zero)) ctx=\(NSGraphicsContext.current?.cgContext.width ?? 0)x\(NSGraphicsContext.current?.cgContext.height ?? 0)")
            }
        #endif
        NSApp.applicationIconImage?.draw(in: bounds)
        let shown = values.filter { $0.value > 0 || showsZeros }  // Zero counts aren't shown.
        var badges: [Corner: Badge] = [:]
        for (left, right) in [(Corner.topLeft, Corner.topRight), (.bottomLeft, .bottomRight)] {
            // Each badge is sized by its own count alone, so it looks the same whatever its neighbor
            // shows. Only if two badges on a row would collide does each get about half the width.
            var pair = [left, right].compactMap { corner in shown[corner].map { (corner, $0) } }
                .map { ($0.0, $0.1, badge(for: $0.1, maxWidth: bounds.width * 0.62)) }
            if pair.count == 2 && pair[0].2.width + pair[1].2.width > bounds.width {
                pair = pair.map { ($0.0, $0.1, badge(for: $0.1, maxWidth: bounds.width * 0.52)) }
            }
            for (corner, _, badge) in pair { badges[corner] = badge }
        }
        // Bottom row first, then top-left, then top-right on top (as MailMate overlaps them).
        for corner in [Corner.bottomLeft, .bottomRight, .topLeft, .topRight] {
            if let badge = badges[corner] { draw(badge, at: corner) }
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

    private struct Badge {
        var label: NSAttributedString
        var width: CGFloat
    }

    private var badgeHeight: CGFloat { (bounds.height * 0.36).rounded() }

    private func badge(for value: Int, maxWidth: CGFloat) -> Badge {
        let height = badgeHeight
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
        return Badge(label: label, width: min(maxWidth, max(height, label.size().width + padding)))
    }

    private func draw(_ badge: Badge, at corner: Corner) {
        let height = badgeHeight, width = badge.width, label = badge.label
        let textSize = label.size()

        // In the tile's corner, as MailMate places them: flush with the top or bottom edge and the side.
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
    /// While the Counters settings are open, all four corners are shown so it's clear where each
    /// counter sits (as MailMate does): enabled ones with their count, even zero; disabled ones as 0.
    var isPreviewing = false {
        didSet {
            guard isPreviewing != oldValue else { return }
            lastValues = nil
            update()
        }
    }
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

    private func counting(_ kind: CountKind) -> MessageCount {
        switch kind {
        case .all: .all
        case .unread: .unread
        case .flagged: .flagged
        case .unreplied: .unreplied
        }
    }

    /// Recomputes the counters and redraws the Dock icon if anything changed.
    func update() {
        var values: [Corner: Int] = [:]
        for (corner, config) in CounterSettings.shared.counters where config.showInDock || isPreviewing {
            guard config.showInDock else { values[corner] = 0; continue }
            guard let scope = MessageScope(key: config.source) else { continue }
            values[corner] = (try? store.count(scope: scope, counting: counting(config.count))) ?? 0
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
        if isPreviewing || values.values.contains(where: { $0 > 0 }) {
            view.values = values
            view.showsZeros = isPreviewing
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
