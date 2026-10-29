import AppKit
import MailStore
import MailSync

/// The block over a message, as MailMate draws it (measured at 1x): the header fields, a fading line,
/// the attachments and the remote-content bar. Native views, so an email's CSS can't touch them; they
/// scroll away with the message (see MessageViewController).
///
/// Fields: SF 13, labels right-aligned in a column as wide as the widest, values 8 pt after it, 14 pt in
/// from the edges, 8 pt above and below, rows 18 pt apart. Then the line (fading in from both sides);
/// with attachments or the bar under it, 8 pt below it, else the body follows 2 pt after it.
/// Attachments: a darker block with 5 pt above and below, 23 pt rows, every second row in a lighter box
/// with 4 pt corners inset 4 pt; 20 pt icon 15 pt in, name, size, then 20 pt round buttons 6 pt apart,
/// 18 pt from the right. A selected row fills that box with the selection color, its text and buttons
/// white. Then the remote-content bar (see RemoteBar).
@MainActor
final class MessageHeaderView: NSView {
    struct Field {
        var label: String
        var value: String
        /// Whether a search looks at it, so marks what it finds there (not the Date).
        var searched = true
    }

    struct Attachment {
        var name: String
        var size: String
        var icon: NSImage
    }

    var onOpen: (Int) -> Void = { _ in }
    var onQuickLook: (Int) -> Void = { _ in }
    /// The selection moved to this attachment with ↑ or ↓ (Quick Look, if open, follows it).
    var onSelectAttachment: (Int) -> Void = { _ in }
    /// Save to Downloads, or with ⌥ Save As….
    var onSave: (Int, _ option: Bool) -> Void = { _, _ in }
    var menuForAttachment: (Int) -> NSMenu? = { _ in nil }
    var dragItem: (Int) -> NSDraggingItem? = { _ in nil }
    /// The block's height changed (the remote-content bar's details opened or closed).
    var onResize: () -> Void = {}
    /// A bar button clicked, and the button (to show a menu under).
    var onBarAction: (MessagePage.Action, NSView) -> Void = { _, _ in }

    private var fieldViews: [(label: NSTextField, value: NSTextField)] = []
    /// The values a search looks at.
    private var searchedValues: [NSTextField] = []

    /// What's marked in the values, as MailMate marks it: the search's terms in the fields it looks at, or
    /// Find's text in all of them (each match its own, see `mark`).
    private var markTerms: [SearchHighlight] = []
    private var finding = false

    /// Marks `terms` in the values: the search's, or with `finding`, Find's (in the Date too, and matches
    /// side by side kept apart, each counted).
    func mark(_ terms: [SearchHighlight], finding: Bool) {
        guard terms != markTerms || finding != self.finding else { return }
        (markTerms, self.finding) = (terms, finding)
        markValues()
    }

    /// Find's current match among the header's, in order (yellow); nil for none here.
    var currentMark: Int? {
        didSet { if currentMark != oldValue { needsDisplay = true } }
    }

    /// How many matches the header shows.
    var markCount: Int { marks.reduce(0) { $0 + $1.ranges.count } }

    /// Where match `index` (counted as `currentMark`) is in this view.
    func markRect(_ index: Int) -> NSRect? {
        var next = 0
        for (value, ranges) in marks {
            if index < next + ranges.count { return markRects(value, ranges)[index - next].reduce(NSRect.null) { $0.union($1) } }
            next += ranges.count
        }
        return nil
    }
    private var rows: [AttachmentRow] = []
    /// The attachments shown, to keep the selection when the same message is shown again.
    private var attachmentKeys: [String] = []
    private var bar: RemoteBar?
    private let attachmentsBox = AttachmentsBox()
    private var line = FadingLine()

    override var isFlipped: Bool { true }

    // MARK: Metrics

