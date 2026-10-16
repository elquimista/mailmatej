import AppKit
import MailStore

/// A virtualized message list. It holds only the ordered IDs; rows are fetched in blocks
/// around what is visible and kept in a small cache, so memory stays flat for any list size.
@MainActor
final class MessageListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Column: String {
        case unread, flag, attachment, from, subject, date, source

        var title: String {
            switch self {
            case .unread, .flag, .attachment: ""
            case .from: "From"
            case .subject: "Subject"
            case .date: "Date Received"
            case .source: "Source Mailbox"
            }
        }

        var sortKey: MessageSort.Key? {
            switch self {
            case .from: .from
            case .subject: .subject
            case .date: .receivedAt
            default: nil
            }
        }
    }

    var onSelectionChange: ((Int64?) -> Void)?
    var onSortChange: ((MessageSort) -> Void)?
    /// "Show in Finder" chosen from a row's context menu.
    var onShowInFinder: ((Int64) -> Void)?

    /// The list's sort, remembered across launches (per list, keyed by its autosave name).
    private(set) var sort: MessageSort

    private let store: MailStore
    private let columns: [Column]
    private let autosaveName: String
    private let widths: [Column: CGFloat]
    private(set) var ids: [Int64] = []
    private var cache: [Int64: MessageRow] = [:]
    private var suppressSelection = false
    private(set) var tableView = NSTableView()

    private static let blockSize = 150
    private static let cacheLimit = 3000

    init(store: MailStore, columns: [Column], autosaveName: String, widths: [Column: CGFloat] = [:]) {
        self.store = store
        self.columns = columns
        self.autosaveName = autosaveName
        self.widths = widths
        sort = Self.savedSort(autosaveName) ?? .newestFirst
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let table = tableView
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.rowHeight = 17  // MailMate density: 13 pt text in 17 pt rows.
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.gridStyleMask = []

        for column in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            c.title = column.title
            switch column {
            case .unread, .flag, .attachment:
                c.width = 16
                c.minWidth = 16
                c.maxWidth = 16
                c.resizingMask = []
                let symbol = column == .flag ? "flag.fill" : column == .attachment ? "paperclip" : "circle.fill"
                c.headerCell.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
            case .from:
                c.width = 220
                c.minWidth = 80
                c.resizingMask = [.userResizingMask, .autoresizingMask]
            case .subject:
                c.width = 460
                c.minWidth = 120
                c.resizingMask = [.userResizingMask, .autoresizingMask]
            case .date:
                c.width = 140
                c.minWidth = 90
                c.resizingMask = .userResizingMask
            case .source:
                c.width = 170
                c.minWidth = 80
                c.resizingMask = [.userResizingMask, .autoresizingMask]
            }
            if let width = widths[column] { c.width = width }
            if let key = column.sortKey {
                c.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: key != .receivedAt)
            }
            table.addTableColumn(c)
        }
        table.autosaveName = autosaveName
        table.autosaveTableColumns = true
        table.sortDescriptors = [NSSortDescriptor(key: sort.key.rawValue, ascending: sort.ascending)]
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        view = scroll
    }

    // MARK: Data

    var selectedIDs: [Int64] {
        tableView.selectedRowIndexes.compactMap { $0 < ids.count ? ids[$0] : nil }
    }

    var selectedID: Int64? { selectedIDs.count == 1 ? selectedIDs[0] : nil }

    /// Where the list is scrolled, as "message X's top edge is `offset` points below the top of the view",
    /// so it survives rows being inserted or removed above it.
    struct ScrollAnchor {
        let id: Int64
        let offset: CGFloat
    }

    enum Scroll {
        /// Keep the same messages in view (used when data changes underneath the user).
        case keepPosition
        /// Return to a saved position; falls back to centering the selection.
        case restore(ScrollAnchor?)
        /// Bring the first selected message into view (centered if it was off-screen).
        case toSelection
        /// Bring a specific message into view.
        case toMessage(Int64?)
    }

    /// Whether the message's row is entirely in view (not cut off or under the column header).
    func isFullyVisible(_ id: Int64?) -> Bool {
        guard let id, let row = ids.firstIndex(of: id), let clip = tableView.enclosingScrollView?.contentView else {
            return false
        }
        var visible = tableView.convert(clip.documentVisibleRect, from: clip)
        let header = tableView.headerView?.frame.height ?? 0
        if clip.contentInsets.top < header {  // The header floats over the content.
            visible.origin.y += header - clip.contentInsets.top
            visible.size.height -= header - clip.contentInsets.top
        }
        return visible.contains(tableView.rect(ofRow: row).insetBy(dx: 0, dy: 1))
    }

    var scrollAnchor: ScrollAnchor? {
        guard let clip = tableView.enclosingScrollView?.contentView, !ids.isEmpty else { return nil }
        let top = clip.bounds.minY
        let row = tableView.row(at: NSPoint(x: 0, y: max(top, 0)))
        guard row >= 0, row < ids.count else { return nil }
        return ScrollAnchor(id: ids[row], offset: top - tableView.rect(ofRow: row).minY)
    }

    /// Replaces the list without firing `onSelectionChange`. `selecting: nil` keeps the current
    /// selection (where those messages still exist); `[]` clears it.
    func setIDs(_ newIDs: [Int64], selecting: [Int64]? = nil, scroll: Scroll = .keepPosition) {
        let wanted = selecting ?? selectedIDs
        let anchor = scrollAnchor

        ids = newIDs
        cache.removeAll(keepingCapacity: true)
        suppressSelection = true
        tableView.reloadData()
        let indexes = IndexSet(wanted.compactMap { newIDs.firstIndex(of: $0) })
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        suppressSelection = false

        switch scroll {
        case .keepPosition:
            if let anchor { restore(anchor) }
        case .restore(let saved):
            if !(saved.map(restore) ?? false), let row = indexes.first { center(row) }
        case .toSelection:
            if let row = indexes.first, !tableView.rows(in: tableView.visibleRect).contains(row) { center(row) }
        case .toMessage(let id):
            if let id, let row = newIDs.firstIndex(of: id) { tableView.scrollRowToVisible(row) }
        }
    }

    @discardableResult
    private func restore(_ anchor: ScrollAnchor) -> Bool {
        guard let row = ids.firstIndex(of: anchor.id) else { return false }
        scrollClip(toY: tableView.rect(ofRow: row).minY + anchor.offset)
        return true
    }

    private func center(_ row: Int) {
        guard let clip = tableView.enclosingScrollView?.contentView else { return }
        scrollClip(toY: tableView.rect(ofRow: row).midY - clip.bounds.height / 2)
    }

    private func scrollClip(toY y: CGFloat) {
        guard let scrollView = tableView.enclosingScrollView else { return }
        let clip = scrollView.contentView
        let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.minX, y: y), size: clip.bounds.size))
        clip.scroll(to: target.origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func row(at index: Int) -> MessageRow? {
        guard index < ids.count else { return nil }
        if let row = cache[ids[index]] { return row }
        if cache.count > Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        let lower = max(0, index - Self.blockSize / 3)
        let upper = min(ids.count, lower + Self.blockSize)
        for row in (try? store.rows(ids: Array(ids[lower..<upper]))) ?? [] {
            cache[row.id] = row
        }
        return cache[ids[index]]
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { ids.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
            let row = row(at: index)
        else { return nil }

        switch column {
        case .unread:
            return iconCell(tableView, column, symbol: row.isSeen ? nil : "circle.fill", tint: .controlAccentColor, size: 7)
        case .flag:
            return iconCell(tableView, column, symbol: row.isFlagged ? "flag.fill" : nil, tint: .systemRed, size: 10)
        case .attachment:
            return iconCell(tableView, column, symbol: row.hasAttachment ? "paperclip" : nil, tint: .secondaryLabelColor, size: 10)
        case .from:
            return textCell(tableView, column, row.fromDisplay, bold: !row.isSeen)
        case .subject:
            return textCell(tableView, column, row.subject.isEmpty ? "(no subject)" : row.subject, bold: !row.isSeen)
        case .date:
            return dateCell(tableView, row.receivedAt, bold: !row.isSeen)
        case .source:
            return textCell(tableView, column, "\(row.mailboxName) – \(row.accountName)", bold: false, secondary: true)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        onSelectionChange?(selectedID)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let first = tableView.sortDescriptors.first, let key = first.key.flatMap(MessageSort.Key.init) else { return }
        sort = MessageSort(key: key, ascending: first.ascending)
        UserDefaults.standard.set(["key": key.rawValue, "ascending": first.ascending], forKey: Self.sortDefaultsKey(autosaveName))
        onSortChange?(sort)
    }

    private static func sortDefaultsKey(_ name: String) -> String { "\(name).Sort" }

    private static func savedSort(_ name: String) -> MessageSort? {
        guard let saved = UserDefaults.standard.dictionary(forKey: sortDefaultsKey(name)),
            let key = (saved["key"] as? String).flatMap(MessageSort.Key.init),
            let ascending = saved["ascending"] as? Bool
        else { return nil }
        return MessageSort(key: key, ascending: ascending)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < ids.count else { return }
        let item = menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinderClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ids[row]
    }

    @objc private func showInFinderClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64 else { return }
        onShowInFinder?(id)
    }

    // MARK: Cells

    private func textCell(
        _ tableView: NSTableView, _ column: Column, _ text: String, bold: Bool, secondary: Bool = false,
        monospacedDigits: Bool = false
    ) -> NSView {
        let id = NSUserInterfaceItemIdentifier("text")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let field = NSTextField(labelWithString: "")
            field.lineBreakMode = .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.font = Self.font(bold: bold, monospacedDigits: monospacedDigits)
        cell.textField?.stringValue = text
        cell.textField?.textColor = secondary ? .secondaryLabelColor : .labelColor
        return cell
    }

    private static func font(bold: Bool, monospacedDigits: Bool = false) -> NSFont {
        let size = NSFont.systemFontSize
        let weight: NSFont.Weight = bold ? .semibold : .regular
        return monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// Date on the left, time right-aligned, as MailMate shows "12/31/89    6:59 PM".
    private func dateCell(_ tableView: NSTableView, _ date: Date, bold: Bool) -> NSView {
        let id = NSUserInterfaceItemIdentifier("date")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? DateCell ?? DateCell(identifier: id)
        let font = Self.font(bold: bold, monospacedDigits: true)
        cell.dateField.font = font
        cell.timeField.font = font
        cell.dateField.stringValue = Formatters.listDay(date)
        cell.timeField.stringValue = Formatters.listTime(date)
        return cell
    }

    private func iconCell(_ tableView: NSTableView, _ column: Column, symbol: String?, tint: NSColor, size: CGFloat) -> NSView {
        let id = NSUserInterfaceItemIdentifier("icon")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.imageView?.image = symbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        }
        cell.imageView?.contentTintColor = tint
        return cell
    }
}

@MainActor
enum Formatters {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    static func listDay(_ date: Date) -> String { day.string(from: date) }

    static func listTime(_ date: Date) -> String { time.string(from: date) }

    static func fullDate(_ date: Date) -> String { full.string(from: date) }
}

/// Two labels in one cell: the date at the leading edge, the time at the trailing edge.
final class DateCell: NSTableCellView {
    let dateField = NSTextField(labelWithString: "")
    let timeField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        timeField.alignment = .right
        for field in [dateField, timeField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byClipping
            addSubview(field)
        }
        textField = dateField  // Lets the table adjust colors for selected rows.
        NSLayoutConstraint.activate([
            dateField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            dateField.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            timeField.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeField.leadingAnchor.constraint(greaterThanOrEqualTo: dateField.trailingAnchor, constant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let color: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
            dateField.textColor = color
            timeField.textColor = color
        }
    }
}
