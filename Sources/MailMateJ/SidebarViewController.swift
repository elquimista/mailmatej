import AppKit
import MailStore
import MailSync

final class SidebarNode: NSObject {
    enum Kind { case header, unified, account, mailbox, smart }

    let key: String
    let kind: Kind
    var title: String
    let symbol: String
    var scope: MessageScope?
    let accountId: String?
    /// JMAP role of a mailbox node ("inbox", "sent", ...).
    var role: String?
    var badge = 0
    var warning: String?
    var info: String?
    var isBusy = false
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
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
    NSTextFieldDelegate
{
    var onSelect: ((SidebarNode) -> Void)?
    /// The selected mailbox went away (deleted): nothing is selected, as in MailMate.
    var onSelectNone: (() -> Void)?
    /// Edit an account's settings (a double-click on it, or Edit Account… in its menu).
    var onEditAccount: ((String) -> Void)?
    /// Unread counts, activity spinners, sync warnings and status tooltips on the rows; MailMate's
    /// mailbox editor shows its sidebar without any of them.
    var showsStatus = true

    private let model: AppModel
    private let outline = SidebarOutlineView()
    /// Sections (Mailboxes, Sources) the user hid with the header's Hide, remembered across launches.
    private var hiddenSections = Set(UserDefaults.standard.stringArray(forKey: "SidebarHiddenSections") ?? [])
    private var roots: [SidebarNode] = []
    private var expandedKeys: Set<String>
    private var suppressSelection = false
    /// Set while `reload()` re-expands rows, so expansion callbacks don't refresh statuses per row.
    private var isReloading = false
    private static let expandedDefaultsKey = "SidebarExpandedKeys"

    init(model: AppModel) {
        self.model = model
        expandedKeys = Set(UserDefaults.standard.stringArray(forKey: Self.expandedDefaultsKey) ?? [])
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            forName: .submailboxSettingsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        NotificationCenter.default.addObserver(forName: MailboxColors.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restyleVisibleRows() }
        }
    }