    private static let font = NSFont.systemFont(ofSize: 13)
    private static let inset: CGFloat = 14
    private static let columnGap: CGFloat = 8
    private static let rowPitch: CGFloat = 18
    private static let rowHeight: CGFloat = 23
    /// A label's line at 13 pt, to count a wrapped value's lines.
    private static let lineHeight = ceil(font.ascender - font.descender + font.leading)

    // MARK: Colors (the CSS values the web page used, which came out as MailMate's on screen)

    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    private static func gray(_ v: Int) -> NSColor { NSColor(srgbRed: CGFloat(v) / 255, green: CGFloat(v) / 255, blue: CGFloat(v) / 255, alpha: 1) }
    private static func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
    }

    static let background = dynamic(dark: rgb(48, 50, 52), light: gray(242))
    static let labelColor = dynamic(dark: gray(128), light: rgb(134, 134, 139))
    static let valueColor = dynamic(dark: .white, light: rgb(29, 29, 31))
    static let lineColor = dynamic(dark: gray(202), light: NSColor(white: 0, alpha: 0.25))
    static let bottomBorder = dynamic(dark: .clear, light: gray(213))
    static let attachmentsBackground = dynamic(dark: rgb(32, 35, 38), light: NSColor(white: 0, alpha: 0.05))
    static let evenRow = dynamic(dark: rgb(42, 46, 47), light: NSColor(white: 0, alpha: 0.04))
    static let attachmentText = dynamic(dark: gray(222), light: rgb(29, 29, 31))
    /// What the search finds (MailMate's 170 grey on screen, light or dark).
    static let markBackground = gray(170)
    /// Find's current match (MailMate's yellow).
    static let currentMarkBackground = rgb(255, 255, 0)

    // MARK: Content

    /// Shows these fields (empty values left out), attachments and remote-content bar.
    func update(fields: [Field], attachments: [Attachment], bar: MessagePage.Bar?) {
        // The attachments block stays, so it keeps the focus while the same message is shown again.
        subviews.filter { $0 !== attachmentsBox }.forEach { $0.removeFromSuperview() }
        searchedValues = []
        fieldViews = fields.filter { !$0.value.isEmpty }.map { field in
            let label = NSTextField(labelWithString: field.label)
            label.font = Self.font
            label.textColor = Self.labelColor
            label.alignment = .right
            let value = NSTextField(wrappingLabelWithString: field.value)
            value.font = Self.font
            value.textColor = Self.valueColor
            value.isSelectable = true
            value.lineBreakMode = .byWordWrapping
            value.maximumNumberOfLines = 0
            if field.searched { searchedValues.append(value) }
            return (label, value)
        }
        for pair in fieldViews {
            addSubview(pair.label)
            addSubview(pair.value)
        }
        markValues()
        line = FadingLine()
        addSubview(line)

        rows = attachments.enumerated().map { index, attachment in
            let row = AttachmentRow(index: index, attachment: attachment, even: index % 2 == 1)
            row.header = self
            return row
        }
        let keys = attachments.map { $0.name + "\t" + $0.size }
        let kept = keys == attachmentKeys ? attachmentsBox.selected : nil
        attachmentKeys = keys
        // The box is kept from message to message, so the previous message's rows go with this.
        attachmentsBox.header = self
        attachmentsBox.subviews = rows
        attachmentsBox.selected = kept
        if rows.isEmpty {
            attachmentsBox.removeFromSuperview()
        } else if attachmentsBox.superview == nil {
            addSubview(attachmentsBox)
        }
        setBar(bar)
        needsLayout = true
    }

    /// Shows this remote-content bar (or none) in place of the one shown, as when what loaded changes it.
    func setBar(_ bar: MessagePage.Bar?) {
        self.bar?.removeFromSuperview()
        self.bar = bar.map { RemoteBar(bar: $0) }
        if let barView = self.bar {
            barView.onAction = { [weak self] action, view in self?.onBarAction(action, view) }
            barView.onToggle = { [weak self] in
                self?.needsLayout = true
                self?.onResize()
            }
            addSubview(barView)
        }
        needsLayout = true
    }

    /// Marks what the search (or Find) finds in the values: black on grey, as MailMate marks it (and the
    /// message's text, see MessagePage's `mmj-mark`).
    private func markValues() {
        let marked = finding ? fieldViews.map(\.value) : searchedValues
        marks = fieldViews.map(\.value).map { value in
            let text = value.stringValue
            let shown = NSMutableAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: Self.valueColor])
            let ranges = marked.contains(value) ? SearchHighlight.ranges(of: markTerms, in: text, joiningSpaced: !finding) : []
            for range in ranges { shown.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
            value.attributedStringValue = shown
            return (value, ranges)
        }
        currentMark = nil
        needsDisplay = true
    }

    /// The marked ranges of each searched value, their boxes drawn under the text (see `draw`).
    private var marks: [(value: NSTextField, ranges: [NSRange])] = []

    /// A value's marks, each its boxes (one a line): 16 px from the top of each line, on whole pixels, as
    /// MailMate's. (AppKit's own text background follows SF 13's 15.5 pt lines, so it falls half a pixel off.)
    private func markRects(_ value: NSTextField, _ ranges: [NSRange]) -> [[NSRect]] {
        guard !ranges.isEmpty, let cell = value.cell else { return [] }
        let text = cell.titleRect(forBounds: value.bounds)
        let storage = NSTextStorage(attributedString: value.attributedStringValue)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: text.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 2  // the field's own (its text starts 2 pt in)
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        return ranges.map { range in
            var rects: [NSRect] = []
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(
                forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                let r = self.convert(rect.offsetBy(dx: text.minX, dy: text.minY), from: value)
                rects.append(NSRect(x: r.minX.rounded(), y: r.minY.rounded(.down), width: (r.maxX - r.minX).rounded(), height: 16))
            }
            return rects
        }
    }

    /// Shows the round buttons' ⌥ variants (Save As… for Save to Downloads) while ⌥ is held.
    var showsOptionVariants = false {
        didSet { if showsOptionVariants != oldValue { rows.forEach { $0.showOptionVariant(showsOptionVariants) } } }
    }

    // MARK: Layout

    /// The block's height at `width`.
    func height(forWidth width: CGFloat) -> CGFloat { place(width: width, apply: false) }

    override func layout() {
        super.layout()
        place(width: bounds.width, apply: true)
        if marks.contains(where: { !$0.ranges.isEmpty }) { needsDisplay = true }  // the marks follow the values
    }

    @discardableResult
    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        let labelWidth = fieldViews.map { ceil($0.label.intrinsicContentSize.width) }.max() ?? 0
        let valueX = Self.inset + labelWidth + Self.columnGap
        let valueWidth = max(40, width - valueX - Self.inset)
        var y: CGFloat = 8
        for (index, pair) in fieldViews.enumerated() {
            pair.value.preferredMaxLayoutWidth = valueWidth
            let lines = max(1, round(pair.value.intrinsicContentSize.height / Self.lineHeight))
            // Rows sit 18 pt apart, a wrapped value's lines 17 pt apart (MailMate's 17.16 pt lines, 1 pt between rows).
            let height = Self.rowPitch - 1 + (lines - 1) * 17
            if apply {
                // Labels draw their text 2 pt inside their frames.
                pair.label.frame = NSRect(x: Self.inset - 2, y: y + Self.textDrop, width: labelWidth + 4, height: Self.rowPitch)
                pair.value.frame = NSRect(x: valueX - 2, y: y + Self.textDrop, width: valueWidth + 4, height: height)
            }
            y += height + (index == fieldViews.count - 1 ? 0 : 1)
        }
        y += 8
        let below = !rows.isEmpty || bar != nil
        if apply { line.frame = NSRect(x: 0, y: below ? y : y - 1, width: width, height: 1) }
        y += below ? 9 : 2
        if !rows.isEmpty {
            let height = 10 + CGFloat(rows.count) * Self.rowHeight
            if apply {
                attachmentsBox.frame = NSRect(x: 0, y: y, width: width, height: height)
                for (index, row) in rows.enumerated() {
                    row.frame = NSRect(x: 4, y: 5 + CGFloat(index) * Self.rowHeight, width: width - 8, height: Self.rowHeight)
                }
            }
            y += height
        }
        if let bar {
            let height = bar.height(forWidth: width)
            if apply { bar.frame = NSRect(x: 0, y: y, width: width, height: height) }
            y += height
        }
        if hasBorder { y += 1 }
        return y
    }

    /// How far a label's text sits below its row's top, to put it where the page put it.
    private static let textDrop: CGFloat = 0

    /// The light appearance closes the block with a 1 pt line, as the page did.
    private var hasBorder: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .darkAqua }

    override func draw(_ dirtyRect: NSRect) {
        Self.background.setFill()
        bounds.fill()
        if hasBorder {
            Self.bottomBorder.setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }
        var index = 0
        for (value, ranges) in marks {
            for rects in markRects(value, ranges) {
                (index == currentMark ? Self.currentMarkBackground : Self.markBackground).setFill()
                rects.forEach { $0.fill() }
                index += 1
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
        needsDisplay = true
        superview?.needsLayout = true
    }

    // MARK: Attachment rows

    fileprivate func open(_ index: Int) { onOpen(index) }
    fileprivate func quickLook(_ index: Int) { onQuickLook(index) }
    fileprivate func selectionMoved(_ index: Int) { onSelectAttachment(index) }
    fileprivate func save(_ index: Int, option: Bool) { onSave(index, option) }
    fileprivate func menu(_ index: Int) -> NSMenu? { menuForAttachment(index) }
    fileprivate func drag(_ index: Int) -> NSDraggingItem? { dragItem(index) }

    #if DEBUG
        /// Every row in the attachments block, current or left over, as name, size and top.
        var debugAttachmentRows: [String] { attachmentsBox.subviews.compactMap { ($0 as? AttachmentRow)?.debugText } }

        /// Clicks attachment `index`, as a click on its row does; nil presses the keys instead (↓ ↑ Space Return).
        func debugAttachment(click index: Int?, key: UInt16? = nil) {
            if let index { return attachmentsBox.select(index) }
            guard let key, let window,
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: key)
            else { return }
            attachmentsBox.keyDown(with: event)
        }
    #endif
}

