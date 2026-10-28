import AppKit
import MailStore

/// A mailbox's icon color, as MailMate's Color menu sets it.
enum MailboxColor: Equatable {
    case accent
    case text
    /// The symbol's own colors, where it has them.
    case multicolor
    case system(String)
    case custom(NSColor)

    /// MailMate's System Colors, in its order: the stored name and the menu title.
    static let systemColors: [(name: String, title: String)] = [
        ("red", "Red"), ("green", "Green"), ("blue", "Blue"), ("orange", "Orange"), ("yellow", "Yellow"),
        ("brown", "Brown"), ("pink", "Pink"), ("purple", "Purple"), ("teal", "Teal"), ("indigo", "Indigo"),
        ("mint", "Mint"), ("cyan", "Cyan"), ("gray", "Gray"),
    ]

    static func systemColor(_ name: String) -> NSColor? {
        switch name {
        case "red": .systemRed
        case "green": .systemGreen
        case "blue": .systemBlue
        case "orange": .systemOrange
        case "yellow": .systemYellow
        case "brown": .systemBrown
        case "pink": .systemPink
        case "purple": .systemPurple
        case "teal": .systemTeal
        case "indigo": .systemIndigo
        case "mint": .systemMint
        case "cyan": .systemCyan
        case "gray": .systemGray
        default: nil
        }
    }

    /// The tint for the icon; nil for multicolor (the symbol draws its own colors).
    var tint: NSColor? {
        switch self {
        case .accent: .controlAccentColor
        case .text: .labelColor
        case .multicolor: nil
        case .system(let name): Self.systemColor(name) ?? .controlAccentColor
        case .custom(let color): color
        }
    }

    fileprivate var stored: String {
        switch self {
        case .accent: "accent"
        case .text: "text"
        case .multicolor: "multicolor"
        case .system(let name): "system:" + name
        case .custom(let color):
            "custom:" + [\.redComponent, \.greenComponent, \.blueComponent].map { (part: KeyPath<NSColor, CGFloat>) in
                String(format: "%.4f", (color.usingColorSpace(.sRGB) ?? color)[keyPath: part])
            }.joined(separator: ",")
        }
    }

    fileprivate init?(stored: String) {
        switch stored {
        case "accent": self = .accent
        case "text": self = .text
        case "multicolor": self = .multicolor
        case let s where s.hasPrefix("system:"): self = .system(String(s.dropFirst(7)))
        case let s where s.hasPrefix("custom:"):
            let parts = s.dropFirst(7).split(separator: ",").compactMap { Double($0) }
            guard parts.count == 3 else { return nil }
            self = .custom(NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: 1))
        default: return nil
        }
    }
}

/// Mailbox colors by sidebar key, kept in the app's preferences.
enum MailboxColors {
    static let didChange = Notification.Name("MailboxColorsDidChange")
    static let defaultsKey = "MailboxColors"

    /// The color chosen for a mailbox or source, or nil for its default (accent, as in MailMate).
    static func color(for key: String) -> MailboxColor? {
        (UserDefaults.standard.dictionary(forKey: defaultsKey)?[key] as? String).flatMap(MailboxColor.init(stored:))
    }

    // MARK: Use Color in Message List

    static let listDefaultsKey = "MailboxColorsInList"

    /// Mailboxes whose messages show their text in the mailbox's color, in the order they were set.
    static var listColoredKeys: [String] { UserDefaults.standard.stringArray(forKey: listDefaultsKey) ?? [] }

    static func usesColorInList(_ key: String) -> Bool { listColoredKeys.contains(key) }