    /// Shows changed mailbox colors without rebuilding the tree.
    private func restyleVisibleRows() {
        let rows = outline.rows(in: outline.visibleRect)
        guard rows.length > 0 else { return }
        for row in rows.location..<(rows.location + rows.length) {
            guard let node = outline.item(atRow: row) as? SidebarNode,
                let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell
            else { continue }
            cell.configure(node, plain: isInEditor)
        }
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
        outline.rowSizeStyle = .custom
        outline.rowHeight = 23  // MailMate density (the source-list default is 28).
        outline.dataSource = self
        outline.delegate = self
        outline.autoresizesOutlineColumn = false

        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        outline.target = self
        outline.doubleAction = #selector(rowDoubleClicked(_:))
        outline.registerForDraggedTypes([Self.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .sourceList
        outline.onReturn = { [weak self] in
            guard let self, let node = selectedNode, canRename(node) else { return NSSound.beep() }
            beginRename(key: node.key, thenEdit: false)
        }

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view = scroll
    }

    var selectedNode: SidebarNode? { outline.item(atRow: outline.selectedRow) as? SidebarNode }

    /// Updates activity spinners, warnings and tooltips of visible rows in place (no reload, so
    /// spinners keep animating). A row spins when its account syncs or downloads, when the download
    /// is working on its mailbox, for unified mailboxes when any mailbox with that role is busy, and
    /// for collapsed rows when anything inside them is busy.
    func refreshStatuses() {
        guard showsStatus else { return }
        let busyIDs = model.busyMailboxIDs
        var busyRoles = Set<String>()

        func selfBusy(_ node: SidebarNode) -> Bool {
            switch node.kind {
            case .account: return node.accountId.map(model.isBusy) ?? false
            case .mailbox:
                if case .mailbox(let id)? = node.scope?.base { return busyIDs.contains(id) }
                return false
            default: return false
            }
        }
        /// Updates `node` and its subtree; returns whether anything in the subtree is busy.
        @discardableResult
        func update(_ node: SidebarNode) -> Bool {
            let own = selfBusy(node)
            if own, let role = node.role { busyRoles.insert(role) }
            let inside = node.children.map(update).contains(true)
            if node.kind == .account, let id = node.accountId {
                node.warning = model.syncWarning(accountId: id)
                node.info = model.downloadInfo(accountId: id)
            }
            node.isBusy = own || (inside && !outline.isItemExpanded(node))
            return own || inside
        }
        for root in roots where root.key != "header.mailboxes" { root.children.forEach { update($0) } }
        // Unified mailboxes, from what the account trees reported.
        for node in roots.first(where: { $0.key == "header.mailboxes" })?.children ?? [] {
            switch node.scope {
            case .role(let role)?: node.isBusy = busyRoles.contains(role)
            case .allMessages?: node.isBusy = !busyIDs.isEmpty
            default: node.isBusy = false
            }
            func markSubmailboxes(_ nodes: [SidebarNode]) {
                for child in nodes {
                    child.isBusy = selfBusy(child)
                    markSubmailboxes(child.children)
                }
            }
            markSubmailboxes(node.children)
        }
        reconfigureVisibleRows()
    }

    /// Every row's key, in tree order: equal when the rows are the same.
    private static func keys(_ nodes: [SidebarNode]) -> [String] {
        nodes.flatMap { [$0.key] + keys($0.children) }
    }

    private func reconfigureVisibleRows() {
        let rows = outline.rows(in: outline.visibleRect)
        for row in rows.location..<(rows.location + rows.length) {
            guard let node = outline.item(atRow: row) as? SidebarNode, node.kind != .header,
                let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell
            else { continue }
            cell.configure(node, plain: !showsStatus)
        }
    }

    /// Rebuilds the tree from the store, keeping expansion and selection.
    func reload() {
        let fresh = Self.buildTree(model: model)
        func record(_ nodes: [SidebarNode], parent: String?) {
            for n in nodes {
                if let scope = n.scope { MailboxColors.scopes[n.key] = scope }
                MailboxColors.parents[n.key] = parent
                record(n.children, parent: n.key)
            }
        }
        record(fresh, parent: nil)
        // Usually only counts and states changed: update the rows in place, so nothing is reloaded or
        // re-expanded (which made expanding a row stutter while mail synced). Rebuild when rows come or go.
        if Self.keys(fresh) == Self.keys(roots) {
            var old: [String: SidebarNode] = [:]
            func index(_ nodes: [SidebarNode]) { for n in nodes { old[n.key] = n; index(n.children) } }
            index(roots)
            func update(_ nodes: [SidebarNode]) {
                for n in nodes {
                    if let node = old[n.key] {
                        node.badge = n.badge
                        node.warning = n.warning
                        node.info = n.info
                        node.role = n.role
                        node.title = n.title
                        node.scope = n.scope  // a special mailbox's conditions wrap its submailboxes
                    }
                    update(n.children)
                }
            }
            update(fresh)
            refreshStatuses()
            return
        }
        let previous = selectedNode?.key
        // At launch, the mailbox chosen last time (the main window's sidebar), else Inbox.
        let launchKey = remembersSelection ? UserDefaults.standard.string(forKey: Self.lastMailboxDefaultsKey) : nil
        let selectedKey = previous ?? launchKey ?? "unified.inbox"
        roots = fresh
        isReloading = true
        defer { isReloading = false }
        suppressSelection = true
        outline.reloadData()
        for root in roots where !hiddenSections.contains(root.key) {
            outline.expandItem(root)
            expandRemembered(root.children)
        }
        // The last mailbox (or Inbox) at launch; after the selected mailbox is deleted, nothing (as MailMate does).
        if let node = find(selectedKey, in: roots) ?? (previous == nil ? find("unified.inbox", in: roots) : nil) {
            var row = outline.row(forItem: node)
            if row < 0 {  // inside a collapsed row: open its ancestors
                for ancestor in ancestors(of: node) { outline.expandItem(ancestor) }
                row = outline.row(forItem: node)
            }
            if row >= 0 {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                if previous == nil {  // at launch, show where it is (once the rows above it are in)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let selected = selectedNode else { return }
                        let row = outline.row(forItem: selected)
                        if row >= 0 { outline.scrollRowToVisible(row) }
                    }
                }
            }
        } else {
            outline.deselectAll(nil)
        }
        suppressSelection = false
        if previous != nil, selectedNode == nil { onSelectNone?() }
        refreshStatuses()
    }

    #if DEBUG
        /// Shows the first header as hovered (Hide visible); with `toggle`, hides its section too.
        func debugHeader(toggle: Bool) {
            guard let header = roots.first, let cell = outline.view(atColumn: 0, row: outline.row(forItem: header), makeIfNecessary: false) as? SidebarHeaderCell
            else { return NSLog("MMJ header: none") }
            cell.mouseEntered(with: NSEvent())
            if toggle { toggleSection(header) }
            NSLog("MMJ header: rows \(outline.numberOfRows), expanded \(outline.isItemExpanded(header)), hidden \(hiddenSections)")
        }

        func debugFocus() { view.window?.makeFirstResponder(outline) }

        /// Logs each header's row frame and its neighbours'.
        func debugRowFrames() {
            for root in roots {
                let row = outline.row(forItem: root)
                guard row >= 0 else { continue }
                let frames = (max(0, row - 1)...min(outline.numberOfRows - 1, row + 1)).map { NSStringFromRect(outline.rect(ofRow: $0)) }
                NSLog("MMJ rows around \(root.title) (row \(row)): \(frames) intercell \(outline.intercellSpacing)")
            }
        }

        /// Selects the item with `key` as a click would (fires `onSelect`).
        func debugExpand(key: String) {
            if let node = find(key, in: roots) { outline.expandItem(node) }
        }

        var debugInboxBadge: Int { find("unified.inbox", in: roots)?.badge ?? -1 }
        /// Every row's badge, as "key=count", in tree order (MMJ_DEBUG_BADGES).
        var debugBadges: String {
            func walk(_ nodes: [SidebarNode]) -> [String] { nodes.flatMap { ["\($0.key)=\($0.badge)"] + walk($0.children) } }
            return walk(roots).joined(separator: " ")
        }

        /// Moves rows as drops would: "key>targetKey@index", several separated by ";".
        func debugMove(_ spec: String) {
            for step in spec.split(separator: ";") {
                let parts = step.split(separator: ">").map(String.init)
                guard parts.count == 2 else { continue }
                let target = parts[1].split(separator: "@").map(String.init)
                guard let node = find(parts[0], in: roots), let into = find(target[0], in: roots) else { continue }
                move(node, into: into, at: Int(target.count > 1 ? target[1] : "-1") ?? -1)
                reload()
            }
            NSLog("MMJ sidebar order: \(roots.map { "\($0.title): " + $0.children.map(\.title).joined(separator: ", ") }.joined(separator: " | "))")
        }

        func debugSelect(key: String) { select(key: key) }

        func debugDuplicate(key: String) {
            guard let node = find(key, in: roots) else { return NSLog("MMJ duplicate: no \(key)") }
            duplicate(node)
            NSLog("MMJ sidebar order: \(roots.map { "\($0.title): " + $0.children.map(\.title).joined(separator: ", ") }.joined(separator: " | "))")
        }
    #endif

    /// Selects a row by key (as a click would), opening the rows above it. Returns whether it exists.
    @discardableResult
    func select(key: String) -> Bool {
        guard let node = find(key, in: roots) else { return false }
        var row = outline.row(forItem: node)
        if row < 0 {
            // Inside a collapsed row: open its ancestors.
            for ancestor in ancestors(of: node) { outline.expandItem(ancestor) }
            row = outline.row(forItem: node)
        }
        guard row >= 0 else { return false }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        return true
    }

    var selectedKey: String? { selectedNode?.key }

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

    func node(forKey key: String) -> SidebarNode? { find(key, in: roots) }

    private func find(_ key: String, in nodes: [SidebarNode]) -> SidebarNode? {
        for node in nodes {
            if node.key == key { return node }
            if let hit = find(key, in: node.children) { return hit }
        }
        return nil
    }

    /// The sidebar's tree; also the Counters pane's Mailbox menu.
    static func buildTree(model: AppModel) -> [SidebarNode] {
        let store = model.store
        let accounts = (try? store.accounts()) ?? []
        let mailboxes = (try? store.mailboxes()) ?? []
        let counts = (try? store.counts(
            flaggedByMailbox: SubmailboxSettings.settings(for: "unified.flagged").splitsBySource)) ?? MailStore.Counts()
        let roles = Set(mailboxes.compactMap(\.role))

        let unified = SidebarNode(key: "header.mailboxes", kind: .header, title: "Mailboxes")
        let unifiedItems: [(String, String, String)] = [
            ("inbox", "Inbox", "tray"), ("drafts", "Drafts", "doc"), ("sent", "Sent Messages", "paperplane"),
            ("archive", "Archive", "archivebox"), ("junk", "Junk", "xmark.bin"), ("trash", "Deleted Messages", "trash"),
        ]
        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        for (role, title, symbol) in unifiedItems where role == "inbox" || roles.contains(role) {
            let node = SidebarNode(key: "unified.\(role)", kind: .unified, title: title, symbol: symbol, scope: .role(role))
            node.badge = counts.unreadByRole[role] ?? 0
            node.children = submailboxes(of: node, mailboxes: mailboxes, accounts: accountsByID, counts: counts)
            // Smart mailboxes made inside it, before its submailboxes.
            node.children = smartNodes(store: store, accounts: accountsByID, inside: MessageScope.role(role).key) + node.children
            narrow(node, store: store)
            unified.children.append(node)
        }
        let all = SidebarNode(key: "unified.all", kind: .unified, title: "All Messages", symbol: "envelope", scope: .allMessages)  // MailMate's
        all.badge = (try? store.count(scope: .allMessages, counting: .unread)) ?? 0
        all.children = submailboxes(of: all, mailboxes: mailboxes, accounts: accountsByID, counts: counts)
        narrow(all, store: store)
        // MailMate's special mailbox for everything, Junk and Deleted Messages included.
        let everything = SidebarNode(
            key: "unified.everything", kind: .unified, title: "All / Junk / Deleted", symbol: "envelope", scope: .everything)
        everything.badge = (try? store.count(scope: .everything, counting: .unread)) ?? 0
        everything.children = smartNodes(store: store, accounts: accountsByID, inside: MessageScope.everything.key)
        all.children = [everything] + smartNodes(store: store, accounts: accountsByID, inside: MessageScope.allMessages.key) + all.children
        unified.children.append(all)
        unified.children += smartNodes(store: store, accounts: accountsByID)
        unified.children = ordered(unified.children)
        // Special mailboxes placed inside smart ones go there, after its own smart submailboxes.
        for placement in (try? store.specialPlacements()) ?? [] {
            guard let special = unified.children.first(where: { $0.kind == .unified && $0.scope?.key == placement.key }),
                let parent = node(withKey: "smart.\(placement.parentId)", in: [unified]), !contains(special, parent)
            else { continue }
            unified.children.removeAll { $0 === special }
            let at = parent.children.lastIndex { $0.kind == .smart || $0.kind == .unified }.map { $0 + 1 } ?? 0
            parent.children.insert(special, at: at)
        }

        let sources = SidebarNode(key: "header.sources", kind: .header, title: "Sources")
        let byAccount = Dictionary(grouping: mailboxes, by: \.accountId)
        for account in accounts {
            let node = SidebarNode(
                key: "account.\(account.id)", kind: .account, title: account.name, symbol: "at",
                scope: .account(account.id), accountId: account.id)
            node.badge = counts.unreadByAccount[account.id] ?? 0
            node.warning = model.syncWarning(accountId: account.id)
            node.info = model.downloadInfo(accountId: account.id)
            node.children = Self.mailboxTree(byAccount[account.id] ?? [], accountId: account.id)
            sources.children.append(node)
        }
        DisplayedCounts.apply(to: [unified, sources], store: store)
        return [unified, sources]
    }

    /// Smart mailboxes, nested as the user arranged them, each with its unread count and the
    /// submailboxes of its Submailboxes tab.
    /// The top-level ones, or with `inside` those inside that special mailbox (by its scope key).
    static func smartNodes(store: MailStore, accounts: [String: AccountRecord], inside special: String? = nil) -> [SidebarNode] {
        let smart = (try? store.smartMailboxes()) ?? []
        let byParent = Dictionary(grouping: smart, by: \.parentId)
        func nodes(_ parent: Int64?) -> [SidebarNode] {
            (byParent[parent] ?? []).filter { parent != nil || $0.parentKey == special }.map { record in
                let node = SidebarNode(
                    key: "smart.\(record.id)", kind: .smart, title: record.name, symbol: record.definition.icon ?? smartSymbol,
                    scope: .smart(record.id))
                node.badge = (try? store.count(scope: .smart(record.id), counting: .unread)) ?? 0
                node.children = nodes(record.id) + splitNodes(record, store: store, accounts: accounts)
                return node
            }
        }
        return nodes(nil)
    }

    /// Smart mailboxes' default icon: a gear, as MailMate's.
    static let smartSymbol = "gearshape"

    /// A smart mailbox's Submailboxes tab as sidebar rows: a child per value, or per account; with both,
    /// the accounts, each with its own values (as unified mailboxes group sources by account).
    private static func splitNodes(_ record: SmartMailboxRecord, store: MailStore, accounts: [String: AccountRecord]) -> [SidebarNode] {
        let split = record.definition.split
        func valueNodes(account: String?) -> [SidebarNode] {
            guard split.byValue, let values = try? store.smartValues(id: record.id, field: split.field, account: account),
                !(split.unlessOnlyOne && values.count < 2)
            else { return [] }
            return values.map { value, unread in
                let scope: MessageScope = account.map { .smartAccountValue(record.id, $0, split.field, value) }
                    ?? .smartValue(record.id, split.field, value)
                let node = SidebarNode(
                    key: "smart.\(record.id)\(account.map { ".account.\($0)" } ?? "").value.\(value.lowercased())", kind: .mailbox,
                    title: value.isEmpty ? "Other" : value, symbol: record.definition.icon ?? smartSymbol, scope: scope, accountId: account)
                node.badge = unread
                return node
            }
        }
        guard split.byAccount, let list = try? store.smartAccounts(id: record.id) else { return valueNodes(account: nil) }
        let sorted = list.compactMap { entry in accounts[entry.accountId].map { ($0, entry.unread) } }
            .sorted { ($0.0.sortOrder, $0.0.name) < ($1.0.sortOrder, $1.0.name) }
        return sorted.map { account, unread in
            let node = SidebarNode(
                key: "smart.\(record.id).account.\(account.id)", kind: .mailbox, title: account.name, symbol: "at",
                scope: .smartAccount(record.id, account.id), accountId: account.id)
            node.badge = unread
            node.children = valueNodes(account: account.id)
            return node
        }
    }

    // MARK: Order

    /// The Mailboxes section's order, as dragged: special and smart mailboxes mixed, by key.
    private static let orderDefaultsKey = "SidebarMailboxOrder"

    /// `nodes` in the saved order; ones not in it (new smart mailboxes) keep their place after the
    /// one before them.
    private static func ordered(_ nodes: [SidebarNode]) -> [SidebarNode] {
        let saved = UserDefaults.standard.stringArray(forKey: orderDefaultsKey) ?? []
        guard !saved.isEmpty else { return nodes }
        let rank = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var result = nodes.filter { rank[$0.key] != nil }.sorted { rank[$0.key]! < rank[$1.key]! }
        for (index, node) in nodes.enumerated() where rank[node.key] == nil {
            let before = nodes[..<index].last { rank[$0.key] != nil || result.contains($0) }
            let at = before.flatMap { b in result.firstIndex { $0 === b } }.map { $0 + 1 } ?? result.count
            result.insert(node, at: at)
        }
        return result
    }

    /// A special mailbox whose Conditions tab narrows it: its submailboxes show only what it shows, and
    /// its counts come from here (the server's count the whole mailboxes).
    private static func narrow(_ node: SidebarNode, store: MailStore) {
        guard let key = node.scope?.key, store.hasSpecialCondition(key: key) else { return }
        if let scope = node.scope { node.badge = (try? store.count(scope: scope, counting: .unread)) ?? 0 }
        func wrap(_ nodes: [SidebarNode]) {
            for child in nodes {
                if let scope = child.scope {
                    child.scope = .within(key, scope)
                    child.badge = (try? store.count(scope: .within(key, scope), counting: .unread)) ?? 0
                }
                wrap(child.children)
            }
        }
        wrap(node.children)
    }

    /// MailMate's submailboxes of a unified mailbox. For a role (Inbox, Sent, ...) one per account's
    /// mailbox of that role (one per account, so by source and by account agree), named after the account.
    /// For Flagged and All Messages, by account: each account; by source: each mailbox holding such mail
    /// ("Inbox – Alice"); Source with "each account": accounts, each with its sources.
    private static func submailboxes(
        of node: SidebarNode, mailboxes: [MailboxRecord], accounts: [String: AccountRecord], counts: MailStore.Counts
    ) -> [SidebarNode] {
        let settings = SubmailboxSettings.settings(for: node.key)
        guard settings.splits, let scope = node.scope else { return [] }
        let order: (MailboxRecord, MailboxRecord) -> Bool = { a, b in
            let x = accounts[a.accountId]!, y = accounts[b.accountId]!
            return (x.sortOrder, x.name, a.name.lowercased()) < (y.sortOrder, y.name, b.name.lowercased())
        }
        let known = mailboxes.filter { accounts[$0.accountId] != nil }
        func child(_ key: String, _ title: String, _ scope: MessageScope, accountId: String, badge: Int, role: String?) -> SidebarNode {
            let child = SidebarNode(
                key: "\(node.key).\(key)", kind: .mailbox, title: title, symbol: node.symbol,
                scope: scope, accountId: accountId)
            child.role = role
            child.badge = badge
            return child
        }
        func source(_ box: MailboxRecord) -> String { "\(box.name) – \(accounts[box.accountId]!.name)" }

        var children: [SidebarNode]
        switch scope {
        case .role(let role):
            children = known.filter { $0.role == role }.sorted(by: order).map { box in
                child(box.accountId, accounts[box.accountId]!.name, .mailbox(box.id), accountId: box.accountId,
                      badge: box.unreadEmails, role: role)
            }
        case .flagged, .allMessages:
            let flagged = scope == .flagged
            let sources = known.filter {
                flagged ? (counts.flaggedByMailbox[$0.id] ?? 0) > 0 : counts.mailboxesWithMail.contains($0.id)
            }.sorted(by: order)
            func sourceNodes(_ boxes: [MailboxRecord]) -> [SidebarNode] {
                boxes.map { box in
                    child("src.\(box.id)", source(box), flagged ? .flaggedInMailbox(box.id) : .mailbox(box.id),
                          accountId: box.accountId, badge: flagged ? counts.flaggedByMailbox[box.id] ?? 0 : box.unreadEmails, role: box.role)
                }
            }
            if settings.splitsByAccount {
                let ids = Set(sources.map(\.accountId))
                children = accounts.values.filter { ids.contains($0.id) }.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
                    .map { account in
                        let node = child(
                            "acct.\(account.id)", account.name, flagged ? .flaggedInAccount(account.id) : .allInAccount(account.id),
                            accountId: account.id,
                            badge: flagged ? counts.flaggedByAccount[account.id] ?? 0
                                : sources.filter { $0.accountId == account.id }.reduce(0) { $0 + $1.unreadEmails },
                            role: nil)
                        if settings.splitsBySource { node.children = sourceNodes(sources.filter { $0.accountId == account.id }) }
                        return node
                    }
            } else {
                children = sourceNodes(sources)
            }
        default:
            children = []
        }
        return settings.unlessOnlyOne && children.count < 2 ? [] : children
    }

    private static func mailboxTree(_ boxes: [MailboxRecord], accountId: String) -> [SidebarNode] {
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
                node.role = box.role
                node.badge = box.unreadEmails
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

    // MARK: Drag and drop

    private static let dragType = NSPasteboard.PasteboardType("com.mailmatej.sidebar-node")

    /// What can be dragged: the special and smart mailboxes (in Mailboxes) and the accounts (in Sources).
    private func isDraggable(_ node: SidebarNode) -> Bool {
        guard !isInEditor else { return false }
        // Special mailboxes at the top or placed in a smart mailbox (not All / Junk / Deleted, part of All Messages).
        return (node.kind == .unified && node.key != "unified.everything") || node.kind == .smart || node.kind == .account
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? SidebarNode, isDraggable(node) else { return nil }
        let item = NSPasteboardItem()
        item.setString(node.key, forType: Self.dragType)
        return item
    }

    private func dragged(_ info: NSDraggingInfo) -> SidebarNode? {
        info.draggingPasteboard.string(forType: Self.dragType).flatMap { find($0, in: roots) }
    }

    /// Where a drop may go: special mailboxes anywhere among Mailboxes, or into (onto, or among the
    /// mailboxes in) a smart mailbox not inside themselves; smart mailboxes there too, or into another
    /// smart mailbox likewise; accounts among the accounts.
    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let node = dragged(info), let target = item as? SidebarNode else { return [] }
        switch node.kind {
        case .account:
            return target.key == "header.sources" && index >= 0 ? .move : []
        case .unified:
            if target.key == "header.mailboxes" { return index >= 0 ? .move : [] }
            guard target.kind == .smart, !Self.contains(node, target) else { return [] }
            // After its smart submailboxes, among the special mailboxes placed there.
            let start = target.children.prefix { $0.kind == .smart }.count
            let placed = target.children.filter { $0.kind == .unified }.count
            return index == -1 || (index >= start && index <= start + placed) ? .move : []
        case .smart:
            if target.key == "header.mailboxes" { return index >= 0 ? .move : [] }
            guard target.kind == .smart || target.kind == .unified, target !== node, !Self.contains(node, target) else { return [] }
            // Among its smart mailboxes, which follow any built-in rows (All / Junk / Deleted).
            let lead = target.children.prefix { $0.kind != .smart }.count
            let smartChildren = target.children.filter { $0.kind == .smart }.count
            return index == -1 || (index >= lead && index <= lead + smartChildren) ? .move : []
        default:
            return []
        }
    }

    private static func node(withKey key: String, in nodes: [SidebarNode]) -> SidebarNode? {
        for node in nodes {
            if node.key == key { return node }
            if let found = self.node(withKey: key, in: node.children) { return found }
        }
        return nil
    }

    private static func contains(_ node: SidebarNode, _ other: SidebarNode) -> Bool {
        node.children.contains { $0 === other || contains($0, other) }
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let node = dragged(info), let target = item as? SidebarNode else { return false }
        return move(node, into: target, at: index)
    }

    /// Drops `node` into `target` at child `index` (-1: onto it), saving the new order.
    @discardableResult
    private func move(_ node: SidebarNode, into target: SidebarNode, at index: Int) -> Bool {
        switch node.kind {
        case .unified where target.kind == .smart:
            guard case .smart(let parent)? = target.scope, let key = node.scope?.key else { return false }
            let placed = target.children.filter { $0.kind == .unified }
            let start = target.children.prefix { $0.kind == .smart }.count
            let old = placed.firstIndex { $0 === node } ?? Int.max
            let position = index - start
            let at = index == -1 ? placed.count : (position > old ? position - 1 : position)
            try? model.store.placeSpecialMailbox(key: key, inside: parent, index: at)
        case .account:
            var ids = target.children.compactMap(\.accountId).filter { $0 != node.accountId }
            let old = target.children.firstIndex { $0 === node } ?? Int.max
            ids.insert(node.accountId ?? "", at: min(index > old ? index - 1 : index, ids.count))
            try? model.store.setAccountOrder(ids)
        case .unified, .smart where target.key == "header.mailboxes":
            if node.kind == .unified, let key = node.scope?.key {  // out of any smart mailbox it was in
                try? model.store.placeSpecialMailbox(key: key, inside: nil, index: 0)
            }
            var keys = target.children.map(\.key).filter { $0 != node.key }
            let old = target.children.firstIndex { $0 === node } ?? Int.max
            keys.insert(node.key, at: min(index > old ? index - 1 : index, keys.count))
            UserDefaults.standard.set(keys, forKey: Self.orderDefaultsKey)
            if case .smart(let id)? = node.scope {
                // Out of any smart mailbox it was in, placed as among the other top-level smart mailboxes.
                let position = keys.prefix { $0 != node.key }.filter { $0.hasPrefix("smart.") }.count
                try? model.store.moveSmartMailbox(id: id, toParent: nil, index: position)
            }
        case .smart:
            guard case .smart(let id)? = node.scope, let targetScope = target.scope else { return false }
            let siblings = target.children.filter { $0.kind == .smart }
            let lead = target.children.prefix { $0.kind != .smart }.count
            let old = siblings.firstIndex { $0 === node } ?? Int.max
            let position = index - lead
            let at = index == -1 ? siblings.count : (position > old ? position - 1 : position)
            if case .smart(let parent) = targetScope {
                try? model.store.moveSmartMailbox(id: id, toParent: parent, index: at)
            } else {  // into a special mailbox
                try? model.store.moveSmartMailbox(id: id, toParent: nil, parentKey: targetScope.key, index: at)
            }
        default:
            return false
        }
        model.refreshNow()
        return true
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

    // Headers aren't AppKit group rows: the source-list style puts 13 pt of space above every group row
    // but the first, where MailMate keeps "Sources" close to the rows above it. (Their look is ours anyway.)

    /// Section headers as MailMate spaces them (measured at 1x): 15 px from the toolbar to the title's
    /// capitals, 28 px from them to the middle of the first row.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? SidebarNode, node.kind == .header else { return outlineView.rowHeight }
        return node === roots.first ? SidebarHeaderCell.firstRowHeight : SidebarHeaderCell.rowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind != .header
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        if node.kind == .header {
            let id = NSUserInterfaceItemIdentifier("header")
            let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarHeaderCell ?? SidebarHeaderCell(identifier: id)
            cell.title = node.title
            cell.isFirst = node === roots.first
            cell.isHidingSection = hiddenSections.contains(node.key)
            cell.onToggle = { [weak self] in self?.toggleSection(node) }
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("item")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarCell ?? SidebarCell(identifier: id)
        cell.configure(node, plain: !showsStatus)
        return cell
    }

    /// Hide or Show on a section header: folds the section away or brings it back (with its folders as
    /// they were), as in MailMate.
    private func toggleSection(_ node: SidebarNode) {
        if outline.isItemExpanded(node) {
            outline.animator().collapseItem(node)
            hiddenSections.insert(node.key)
        } else {
            outline.animator().expandItem(node)
            expandRemembered(node.children)
            hiddenSections.remove(node.key)
        }
        UserDefaults.standard.set(Array(hiddenSections), forKey: "SidebarHiddenSections")
        let row = outline.row(forItem: node)
        if row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarHeaderCell {
            cell.isHidingSection = hiddenSections.contains(node.key)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        (item as? SidebarNode)?.kind == .header ? nil : SidebarRowView()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = selectedNode else { return }
        if remembersSelection {
            UserDefaults.standard.set(node.key, forKey: Self.lastMailboxDefaultsKey)
        }
        guard !suppressSelection else { return }
        onSelect?(node)
    }

    /// Whether the selected mailbox is kept for the next launch (the main window's sidebar).
    var remembersSelection = false
    private static let lastMailboxDefaultsKey = "LastMailbox"

    /// The rows above a node, outermost first.
    private func ancestors(of node: SidebarNode) -> [SidebarNode] {
        func path(_ nodes: [SidebarNode], _ trail: [SidebarNode]) -> [SidebarNode]? {
            for n in nodes {
                if n === node { return trail }
                if let found = path(n.children, trail + [n]) { return found }
            }
            return nil
        }
        return path(roots, []) ?? []
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode, node.kind != .header else { return }
        expandedKeys.insert(node.key)
        UserDefaults.standard.set(Array(expandedKeys), forKey: Self.expandedDefaultsKey)
        if !isReloading { refreshStatusesAfterAnimation() }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode, node.kind != .header else { return }
        expandedKeys.remove(node.key)
        UserDefaults.standard.set(Array(expandedKeys), forKey: Self.expandedDefaultsKey)
        if !isReloading { refreshStatusesAfterAnimation() }
    }

    private var statusRefreshPending = false

    /// Expanding or collapsing only changes whether a row shows its children's activity; reconfiguring
    /// the rows during the outline's slide made it stutter, so the refresh waits until it's done.
    private func refreshStatusesAfterAnimation() {
        guard !statusRefreshPending else { return }
        statusRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            statusRefreshPending = false
            refreshStatuses()
        }
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outline.item(atRow: outline.clickedRow) as? SidebarNode else { return }
        func add(_ title: String, _ action: Selector) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.representedObject = node
            item.target = self
        }
        if node.key == "header.mailboxes" || node.kind == .unified || node.kind == .smart {
            add("New Smart Mailbox", #selector(newSmartMailboxClicked(_:)))
            menu.addItem(.separator())
        }
        if node.kind != .header {
            let count = menu.addItem(withTitle: "Displayed Count", action: nil, keyEquivalent: "")
            count.submenu = countMenu(for: node)
            let color = menu.addItem(withTitle: "Color", action: nil, keyEquivalent: "")
            color.submenu = colorMenu(for: node)
            let symbol = menu.addItem(withTitle: "Symbol", action: nil, keyEquivalent: "")
            symbol.submenu = symbolMenu(for: node)
            menu.addItem(.separator())
        }
        if node.kind == .smart {
            add("Edit Smart Mailbox…", #selector(editMailboxClicked(_:)))
            add("Rename Smart Mailbox", #selector(renameClicked(_:)))
            add("Duplicate Smart Mailbox", #selector(duplicateClicked(_:)))
            menu.addItem(.separator())
            add("Delete Smart Mailbox…", #selector(deleteSmartClicked(_:)))
            return
        }
        if node.kind == .unified {
            add("Edit Mailbox…", #selector(editMailboxClicked(_:)))
            return
        }
        guard let accountId = node.accountId else { return }
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
            let edit = menu.addItem(withTitle: "Edit Account…", action: #selector(editAccountClicked(_:)), keyEquivalent: "")
            edit.representedObject = accountId
            edit.target = self
            let remove = menu.addItem(withTitle: "Remove Account…", action: #selector(removeClicked(_:)), keyEquivalent: "")
            remove.representedObject = node
            remove.target = self
        }
    }

    // MARK: Displayed Count

    /// MailMate's Displayed Count submenu: Inherit, No Count, the counts, and Include Submailboxes.
    private func countMenu(for node: SidebarNode) -> NSMenu {
        let menu = NSMenu()
        let current = DisplayedCounts.kind(for: node.key)
        func add(_ title: String, _ kind: DisplayedCounts.Kind?) {
            let item = menu.addItem(withTitle: title, action: #selector(countChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CountChoice(key: node.key, kind: kind)
            item.state = kind == current ? .on : .off
        }
        add("Inherit", nil)
        add(DisplayedCounts.Kind.none.title, DisplayedCounts.Kind.none)
        menu.addItem(.separator())
        for kind in DisplayedCounts.Kind.allCases where kind != .none { add(kind.title, kind) }
        menu.addItem(.separator())
        let include = menu.addItem(withTitle: "Include Submailboxes", action: #selector(toggleIncludeSubmailboxes(_:)), keyEquivalent: "")
        include.target = self
        include.representedObject = node.key
        include.state = includesSubmailboxes(node) ? .on : .off
        return menu
    }

    private final class CountChoice: NSObject {
        let key: String
        let kind: DisplayedCounts.Kind?
        init(key: String, kind: DisplayedCounts.Kind?) {
            self.key = key
            self.kind = kind
        }
    }

    /// Include Submailboxes for a node: its own choice, else the nearest one above it.
    private func includesSubmailboxes(_ node: SidebarNode) -> Bool {
        for n in [node] + ancestors(of: node).reversed() {
            if let on = DisplayedCounts.includesSubmailboxes(n.key) { return on }
        }
        return false
    }

    @objc private func countChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? CountChoice else { return }
        DisplayedCounts.set(choice.kind, for: choice.key)
        reload()
    }

    @objc private func toggleIncludeSubmailboxes(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let node = Self.node(withKey: key, in: roots) else { return }
        DisplayedCounts.setIncludesSubmailboxes(!includesSubmailboxes(node), for: key)
        reload()
    }

    // MARK: Color

    /// MailMate's Color submenu: Accent, Text, Multicolor and Custom…, then the system colors under
    /// their heading, the chosen one checked.
    private func colorMenu(for node: SidebarNode) -> NSMenu {
        let menu = NSMenu()
        let current = MailboxColors.color(for: node.key) ?? (node.kind == .account ? nil : .accent)
        func add(_ title: String, _ image: NSImage, _ color: MailboxColor?, indented: Bool = false) {
            let item = menu.addItem(withTitle: title, action: #selector(colorChosen(_:)), keyEquivalent: "")
            item.target = self
            item.image = image
            item.representedObject = ColorChoice(key: node.key, color: color)
            item.indentationLevel = indented ? 1 : 0
            if let color, color == current { item.state = .on }
            if case .custom = current, case .custom = color ?? .accent { item.state = .on }
        }
        add("Accent Color", MailboxColors.swatch { .controlAccentColor }, .accent)
        add("Text Color", MailboxColors.swatch { .labelColor }, .text)
        add("Multicolor", MailboxColors.multicolorSwatch, .multicolor)
        add("Custom…", MailboxColors.customSwatch, nil)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "System Colors"))
        for (name, title) in MailboxColor.systemColors {
            add(title, MailboxColors.swatch { MailboxColor.systemColor(name) ?? .gray }, .system(name), indented: true)
        }
        menu.addItem(.separator())
        let inList = menu.addItem(withTitle: "Use Color in Message List", action: #selector(toggleColorInList(_:)), keyEquivalent: "")
        inList.target = self
        inList.representedObject = node.key
        inList.state = MailboxColors.usesColorInList(node.key) ? .on : .off
        // As in MailMate: not for the accent color (the default), which the selection already uses.
        let chosen = MailboxColors.color(for: node.key)
        if chosen == nil || chosen == .accent { inList.action = nil }
        return menu
    }

    private final class ColorChoice: NSObject {
        let key: String
        /// nil: Custom…, which asks.
        let color: MailboxColor?
        init(key: String, color: MailboxColor?) {
            self.key = key
            self.color = color
        }
    }

    /// Messages in the mailbox show their text in its color.
    @objc private func toggleColorInList(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        MailboxColors.setUsesColorInList(!MailboxColors.usesColorInList(key), for: key)
    }

    /// The mailbox whose color the color panel is choosing (Custom…).
    private var customColorKey: String?

    @objc private func colorChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ColorChoice else { return }
        if let color = choice.color { return MailboxColors.set(color, for: choice.key) }
        customColorKey = choice.key
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        if case .custom(let color)? = MailboxColors.color(for: choice.key) { panel.color = color }
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func customColorChanged(_ panel: NSColorPanel) {
        guard let key = customColorKey else { return }
        MailboxColors.set(.custom(panel.color), for: key)
    }

    // MARK: Symbol

    /// MailMate's Symbol submenu: Default (the mailbox's own symbol) and Custom…, then its choices.
    /// Default is checked while nothing was chosen, and so is the choice showing (Custom… for one from
    /// the Symbols panel).
    private func symbolMenu(for node: SidebarNode) -> NSMenu {
        let menu = NSMenu()
        let chosen = MailboxSymbols.symbol(for: node.key)
        let showing = chosen ?? node.symbol
        func add(_ title: String, _ symbol: String, _ choice: String?, on: Bool) {
            let item = menu.addItem(withTitle: title, action: #selector(symbolChosen(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.representedObject = SymbolChoice(node: node, symbol: choice)
            item.state = on ? .on : .off
        }
        add("Default", node.symbol, nil, on: chosen == nil)
        let custom = menu.addItem(withTitle: "Custom…", action: #selector(customSymbolClicked(_:)), keyEquivalent: "")
        custom.target = self
        // A symbol chosen in the Symbols panel shows (and is checked) here, as in MailMate.
        let isCustom = chosen.map { symbol in !MailboxSymbols.presets.contains { $0.symbol == symbol } } ?? false
        custom.image = NSImage(systemSymbolName: isCustom ? showing : "questionmark.square.dashed", accessibilityDescription: nil)
        custom.state = isCustom ? .on : .off
        custom.representedObject = node
        menu.addItem(.separator())
        for (title, symbol) in MailboxSymbols.presets {
            add(title, symbol, symbol, on: symbol == showing)
        }
        return menu
    }

    private final class SymbolChoice: NSObject {
        let node: SidebarNode
        /// nil: Default.
        let symbol: String?
        init(node: SidebarNode, symbol: String?) {
            self.node = node
            self.symbol = symbol
        }
    }

    @objc private func symbolChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SymbolChoice else { return }
        MailboxSymbols.set(choice.symbol, for: choice.node.key)
    }

    @objc private func customSymbolClicked(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        SymbolPanel.show(key: node.key, defaultSymbol: node.symbol)
    }

    @objc private func editMailboxClicked(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        editMailbox(node)
    }

    /// A double-click on a unified mailbox edits it, on an account its settings, as in MailMate.
    @objc private func rowDoubleClicked(_ sender: NSOutlineView) {
        guard let node = outline.item(atRow: outline.clickedRow) as? SidebarNode else { return }
        if node.kind == .account, let id = node.accountId { return onEditAccount?(id) ?? () }
        editMailbox(node)
    }

    @objc private func editAccountClicked(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onEditAccount?(id) }
    }

    /// Opens MailMate's mailbox editor on a unified or smart mailbox (not from the editor's own sidebar).
    private func editMailbox(_ node: SidebarNode) {
        guard node.kind == .unified || node.kind == .smart, !isInEditor else { return }
        MailboxEditorWindowController.show(key: node.key, model: model, over: view.window)
    }

    private var isInEditor: Bool { view.window?.windowController is MailboxEditorWindowController }

    // MARK: Smart mailboxes

    @objc private func newSmartMailboxClicked(_ sender: NSMenuItem) {
        newSmartMailbox(inside: sender.representedObject as? SidebarNode)
    }

    /// MailMate's New Smart Mailbox: "Untitled", inside the given smart mailbox (else at the top level),
    /// selected, with its editor open at once on Conditions.
    /// On a special mailbox (MailMate's New Smart Mailbox on All Messages) it goes inside that one,
    /// starting from its messages.
    func newSmartMailbox(inside node: SidebarNode?) {
        var parentId: Int64?, parentKey: String?
        if case .smart(let id)? = node?.scope { parentId = id }
        if node?.kind == .unified { parentKey = node?.scope?.key }
        guard let id = model.createSmartMailbox(name: "Untitled", parentId: parentId, parentKey: parentKey) else { return }
        reload()
        if let parent = node, parent.kind == .smart || parent.kind == .unified, let fresh = find(parent.key, in: roots) {
            outline.expandItem(fresh)
        }
        let key = "smart.\(id)"
        guard select(key: key) else { return }
        MailboxEditorWindowController.show(key: key, model: model, over: view.window, tab: .conditions)
    }

    #if DEBUG
        func debugNewSmartMailbox(inside key: String) { newSmartMailbox(inside: find(key, in: roots)) }

        /// Logs the Symbol submenu for `key` ([x] when checked) and writes its first items' icons, side
        /// by side, to `path`.
        func debugSymbolMenu(key: String, path: String) {
            guard let node = find(key, in: roots) else { return NSLog("MMJ symbol menu: no \(key)") }
            let items = symbolMenu(for: node).items.filter { !$0.isSeparatorItem }
            NSLog("MMJ symbol menu: " + items.map { ($0.state == .on ? "[x] " : "") + $0.title }.joined(separator: ", "))
            let strip = NSImage(size: NSSize(width: 4 * 24, height: 20), flipped: false) { _ in
                NSColor.white.set()
                for (i, item) in items.prefix(4).enumerated() { item.image?.draw(in: NSRect(x: i * 24 + 2, y: 2, width: 16, height: 16)) }
                return true
            }
            if let tiff = strip.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    #endif

    /// MailMate's Duplicate Mailbox: a copy right after it (see `MailStore.duplicateSmartMailbox`), with
    /// its color, selected with its name ready to edit.
    @objc private func duplicateClicked(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        duplicate(node)
    }

    func duplicate(_ node: SidebarNode) {
        guard case .smart(let id)? = node.scope, let copy = try? model.store.duplicateSmartMailbox(id: id) else { return }
        let key = "smart.\(copy)"
        if let color = MailboxColors.color(for: node.key) { MailboxColors.set(color, for: key) }
        if MailboxColors.usesColorInList(node.key) { MailboxColors.setUsesColorInList(true, for: key) }
        // Right after the original in the Mailboxes section's dragged order, too.
        var order = UserDefaults.standard.stringArray(forKey: Self.orderDefaultsKey) ?? []
        if let at = order.firstIndex(of: node.key) {
            order.insert(key, at: at + 1)
            UserDefaults.standard.set(order, forKey: Self.orderDefaultsKey)
        }
        reload()
        if select(key: key) { beginRename(key: key, thenEdit: false) }
    }

    @objc private func renameClicked(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        beginRename(key: node.key, thenEdit: false)
    }

    private var renaming: (key: String, thenEdit: Bool)?

    /// Smart mailboxes and an account's folders can be renamed (not unified mailboxes, accounts, or Inbox).
    private func canRename(_ node: SidebarNode) -> Bool {
        if node.kind == .smart { return true }
        guard node.key.hasPrefix("mailbox."), case .mailbox? = node.scope else { return false }
        return node.role != "inbox"
    }

    /// Edits a smart mailbox's or folder's name in its row.
    private func beginRename(key: String, thenEdit: Bool) {
        guard let node = find(key, in: roots) else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell,
            let field = cell.textField
        else { return }
        renaming = (key, thenEdit)
        field.isEditable = true
        field.delegate = self
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Escape cancels the rename, keeping the old name.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard renaming != nil, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if let node = renaming.flatMap({ find($0.key, in: roots) }) { (control as? NSTextField)?.stringValue = node.title }
        view.window?.makeFirstResponder(outline)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let renaming else { return }
        self.renaming = nil
        field.isEditable = false
        guard let node = find(renaming.key, in: roots) else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
        if !name.isEmpty, name != node.title, movement != .cancel {
            node.title = name
            switch node.scope {
            case .smart(let id)?: model.updateSmartMailbox(id: id, name: name)
            case .mailbox(let id)?: model.renameMailbox(id: id, to: name)
            default: break
            }
        } else {
            field.stringValue = node.title
        }
        // Return (or Escape) hands the keyboard back to the sidebar; Return after New Smart Mailbox goes on
        // to its editor. Ending the edit by clicking elsewhere stays where the click was.
        if movement == .return || movement == .cancel {
            view.window?.makeFirstResponder(outline)
            if renaming.thenEdit, movement == .return { editMailbox(node) }
        }
    }

    @objc private func deleteSmartClicked(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode, case .smart(let id)? = node.scope, let window = view.window
        else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(node.title)”?"
        alert.informativeText = node.children.contains { $0.kind == .smart }
            ? "The smart mailboxes inside it are deleted too. No messages are deleted."
            : "No messages are deleted."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.model.deleteSmartMailbox(id: id)
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
    /// Shown instead of the badge while the account syncs or downloads, as in MailMate.
    private let spinner: NSProgressIndicator = {
        let p = NSProgressIndicator()
        p.style = .spinning
        p.controlSize = .small
        p.isDisplayedWhenStopped = false
        return p
    }()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let image = NSImageView()
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        for v in [image, field, badge, spinner] as [NSView] {
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
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `plain`: icon and name only (the mailbox editor's sidebar).
    func configure(_ node: SidebarNode, plain: Bool = false) {
        textField?.stringValue = node.title
        if let warning = node.warning, !plain {
            imageView?.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Sync error")
            imageView?.contentTintColor = .systemOrange
            toolTip = warning
        } else {
            if let imageView {
                MailboxColors.style(
                    imageView, key: node.key, symbol: node.symbol,
                    fallback: node.kind == .account ? .secondaryLabelColor : .controlAccentColor)
            }
            toolTip = plain ? nil : node.info
        }
        badge.count = plain ? 0 : node.badge
        if node.isBusy, !plain {
            badge.isHidden = true
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }
}

/// An unread-count capsule matching MailMate's pixel for pixel (fitted against a MailMate screenshot):
/// SF 11 pt Bold digits, an 18 pt capsule 12 pt wider than the digits, translucent white fill and
/// translucent black digits, so it looks right on both the sidebar and the selection color.
final class BadgeView: NSView {
    var count = 0 {
        didSet {
            isHidden = count == 0
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private static let font = NSFont.systemFont(ofSize: 11, weight: .bold)
    private static let fill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.33) : NSColor(white: 0, alpha: 0.18)
    }
    private static let digits = NSColor(white: 0, alpha: 0.75)

    private var attributed: NSAttributedString {
        NSAttributedString(string: String(count), attributes: [.font: Self.font, .foregroundColor: Self.digits])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(18, ceil(attributed.size().width) + 12), height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let text = attributed
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/// Sidebar selection in MailMate's shape (inset, rounded) and the app's own colors: the same
/// accent-based selection color as the message lists while focused, grey otherwise.
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 10, dy: 0)
        (isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }
}

/// The sidebar outline. Section headers are top-level rows (not group rows), so: no chevron on them
/// (they show Hide/Show instead), and the rows under them are drawn one level further left, where they
/// sat under group rows.
final class SidebarOutlineView: NSOutlineView {
    /// Return (or Enter) on the selected row: rename it, as in Finder.
    var onReturn: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers.isEmpty, event.keyCode == 36 || event.keyCode == 76 { return onReturn() }
        super.keyDown(with: event)
    }

    private func isHeader(_ row: Int) -> Bool { (item(atRow: row) as? SidebarNode)?.kind == .header }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        if isHeader(row) { return .zero }
        var frame = super.frameOfOutlineCell(atRow: row)
        if level(forRow: row) > 0 { frame.origin.x -= indentationPerLevel }
        return frame
    }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        // Headers start where group rows did, without the room left for a disclosure triangle (11 pt).
        let shift = isHeader(row) ? 11 : level(forRow: row) > 0 ? indentationPerLevel : 0
        frame.origin.x -= shift
        frame.size.width += shift
        // A header spans to the row's right edge (where Hide sits), as a group row did.
        if isHeader(row) { frame.size.width = rect(ofRow: row).maxX - frame.minX }
        return frame
    }
}

/// A section header as MailMate draws it (measured at 1x): 12 pt semibold grey title, and "Hide" (or
/// "Show" once hidden) at the right while the pointer is over the header.
final class SidebarHeaderCell: NSTableCellView {
    /// Shows as (181, 181, 181) on the dark sidebar, as MailMate's headers do (explicit sRGB greys draw
    /// lighter on this display: 166 comes out as 181).
    static let color = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 166 / 255, green: 166 / 255, blue: 166 / 255, alpha: 1) : .secondaryLabelColor
    }
    static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    /// The first header (measured at 1x): 15 px from the toolbar to its capitals, 28 px from them to the
    /// middle of the first row. Later ones: 18.5 px from the middle of the row above, 26.5 px below.
    static let firstRowHeight: CGFloat = 32
    static let rowHeight: CGFloat = 22

    private let toggle = NSButton(title: "Hide", target: nil, action: nil)
    /// Not the cell's `textField`: AppKit restyles that one in a group row (smaller, fainter).
    private let label = NSTextField(labelWithString: "")
    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
    var onToggle: () -> Void = {}
    private var titleOffset: NSLayoutConstraint!
    var isFirst = true {
        didSet { titleOffset.constant = isFirst ? 4 : 2 }
    }
    var isHidingSection = false {
        didSet { updateToggle() }
    }
    private var hovering = false {
        didSet { toggle.isHidden = !hovering }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = label
        titleOffset = field.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 4)
        field.font = Self.font
        field.textColor = Self.color
        toggle.isBordered = false
        toggle.target = self
        toggle.action = #selector(toggleClicked(_:))
        toggle.isHidden = true
        for v in [field, toggle] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            // 4 px left of the rows' chevrons, as in MailMate (measured at 1x).
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -5),
            titleOffset,
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),  // 3 px inside the badges' right edge
            toggle.centerYAnchor.constraint(equalTo: field.centerYAnchor),
        ])
        updateToggle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateToggle() {
        toggle.attributedTitle = NSAttributedString(
            string: isHidingSection ? "Show" : "Hide", attributes: [.font: Self.font, .foregroundColor: Self.color])
    }

    @objc private func toggleClicked(_ sender: Any?) { onToggle() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovering = false
    }
}
