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
            case .unread: .unread
            case .flag: .flagged
            default: nil
            }
        }
    }

    var onSelectionChange: ((Int64?) -> Void)?
    var onSortChange: ((MessageSort) -> Void)?
    /// "Show in Finder" chosen from a row's context menu.
    var onShowInFinder: ((Int64) -> Void)?
    /// A message double-clicked.
    var onOpen: ((Int64) -> Void)?

    /// The list's sort, remembered across launches (per list, keyed by its autosave name).
    private(set) var sort: MessageSort

    private let store: MailStore
    private let columns: [Column]
    private let autosaveName: String
    private let widths: [Column: CGFloat]
    /// Dates as "47 hours ago", "11 days ago" (MailMate's Correspondence pane) instead of day and time.
    private let relativeDates: Bool
    private var relativeTimer: Timer?
    private(set) var ids: [Int64] = []
    private var cache: [Int64: MessageRow] = [:]
    private var suppressSelection = false
    private(set) var tableView: NSTableView = MessageTableView()

    /// Thread layout of the rows, when the list shows threads (see `MailStore.threadedMessages`).
    var threadRows: [Int64: MailStore.ThreadedRow] = [:]
    var showsThreads = false {
        didSet { if showsThreads != oldValue { updateFromHeader() } }
    }
    /// Threads whose replies show; the others are collapsed (threads start collapsed, as in MailMate).
    var expandedThreads: Set<String> = []
    /// Messages inside open threads whose replies show (branches start folded, as threads do).
    var openedMessages: Set<Int64> = []
    /// Fold or open a row's replies (its chevron, or ← and → on it): the whole thread on its first row.
    var onToggleThread: ((MailStore.ThreadedRow, Bool) -> Void)?

    private func isFolded(_ row: MailStore.ThreadedRow) -> Bool {
        row.depth == 0 ? !expandedThreads.contains(row.thread) : !openedMessages.contains(row.id)
    }

    private static let blockSize = 150
    private static let cacheLimit = 3000

    init(
        store: MailStore, columns: [Column], autosaveName: String, widths: [Column: CGFloat] = [:],
        defaultSort: MessageSort = .newestFirst, relativeDates: Bool = false
    ) {
        self.store = store
        self.columns = columns
        self.autosaveName = autosaveName
        self.widths = widths
        self.relativeDates = relativeDates
        sort = Self.savedSort(autosaveName) ?? defaultSort
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(forName: MailboxColors.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {  // Rows take their mailboxes' new colors.
                guard let self, self.isViewLoaded else { return }
                self.rowColors.removeAll()
                self.cache.removeAll()
                self.tableView.reloadData()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        // "Today" and "Yesterday" move on at midnight, even in a list left open for days.
        NotificationCenter.default.addObserver(
            self, selector: #selector(dayChanged), name: .NSCalendarDayChanged, object: nil)
        if relativeDates {
            // "3 minutes ago" moves on by the minute; only the visible dates are redrawn.
            relativeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisibleDates() }
            }
        }
        let table = tableView
        (table as? MessageTableView)?.onArrow = { [weak self] expand in self?.arrowKey(expand: expand) ?? false }
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked(_:))
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
                // As title text, not the cell's image, which the header draws at reduced opacity.
                // Paperclip in Medium: Regular's thin diagonals blur to grey at 1x (MailMate's are crisp).
                if let image = Self.headerSymbol(
                    symbol, pointSize: column == .unread ? 9 : 11, weight: column == .attachment ? .medium : .regular)
                {
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    // Placed against the title text as MailMate places them (measured at 1x).
                    attachment.bounds = NSRect(
                        x: 0, y: column == .unread ? 0 : column == .flag ? -1 : -2,
                        width: image.size.width, height: image.size.height)
                    let title = NSMutableAttributedString(attachment: attachment)
                    let style = NSMutableParagraphStyle()
                    style.alignment = .center
                    title.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: title.length))
                    let cell = IconHeaderCell()
                    cell.attributedStringValue = title
                    c.headerCell = cell
                }
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
                c.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: !key.startsDescending)
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
        let container = NSView()
        for v in [resultBar, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        resultBar.isHidden = true
        // The window's content runs under the toolbar: the bar sits below it, and the list keeps running
        // under the toolbar while there's no bar (the scroll view insets itself).
        listUnderToolbar = scroll.topAnchor.constraint(equalTo: container.topAnchor)
        listUnderBar = scroll.topAnchor.constraint(equalTo: resultBar.bottomAnchor)
        NSLayoutConstraint.activate([
            resultBar.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            resultBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            resultBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            resultBar.heightAnchor.constraint(equalToConstant: ResultBar.height),
            listUnderToolbar,
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    // MARK: Result bar

    private let resultBar = ResultBar()
    private var listUnderToolbar: NSLayoutConstraint!
    private var listUnderBar: NSLayoutConstraint!

    #if DEBUG
        var debugResultBar: String { "bar \(NSStringFromRect(resultBar.frame)) hidden \(resultBar.isHidden) view \(NSStringFromRect(view.frame)) \(type(of: view))" }
    #endif

    /// MailMate's bar over a search result's list ("Same thread"), with Cancel; nil hides it.
    func showResultBar(_ title: String?, symbol: String = "", onCancel: @escaping () -> Void = {}) {
        if let title { resultBar.show(title: title, symbol: symbol, onCancel: onCancel) }
        resultBar.isHidden = title == nil
        listUnderToolbar.isActive = title == nil
        listUnderBar.isActive = title != nil
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
        // Vertically only: rows can be a little wider than the visible area (column widths).
        let rect = tableView.rect(ofRow: row)
        return rect.minY + 1 >= visible.minY && rect.maxY - 1 <= visible.maxY
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
    /// Shows the replies under `id` opening or closing, with the rows sliding in or out as MailMate
    /// animates its threads. Returns false if the new list differs in any other way (reload instead).
    func animateBranch(of id: Int64, to newIDs: [Int64], selecting: [Int64]) -> Bool {
        guard let row = ids.firstIndex(of: id), newIDs.firstIndex(of: id) == row else { return false }
        let start = row + 1, delta = newIDs.count - ids.count
        let (longer, shorter) = delta >= 0 ? (newIDs, ids) : (ids, newIDs)
        let count = abs(delta)
        guard longer[..<start] == shorter[..<start], longer[(start + count)...] == shorter[start...] else { return false }
        #if DEBUG
            NSLog("MMJ animateBranch: \(delta > 0 ? "insert" : "remove") \(count) row(s) after row \(row)")
        #endif
        suppressSelection = true
        ids = newIDs
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            if delta > 0 {
                tableView.insertRows(at: IndexSet(start..<(start + count)), withAnimation: .slideDown)
            } else if delta < 0 {
                tableView.removeRows(at: IndexSet(start..<(start + count)), withAnimation: .slideUp)
            }
        }
        // The toggled row's chevron turns.
        tableView.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        tableView.selectRowIndexes(IndexSet(selecting.compactMap { newIDs.firstIndex(of: $0) }), byExtendingSelection: false)
        suppressSelection = false
        return true
    }

    func setIDs(_ newIDs: [Int64], selecting: [Int64]? = nil, scroll: Scroll = .keepPosition) {
        let wanted = selecting ?? selectedIDs
        let anchor = scrollAnchor

        ids = newIDs
        cache.removeAll(keepingCapacity: true)
        rowColors.removeAll(keepingCapacity: true)
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

    /// Shows a message as read or unread right away, before the store's change reaches the list.
    func showSeen(_ seen: Bool, id: Int64) {
        guard let index = ids.firstIndex(of: id), var row = cache[id], row.isSeen != seen else { return }
        row.isSeen = seen
        cache[id] = row
        tableView.reloadData(forRowIndexes: [index], columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    /// Shows a message as flagged or not at once, before the store's change comes back.
    func showFlagged(_ flagged: Bool, id: Int64) {
        guard let index = ids.firstIndex(of: id), var row = cache[id], row.isFlagged != flagged else { return }
        row.isFlagged = flagged
        cache[id] = row
        tableView.reloadData(forRowIndexes: [index], columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    private func row(at index: Int) -> MessageRow? {
        guard index < ids.count else { return nil }
        if let row = cache[ids[index]] { return row }
        if cache.count > Self.cacheLimit {
            cache.removeAll(keepingCapacity: true)
            rowColors.removeAll(keepingCapacity: true)
        }
        let lower = max(0, index - Self.blockSize / 3)
        let upper = min(ids.count, lower + Self.blockSize)
        let block = Array(ids[lower..<upper])
        for row in (try? store.rows(ids: block)) ?? [] {
            cache[row.id] = row
        }
        rowColors.merge(MailboxColors.listColors(for: block, store: store, viewing: colorKey)) { _, new in new }
        return cache[ids[index]]
    }

    /// Text colors of rows in mailboxes that use their color in the message list (fetched with the rows).
    private var rowColors: [Int64: NSColor] = [:]
    /// The sidebar mailbox this list shows, whose colored submailboxes color its rows (nil: none).
    var colorKey: String?

    // MARK: NSTableViewDataSource / Delegate

    #if DEBUG
        /// Closed threads whose first message is read but which have unread replies, with their text weight.
        func debugUnreadThreads() -> [String] {
            ids.indices.compactMap { index in
                guard let row = row(at: index), row.isSeen, let thread = threadRows[row.id], thread.size > 1, thread.anyUnread
                else { return nil }
                let cell = tableView(tableView, viewFor: tableView.tableColumns.first { $0.identifier.rawValue == Column.subject.rawValue }, row: index) as? NSTableCellView
                let weight = cell?.textField?.font.map { NSFontManager.shared.weight(of: $0) } ?? -1
                return "\(row.id) open=\(expandedThreads.contains(thread.thread)) dot=\(showsUnread(row)) weight=\(weight)"
            }
        }
    #endif

    func numberOfRows(in tableView: NSTableView) -> Int { ids.count }

    /// Unread dot and bold text, as MailMate shows them: a closed thread is unread if any of its messages
    /// is; any other row goes by its own message (which `showSeen` changes at once).
    private func showsUnread(_ row: MessageRow) -> Bool {
        if !row.isSeen { return true }
        guard let thread = threadRows[row.id] else { return false }
        return thread.size > 1 && thread.anyUnread && !expandedThreads.contains(thread.thread)
    }

    /// A closed thread shows when its newest message arrived, where the thread sorts by date; any other
    /// row its own date.
    private func shownDate(_ row: MessageRow) -> Date {
        guard let thread = threadRows[row.id], thread.size > 1, !expandedThreads.contains(thread.thread) else {
            return row.receivedAt
        }
        return Date(timeIntervalSince1970: thread.newestAt)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let tableColumn, let column = Column(rawValue: tableColumn.identifier.rawValue),
            let row = row(at: index)
        else { return nil }

        let unread = showsUnread(row)
        switch column {
        case .unread:
            // Read and replied shows the arrow.
            if unread { return iconCell(tableView, column, image: Self.unreadDot, tint: .controlAccentColor) }
            return iconCell(tableView, column, image: row.isAnswered ? Self.repliedArrow : nil, tint: .labelColor)
        case .flag:
            return iconCell(tableView, column, image: row.isFlagged ? Self.rowFlag : nil, tint: .systemRed)
        case .attachment:
            return iconCell(tableView, column, image: row.hasAttachment ? Self.rowPaperclip : nil, tint: .labelColor)
        default:
            let cell = textColumnCell(tableView, column, row, bold: unread)
            (cell as? ColoredCell)?.rowColor = rowColors[row.id]
            return cell
        }
    }

    private func textColumnCell(_ tableView: NSTableView, _ column: Column, _ row: MessageRow, bold unread: Bool) -> NSView {
        switch column {
        case threadColumn where showsThreads:
            let text = column == .from ? row.fromDisplay : (row.subject.isEmpty ? "(no subject)" : row.subject)
            return threadCell(tableView, row, text: text, thread: threadRows[row.id], bold: unread)
        case .date:
            let date = shownDate(row)
            if relativeDates { return textCell(tableView, column, Formatters.relative(date), bold: unread) }
            return dateCell(tableView, date, bold: unread)
        case .source:
            return textCell(tableView, column, "\(row.mailboxName) – \(row.accountName)", bold: unread)
        case .subject:
            return textCell(tableView, column, row.subject.isEmpty ? "(no subject)" : row.subject, bold: unread)
        default:
            return textCell(tableView, column, row.fromDisplay, bold: unread)
        }
    }

    private func refreshVisibleDates() {
        let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(Column.date.rawValue))
        let rows = tableView.rows(in: tableView.visibleRect)
        guard column >= 0, rows.length > 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<NSMaxRange(rows)), columnIndexes: [column])
    }

    /// Foundation posts NSCalendarDayChanged on a background queue, so this must be nonisolated:
    /// a main-actor @objc method traps on Swift 6's executor check before its body runs.
    @objc nonisolated private func dayChanged() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.redrawDates() }
        }
    }

    private func redrawDates() {
        let column = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(Column.date.rawValue))
        guard column >= 0, tableView.numberOfRows > 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<tableView.numberOfRows), columnIndexes: [column])
    }

    /// A click changes the selection on mouse-down but reports it only on mouse-up; reporting it while
    /// it's changing shows (and marks read) the message at once, as the arrow keys do.
    private var reportedWhileChanging: [Int64]?

    func tableViewSelectionIsChanging(_ notification: Notification) {
        // Only for the mouse: for the arrow keys this comes before the selection moves.
        guard !suppressSelection, [.leftMouseDown, .leftMouseDragged].contains(NSApp.currentEvent?.type) else { return }
        let selection = selectedIDs
        guard selection != reportedWhileChanging else { return }
        reportedWhileChanging = selection
        onSelectionChange?(selectedID)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        defer { reportedWhileChanging = nil }
        if reportedWhileChanging == selectedIDs { return }  // Already reported on mouse-down.
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

    /// Adds the window's message actions for these messages to the context menu.
    var addContextItems: ((NSMenu, [Int64]) -> Void)?

    func menuNeedsUpdate(_ menu: NSMenu) {
        fillContextMenu(menu, row: tableView.clickedRow)
    }

    private func fillContextMenu(_ menu: NSMenu, row: Int) {
        menu.removeAllItems()
        guard row >= 0, row < ids.count else { return }
        // As in MailMate (and macOS lists): inside the selection the menu acts on the selection; outside
        // it, on the clicked message alone, which isn't selected (so it isn't opened, nor marked read).
        let targets = tableView.selectedRowIndexes.contains(row) ? selectedIDs : [ids[row]]
        addContextItems?(menu, targets)
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        let item = menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinderClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ids[row]
    }

    #if DEBUG
        /// The context menu of a row as a right-click builds it; runs the item titled `run`, if any.
        func debugContextMenu(row: Int, run: String?) -> [String] {
            let menu = NSMenu()
            fillContextMenu(menu, row: row)
            // "Item" runs an item, "Item>Sub" an item of its submenu.
            let path = run?.split(separator: ">").map(String.init) ?? []
            var item = path.first.flatMap { title in menu.items.first { $0.title == title } }
            if path.count > 1 { item = item?.submenu?.items.first { $0.title == path[1] } }
            if let item, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
            return menu.items.map { item in
                // Greyed out as the menu would show it (its target's validation).
                let off = item.action != nil && (item.target as? NSMenuItemValidation)?.validateMenuItem(item) == false
                return item.isSeparatorItem ? "—" : item.title + (off ? " (off)" : "")
                    + (item.submenu.map { " [" + $0.items.map(\.title).joined(separator: ", ") + "]" } ?? "")
            }
        }
    #endif

    @objc private func showInFinderClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64 else { return }
        onShowInFinder?(id)
    }

    // MARK: Cells

    private func textCell(
        _ tableView: NSTableView, _ column: Column, _ text: String, bold: Bool
    ) -> NSView {
        let id = NSUserInterfaceItemIdentifier("text")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ColoredCell ?? {
            let cell = ColoredCell()
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
        cell.textField?.font = Self.font(bold: bold)
        cell.textField?.stringValue = text
        return cell
    }

    /// Unread in Bold, read in Regular, with proportional digits, as MailMate draws its lists
    /// (fitted by ink width at 1x: "Today" 36 vs 39 px, "12:33 PM" 54 px).
    private static func font(bold: Bool) -> NSFont {
        NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: bold ? .bold : .regular)
    }

    /// Date on the left, time right-aligned, as MailMate shows "12/31/89    6:59 PM".
    private func dateCell(_ tableView: NSTableView, _ date: Date, bold: Bool) -> NSView {
        let id = NSUserInterfaceItemIdentifier("date")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? DateCell ?? DateCell(identifier: id)
        let font = Self.font(bold: bold)
        cell.dateField.font = font
        cell.timeField.font = font
        cell.dateField.stringValue = Formatters.listDay(date)
        cell.timeField.stringValue = Formatters.listTime(date)
        return cell
    }

    /// A header symbol in the header text's color, as MailMate draws them. Measured at 1x: dot 9 px,
    /// flag 10 × 11 px, paperclip 11 × 12 px.
    private static func headerSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        else { return nil }
        // Cropped to the glyph's ink: the symbol's own padding would get it clipped in a 16 pt column.
        let ink = inkBounds(of: symbol)
        // Drawn on demand, so the color follows the current appearance.
        return NSImage(size: ink.size, flipped: false) { rect in
            symbol.draw(at: NSPoint(x: -ink.minX, y: -ink.minY), from: .zero, operation: .sourceOver, fraction: 1)
            NSColor.headerTextColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// The part of an image that has ink, in points, found at 4× so it survives Retina drawing.
    static func inkBounds(of image: NSImage, integral: Bool = true) -> NSRect {
        let scale: CGFloat = 4
        let width = Int(image.size.width * scale), height = Int(image.size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return NSRect(origin: .zero, size: image.size) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return NSRect(origin: .zero, size: image.size) }
        // Bitmap rows run top-down; image coordinates bottom-up. Whole points (by default), so the glyph
        // keeps its own pixel alignment.
        let rect = NSRect(
            x: CGFloat(minX) / scale, y: CGFloat(height - 1 - maxY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
        return integral ? rect.integral : rect
    }

    /// The unread dot: a 10 px circle, as MailMate draws it (measured at 1x).
    private static let unreadDot: NSImage = {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// The flag in rows, as MailMate draws it (measured at 1x): about 11 × 13 px, rows 2–14 of the row,
    /// on whole pixels.
    /// The replied arrow in the status column, as MailMate draws it (measured at 1x): 14 × 12 px from
    /// 2 px below the row's top, in the text color.
    private static let repliedArrow: NSImage? = cellSymbol("arrowshape.turn.up.left.fill", pointSize: 13, top: 2, width: 16)

    /// A symbol in a cell-sized image, on whole pixels: centered across, `top` px below the cell's top.
    private static func cellSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular, top: CGFloat, width: CGFloat)
        -> NSImage?
    {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        else { return nil }
        let ink = inkBounds(of: symbol, integral: false)
        let size = NSSize(width: width, height: 17)
        let shift = NSPoint(
            x: ((size.width - ink.width) / 2 - ink.minX).rounded(), y: (size.height - top - ink.maxY).rounded())
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(at: shift, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: Threads

    /// The column with the chevrons and indents: From, or Subject in a list without From (Correspondence).
    private var threadColumn: Column { columns.contains(.from) ? .from : .subject }

    /// In a threaded list MailMate lines the From header up with the senders, past the chevrons.
    private func updateFromHeader() {
        guard let column = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(threadColumn.rawValue)) else {
            return
        }
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = showsThreads ? 12 : 0
        style.lineBreakMode = .byTruncatingTail
        column.headerCell.attributedStringValue = NSAttributedString(string: threadColumn.title, attributes: [
            .paragraphStyle: style, .font: column.headerCell.font ?? NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ])
        tableView.headerView?.needsDisplay = true
    }

    /// MailMate's From cell in a threaded list (measured at 1x): text 20 px past the column's left edge,
    /// 8 px further per level of replies, and an 8 × 5 px chevron 16 px before the text on every message
    /// with replies.
    private func threadCell(
        _ tableView: NSTableView, _ row: MessageRow, text: String, thread: MailStore.ThreadedRow?, bold: Bool
    ) -> NSView {
        let id = NSUserInterfaceItemIdentifier("thread")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ThreadFromCell ?? ThreadFromCell(identifier: id)
        cell.textField?.font = Self.font(bold: bold)
        cell.textField?.stringValue = text
        cell.depth = thread?.depth ?? 0
        if let thread, thread.hasReplies {
            let collapsed = isFolded(thread)
            cell.chevron.isHidden = false
            cell.chevron.image = collapsed ? Self.chevronRight : Self.chevronDown
            cell.onToggle = { [weak self] in self?.onToggleThread?(thread, !collapsed) }
        } else {
            cell.chevron.isHidden = true
            cell.onToggle = nil
        }
        return cell
    }

    private static let chevronDown = cellSymbol("chevron.down", pointSize: 9, weight: .semibold, top: 7, width: 14)
    private static let chevronRight = cellSymbol("chevron.right", pointSize: 9, weight: .semibold, top: 5, width: 14)

    /// As in MailMate's outline: → opens the selected message's replies; ← folds them, or, on a message
    /// with none showing, selects the message it replies to (so a second ← folds that one). Returns
    /// whether it acted.
    private func arrowKey(expand: Bool) -> Bool {
        guard showsThreads, let id = selectedID, let thread = threadRows[id] else { return false }
        if thread.hasReplies, isFolded(thread) == expand {
            onToggleThread?(thread, !expand)
            return true
        }
        guard !expand, thread.depth > 0, let row = ids.firstIndex(of: id),
            let parent = ids[..<row].lastIndex(where: { threadRows[$0]?.depth == thread.depth - 1 })
        else { return false }
        tableView.selectRowIndexes([parent], byExtendingSelection: false)
        tableView.scrollRowToVisible(parent)
        return true
    }

    private static let rowFlag: NSImage? = {
        guard let symbol = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: "Flagged")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        else { return nil }
        let ink = inkBounds(of: symbol, integral: false)
        let size = NSSize(width: 16, height: 17)  // The flag column's cell.
        // Measured on screen against MailMate: the ink from 2 px below the row's top, 26 px before the sender.
        let shift = NSPoint(
            x: ((size.width - ink.width) / 2 - ink.minX).rounded() - 1, y: (size.height - 1 - ink.maxY).rounded())
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(at: shift, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// The paperclip as MailMate draws it in rows (measured at 1x): 14 px, 2 px below the row's top,
    /// on whole pixels in a cell-sized image so centering can't blur it.
    private static let rowPaperclip: NSImage? = {
        guard let symbol = NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        else { return nil }
        let ink = inkBounds(of: symbol, integral: false)
        let size = NSSize(width: 16, height: 17)  // The attachment column's cell.
        // Whole-pixel shift, centered across. Down from the top by 1 by the 4× ink box, which comes out
        // as MailMate's 2 px on screen (symbols snap to the pixel grid at 1x).
        let shift = NSPoint(
            x: ((size.width - ink.width) / 2 - ink.minX).rounded(), y: (size.height - 1 - ink.maxY).rounded())
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(at: shift, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }()

    private func iconCell(_ tableView: NSTableView, _ column: Column, image: NSImage?, tint: NSColor) -> NSView {
        let id = NSUserInterfaceItemIdentifier("icon")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? IconCellView ?? {
            let cell = IconCellView()
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
        cell.imageView?.image = image
        cell.tint = tint
        return cell
    }
}

/// Header cell for the narrow icon columns: the symbol gets the whole cell, not the inset title area
/// (which would clip a 10 px flag in a 16 pt column).
final class IconHeaderCell: NSTableHeaderCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect { rect }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let size = attributedStringValue.size()
        // On whole pixels: half-pixel centering would blur the thin strokes.
        let origin = controlView.backingAlignedRect(
            NSRect(x: cellFrame.midX - size.width / 2, y: cellFrame.midY - size.height / 2, width: size.width, height: size.height),
            options: .alignAllEdgesNearest
        ).origin
        attributedStringValue.draw(at: origin)
    }
}

/// An icon that turns white on a selected row while the list is focused, as MailMate's unread dot does.
final class IconCellView: NSTableCellView {
    var tint: NSColor = .controlAccentColor {
        didSet { updateTint() }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTint() }
    }

    private func updateTint() {
        imageView?.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : tint
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

    /// "October 14, 2026 at 4:16 PM", as MailMate shows it (no weekday).
    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f
    }()

    /// "Today", "Yesterday", otherwise the short date.
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        f.doesRelativeDateFormatting = true
        return f
    }()

    static func listDay(_ date: Date) -> String { day.string(from: date) }

    /// "5 minutes ago", "47 hours ago", "11 days ago", as MailMate's Correspondence pane shows dates:
    /// hours up to two days, then days; months and years for old mail.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        func ago(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return ago(Int(seconds / 60), "minute") }
        if seconds < 48 * 3600 { return ago(Int(seconds / 3600), "hour") }
        let days = Int(seconds / 86400)
        if days < 60 { return ago(days, "day") }
        if days < 730 { return ago(days / 30, "month") }
        return ago(days / 365, "year")
    }

    static func listTime(_ date: Date) -> String { time.string(from: date) }

    static func fullDate(_ date: Date) -> String { full.string(from: date) }
}

/// Two labels in one cell: the date at the leading edge, the time at the trailing edge.
/// A list cell whose text takes the row's mailbox color (Use Color in Message List), white when selected.
class ColoredCell: NSTableCellView {
    var rowColor: NSColor? { didSet { applyColor() } }
    var coloredFields: [NSTextField] { textField.map { [$0] } ?? [] }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { applyColor() } }

    func applyColor() {
        let color = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : rowColor ?? .labelColor
        for field in coloredFields { field.textColor = color }
    }
}