    static func setUsesColorInList(_ on: Bool, for key: String) {
        var keys = listColoredKeys.filter { $0 != key }
        if on { keys.append(key) }
        UserDefaults.standard.set(keys, forKey: listDefaultsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The list each sidebar mailbox shows, and the mailbox it sits inside, by key (kept current by the
    /// sidebar).
    nonisolated(unsafe) static var scopes: [String: MessageScope] = [:]
    nonisolated(unsafe) static var parents: [String: String] = [:]

    /// Whether `key` is `viewing` or sits somewhere inside it in the sidebar.
    private static func isWithin(_ key: String, _ viewing: String) -> Bool {
        var current: String? = key
        var steps = 0
        while let k = current, steps < 64 {
            if k == viewing { return true }
            current = parents[k]
            steps += 1
        }
        return false
    }

    /// The text color of each of these messages, in the list of the mailbox `viewing`, that is in a
    /// mailbox using its color in the message list: that mailbox itself or one inside it (a color shows
    /// only in lists containing its mailbox). A message in several gets the innermost one's.
    static func listColors(for ids: [Int64], store: MailStore, viewing: String?) -> [Int64: NSColor] {
        guard let viewing else { return [:] }
        func depth(_ key: String) -> Int {
            var n = 0
            var k = key
            while let parent = parents[k], n < 64 { k = parent; n += 1 }
            return n
        }
        let keys = listColoredKeys.filter { isWithin($0, viewing) }.sorted { depth($0) > depth($1) }
        guard !keys.isEmpty, !ids.isEmpty else { return [:] }
        var colors: [Int64: NSColor] = [:]
        var left = ids
        for key in keys {
            guard !left.isEmpty, let scope = scopes[key], let inList = try? store.ids(left, in: scope), !inList.isEmpty else { continue }
            guard let chosen = color(for: key), chosen != .accent else { continue }  // greyed out for Accent
            let color = chosen.tint ?? .labelColor
            for id in inList { colors[id] = color }
            left.removeAll { inList.contains($0) }
        }
        return colors
    }

    static func set(_ color: MailboxColor, for key: String) {
        var all = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        all[key] = color.stored
        UserDefaults.standard.set(all, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Puts a mailbox's icon in its color (the accent when none was chosen): `image` gets the
    /// multicolor configuration where needed.
    static func style(_ imageView: NSImageView, key: String, symbol: String) {
        let image = MailboxSymbols.symbol(for: key).flatMap { MailboxSymbols.image($0) } ?? MailboxSymbols.image(symbol)
        switch color(for: key) {
        case .multicolor?:
            imageView.image = image?.withSymbolConfiguration(multicolor)
            imageView.contentTintColor = nil
        case .accent?, nil:
            imageView.image = image
            imageView.contentTintColor = .controlAccentColor
        case let chosen?:
            // Drawn into the image (not a tint), so it keeps its color on a selected row, as in MailMate.
            imageView.image = image.map { tinted($0, chosen.tint ?? .labelColor) }
            imageView.contentTintColor = nil
        }
    }

    /// A mailbox's icon for menus: its chosen symbol in black and white (a template, so it turns white
    /// on a highlighted row), as MailMate's menus show it; only the sidebar shows colors.
    static func menuImage(key: String, symbol: String) -> NSImage? {
        MailboxSymbols.symbol(for: key).flatMap { MailboxSymbols.menuImage($0) } ?? MailboxSymbols.menuImage(symbol)
    }

    /// A symbol filled with a color, as a plain (non-template) image the selection doesn't recolor.
    /// Drawn on demand, so dynamic colors follow the appearance.
    static func tinted(_ symbol: NSImage, _ color: NSColor) -> NSImage {
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        image.alignmentRect = symbol.alignmentRect
        return image
    }

    /// The symbol's own colors; a symbol without any is drawn in the text color (not plain black).
    static var multicolor: NSImage.SymbolConfiguration {
        NSImage.SymbolConfiguration(hierarchicalColor: .labelColor).applying(.preferringMulticolor())
    }

    // MARK: Menu swatches

    /// A swatch drawn in a 13 pt square, in an image one point taller: a menu row (22 pt) centers a
    /// 13 pt image on a half point, which cut off the circles' top or bottom; 14 pt sits on whole points.
    private static func swatchImage(width: CGFloat = 13, _ draw: @escaping (NSRect) -> Void) -> NSImage {
        NSImage(size: NSSize(width: width, height: 14), flipped: false) { _ in
            draw(NSRect(x: 0, y: 1, width: width, height: 13))
            return true
        }
    }

    /// MailMate's swatch (measured at 1x): a 13 pt ring, 1 pt wide, around a 9 pt dot, both in the color.
    static func swatch(_ color: @escaping () -> NSColor) -> NSImage {
        swatchImage { rect in
            color().set()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
        }
    }

    /// Custom…: a dashed ring around a grey dot.
    static let customSwatch = swatchImage { rect in
        NSColor.labelColor.withAlphaComponent(0.8).set()
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.setLineDash([1.5, 1], count: 2, phase: 0)
        ring.stroke()
        NSColor.systemGray.withAlphaComponent(0.9).set()
        NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5)).fill()
    }

    /// Multicolor: seven dots, one in the middle and six around it.
    static let multicolorSwatch = swatchImage(width: 15) { rect in
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemPurple, .systemYellow, .systemBlue, .white]
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let dot: CGFloat = 4.2
        for (i, color) in colors.enumerated() {
            let angle = CGFloat(i) * .pi / 3 + .pi / 3
            let p = NSPoint(x: center.x + cos(angle) * 4.4, y: center.y + sin(angle) * 4.4)  // within the 13 pt square
            color.set()
            NSBezierPath(ovalIn: NSRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot)).fill()
        }
        NSColor.systemGreen.set()
        NSBezierPath(ovalIn: NSRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)).fill()
    }
}

