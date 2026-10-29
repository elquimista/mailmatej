import AppKit

/// MailMate's find bar over the message (Edit ▸ Find ▸ Find…, ⌘F), AppKit's own: how many matches, the
/// text to find (with the recent ones), ‹ › for the previous and next match, Done. Measured at 1x: 29 pt
/// over a 1 pt line, SF 11; outlines 6 pt from the top: Done 42 × 18 pt, 7 pt from the right; ‹ › (two
/// 23 pt segments) 8 pt before it; the field 198 × 16 pt (from 7 pt down) 9 pt before that; the count's
/// text 10 pt before the field, on the same baseline as Done's, 19 pt down.
@MainActor
final class MessageFindBar: NSView, NSSearchFieldDelegate {
    /// The text to find changed (typed, cleared).
    var onChange: (String) -> Void = { _ in }
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onDone: () -> Void = {}

    let field = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let arrows = NSSegmentedControl()
    private let done = NSButton(title: "Done", target: nil, action: nil)

    static let height: CGFloat = 30

    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    private static func gray(_ v: CGFloat) -> NSColor { NSColor(srgbRed: v / 255, green: v / 255, blue: v / 255, alpha: 1) }
    static let background = dynamic(dark: NSColor(srgbRed: 41 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1), light: gray(236))
    static let line = dynamic(dark: NSColor(srgbRed: 62 / 255, green: 65 / 255, blue: 66 / 255, alpha: 1), light: gray(214))

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        count.font = small
        count.textColor = .labelColor
        count.alignment = .right

        field.controlSize = .small
        field.font = small
        field.cell?.isScrollable = true
        field.sendsSearchStringImmediately = true  // as typed, and when cleared
        field.target = self
        field.action = #selector(fieldChanged(_:))
        field.delegate = self
        field.recentsAutosaveName = "MessageFindRecents"
        field.searchMenuTemplate = Self.recentsMenu()

        arrows.segmentCount = 2
        arrows.trackingMode = .momentary
        arrows.controlSize = .regular  // 18 pt outlines (small ones are 16)
        arrows.segmentStyle = .roundRect  // outlined on the bar, as AppKit's find bar draws them
        arrows.setWidth(23, forSegment: 0)  // drawn 22 pt each, inside 23 pt apart outlines
        arrows.setWidth(21, forSegment: 1)
        arrows.setImage(NSImage(named: NSImage.goLeftTemplateName), forSegment: 0)
        arrows.setImage(NSImage(named: NSImage.goRightTemplateName), forSegment: 1)
        arrows.setToolTip("Previous Match", forSegment: 0)
        arrows.setToolTip("Next Match", forSegment: 1)
        arrows.target = self
        arrows.action = #selector(arrowClicked(_:))

        done.controlSize = .regular
        done.font = small
        done.bezelStyle = .roundRect
        done.target = self
        done.action = #selector(doneClicked(_:))

        [count, field, arrows, done].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The search field's menu: its recent finds, as AppKit's find bar keeps them.
    private static func recentsMenu() -> NSMenu {
        let menu = NSMenu()
        let title = NSMenuItem(title: "Recent Searches", action: nil, keyEquivalent: "")
        title.tag = NSSearchField.recentsTitleMenuItemTag
        let recents = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        recents.tag = NSSearchField.recentsMenuItemTag
        let none = NSMenuItem(title: "No Recent Searches", action: nil, keyEquivalent: "")
        none.tag = NSSearchField.noRecentsMenuItemTag
        let clear = NSMenuItem(title: "Clear Recent Searches", action: nil, keyEquivalent: "")
        clear.tag = NSSearchField.clearRecentsMenuItemTag
        [title, recents, none, .separator(), clear].forEach(menu.addItem)
        return menu
    }

    /// "2 matches", "1 match", "Not found"; nothing while there's no text.
    func showCount(_ matches: Int?) {
        count.stringValue = matches.map { $0 == 0 ? "Not found" : $0 == 1 ? "1 match" : "\($0) matches" } ?? ""
        needsLayout = true
    }

    /// Keeps the text found as a recent find (as Return does in AppKit's find bar).
    func rememberText() {
        let text = field.stringValue
        guard !text.isEmpty else { return }
        field.recentSearches = [text] + field.recentSearches.filter { $0 != text }.prefix(9)
    }

    override func layout() {
        super.layout()
        // Frames for the measured outlines: the buttons' 1 pt below their frames' tops (the segments' 1 pt
        // in from the left too), the search field's 1 pt in and 2 pt down.
        let right = bounds.width
        done.frame = NSRect(x: right - 49, y: 5, width: 42, height: 21)
        arrows.frame = NSRect(x: right - 105, y: 5, width: arrows.intrinsicContentSize.width, height: 21)
        field.frame = NSRect(x: right - 312, y: 5, width: 200, height: 19)
        count.sizeToFit()
        let width = count.frame.width
        count.frame = NSRect(x: right - 318 - width, y: 19 - count.firstBaselineOffsetFromTop, width: width, height: count.frame.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.background.setFill()
        bounds.fill()
        Self.line.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: Actions

    @objc private func fieldChanged(_ sender: NSSearchField) { onChange(sender.stringValue) }

    @objc private func arrowClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { onPrevious() } else { onNext() }
    }

    @objc private func doneClicked(_ sender: Any?) { onDone() }

    /// Return finds the next match (⇧Return the previous), as AppKit's; Escape, as MailMate's (see `escape`).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            rememberText()
            if NSEvent.modifierFlags.contains(.shift) { onPrevious() } else { onNext() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            escape()
            return true
        default:
            return false
        }
    }

    /// Escape clears the text first (the bar stays, for another), then, on an empty field, closes the bar.
    func escape() {
        guard !field.stringValue.isEmpty else { return onDone() }
        field.stringValue = ""
        onChange("")
    }
}