final class DateCell: ColoredCell {
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
        textField = dateField
        NSLayoutConstraint.activate([
            dateField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            dateField.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            timeField.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeField.leadingAnchor.constraint(greaterThanOrEqualTo: dateField.trailingAnchor, constant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var coloredFields: [NSTextField] { [dateField, timeField] }
}

extension MessageListViewController {
    @objc fileprivate func rowDoubleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < ids.count else { return }
        onOpen?(ids[row])
    }
}

/// The message table, passing ← and → to the list for collapsing and expanding threads.
final class MessageTableView: NSTableView {
    var onArrow: (Bool) -> Bool = { _ in false }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow? where onArrow(false): return
        case .rightArrow? where onArrow(true): return
        default: super.keyDown(with: event)
        }
    }
}

/// From cell of a threaded list: a chevron on a thread's first row and the sender, indented for replies.
final class ThreadFromCell: ColoredCell {
    let chevron = NSButton()
    var onToggle: (() -> Void)?
    private var leading: NSLayoutConstraint!
    private var chevronLeading: NSLayoutConstraint!

    var depth = 0 {
        didSet {
            leading.constant = 15 + CGFloat(depth) * 8  // 8 px a level, as deep as the thread goes
            chevronLeading.constant = -3 + CGFloat(depth) * 8
        }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        chevron.isBordered = false
        chevron.imagePosition = .imageOnly
        chevron.contentTintColor = .secondaryLabelColor
        chevron.target = self
        chevron.action = #selector(toggle(_:))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        addSubview(chevron)
        textField = field
        leading = field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15)
        chevronLeading = chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -3)
        NSLayoutConstraint.activate([
            leading,
            chevronLeading,
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.topAnchor.constraint(equalTo: topAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 14),
            chevron.heightAnchor.constraint(equalToConstant: 17),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle(_ sender: Any?) { onToggle?() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { chevron.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor }
    }
}

/// The bar over a search result's list, as MailMate draws it (measured at 1x): 29 pt and a 1 pt line,
/// a little lighter than the list; the search's symbol 9 pt in and its name in bold 11 pt grey; outlined
/// buttons 18 pt tall with 4 pt corners, 7 pt from the right.
final class ResultBar: NSView {
    static let height: CGFloat = 30
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let cancel = OutlineButton(title: "Cancel")

    private static let background = NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 40 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1) : NSColor(white: 0.93, alpha: 1)
    }
    private static let line = NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 62 / 255, green: 65 / 255, blue: 66 / 255, alpha: 1) : NSColor(white: 0.82, alpha: 1)
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = .secondaryLabelColor
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleNone
        [icon, label, cancel].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(title: String, symbol: String, onCancel: @escaping () -> Void) {
        label.stringValue = title
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        cancel.onClick = onCancel
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 28 - 2, y: ((29 - label.frame.height) / 2).rounded() + 1)
        // The symbol stands on the text's baseline and reaches its cap height, as MailMate's does.
        let size = icon.image?.size ?? .zero
        let baseline = label.frame.minY + label.firstBaselineOffsetFromTop
        let ink = (icon.image?.alignmentRect ?? .zero)
        // Its ink from 9 pt in (the symbol has 1 pt of space on its left), 4 pt before the text.
        icon.frame = NSRect(x: 8, y: (baseline - size.height + ink.minY).rounded(), width: size.width, height: size.height)
        let width = cancel.intrinsicContentSize.width
        cancel.frame = NSRect(x: bounds.width - 7 - width, y: 5, width: width, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.background.setFill()
        bounds.fill()
        Self.line.setFill()
        NSRect(x: 0, y: 29, width: bounds.width, height: 1).fill()
    }
}

/// MailMate's small outlined buttons: SF 11 in the text color 7 pt from a grey 1 pt outline with 4 pt
/// corners, darker while pressed.
final class OutlineButton: NSView {
    var onClick: () -> Void = {}
    private let title: String
    private var pressed = false {
        didSet { needsDisplay = true }
    }

    private static let font = NSFont.systemFont(ofSize: 11)
    /// MailMate's outline shows as 125 on the dark bar.
    private static let outline = NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 108 / 255, alpha: 1) : NSColor(white: 0, alpha: 0.25)
    }

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 14, height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        if pressed {
            NSColor.labelColor.withAlphaComponent(0.15).setFill()
            box.fill()
        }
        Self.outline.setStroke()
        box.lineWidth = 1
        box.stroke()
        let text = NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: NSColor.labelColor])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
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