/// Mailbox symbols chosen with MailMate's Symbol menu, by sidebar key, kept in the app's preferences.
enum MailboxSymbols {
    static let defaultsKey = "MailboxSymbols"

    /// MailMate's Symbol menu choices, in its order: the menu title and the SF Symbol.
    static let presets: [(title: String, symbol: String)] = [
        ("Calendar", "calendar"), ("Calendar with Badge", "calendar.badge.exclamationmark"),
        ("Envelope", "envelope"), ("Envelope with Badge", "envelope.badge"), ("Flag", "flag"),
        ("Folder", "folder"), ("Folder for Person", "folder.badge.person.crop"),
        ("List", "list.bullet.rectangle"), ("Star", "star"), ("Tag", "tag"),
    ]

    /// Sources' symbols, drawn here (`image`), as MailMate picks one by provider: Gmail's G, Fastmail's
    /// mark, and SF's network globe for the rest.
    static let gmail = "mailmatej.gmail"
    static let fastmail = "mailmatej.fastmail"
    static let network = "mailmatej.network"
    /// Each one's size in the sidebar, in points square (see `sourceImage`), and how it's drawn.
    private static let drawings: [String: (size: CGFloat, draw: @Sendable (CGFloat) -> Void)] = [
        gmail: (12, drawG), fastmail: (13, drawFastmail), network: (13, drawNetwork),
    ]
    static var drawn: Set<String> { Set(drawings.keys) }

    /// A source's symbol: Gmail's G, Fastmail's mark for an account on its servers (fastmail.com or
    /// messagingengine.com, as MailMate tells them), else the network globe.
    static func symbol(for account: AccountRecord) -> String {
        if account.isGmail { return gmail }
        let host = URL(string: account.sessionURL)?.host?.lowercased() ?? ""
        let onFastmail = ["fastmail.com", "messagingengine.com"].contains { host == $0 || host.hasSuffix("." + $0) }
        return onFastmail ? fastmail : network
    }

    /// A symbol by name: an SF Symbol, or one drawn here at `scale` times its sidebar size (`sidebar`:
    /// placed as the sidebar wants it, see `sourceImage`; else alone in its square).
    static func image(_ name: String, scale: CGFloat = 1, sidebar: Bool = true) -> NSImage? {
        guard let drawing = drawings[name] else { return NSImage(systemSymbolName: name, accessibilityDescription: nil) }
        return sourceImage(drawing.size, scale, sidebar, drawing.draw)
    }

    /// A symbol for a menu item. A menu shows at most 12 pt of an image's height (the 13 pt ones lost
    /// an edge), so drawn ones are that tall at most, centred.
    static func menuImage(_ name: String) -> NSImage? {
        image(name, scale: drawings[name].map { 12 / $0.size } ?? 1, sidebar: false)
    }

