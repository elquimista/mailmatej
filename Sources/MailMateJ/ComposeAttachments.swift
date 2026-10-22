import AppKit
import UniformTypeIdentifiers

/// The composer's bottom bar, as MailMate's (measured at 1x): with no attachments, a 45 pt bar with a 17 pt
/// add button in the middle; with attachments, a table of 23 pt rows, every other one striped, selectable
/// with the inset rounded selection (17 pt file icon 18 pt in, 13 pt name at 41 pt, its size ending 99 pt
/// from the right edge, then its Quick Look, Remove and Add buttons: 20 pt discs 26 pt apart, the last
/// ending 19 pt from the right edge), the first row's middle 16.5 pt down. Delete removes the selected rows.
final class ComposeAttachmentsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct Item {
        var name: String
        var size: Int?
        var icon: NSImage
    }

    var items: [Item] = [] {
        didSet { update() }
    }
    /// Sizes once encoded for sending, rather than the files' sizes (as the format bar's total).
    var showsEncodedSize = true {
        didSet { if showsEncodedSize != oldValue { reload() } }
    }
    /// A click on a size: switch between file and encoded sizes.
    var onToggleSize: () -> Void = {}
    var onAdd: () -> Void = {}
    /// A row's Remove or Quick Look button.
    var onRemove: (IndexSet) -> Void = { _ in }
    var onQuickLook: (IndexSet) -> Void = { _ in }
    /// A double-clicked row: opened in its default app, as in MailMate.
    var onOpen: (Int) -> Void = { _ in }

    static let rowHeight: CGFloat = 23
    /// Rows shown before the list scrolls.
    private static let maxVisibleRows = 5

    private let table = AttachmentTableView()
    private let scroll = NSScrollView()
    private let addButton = NSButton()
    private var height: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        addButton.isBordered = false
        addButton.image = Self.disc(size: 17, cut: Self.smallCross(in:))
        addButton.contentTintColor = Self.discColor
        addButton.toolTip = "Attach Files…"
        addButton.target = self
        addButton.action = #selector(add(_:))
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("attachment"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .plain
        table.allowsMultipleSelection = true
        table.onDelete = { [weak self] in
            guard let self, !table.selectedRowIndexes.isEmpty else { return }
            onRemove(table.selectedRowIndexes)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(open(_:))
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for view in [addButton, scroll] as [NSView] { addSubview(view) }
        height = heightAnchor.constraint(equalToConstant: 45)
        NSLayoutConstraint.activate([
            height,
            addButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            // The first row's middle 16.5 pt below the bar's top, as in MailMate.
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 16.5 - Self.rowHeight / 2),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(45 - 16.5 - Self.rowHeight / 2)),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        let empty = items.isEmpty
        addButton.isHidden = !empty
        scroll.isHidden = empty
        let rows = CGFloat(min(max(items.count, 1), Self.maxVisibleRows))
        height.constant = 45 + (rows - 1) * Self.rowHeight
        reload()
    }

    /// Reloads the rows, keeping the selection (a thumbnail arriving reloads them).
    private func reload() {
        let selected = table.selectedRowIndexes.filteredIndexSet { $0 < items.count }
        table.reloadData()
        table.selectRowIndexes(selected, byExtendingSelection: false)
    }

    @objc private func add(_ sender: Any?) { onAdd() }

    #if DEBUG
        func debugSelect(_ row: Int) {
            window?.makeFirstResponder(table)
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
    #endif
    @objc private func open(_ sender: Any?) {
        if table.clickedRow >= 0 { onOpen(table.clickedRow) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("attachment")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? AttachmentCell ?? AttachmentCell(identifier: id)
        let item = items[row]
        cell.imageView?.image = item.icon
        cell.textField?.stringValue = item.name
        cell.size.stringValue = item.size.map { Self.byteCount(showsEncodedSize ? Self.encodedSize($0) : $0) } ?? ""
        cell.size.toolTip = showsEncodedSize ? "Encoded size" : "File size"
        cell.onToggleSize = { [weak self] in self?.onToggleSize() }
        cell.onQuickLook = { [weak self] in self?.onQuickLook([row]) }
        cell.onRemove = { [weak self] in self?.onRemove([row]) }
        cell.onAdd = { [weak self] in self?.onAdd() }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: .init("stripe"), owner: nil) as? StripedRowView ?? StripedRowView()
        view.identifier = .init("stripe")
        view.striped = row % 2 == 1
        return view
    }

    /// One of a row's 20 pt round buttons.
    fileprivate static func button(_ cut: @escaping (NSRect) -> Void, _ tip: String) -> NSButton {
        let b = NSButton()
        b.isBordered = false
        b.image = disc(size: 20, diameter: 19.5, cut: cut)
        b.contentTintColor = discColor
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 20).isActive = true
        b.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return b
    }

    // MARK: Drawing

    /// The discs' grey: the window's text color at 55%, as the add button always had.
    private static let discColor = NSColor.labelColor.withAlphaComponent(0.55)

    /// A disc with a shape cut out of it (template, tinted by the button). `diameter` below the image's
    /// size leaves the disc on the pixel grid's corner, as MailMate's 19.5 pt discs sit.
    private static func disc(size: CGFloat, diameter: CGFloat? = nil, cut: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let disc = NSRect(x: 0, y: 0, width: diameter ?? size, height: diameter ?? size)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: disc).fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            cut(disc)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The empty bar's add button: a 9 pt cross of 1 pt lines in the middle of the 17 pt disc.
    private static func smallCross(in rect: NSRect) {
        let mid = NSPoint(x: floor(rect.midX), y: floor(rect.midY))
        NSRect(x: mid.x - 4, y: mid.y, width: 9, height: 1).fill()
        NSRect(x: mid.x, y: mid.y - 4, width: 1, height: 9).fill()
    }

    // MailMate's buttons, fitted to its pixels at 1x: a 19.5 pt disc with 9.5 pt lines, 1.25 pt thick,
    // centered on it (so off the pixel grid: they draw soft, not as hard 1 px lines).
    private static func horizontal(in disc: NSRect) {
        NSRect(x: disc.midX - 4.75, y: disc.midY - 0.625, width: 9.5, height: 1.25).fill()
    }

    fileprivate static func cross(in disc: NSRect) {
        horizontal(in: disc)
        NSRect(x: disc.midX - 0.625, y: disc.midY - 4.75, width: 1.25, height: 9.5).fill()
    }

    fileprivate static func minus(in disc: NSRect) { horizontal(in: disc) }

    /// The filled eye cut out, its pupil left as a ring, as MailMate's.
    fileprivate static func eye(in rect: NSRect) {
        guard let symbol = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        else { return }
        let size = symbol.size
        symbol.draw(
            in: NSRect(x: rect.midX - size.width / 2 + 0.5, y: rect.midY - size.height / 2 + 0.25, width: size.width, height: size.height),
            from: .zero, operation: .destinationOut, fraction: 1)
    }

    /// The size of a file once encoded for sending: base64 in 76-character lines ending in CRLF.
    static func encodedSize(_ bytes: Int) -> Int {
        let base64 = (bytes + 2) / 3 * 4
        return base64 + (base64 + 75) / 76 * 2
    }

    /// "15.5 KiB", as MailMate shows sizes: binary units, one decimal.
    static func byteCount(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) bytes" }
        let units = ["KiB", "MiB", "GiB"]
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: "%.1f %@", value, units[unit])
    }
}

