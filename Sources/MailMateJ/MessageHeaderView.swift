import AppKit
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
/// 18 pt from the right. The bar: 29 pt, text 14 pt in, buttons 8 pt apart, 10 pt from the right.
@MainActor
final class MessageHeaderView: NSView {
    struct Field {
        var label: String
        var value: String
    }

    struct Attachment {
        var name: String
        var size: String
        var icon: NSImage
    }

    var onOpen: (Int) -> Void = { _ in }
    var onQuickLook: (Int) -> Void = { _ in }
    /// Save to Downloads, or with ⌥ Save As….
    var onSave: (Int, _ option: Bool) -> Void = { _, _ in }
    var menuForAttachment: (Int) -> NSMenu? = { _ in nil }
    var dragItem: (Int) -> NSDraggingItem? = { _ in nil }
    /// A bar button clicked, and the button (to show a menu under).
    var onBarAction: (MessagePage.Action, NSView) -> Void = { _, _ in }

    private var fieldViews: [(label: NSTextField, value: NSTextField)] = []
    private var rows: [AttachmentRow] = []
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

    // MARK: Content

    /// Shows these fields (empty values left out), attachments and remote-content bar.
    func update(fields: [Field], attachments: [Attachment], bar: MessagePage.Bar?) {
        subviews.forEach { $0.removeFromSuperview() }
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
            return (label, value)
        }
        for pair in fieldViews {
            addSubview(pair.label)
            addSubview(pair.value)
        }
        line = FadingLine()
        addSubview(line)

        rows = attachments.enumerated().map { index, attachment in
            let row = AttachmentRow(index: index, attachment: attachment, even: index % 2 == 1)
            row.header = self
            return row
        }
        if !rows.isEmpty {
            addSubview(attachmentsBox)
            rows.forEach(attachmentsBox.addSubview)
        }
        self.bar = bar.map { RemoteBar(bar: $0) }
        if let barView = self.bar {
            barView.onAction = { [weak self] action, view in self?.onBarAction(action, view) }
            addSubview(barView)
        }
        needsLayout = true
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
            if apply { bar.frame = NSRect(x: 0, y: y, width: width, height: RemoteBar.height) }
            y += RemoteBar.height
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
    fileprivate func save(_ index: Int, option: Bool) { onSave(index, option) }
    fileprivate func menu(_ index: Int) -> NSMenu? { menuForAttachment(index) }
    fileprivate func drag(_ index: Int) -> NSDraggingItem? { dragItem(index) }
}

/// The line under the fields: transparent at both ends, the line color in the middle.
private final class FadingLine: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let color = MessageHeaderView.lineColor
        NSGradient(colors: [color.withAlphaComponent(0), color, color.withAlphaComponent(0)])?.draw(in: bounds, angle: 0)
    }
}

private final class AttachmentsBox: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        MessageHeaderView.attachmentsBackground.setFill()
        bounds.fill()
    }
}

/// An attachment: icon, name and size, and its Quick Look and Save buttons. Double-click opens it,
/// the context menu offers the rest, and it drags out as a file.
private final class AttachmentRow: NSView, NSDraggingSource {
    let index: Int
    weak var header: MessageHeaderView?
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
        guard even else { return }
        MessageHeaderView.evenRow.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return showMenu(event) }
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
/// pointer is on it and darker while pressed; with an ⌥ variant, that shows while ⌥ is held.
private final class CircleButton: NSView {
    var onClick: (_ option: Bool) -> Void = { _ in }
    var showsOption = false {
        didSet {
            toolTip = showsOption ? option?.title ?? title : title
            needsDisplay = true
        }
    }

    private let images: [NSImage]
    private let optionImages: [NSImage]?
    private let title: String
    private let option: (symbol: String, title: String)?
    private var hovered = false {
        didSet { needsDisplay = true }
    }
    private var pressed = false {
        didSet { needsDisplay = true }
    }

    init(symbol: String, title: String, option: (symbol: String, title: String)? = nil) {
        images = Self.variants(symbol)
        optionImages = option.map { Self.variants($0.symbol) }
        self.title = title
        self.option = option
        super.init(frame: .zero)
        toolTip = title
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Normal, hovered (brightened by a quarter) and pressed (darkened by a fifth), from the grey that
    /// shows as MailMate's (171, 172, 172).
    private static func variants(_ symbol: String) -> [NSImage] {
        [157, 196, 126].map { circle(symbol, gray: CGFloat($0) / 255) }
    }

    private static func circle(_ symbolName: String, gray: CGFloat) -> NSImage {
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
        let set = showsOption ? optionImages ?? images : images
        set[pressed ? 2 : hovered ? 1 : 0].draw(in: bounds)
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

/// The remote-content bar: orange while remote content is blocked, grey once it's loaded, its
/// buttons on the right.
private final class RemoteBar: NSView {
    static let height: CGFloat = 29
    var onAction: (MessagePage.Action, NSView) -> Void = { _, _ in }
    private let loaded: Bool
    private let label: NSTextField
    private let buttons: [BarButton]

    override var isFlipped: Bool { true }

    private static let blocked = NSColor(srgbRed: 1, green: 159 / 255, blue: 10 / 255, alpha: 1)
    private static let loadedBackground = NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 58 / 255, green: 58 / 255, blue: 60 / 255, alpha: 1)
            : NSColor(srgbRed: 232 / 255, green: 232 / 255, blue: 237 / 255, alpha: 1)
    }
    private static let loadedText = NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 174 / 255, green: 174 / 255, blue: 178 / 255, alpha: 1)
            : NSColor(srgbRed: 110 / 255, green: 110 / 255, blue: 115 / 255, alpha: 1)
    }

    init(bar: MessagePage.Bar) {
        loaded = bar.loaded
        label = NSTextField(labelWithString: bar.text)
        buttons = bar.actions.map { BarButton(title: $0.title, action: $0.action) }
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: 13)
        label.textColor = loaded ? Self.loadedText : .black
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
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        var x = bounds.width - 10
        for button in buttons.reversed() {
            let size = button.intrinsicContentSize
            x -= size.width
            button.frame = NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
            x -= 8
        }
        label.frame = NSRect(x: 14 - 2, y: (bounds.height - 16) / 2, width: max(0, x - 12), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        (loaded ? Self.loadedBackground : Self.blocked).setFill()
        bounds.fill()
    }
}

/// The bar's small white buttons: SF 11, 1 pt translucent border, 5 pt corners, 9 pt either side.
private final class BarButton: NSView {
    let action: MessagePage.Action
    var onClick: () -> Void = {}
    private let title: NSAttributedString
    private var pressed = false {
        didSet { needsDisplay = true }
    }

    init(title: String, action: MessagePage.Action) {
        self.action = action
        self.title = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(srgbRed: 29 / 255, green: 29 / 255, blue: 31 / 255, alpha: 1),
        ])
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: (title.size().width + 20).rounded(), height: 19)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The fill runs under the border too, so the border shows grey on any bar.
        (pressed ? NSColor(white: 229 / 255, alpha: 1) : .white).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
        NSColor(white: 0, alpha: 0.25).setStroke()
        box.lineWidth = 1
        box.stroke()
        let size = title.size()
        title.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
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
