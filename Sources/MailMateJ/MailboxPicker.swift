import AppKit
import MailStore

/// MailMate's mailbox picker for the keyboard's "move to mailbox" (v) and "go to mailbox" (g then l): a
/// panel that appears at once (no sheet animation, which matters over a remote connection), with a
/// filter field, a field naming a new submailbox (moving only), two-line rows (name, then account or
/// "Unified"), and the selected mailbox's path and size at the bottom. Measured against MailMate at 1x:
/// 400 × 528 pt, 38 pt rows, 22 px icons 24 px in, names 13 pt at 55 px, accounts 10 pt.
/// ↑ and ↓ move, Return chooses, Escape closes.
@MainActor
final class MailboxPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSTextFieldDelegate,
    NSWindowDelegate, NSToolbarDelegate
{
    struct Choice {
        let node: SidebarNode
        let title: String
        /// The account, or "Unified".
        let subtitle: String
        let isUnified: Bool
        /// "account ▸ Parent ▸ Mailbox", shown at the bottom.
        let path: String
        let count: Int?
    }

    private let all: [Choice]
    private var shown: [Choice]
    private let onChoose: (Choice) -> Void
    private let onCreate: ((String, Choice) -> Void)?
    private let panel: NSPanel
    private let field = NSSearchField()
    /// A plain rounded field, outlined in the toolbar as MailMate's is.
    private let newField = NSTextField()
    private let table = NSTableView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let recentsKey: String
    /// Keeps the picker alive while its panel is up.
    private static var open: MailboxPicker?

    /// Shows the picker over `window`. Recently chosen mailboxes (per `recentsKey`) come first.
    /// - Parameter onCreate: given, the "new submailbox" field creates one inside the selected mailbox.
    static func show(
        over window: NSWindow, title: String, choices: [Choice], recentsKey: String,
        onChoose: @escaping (Choice) -> Void, onCreate: ((String, Choice) -> Void)? = nil
    ) {
        guard !choices.isEmpty else { return NSSound.beep() }
        open?.close()
        let recents = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        let byKey = Dictionary(choices.map { ($0.node.key, $0) }, uniquingKeysWith: { a, _ in a })
        let first = recents.compactMap { byKey[$0] }
        let ordered = first + choices.filter { !recents.contains($0.node.key) }
        let picker = MailboxPicker(
            choices: ordered, title: title, recentsKey: recentsKey, onChoose: onChoose, onCreate: onCreate)
        open = picker
        // MailMate's size, 400 × 528 (set once the toolbar is in, which would otherwise shrink it).
        let frame = window.frame
        picker.panel.setFrame(NSRect(x: frame.midX - 200, y: frame.midY - 264, width: 400, height: 528), display: false)
        picker.panel.makeKeyAndOrderFront(nil)
        // Once more now it's on screen: showing the toolbar the first time shrinks the panel.
        picker.panel.setFrame(NSRect(x: frame.midX - 200, y: frame.midY - 264, width: 400, height: 528), display: true)
        picker.panel.makeFirstResponder(picker.field)
    }

    private init(
        choices: [Choice], title: String, recentsKey: String, onChoose: @escaping (Choice) -> Void,
        onCreate: ((String, Choice) -> Void)?
    ) {
        all = choices
        shown = choices
        self.recentsKey = recentsKey
        self.onChoose = onChoose
        self.onCreate = onCreate
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        super.init()
        panel.title = title
        panel.animationBehavior = .none  // Appears and goes at once.
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        // Stays above the main window while it's clicked (as MailMate's does); a choice then applies to
        // whatever is selected at that moment.
        panel.isFloatingPanel = true
        panel.delegate = self
        // Only the close button, as MailMate's panel has.
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        field.placeholderString = "Search"
        field.delegate = self
        newField.placeholderString = "Name of new submailbox"
        newField.delegate = self
        newField.isHidden = onCreate == nil
        newField.isBezeled = false
        newField.drawsBackground = false
        newField.focusRingType = .none

        let column = NSTableColumn(identifier: .init("name"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 37  // 37 px selection, 1 px apart, as MailMate's
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(chooseClicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)  // 9 px above the first row

        // MailMate's footer (measured at 1x): 12 pt semibold, white in dark mode, the count right after
        // the path, on the list's background.
        let footerColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black }
        pathLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        pathLabel.textColor = footerColor
        pathLabel.lineBreakMode = .byTruncatingHead
        countLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        countLabel.textColor = footerColor
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bottomLine = NSBox()
        bottomLine.boxType = .separator
        let footer = NSBox()
        footer.boxType = .custom
        footer.borderWidth = 0
        footer.fillColor = table.backgroundColor

        let content = NSView()
        for v in [scroll, footer, bottomLine, pathLabel, countLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomLine.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            bottomLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pathLabel.topAnchor.constraint(equalTo: bottomLine.bottomAnchor, constant: 4),
            pathLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -5),
            pathLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            footer.topAnchor.constraint(equalTo: bottomLine.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            countLabel.leadingAnchor.constraint(equalTo: pathLabel.trailingAnchor, constant: 12),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            countLabel.firstBaselineAnchor.constraint(equalTo: pathLabel.firstBaselineAnchor),
        ])
        panel.contentView = content
        // The fields sit in the panel's toolbar, under the title, as in MailMate (title and fields 62 px,
        // fields 22 px tall at 8 px from the sides, 9 px apart).
        let toolbar = NSToolbar(identifier: "MailboxPicker")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        panel.toolbar = toolbar
        panel.toolbarStyle = .expanded
        table.reloadData()
        select(0)
    }

    // MARK: Toolbar

    private static let fieldsItem = NSToolbarItem.Identifier("fields")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.fieldsItem] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.fieldsItem] }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let stack = NSStackView(views: newField.isHidden ? [field] : [field, OutlinedField(newField)])
        stack.spacing = 9
        stack.distribution = .fill
        // MailMate's fields: 187 and 188 px wide, 9 px apart, 8 px from each side.
        if !newField.isHidden { field.widthAnchor.constraint(equalToConstant: 187).isActive = true }
        // 28 pt tall with the fields 4 pt from its top: the title band then reads 32 px and the toolbar's
        // line falls at 62 px, as in MailMate.
        let holder = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(stack)
        holder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // The toolbar centres its item 2 px left of the middle: 386 wide, fields from 2 in.
            holder.widthAnchor.constraint(equalToConstant: 386),
            holder.heightAnchor.constraint(equalToConstant: 28),
            stack.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            stack.topAnchor.constraint(equalTo: holder.topAnchor, constant: 4),
        ])
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = holder
        return item
    }

    // MARK: Filtering and keys

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === field else { return }
        // Letters in order, as MailMate matches ("postin" finds postmaster@…'s Inbox), best first.
        let query = field.stringValue
        shown = query.trimmingCharacters(in: .whitespaces).isEmpty ? all : all.enumerated().compactMap { index, choice in
            FuzzyMatch.score(query, in: [
                choice.subtitle + " " + choice.title, choice.title + " " + choice.subtitle, choice.path,
            ]).map { (score: $0, index: index, choice: choice) }
        }.sorted { ($0.score, $0.index) < ($1.score, $1.index) }.map(\.choice)
        table.reloadData()
        select(0)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): step(1)
        case #selector(NSResponder.moveUp(_:)): step(-1)
        case #selector(NSResponder.insertNewline(_:)): control === newField ? create() : choose()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func step(_ by: Int) {
        guard !shown.isEmpty else { return }
        select(max(0, min(shown.count - 1, table.selectedRow + by)))
    }

    private func select(_ row: Int) {
        guard shown.indices.contains(row) else {
            pathLabel.stringValue = ""
            countLabel.stringValue = ""
            return
        }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        updateFooter()
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateFooter() }

    private func updateFooter() {
        guard shown.indices.contains(table.selectedRow) else { return }
        let choice = shown[table.selectedRow]
        pathLabel.stringValue = choice.path
        countLabel.stringValue = choice.count.map { "\($0.formatted()) item\($0 == 1 ? "" : "s")" } ?? ""
    }

    @objc private func chooseClicked(_ sender: Any?) { choose() }

    private func choose() {
        guard shown.indices.contains(table.selectedRow) else { return NSSound.beep() }
        let choice = shown[table.selectedRow]
        remember(choice)
        close()
        onChoose(choice)
    }

    /// The "new submailbox" field: a mailbox with that name inside the selected one.
    private func create() {
        let name = newField.stringValue.trimmingCharacters(in: .whitespaces)
        guard let onCreate, !name.isEmpty, shown.indices.contains(table.selectedRow),
            case .mailbox? = shown[table.selectedRow].node.scope
        else { return NSSound.beep() }
        let parent = shown[table.selectedRow]
        close()
        onCreate(name, parent)
    }

    private func remember(_ choice: Choice) {
        var recents = UserDefaults.standard.stringArray(forKey: recentsKey) ?? []
        recents.removeAll { $0 == choice.node.key }
        recents.insert(choice.node.key, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(3)), forKey: recentsKey)
    }

    private func close() {
        panel.orderOut(nil)
        if Self.open === self { Self.open = nil }
    }

    func windowWillClose(_ notification: Notification) {
        if Self.open === self { Self.open = nil }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PickerRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("choice")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? PickerCell ?? PickerCell(identifier: id)
        cell.show(shown[row])
        return cell
    }

    #if DEBUG
        /// Types a filter and chooses the first match, as a user would; with `create`, names a new
        /// submailbox inside it instead.
        static func debugChoose(filter: String, create: String? = nil) {
            guard let picker = open else { return NSLog("MMJ picker: none open") }
            picker.field.stringValue = filter
            picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: picker.field))
            NSLog("MMJ picker: \(picker.shown.count) matches for \"\(filter)\": \(picker.shown.prefix(4).map { "\($0.title) — \($0.subtitle)" }) footer \(picker.pathLabel.stringValue) | \(picker.countLabel.stringValue)")
            if let create {
                picker.newField.stringValue = create
                picker.create()
            } else {
                picker.choose()
            }
        }

        static var debugPanel: NSWindow? { open?.panel }
        static var debugFirstRows: [String] { open.map { $0.shown.prefix(6).map { "\($0.title) — \($0.subtitle)" } } ?? [] }
    #endif
}