/// The line under the fields: transparent at both ends, the line color in the middle.
private final class FadingLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let color = MessageHeaderView.lineColor
        NSGradient(colors: [color.withAlphaComponent(0), color, color.withAlphaComponent(0)])?.draw(in: bounds, angle: 0)
    }
}

/// The attachments block, whose rows select as MailMate's do: a click selects a row, shown in the
/// selection color while the block has the focus (grey otherwise); ↑ and ↓ move the selection, Space
/// shows the attachment in Quick Look and Return opens it.
private final class AttachmentsBox: NSView {
    weak var header: MessageHeaderView?
    var selected: Int? {
        didSet { updateHighlight() }
    }
    private var hasFocus = false {
        didSet { updateHighlight() }
    }

    #if DEBUG
        /// Draws the selection as while the window is in front (MMJ_DEBUG_EMPHASIZED), for checking it
        /// from scripts that leave the app behind.
        static let debugEmphasized = ProcessInfo.processInfo.environment["MMJ_DEBUG_EMPHASIZED"] != nil
    #endif

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }  // not in the Tab loop

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError() }

    private var rows: [AttachmentRow] { subviews.compactMap { $0 as? AttachmentRow } }

    /// A click on a row: selects it, and takes the focus for the keys.
    func select(_ index: Int) {
        selected = index
        window?.makeFirstResponder(self)
    }

    private func updateHighlight() {
        var emphasized = hasFocus && window?.isKeyWindow == true
        #if DEBUG
            emphasized = emphasized || (hasFocus && Self.debugEmphasized)
        #endif
        for row in rows {
            row.highlight = row.index != selected ? .none : emphasized ? .emphasized : .unemphasized
        }
    }

    override func becomeFirstResponder() -> Bool {
        hasFocus = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        hasFocus = false
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        NotificationCenter.default.removeObserver(self)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged), name: name, object: newWindow)
        }
    }

    @objc private func windowKeyChanged() { updateHighlight() }

    override func keyDown(with event: NSEvent) {
        let count = rows.count
        guard count > 0, event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            return super.keyDown(with: event)
        }
        switch event.keyCode {
        case 125, 126:  // ↓, ↑
            let down = event.keyCode == 125
            let next = min(max((selected ?? (down ? -1 : count)) + (down ? 1 : -1), 0), count - 1)
            guard next != selected else { return }
            selected = next
            header?.selectionMoved(next)
        case 49:  // Space
            if let selected { header?.quickLook(selected) }
        case 36, 76:  // Return, Enter
            if let selected { header?.open(selected) }
        default:
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        MessageHeaderView.attachmentsBackground.setFill()
        bounds.fill()
    }
}

