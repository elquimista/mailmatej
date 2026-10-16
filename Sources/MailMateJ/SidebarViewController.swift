import AppKit
import MailStore
import MailSync

final class SidebarNode: NSObject {
    enum Kind { case header, unified, account, mailbox }

    let key: String
    let kind: Kind
    let title: String
    let symbol: String
    let scope: MessageScope?
    let accountId: String?
    var badge = 0
    var warning: String?
    var children: [SidebarNode] = []

    init(key: String, kind: Kind, title: String, symbol: String = "", scope: MessageScope? = nil, accountId: String? = nil) {
        self.key = key
        self.kind = kind
        self.title = title
        self.symbol = symbol
        self.scope = scope
        self.accountId = accountId
    }
}

/// Source-list sidebar: unified "Mailboxes" by role, then "Sources" with each account's folder tree.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    var onSelect: ((SidebarNode) -> Void)?

    private let model: AppModel
    private let outline = NSOutlineView()
    private var roots: [SidebarNode] = []
    private var expandedKeys: Set<String>
    private var suppressSelection = false
    private static let expandedDefaultsKey = "SidebarExpandedKeys"

    init(model: AppModel) {
        self.model = model
        expandedKeys = Set(UserDefaults.standard.stringArray(forKey: Self.expandedDefaultsKey) ?? [])
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.dataSource = self
        outline.delegate = self
        outline.autoresizesOutlineColumn = false

        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view = scroll
    }

    var selectedNode: SidebarNode? { outline.item(atRow: outline.selectedRow) as? SidebarNode }

    /// Rebuilds the tree from the store, keeping expansion and selection.
    func reload() {
        let selectedKey = selectedNode?.key ?? "unified.inbox"
        roots = buildTree()
        suppressSelection = true
        outline.reloadData()
        for root in roots {
            outline.expandItem(root)
            expandRemembered(root.children)
        }
        if let node = find(selectedKey, in: roots) ?? find("unified.inbox", in: roots) {
            let row = outline.row(forItem: node)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
        suppressSelection = false
    }

    #if DEBUG
        /// Selects the item with `key` as a click would (fires `onSelect`).
        func debugSelect(key: String) {
            guard let node = find(key, in: roots) else { return }
            let row = outline.row(forItem: node)
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) }
        }
    #endif

    /// Selects the default item and notifies `onSelect`.
    func selectInitial() {
        reload()
        if let node = selectedNode { onSelect?(node) }
    }

    private func expandRemembered(_ nodes: [SidebarNode]) {
        for node in nodes where expandedKeys.contains(node.key) {
            outline.expandItem(node)
            expandRemembered(node.children)
        }
    }

    private func find(_ key: String, in nodes: [SidebarNode]) -> SidebarNode? {
        for node in nodes {
            if node.key == key { return node }
            if let hit = find(key, in: node.children) { return hit }
        }
        return nil
    }

    private func buildTree() -> [SidebarNode] {
        let store = model.store
        let accounts = (try? store.accounts()) ?? []
        let mailboxes = (try? store.mailboxes()) ?? []
        let counts = (try? store.counts()) ?? MailStore.Counts()
        let roles = Set(mailboxes.compactMap(\.role))

        let unified = SidebarNode(key: "header.mailboxes", kind: .header, title: "Mailboxes")
        let unifiedItems: [(String, String, String)] = [
            ("inbox", "Inbox", "tray"), ("drafts", "Drafts", "doc"), ("sent", "Sent Messages", "paperplane"),
            ("archive", "Archive", "archivebox"), ("junk", "Junk", "xmark.bin"), ("trash", "Deleted Messages", "trash"),
        ]
        for (role, title, symbol) in unifiedItems where role == "inbox" || roles.contains(role) {
            let node = SidebarNode(key: "unified.\(role)", kind: .unified, title: title, symbol: symbol, scope: .role(role))
            if role == "inbox" || role == "junk" { node.badge = counts.unreadByRole[role] ?? 0 }
            unified.children.append(node)
            if role == "inbox" {
                let flagged = SidebarNode(key: "unified.flagged", kind: .unified, title: "Flagged", symbol: "flag", scope: .flagged)
                flagged.badge = counts.flagged
                unified.children.append(flagged)
            }
        }
        unified.children.append(
            SidebarNode(key: "unified.all", kind: .unified, title: "All Messages", symbol: "tray.full", scope: .allMessages))

        let sources = SidebarNode(key: "header.sources", kind: .header, title: "Sources")
        let byAccount = Dictionary(grouping: mailboxes, by: \.accountId)
        for account in accounts {
            let node = SidebarNode(
                key: "account.\(account.id)", kind: .account, title: account.name, symbol: "at",
                scope: .account(account.id), accountId: account.id)
            node.badge = counts.unreadByAccount[account.id] ?? 0
            node.warning = model.syncWarning(accountId: account.id)
            node.children = mailboxTree(byAccount[account.id] ?? [], accountId: account.id)
            sources.children.append(node)
        }
        return [unified, sources]
    }

    private func mailboxTree(_ boxes: [MailboxRecord], accountId: String) -> [SidebarNode] {
        let roleOrder = ["inbox", "drafts", "sent", "archive", "junk", "trash"]
        let children = Dictionary(grouping: boxes, by: { $0.parentRemoteId ?? "" })
        func build(_ parent: String) -> [SidebarNode] {
            (children[parent] ?? []).sorted { a, b in
                let ra = a.role.flatMap(roleOrder.firstIndex) ?? 99
                let rb = b.role.flatMap(roleOrder.firstIndex) ?? 99
                return (ra, a.sortOrder, a.name.lowercased()) < (rb, b.sortOrder, b.name.lowercased())
            }.map { box in
                let node = SidebarNode(
                    key: "mailbox.\(accountId).\(box.remoteId)", kind: .mailbox, title: box.name,
                    symbol: Self.symbol(forRole: box.role), scope: .mailbox(box.id), accountId: accountId)
                if box.role != "sent" && box.role != "trash" && box.role != "drafts" { node.badge = box.unreadEmails }
                node.children = build(box.remoteId)
                return node
            }
        }
        return build("")
    }

    static func symbol(forRole role: String?) -> String {
        switch role {
        case "inbox": "tray"
        case "sent": "paperplane"
        case "drafts": "doc"
        case "archive": "archivebox"
        case "junk": "xmark.bin"
        case "trash": "trash"
        default: "folder"
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarNode)?.children.isEmpty ?? true)
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind == .header
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind != .header
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        if node.kind == .header {
            let id = NSUserInterfaceItemIdentifier("header")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = id
                let field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field)
                cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            }()
            cell.textField?.stringValue = node.title
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("item")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarCell ?? SidebarCell(identifier: id)
        cell.configure(node)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let node = selectedNode else { return }
        onSelect?(node)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode, node.kind != .header else { return }
        expandedKeys.insert(node.key)
        UserDefaults.standard.set(Array(expandedKeys), forKey: Self.expandedDefaultsKey)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode, node.kind != .header else { return }
        expandedKeys.remove(node.key)
        UserDefaults.standard.set(Array(expandedKeys), forKey: Self.expandedDefaultsKey)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outline.item(atRow: outline.clickedRow) as? SidebarNode, let accountId = node.accountId else { return }
        let sync = menu.addItem(withTitle: "Sync Now", action: #selector(syncClicked(_:)), keyEquivalent: "")
        sync.representedObject = accountId
        sync.target = self
        if node.kind == .account {
            if let warning = node.warning {
                menu.addItem(.separator())
                let firstLine = warning.split(separator: "\n").first.map(String.init) ?? warning
                let item = menu.addItem(withTitle: firstLine, action: nil, keyEquivalent: "")
                item.isEnabled = false
            }
            menu.addItem(.separator())
            let remove = menu.addItem(withTitle: "Remove Account…", action: #selector(removeClicked(_:)), keyEquivalent: "")
            remove.representedObject = node
            remove.target = self
        }
    }

    @objc private func syncClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.sync(accountId: id)
    }

    @objc private func removeClicked(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode, let id = node.accountId, let window = view.window else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Remove “\(node.title)”?"
        alert.informativeText = "Local copies of its messages are deleted. Nothing changes on the server."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.model.removeAccount(id: id)
        }
    }
}

/// Icon, title, and an unread-count capsule.
final class SidebarCell: NSTableCellView {
    private let badge = BadgeView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let image = NSImageView()
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        for v in [image, field, badge] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        imageView = image
        textField = field
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: field.trailingAnchor, constant: 6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ node: SidebarNode) {
        textField?.stringValue = node.title
        if let warning = node.warning {
            imageView?.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Sync error")
            imageView?.contentTintColor = .systemOrange
            toolTip = warning
        } else {
            imageView?.image = NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil)
            imageView?.contentTintColor = node.kind == .account ? .secondaryLabelColor : .controlAccentColor
            toolTip = nil
        }
        badge.count = node.badge
    }
}

final class BadgeView: NSView {
    var count = 0 {
        didSet {
            isHidden = count == 0
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var attributed: NSAttributedString {
        NSAttributedString(string: count.formatted(), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
    }

    override var intrinsicContentSize: NSSize {
        let size = attributed.size()
        return NSSize(width: max(20, ceil(size.width) + 12), height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.quaternaryLabelColor.setFill()
        path.fill()
        let text = attributed
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