/// MailMate's "new submailbox" field: a 1 px outline (86 on its 72 toolbar) with 5 px corners, the text
/// 4 px inside it, 22 px tall.
private final class OutlinedField: NSView {
    init(_ field: NSTextField) {
        super.init(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 1, alpha: 0.065) : NSColor(white: 0, alpha: 0.12)).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        path.lineWidth = 1
        path.stroke()
    }
}

/// The selection 37 px tall, leaving the 1 px between rows, as MailMate draws it.
private final class PickerRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        (isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 1).fill()
    }
}

/// A picker row as MailMate draws it: icon, name, and the account (or "Unified", in italics) below.
private final class PickerCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let account = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail
        account.lineBreakMode = .byTruncatingTail
        icon.contentTintColor = .controlAccentColor
        icon.imageScaling = .scaleNone
        for v in [icon, name, account] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            // Symbols at 20 pt (a folder 22 × 18 px), centred 35 px in, unscaled.
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 35),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 28),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 54),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            account.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            account.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            account.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ choice: MailboxPicker.Choice) {
        name.stringValue = choice.title
        account.stringValue = choice.subtitle
        let font = NSFont.systemFont(ofSize: 10)
        account.font = choice.isUnified ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
        icon.image = NSImage(systemSymbolName: choice.node.symbol.isEmpty ? "folder" : choice.node.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
        updateColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        name.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        account.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        icon.contentTintColor = selected ? .alternateSelectedControlTextColor : .controlAccentColor
    }
}
