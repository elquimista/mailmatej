import AppKit

/// MailMate's address completion for the composer's address fields, replacing AppKit's (which changes the
/// case of what's typed to match a suggestion and can't put it back):
/// - while what's typed starts the best suggestion, the rest of it is filled in, selected;
/// - once nothing starts with it, the text is exactly as typed again (case included);
/// - the suggestions show in a list under the field (measured at 1x: the field's width, 24 pt rows, 13 pt
///   text 11 pt in, the highlighted row in the accent color). ↑↓ move through them, Return or Tab takes
///   the highlighted one, Escape closes the list, a click takes one.
@MainActor
final class AddressCompleter: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// Suggestions for what's typed, leaving out the addresses already in the field.
    private let suggest: (_ typed: String, _ present: Set<String>) -> [String]

    private weak var field: AddressTokenField?
    /// The address being typed, exactly as typed, and where it starts in the field editor's text.
    private var typed = ""
    private var start = 0
    /// The table follows at once: laid out with a count of a longer list, it asked for rows past the end.
    private var items: [String] = [] {
        didSet { table.reloadData() }
    }
    private var highlighted = -1
    /// Set while this changes the text itself, so the change isn't taken for typing.
    private var applying = false

    private let panel = CompletionPanel()
    private let table = NSTableView()

    static let rowHeight: CGFloat = 24
    private static let maxRows = 10

    init(suggest: @escaping (_ typed: String, _ present: Set<String>) -> [String]) {
        self.suggest = suggest
        super.init()
        let column = NSTableColumn(identifier: .init("address"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.refusesFirstResponder = true

        let content = CompletionBackground()
        table.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: content.topAnchor, constant: 1),
            table.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -1),
            table.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 1),
            table.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -1),
        ])
        panel.contentView = content
    }

    // MARK: Typing

    /// After each edit in an address field: works out what's being typed and completes it.
    func textChanged(in field: AddressTokenField) {
        guard !applying, let editor = field.currentEditor() as? NSTextView else { return }
        self.field = field
        let text = editor.string as NSString
        let cursor = editor.selectedRange().location
        guard cursor <= text.length else { return close() }

        // The address being typed runs from after the previous token (or comma) to the cursor.
        var from = cursor
        while from > 0 {
            let c = text.character(at: from - 1)
            if c == 0xFFFC || c == 0x2C || c == 0x3B { break }  // token attachment, ",", ";"
            from -= 1
        }
        while from < cursor, text.character(at: from) == 0x20 { from += 1 }
        let fragment = text.substring(with: NSRange(location: from, length: cursor - from))

        // Keep what was typed exactly: a completion shown earlier may have changed its case.
        let previous = start == from ? typed : ""
        let added = fragment.count - previous.count
        let typing = added > 0 && fragment.lowercased().hasPrefix(previous.lowercased())
        typed = typing ? previous + fragment.suffix(added) : (fragment.count <= previous.count && start == from
            ? String(previous.prefix(fragment.count)) : fragment)
        start = from

        let present = Set(field.addresses.compactMap { $0.email?.lowercased() })
        items = typed.trimmingCharacters(in: .whitespaces).isEmpty ? [] : suggest(typed, present)
        // Nothing typed after the cursor (other than a completion's selected rest).
        let after = text.substring(from: cursor).prefix { $0 != "\u{FFFC}" && $0 != "," && $0 != ";" }
        let completes = typing && after.isEmpty && items.first?.lowercased().hasPrefix(typed.lowercased()) == true
        if completes, let best = items.first {
            highlighted = 0
            replaceFragment(with: best, selectingFrom: typed.count, in: editor)
        } else {
            highlighted = -1
            if fragment != typed { replaceFragment(with: typed, selectingFrom: nil, in: editor) }
        }
        items.isEmpty ? close() : show(below: field)
    }

    /// Return/Tab, ↑↓, Escape while the list is open. Returns whether it handled the key.
    func handle(_ command: Selector, in field: AddressTokenField) -> Bool {
        guard panel.isVisible, let editor = field.currentEditor() as? NSTextView else { return false }
        switch command {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let step = command == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            highlighted = max(0, min(items.count - 1, highlighted + step))
            let item = items[highlighted]
            replaceFragment(with: item, selectingFrom: item.lowercased().hasPrefix(typed.lowercased()) ? typed.count : 0, in: editor)
            table.selectRowIndexes([highlighted], byExtendingSelection: false)
            table.scrollRowToVisible(highlighted)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            replaceFragment(with: typed, selectingFrom: nil, in: editor)
            close()
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            // The highlighted one is already in the field: the token field makes it a token as usual.
            if highlighted >= 0 { replaceFragment(with: items[highlighted], selectingFrom: nil, in: editor) }
            close()
            return false
        default:
            return false
        }
    }

    #if DEBUG
        var debugPanelNumber: Int? { panel.isVisible ? panel.windowNumber : nil }
        var debugState: String { "list \(panel.isVisible ? "shown" : "hidden") \(items.count) items, highlighted \(highlighted)" }
    #endif

    func close() {
        if panel.isVisible {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        items = []
        highlighted = -1
    }

    /// Puts `text` where the address being typed is (through to the next token), selecting from
    /// `selectingFrom` characters in to its end (nil: the cursor after it).
    private func replaceFragment(with text: String, selectingFrom: Int?, in editor: NSTextView) {
        let string = editor.string as NSString
        var end = start
        while end < string.length {
            let c = string.character(at: end)
            if c == 0xFFFC || c == 0x2C || c == 0x3B { break }
            end += 1
        }
        let range = NSRange(location: start, length: end - start)
        applying = true
        defer { applying = false }
        if editor.shouldChangeText(in: range, replacementString: text) {
            editor.replaceCharacters(in: range, with: text)
            editor.didChangeText()
        }
        let length = (text as NSString).length
        if let from = selectingFrom {
            let offset = (String(text.prefix(from)) as NSString).length
            editor.setSelectedRange(NSRange(location: start + offset, length: length - offset))
        } else {
            editor.setSelectedRange(NSRange(location: start + length, length: 0))
        }
    }

    // MARK: List

    private func show(below field: AddressTokenField) {
        guard let window = field.window else { return }
        let anchor = field.completionAnchor ?? field
        let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let rows = CGFloat(min(items.count, Self.maxRows))
        let height = rows * Self.rowHeight + 2
        panel.setFrame(NSRect(x: frame.minX, y: frame.minY - height, width: frame.width, height: height), display: false)
        if highlighted >= 0 {
            table.selectRowIndexes([highlighted], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        if !panel.isVisible {
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, row < items.count, let field, let editor = field.currentEditor() as? NSTextView else { return }
        replaceFragment(with: items[row], selectingFrom: nil, in: editor)
        close()
        editor.insertText(",", replacementRange: editor.selectedRange())  // made a token, as typing "," does
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let id = NSUserInterfaceItemIdentifier("suggestion")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SuggestionCell ?? SuggestionCell(identifier: id)
        cell.textField?.stringValue = items[row]
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SuggestionRowView() }
}

/// The list's window: floats under the field without taking the keyboard from it.
private final class CompletionPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// MailMate's list: dark (41,45,49 at 1x) inside a 1 pt near-black border.
private final class CompletionBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 38 / 255, green: 42 / 255, blue: 46 / 255, alpha: 1).setFill()
        bounds.fill()
        NSColor.black.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }
}

/// The highlighted suggestion: the whole row in the accent color.
private final class SuggestionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        bounds.fill()
    }

    override var isEmphasized: Bool {
        get { true }
        set {}
    }
}

private final class SuggestionCell: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),  // 11 pt in from the list's edge
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { textField?.textColor = backgroundStyle == .emphasized ? .white : .labelColor }
    }
}