    /// A source's symbol, `size` points square in the sidebar. MailMate's G is 12 pt beside the 13 pt
    /// name, a point beyond its ascenders above and below (measured at 1x); the network globe, and
    /// Fastmail's mark with it, are a point bigger, as MailMate draws SF Symbols bigger than ours (its
    /// folder 15 by 12 pt, ours 14 by 11). A template, so it takes the row's tint. For the sidebar the
    /// image is 16 pt wide, the symbol ending 3 pt from its right: centred in the sidebar's 18 pt icon
    /// box, the symbol ends 9 pt before the name, as MailMate's do.
    private static func sourceImage(
        _ size: CGFloat, _ scale: CGFloat, _ sidebar: Bool, _ draw: @escaping @Sendable (CGFloat) -> Void
    ) -> NSImage {
        let width = sidebar ? 16 : size, left = sidebar ? 13 - size : 0
        let image = NSImage(size: NSSize(width: width * scale, height: size * scale), flipped: false) { _ in
            NSGraphicsContext.current?.cgContext.translateBy(x: left * scale, y: 0)
            draw(size * scale)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// A G: a ring a fifth as thick, heavier than the SF Symbols around it (as MailMate's), open at the
    /// upper right, and a bar from its middle to the right edge, 2 pt at 12 pt so it sits on the pixel grid.
    private static func drawG(_ size: CGFloat) {
        let ring = size / 5
        let center = NSPoint(x: size / 2, y: size / 2)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: (size - ring) / 2, startAngle: 45, endAngle: 0)
        arc.lineWidth = ring
        NSColor.black.set()
        arc.stroke()
        NSRect(x: center.x, y: center.y - size / 12, width: size / 2, height: size / 6).fill()
    }

    /// Fastmail's mark in one color, simplified to read at this size: a thin ring around an envelope
    /// notched at the top to its middle. The envelope's edges are on whole points.
    private static func drawFastmail(_ size: CGFloat) {
        let ring = size * 1.25 / 12
        let center = NSPoint(x: size / 2, y: size / 2)
        let circle = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: ring / 2, dy: ring / 2))
        circle.lineWidth = ring
        NSColor.black.set()
        circle.stroke()
        let left = (size / 4).rounded(), right = size - left
        let bottom = (size * 0.3).rounded(), top = size - bottom
        let envelope = NSBezierPath()
        envelope.move(to: NSPoint(x: left, y: top))
        envelope.line(to: NSPoint(x: center.x, y: (top + bottom) / 2))
        envelope.line(to: NSPoint(x: right, y: top))
        envelope.line(to: NSPoint(x: right, y: bottom))
        envelope.line(to: NSPoint(x: left, y: bottom))
        envelope.close()
        envelope.fill()
    }

    /// SF's network globe: at a point size equal to the size, its outline is that wide, centred in the
    /// symbol's image.
    private static func drawNetwork(_ size: CGFloat) {
        guard let symbol = NSImage(systemSymbolName: "network", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        else { return }
        let origin = NSPoint(x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2)
        symbol.draw(in: NSRect(origin: origin, size: symbol.size))
    }

    /// The symbol chosen for a mailbox, or nil for its default.
    static func symbol(for key: String) -> String? {
        UserDefaults.standard.dictionary(forKey: defaultsKey)?[key] as? String
    }

    /// nil goes back to the mailbox's default symbol.
    static func set(_ symbol: String?, for key: String) {
        var all = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        all[key] = symbol
        UserDefaults.standard.set(all, forKey: defaultsKey)
        NotificationCenter.default.post(name: MailboxColors.didChange, object: nil)
    }

    /// Every SF Symbol name this system has, A to Z, as MailMate's Symbols panel lists them.
    nonisolated(unsafe) static let allNames: [String] = {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let symbols = plist["symbols"] as? [String: Any]
        else { return presets.map(\.symbol).sorted() }
        return symbols.keys.sorted()
    }()
}
