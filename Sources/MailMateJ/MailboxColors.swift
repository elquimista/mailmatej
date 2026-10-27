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
    private static let defaultsKey = "MailboxColors"

    /// The color chosen for a mailbox, or nil for its default (accent; text grey for accounts).
    static func color(for key: String) -> MailboxColor? {
        (UserDefaults.standard.dictionary(forKey: defaultsKey)?[key] as? String).flatMap(MailboxColor.init(stored:))
    }

    // MARK: Use Color in Message List

    private static let listDefaultsKey = "MailboxColorsInList"

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

    /// Puts a mailbox's icon in its color: `image` gets the multicolor configuration where needed,
    /// `fallback` is the tint when no color was chosen.
    static func style(_ imageView: NSImageView, key: String, symbol: String, fallback: NSColor) {
        let image = NSImage(systemSymbolName: MailboxSymbols.symbol(for: key) ?? symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        switch color(for: key) {
        case .multicolor?:
            imageView.image = image?.withSymbolConfiguration(multicolor)
            imageView.contentTintColor = nil
        case .accent?:
            imageView.image = image
            imageView.contentTintColor = .controlAccentColor
        case let chosen?:
            // Drawn into the image (not a tint), so it keeps its color on a selected row, as in MailMate.
            imageView.image = image.map { tinted($0, chosen.tint ?? .labelColor) }
            imageView.contentTintColor = nil
        case nil:
            imageView.image = image
            imageView.contentTintColor = fallback
        }
    }

    /// A mailbox's icon for menus: its chosen symbol in black and white (a template, so it turns white
    /// on a highlighted row), as MailMate's menus show it; only the sidebar shows colors.
    static func menuImage(key: String, symbol: String) -> NSImage? {
        NSImage(systemSymbolName: MailboxSymbols.symbol(for: key) ?? symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
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
    private static let defaultsKey = "MailboxSymbols"

    /// MailMate's Symbol menu choices, in its order: the menu title and the SF Symbol.
    static let presets: [(title: String, symbol: String)] = [
        ("Calendar", "calendar"), ("Calendar with Badge", "calendar.badge.exclamationmark"),
        ("Envelope", "envelope"), ("Envelope with Badge", "envelope.badge"), ("Flag", "flag"),
        ("Folder", "folder"), ("Folder for Person", "folder.badge.person.crop"),
        ("List", "list.bullet.rectangle"), ("Star", "star"), ("Tag", "tag"),
    ]

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