/// An attachment: icon, name and size, and its Quick Look and Save buttons. Double-click opens it,
/// the context menu offers the rest, and it drags out as a file.
private final class AttachmentRow: NSView, NSDraggingSource {
    enum Highlight { case none, emphasized, unemphasized }

    let index: Int
    weak var header: MessageHeaderView?
    /// Selected, and whether the selection shows in the selection color (the block has the focus).
    var highlight = Highlight.none {
        didSet {
            guard highlight != oldValue else { return }
            let white = highlight == .emphasized
            for label in [name, size] { label.textColor = white ? .alternateSelectedControlTextColor : MessageHeaderView.attachmentText }
            quickLook.isOnSelection = white
            save.isOnSelection = white
            needsDisplay = true
        }
    }
    private let even: Bool
    private let icon = NSImageView()
    private let name: NSTextField
    private let size: NSTextField
    private let quickLook: CircleButton
    private let save: CircleButton
    private var pressLocation: NSPoint?
    private var dragged = false

    override var isFlipped: Bool { true }

    init(index: Int, attachment: MessageHeaderView.Attachment, even: Bool) {
        self.index = index
        self.even = even
        name = NSTextField(labelWithString: attachment.name)
        size = NSTextField(labelWithString: attachment.size)
        quickLook = CircleButton(symbol: "eye.circle.fill", title: "Quick Look")
        save = CircleButton(
            symbol: "arrow.down.circle.fill", title: "Save to Downloads",
            option: (symbol: "folder.circle.fill", title: "Save As…"))
        super.init(frame: .zero)
        icon.image = attachment.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        for label in [name, size] {
            label.font = .systemFont(ofSize: 13)
            label.textColor = MessageHeaderView.attachmentText
        }
        size.alignment = .right  // its text ends exactly 8 pt before the buttons
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = attachment.name
        name.cell?.usesSingleLineMode = true
        quickLook.onClick = { [weak self] _ in guard let self else { return }; header?.quickLook(index) }
        save.onClick = { [weak self] option in guard let self else { return }; header?.save(index, option: option) }
        [icon, name, size, quickLook, save].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func showOptionVariant(_ on: Bool) { save.showsOption = on }

    #if DEBUG
        var debugText: String { "\(name.stringValue) \(size.stringValue) y=\(frame.minY)\(highlight == .none ? "" : " selected (\(highlight))")" }
    #endif

    override func layout() {
        super.layout()
        // Placed on whole points where the page put them in the 23 pt row: buttons 1 pt from the top,
        // icon 2 pt, text 3 pt.
        icon.frame = NSRect(x: 11, y: 2, width: 20, height: 20)
        save.frame = NSRect(x: bounds.width - 14 - 20, y: 1, width: 20, height: 20)
        quickLook.frame = save.frame.offsetBy(dx: -26, dy: 0)
        let sizeWidth = ceil(size.intrinsicContentSize.width) + 6  // labels draw their text 2 pt inside
        size.frame = NSRect(x: quickLook.frame.minX - 8 - sizeWidth + 2, y: 3, width: sizeWidth, height: 16)
        name.frame = NSRect(x: icon.frame.maxX + 5 - 2, y: 3, width: max(0, size.frame.minX - 12 - icon.frame.maxX - 3), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The selection fills the same box as every second row (measured on MailMate's: identical).
        switch highlight {
        case .emphasized: NSColor.selectedContentBackgroundColor.setFill()
        case .unemphasized: NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        case .none:
            guard even else { return }
            MessageHeaderView.evenRow.setFill()
        }
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return showMenu(event) }
        (superview as? AttachmentsBox)?.select(index)
        pressLocation = event.locationInWindow
        dragged = false
        if event.clickCount >= 2 { header?.open(index) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressLocation, !dragged,
            hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 3,
            let item = header?.drag(index)
        else { return }
        dragged = true
        item.draggingFrame = NSRect(origin: convert(event.locationInWindow, from: nil).applying(.init(translationX: -16, y: -16)), size: NSSize(width: 32, height: 32))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { pressLocation = nil }

    override func rightMouseDown(with event: NSEvent) { showMenu(event) }

    private func showMenu(_ event: NSEvent) {
        guard let menu = header?.menu(index) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}

/// MailMate's round attachment buttons: a 20 pt grey circle with the symbol cut out, lighter while the
/// pointer is on it and darker while pressed; with an ⌥ variant, that shows while ⌥ is held. White on
/// a selected row, as MailMate's.
private final class CircleButton: NSView {
    var onClick: (_ option: Bool) -> Void = { _ in }
    var showsOption = false {
        didSet {
            toolTip = showsOption ? option?.title ?? title : title
            needsDisplay = true
        }
    }
    var isOnSelection = false {
        didSet { if isOnSelection != oldValue { needsDisplay = true } }
    }

    private let symbol: String
    private let title: String
    private let option: (symbol: String, title: String)?
    private var hovered = false {
        didSet { needsDisplay = true }
    }
    private var pressed = false {
        didSet { needsDisplay = true }
    }

    init(symbol: String, title: String, option: (symbol: String, title: String)? = nil) {
        self.symbol = symbol
        self.title = title
        self.option = option
        super.init(frame: .zero)
        toolTip = title
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Normal, hovered (brightened by a quarter) and pressed (darkened by a fifth), from the grey that
    /// shows as MailMate's (171, 172, 172); on a selected row white, pressed darkened by a sixth.
    private static let grays = [157, 196, 126]
    private static let whites = [255, 255, 214]

    /// Each circle made once (finding a symbol's ink renders it), shared by every row.
    private static var circles: [String: NSImage] = [:]

    private static func circle(_ symbolName: String, gray: Int) -> NSImage {
        let key = "\(symbolName) \(gray)"
        if let image = circles[key] { return image }
        let image = makeCircle(symbolName, gray: CGFloat(gray) / 255)
        circles[key] = image
        return image
    }

    private static func makeCircle(_ symbolName: String, gray: CGFloat) -> NSImage {
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 32, weight: .regular))
        else { return NSImage() }
        // The circle's ink, scaled to exactly 20 × 20 pt.
        let ink = MessageListViewController.inkBounds(of: symbol, integral: false)
        return NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            let scale = rect.width / max(ink.width, ink.height)
            symbol.draw(in: NSRect(
                x: -ink.minX * scale, y: -ink.minY * scale, width: symbol.size.width * scale, height: symbol.size.height * scale))
            NSColor(srgbRed: gray, green: gray, blue: gray, alpha: 1).set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let levels = isOnSelection ? Self.whites : Self.grays
        let name = showsOption ? option?.symbol ?? symbol : symbol
        Self.circle(name, gray: levels[pressed ? 2 : hovered ? 1 : 0]).draw(in: bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        // As a button does: tracks the pointer until release, acting only if it's still on the button.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                pressed = false
                if inside { onClick(next.modifierFlags.contains(.option)) }
                return
            }
            pressed = inside
        }
    }
}

/// The remote-content bar, MailMate's (measured at 1x): yellow while external resources are blocked,
/// orange when some are strictly blocked, red once a 1 by 1 image has been downloaded; 30 pt with buttons,
/// 28 without (all strictly blocked); a disclosure triangle 6 pt in, the text 22 pt in (SF 13, black, its baseline 20 pt down),
/// outlined buttons 7 pt from the right, 10 pt apart. Opened (a click on the bar), the details under it on
/// light grey (see `RemoteDetails`), for every message until closed again.
private final class RemoteBar: NSView {
    var onAction: (MessagePage.Action, NSView) -> Void = { _, _ in }
    /// The details opened or closed: the bar's height changed.
    var onToggle: () -> Void = {}
    private let level: MessagePage.Bar.Level
    private var barHeight: CGFloat { buttons.isEmpty ? 28 : 30 }
    private let label: NSTextField
    private let buttons: [BarButton]
    private let details: RemoteDetails

    override var isFlipped: Bool { true }

    private static let yellow = NSColor(srgbRed: 1, green: 214 / 255, blue: 10 / 255, alpha: 1)
    private static let orange = NSColor(srgbRed: 1, green: 159 / 255, blue: 10 / 255, alpha: 1)
    private static let red = NSColor(srgbRed: 1, green: 69 / 255, blue: 58 / 255, alpha: 1)

    /// Whether the details show (kept from message to message, as MailMate does).
    private static var opened: Bool {
        get { UserDefaults.standard.bool(forKey: "RemoteContentDetailsShown") }
        set { UserDefaults.standard.set(newValue, forKey: "RemoteContentDetailsShown") }
    }

    init(bar: MessagePage.Bar) {
        level = bar.level
        label = NSTextField(labelWithString: bar.text)
        buttons = bar.actions.map { BarButton(title: $0.title, action: $0.action) }
        details = RemoteDetails(bar.details)
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .black
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        addSubview(label)
        for button in buttons {
            button.onClick = { [weak self, weak button] in
                guard let self, let button else { return }
                onAction(button.action, button)
            }
            addSubview(button)
        }
        details.isHidden = !Self.opened
        addSubview(details)
    }

    required init?(coder: NSCoder) { fatalError() }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard !details.isHidden else { return barHeight }
        return barHeight + details.height(forWidth: width)
    }

    override func layout() {
        super.layout()
        var x = bounds.width - 7
        for button in buttons.reversed() {
            let size = button.intrinsicContentSize
            x -= size.width
            button.frame = NSRect(x: x, y: (barHeight - size.height) / 2, width: size.width, height: size.height)
            x -= 10
        }
        label.frame = NSRect(x: 19, y: 0, width: max(0, x - 19), height: 16)  // its ink 22 pt in
        label.frame.origin.y = 20 - label.firstBaselineOffsetFromTop
        details.frame = NSRect(x: 0, y: barHeight, width: bounds.width, height: bounds.height - barHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = switch level {
        case .yellow: Self.yellow
        case .orange: Self.orange
        case .red: Self.red
        }
        color.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: barHeight).fill()
        // MailMate's disclosure triangle, as measured: ▸ closed, ▾ opened (a little to the right).
        let triangle = NSBezierPath()
        if details.isHidden {
            triangle.move(to: NSPoint(x: 6.33, y: 11.9))
            triangle.line(to: NSPoint(x: 11.7, y: 14.5))
            triangle.line(to: NSPoint(x: 6.33, y: 17.1))
        } else {
            triangle.move(to: NSPoint(x: 7.25, y: 11.92))
            triangle.line(to: NSPoint(x: 12.61, y: 11.92))
            triangle.line(to: NSPoint(x: 9.93, y: 17.28))
        }
        triangle.close()
        NSColor.black.setFill()
        triangle.fill()
    }

    /// A click on the bar (not its buttons) opens or closes the details.
    override func mouseDown(with event: NSEvent) {
        guard convert(event.locationInWindow, from: nil).y < barHeight else { return super.mouseDown(with: event) }
        details.isHidden.toggle()
        Self.opened = !details.isHidden
        needsDisplay = true
        onToggle()
    }
}

/// The bar's details, MailMate's (measured at 1x): on light grey (238), each row's label 6 pt in and its
/// lines 202 pt in (SF 13, black, 16 pt lines, wrapping 18 pt short of the right, an address anywhere),
/// rows 10 pt apart, the first line 5 pt down, 4 pt under the last.
private final class RemoteDetails: NSView {
    private let rows: [(label: NSTextField, value: NSTextField)]

    override var isFlipped: Bool { true }

    init(_ details: [(label: String, lines: [String])]) {
        let font = NSFont.systemFont(ofSize: 13)
        let lines = NSMutableParagraphStyle()
        lines.minimumLineHeight = 16
        lines.maximumLineHeight = 16
        lines.lineBreakMode = .byWordWrapping
        rows = details.map { title, text in
            let label = NSTextField(labelWithString: title)
            label.font = font
            label.textColor = .black
            let value = NSTextField(wrappingLabelWithString: "")
            value.isSelectable = true
            value.attributedStringValue = NSAttributedString(
                string: text.joined(separator: "\n"), attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: lines])
            return (label, value)
        }
        super.init(frame: .zero)
        for row in rows {
            addSubview(row.label)
            addSubview(row.value)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func height(forWidth width: CGFloat) -> CGFloat { place(width: width, apply: false) }

    override func layout() {
        super.layout()
        place(width: bounds.width, apply: true)
    }

    @discardableResult
    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        let valueWidth = max(60, width - 200 - 16)
        var y: CGFloat = 5
        for (label, value) in rows {
            let height = ceil(value.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: valueWidth, height: 100_000)).height ?? 16)
            if apply {
                label.frame = NSRect(x: 4, y: y, width: 194, height: 16)
                value.frame = NSRect(x: 200, y: y, width: valueWidth, height: height)
            }
            y += height + 10
        }
        return y - 10 + 4
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 238 / 255, green: 238 / 255, blue: 238 / 255, alpha: 1).setFill()
        bounds.fill()
    }
}

/// The bar's buttons, MailMate's: SF 13 black in a 1 pt black outline with 4 pt corners, 20 pt tall, 7 pt
/// either side of the text.
private final class BarButton: NSView {
    let action: MessagePage.Action
    var onClick: () -> Void = {}
    private let title: NSAttributedString
    private var pressed = false {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    init(title: String, action: MessagePage.Action) {
        self.action = action
        self.title = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: (title.size().width + 14).rounded(.up), height: 20) }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        if pressed {
            NSColor(white: 0, alpha: 0.15).setFill()
            box.fill()
        }
        NSColor.black.setStroke()
        box.lineWidth = 1
        box.stroke()
        // On the bar's text's line (drawn from its line's top, which sits a point above the ascender).
        title.draw(at: NSPoint(x: (bounds.width - title.size().width) / 2, y: 14 - NSFont.systemFont(ofSize: 13).ascender))
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                pressed = false
                if inside { onClick() }
                return
            }
            pressed = inside
        }
    }
}