private final class AttachmentCell: NSTableCellView {
    let size = NSTextField(labelWithString: "")
    var onToggleSize: () -> Void = {}
    var onQuickLook: () -> Void = {}
    var onRemove: () -> Void = {}
    var onAdd: () -> Void = {}

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        let name = NSTextField(labelWithString: "")
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        size.font = .systemFont(ofSize: 13)
        size.alignment = .right
        size.setContentCompressionResistancePriority(.required, for: .horizontal)
        size.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(sizeClicked(_:))))
        let buttons = NSStackView(views: [
            ComposeAttachmentsView.button(ComposeAttachmentsView.eye(in:), "Quick Look"),
            ComposeAttachmentsView.button(ComposeAttachmentsView.minus(in:), "Remove Attachment"),
            ComposeAttachmentsView.button(ComposeAttachmentsView.cross(in:), "Attach Files…"),
        ])
        buttons.spacing = 6
        for (button, action) in zip(buttons.arrangedSubviews.compactMap { $0 as? NSButton },
            [#selector(quickLookClicked(_:)), #selector(removeClicked(_:)), #selector(addClicked(_:))])
        {
            button.target = self
            button.action = action
        }
        for view in [icon, name, size, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = icon
        textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 17),
            icon.heightAnchor.constraint(equalToConstant: 19),  // a portrait picture's thumbnail is 19 pt tall
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 41),
            name.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),  // 1 pt above the middle, as MailMate
            size.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 12),
            size.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -99),
            size.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -19),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { size.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor }
    }

    @objc private func sizeClicked(_ sender: Any?) { onToggleSize() }
    @objc private func quickLookClicked(_ sender: Any?) { onQuickLook() }
    @objc private func removeClicked(_ sender: Any?) { onRemove() }
    @objc private func addClicked(_ sender: Any?) { onAdd() }
}

/// MailMate's rows (measured at 1x): every other one a little lighter than the bar (60 against 47, dark),
/// and the selection in its color; both a rounded rectangle 10 pt in from both sides, 5 pt corners, the
/// full row tall.
private final class StripedRowView: NSTableRowView {
    var striped = false {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard striped else { return }
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        shape.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        (isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        shape.fill()
    }

    private var shape: NSBezierPath { NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 0), xRadius: 5, yRadius: 5) }
}

/// The attachments table: Delete (or Forward Delete) removes the selected attachments.
private final class AttachmentTableView: NSTableView {
    var onDelete: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { return onDelete() }
        super.keyDown(with: event)
    }
}

/// The composer's text view: files dropped on it go to the composer (with the text position they were
/// dropped at), not inserted as paths, as in MailMate.
final class ComposeTextView: NSTextView {
    var onDropFiles: ([URL], Int) -> Void = { _, _ in }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onDropFiles(urls, characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil)))
        return true
    }
}

/// The composer's content view: files dropped anywhere on the window are attached.
final class FileDropView: NSView {
    var onDropFiles: ([URL]) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { fileURLs(sender).isEmpty ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        onDropFiles(urls)
        return true
    }
}
