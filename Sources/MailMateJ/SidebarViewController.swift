import AppKit
import GmailKit
import MailStore
import MailSync

final class SidebarNode: NSObject {
    enum Kind { case header, unified, account, mailbox, smart }

    let key: String
    let kind: Kind
    var title: String
    /// The SF Symbol shown before the title; none ("") for the submailboxes a Submailboxes tab makes,
    /// as in MailMate (one chosen with the Symbol menu still shows).
    let symbol: String
    var scope: MessageScope?
    let accountId: String?
    /// JMAP role of a mailbox node ("inbox", "sent", ...).
    var role: String?
    var badge = 0
    var warning: String?
    /// The account is offline: its row in red, " (offline)" after its name, as in MailMate.
    var isOffline = false
    /// Why, or what's waiting for it (the row's tooltip).
    var offlineReason: String?
    var info: String?
    var isBusy = false
    /// Made by a Submailboxes tab (one per value, account or source of the mailbox above), so it comes
    /// and goes with the mail: nothing can be made inside it.
    var isGenerated = false
    var children: [SidebarNode] = []

    init(key: String, kind: Kind, title: String, symbol: String = "", scope: MessageScope? = nil, accountId: String? = nil) {
        self.key = key
        self.kind = kind
        self.title = title
        self.symbol = symbol
        self.scope = scope
        self.accountId = accountId
    }

    /// This row and the rows inside it, as new nodes (for another outline: the mailbox editor's sidebar).
    func copied() -> SidebarNode {
        let node = SidebarNode(key: key, kind: kind, title: title, symbol: symbol, scope: scope, accountId: accountId)
        node.role = role
        node.badge = badge
        node.warning = warning
        node.isOffline = isOffline
        node.offlineReason = offlineReason
        node.info = info
        node.isBusy = isBusy
        node.isGenerated = isGenerated
        node.children = children.map { $0.copied() }
        return node
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
    /// A mailbox or account was renamed in its row.
    var onRename: ((SidebarNode) -> Void)?
    /// Edit an account's settings (a double-click on it, or Edit Account… in its menu).
    var onEditAccount: ((String) -> Void)?
    /// Unread counts, activity spinners, sync warnings and status tooltips on the rows; MailMate's
    /// mailbox editor shows its sidebar without any of them.
    var showsStatus = true
    /// The main window's sidebar. It builds the tree with every change (reloading with each store
    /// change) and posts `treeDidChange`; the mailbox editor's sidebar, its menus and the mailbox picker
    /// take the tree from it, so the mail is queried once per change.
    static weak var main: SidebarViewController?
    static let treeDidChange = Notification.Name("SidebarTreeDidChange")

    /// The main sidebar's tree as it is now (to read: for menus and lists), else one built without counts.
    static func currentTree(model: AppModel) -> [SidebarNode] {
        main?.roots ?? buildTree(model: model, counts: false)
    }

    private let model: AppModel
    private let outline = SidebarOutlineView()
    /// Sections (Mailboxes, Sources) the user hid with the header's Hide, remembered across launches.
    private var hiddenSections = Set(UserDefaults.standard.stringArray(forKey: "SidebarHiddenSections") ?? [])
    private var roots: [SidebarNode] = []
    private var expandedKeys: Set<String>
    private var suppressSelection = false
    /// Set while `reload()` re-expands rows, so expansion callbacks don't refresh statuses per row.
    private var isReloading = false
    static let expandedDefaultsKey = "SidebarExpandedKeys"

    init(model: AppModel) {
        self.model = model
        expandedKeys = Set(UserDefaults.standard.stringArray(forKey: Self.expandedDefaultsKey) ?? [])
        super.init(nibName: nil, bundle: nil)
        // Posted on the main thread; at once, before the sidebar shows the new mailbox.
        NotificationCenter.default.addObserver(forName: MailboxSettings.didForget, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.expandedKeys = Set(UserDefaults.standard.stringArray(forKey: Self.expandedDefaultsKey) ?? [])
            }
        }
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
        let container = NSView()
        for v in [scroll, progressBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        progressBar.isHidden = true
        progressHeight = progressBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: progressBar.topAnchor),
            progressBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            progressBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            progressHeight,
        ])
        view = container
    }

    /// Sync and download progress, at the bottom while there is any (the main window's sidebar).
    private let progressBar = SyncProgressBar()
    private var progressHeight: NSLayoutConstraint!

    /// Shows the progress bar (`fraction` done) with the first of `texts` that fits across it, or hides it.
    func showProgress(_ shown: Bool, fraction: Double = 0, texts: [String] = []) {
        progressBar.fraction = fraction
        progressBar.texts = texts
        guard progressBar.isHidden == shown else { return }
        progressBar.isHidden = !shown
        progressHeight.constant = shown ? SyncProgressBar.height : 0
    }

    var selectedNode: SidebarNode? { outline.item(atRow: outline.selectedRow) as? SidebarNode }

    /// Updates activity spinners, warnings and tooltips of visible rows in place (no reload, so
    /// spinners keep animating). Spinners stay where the work is: a row spins when its account syncs
    /// or downloads, when the download is working on its mailbox, for unified mailboxes when any
    /// mailbox with that role is busy, for collapsed rows when anything inside them is busy, and for a
    /// smart mailbox whose mailbox list names a busy account or mailbox itself (not through All
    /// Messages or a unified mailbox, which would set nearly every smart mailbox spinning); of its
    /// submailboxes, only the busy account's.
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
                node.isOffline = model.isOffline(accountId: id)
                node.offlineReason = model.offlineReason(accountId: id)
                node.info = model.downloadInfo(accountId: id)
            }
            node.isBusy = own || (inside && !outline.isItemExpanded(node))
            return own || inside
        }
        for root in roots where root.key != "header.mailboxes" { root.children.forEach { update($0) } }

        guard let unified = roots.first(where: { $0.key == "header.mailboxes" }) else { return reconfigureVisibleRows() }
        // Smart mailboxes: by the busy accounts whose mail their Mailboxes tab brings in by name (an
        // account, one of its mailboxes being downloaded, or another smart mailbox), Any/All/None followed.
        let smart = Dictionary(((try? model.store.smartMailboxes()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let mailboxAccounts = Dictionary(((try? model.store.mailboxes()) ?? []).map { ($0.id, $0.accountId) }, uniquingKeysWith: { a, _ in a })
        /// nil: the smart mailbox names no account (it lists Inbox, say).
        var busyBySmart: [Int64: Set<String>?] = [:]
        func busyAccounts(_ id: Int64, visited: Set<Int64> = []) -> Set<String>? {
            if let known = busyBySmart[id] { return known }
            guard !visited.contains(id), let record = smart[id] else { return nil }
            let accounts = record.definition.sources.namedAccounts { key -> Set<String>? in
                switch MessageScope(key: key)?.base {
                case .account(let account)?, .allInAccount(let account)?, .flaggedInAccount(let account)?:
                    return model.isBusy(accountId: account) ? [account] : []
                case .mailbox(let box)?, .flaggedInMailbox(let box)?:
                    // While its account syncs or downloads (mail arriving in it), or it's downloading itself.
                    guard let account = mailboxAccounts[box] else { return [] }
                    return model.isBusy(accountId: account) || busyIDs.contains(box) ? [account] : []
                case let scope? where scope.smartID != nil:
                    return busyAccounts(scope.smartID!, visited: visited.union([id]))
                default:
                    return nil  // names no account (Inbox, All Messages)
                }
            }
            busyBySmart[id] = .some(accounts)
            return accounts
        }
        @discardableResult
        func mark(_ node: SidebarNode) -> Bool {
            let own: Bool
            switch node.scope?.base {
            case .role(let role)?: own = busyRoles.contains(role)
            case .allMessages?: own = !busyIDs.isEmpty
            // A smart mailbox's per-account submailbox: when the smart mailbox brings in that busy account;
            // a per-value one never (its smart mailbox shows it, not dozens of children at once).
            case .smartAccount(let id, let account)?, .smartAccountValue(let id, let account, _, _)?:
                own = busyAccounts(id)?.contains(account) ?? false
            case .smartValue?, .value?: own = false
            case let scope? where scope.smartID != nil: own = !(busyAccounts(scope.smartID!) ?? []).isEmpty
            default: own = selfBusy(node)  // a special mailbox's submailbox (Inbox ▸ Alice): its mailbox
            }
            let inside = node.children.map(mark).contains(true)
            node.isBusy = own || (inside && !outline.isItemExpanded(node))
            return own || inside
        }
        unified.children.forEach { mark($0) }
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

    /// Rebuilds the tree from the store, keeping expansion and selection. With `keepingCounts` (only the
    /// mailbox list changed: a new smart mailbox), the rows already here keep their counts and generated
    /// submailboxes, so only new rows are queried.
    func reload(keepingCounts: Bool = false) {
        defer { if Self.main === self { NotificationCenter.default.post(name: Self.treeDidChange, object: self) } }
        var reuse: [String: SidebarNode]?
        if keepingCounts {
            var old: [String: SidebarNode] = [:]
            func index(_ nodes: [SidebarNode]) { for n in nodes { old[n.key] = n; index(n.children) } }
            index(roots)
            reuse = old
        }
        // The editor's sidebar mirrors the main one, which was just built (or will post `treeDidChange`).
        let fresh = if let main = Self.main, main !== self, !showsStatus {
            main.roots.map { $0.copied() }
        } else {
            Self.buildTree(model: model, counts: showsStatus, reuse: reuse)
        }
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
                        node.isOffline = n.isOffline
                        node.offlineReason = n.offlineReason
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
                reveal(node)
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

        /// The Mailboxes section's rows, top level, in order.
        var debugOrder: String { roots.first?.children.map(\.title).joined(separator: ", ") ?? "" }

        /// Logs a mailbox's message items (title, enabled); `choose` ("erase", "read") does one as its
        /// menu item does (Erase confirmed).
        /// A mailbox's context menu: titles, "-" between groups, "(off)" when greyed out.
        func debugContextMenu(key: String) -> [String] {
            guard let node = find(key, in: roots) else { return ["no \(key)"] }
            let menu = NSMenu()
            fillContextMenu(menu, for: node)
            return menu.items.map { $0.isSeparatorItem ? "-" : $0.title + ($0.isEnabled && ($0.action != nil || $0.submenu != nil) ? "" : " (off)") }
        }

        func debugEmpty(key: String, choose: String?) {
            guard let node = find(key, in: roots) else { return NSLog("MMJ empty: no \(key)") }
            let items = messageItems(node)
            NSLog("MMJ empty: \(key) items=\(items.map { "\($0.title)\($0.action == nil ? " (off)" : "")" })")
            guard let scope = node.scope else { return }
            if choose == "erase", items.contains(where: { $0.title.hasPrefix("Empty") && $0.action != nil }) { model.emptyMailbox(scope) }
            if choose == "read" { model.markAllRead(scope) }
        }

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
            reveal(node)
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

    /// Opens the rows above a node to show it, without remembering them as opened: rows stay as the
    /// user left them, so a mailbox the app selects itself (Inbox when the last one is gone, Go to Mailbox,
    /// Back) doesn't reopen a row the user keeps closed at the next launch.
    private func reveal(_ node: SidebarNode) {
        revealing = true
        defer { revealing = false }
        for ancestor in ancestors(of: node) { outline.expandItem(ancestor) }
    }

    private var revealing = false

    private func expandRemembered(_ nodes: [SidebarNode]) {
        for node in nodes where expandedKeys.contains(node.key) {
            outline.expandItem(node)
            expandRemembered(node.children)
        }
    }

    func node(forKey key: String) -> SidebarNode? { find(key, in: roots) }

    /// Whether the mailbox is Sent or Drafts (unified or an account's), or sits inside one: mail sent,
    /// whose list shows To in place of From.
    func holdsSentMail(_ key: String) -> Bool {
        var current: String? = key
        var steps = 0
        while let key = current, steps < 64 {
            if let node = node(forKey: key) {
                var role = node.role
                if case .role(let unified)? = node.scope { role = unified }
                if role == "sent" || role == "drafts" { return true }
            }
            current = MailboxColors.parents[key]
            steps += 1
        }
        return false
    }

    private func find(_ key: String, in nodes: [SidebarNode]) -> SidebarNode? {
        for node in nodes {
            if node.key == key { return node }
            if let hit = find(key, in: node.children) { return hit }
        }
        return nil
    }

    /// The sidebar's tree. Without `counts` the unread counts of smart and special mailboxes aren't
    /// queried. With `reuse` (the rows as they were, by key) those rows keep their counts and generated
    /// submailboxes: only rows new since are queried.
    static func buildTree(model: AppModel, counts withCounts: Bool = true, reuse: [String: SidebarNode]? = nil) -> [SidebarNode] {
        let store = model.store
        let accounts = (try? store.accounts()) ?? []
        let mailboxes = (try? store.mailboxes()) ?? []
        let smart = (try? store.smartMailboxes()) ?? []
        /// A row's unread count, when counting and the row is new (kept rows get theirs back at the end).
        func count(_ key: String, _ scope: MessageScope) -> Int? {
            guard withCounts, reuse?[key] == nil else { return nil }
            return (try? store.count(scope: scope, counting: .unread)) ?? 0
        }
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
            node.children = submailboxes(of: node, store: store, mailboxes: mailboxes, accounts: accountsByID, counts: counts, reuse: reuse)
            // Smart mailboxes made inside it, before its submailboxes.
            node.children = smartNodes(smart, inside: MessageScope.role(role).key, store: store, accounts: accountsByID, count: count, reuse: reuse)
                + node.children
            narrow(node, store: store, count: count)
            unified.children.append(node)
        }
        let all = SidebarNode(key: "unified.all", kind: .unified, title: "All Messages", symbol: "envelope", scope: .allMessages)  // MailMate's
        all.badge = count(all.key, .allMessages) ?? 0
        all.children = submailboxes(of: all, store: store, mailboxes: mailboxes, accounts: accountsByID, counts: counts, reuse: reuse)
        narrow(all, store: store, count: count)
        // MailMate's special mailbox for everything, Junk and Deleted Messages included.
        let everything = SidebarNode(
            key: "unified.everything", kind: .unified, title: "All / Junk / Deleted", symbol: "envelope", scope: .everything)
        everything.badge = count(everything.key, .everything) ?? 0
        everything.children = smartNodes(
            smart, inside: MessageScope.everything.key, store: store, accounts: accountsByID, count: count, reuse: reuse)
        all.children = [everything]
            + smartNodes(smart, inside: MessageScope.allMessages.key, store: store, accounts: accountsByID, count: count, reuse: reuse)
            + all.children
        unified.children.append(all)
        unified.children += smartNodes(smart, store: store, accounts: accountsByID, count: count, reuse: reuse)
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
                key: "account.\(account.id)", kind: .account, title: account.name,
                symbol: MailboxSymbols.symbol(for: account),
                scope: .account(account.id), accountId: account.id)
            node.badge = counts.unreadByAccount[account.id] ?? 0
            node.warning = model.syncWarning(accountId: account.id)
            node.isOffline = model.isOffline(accountId: account.id)
            node.offlineReason = model.offlineReason(accountId: account.id)
            node.info = model.downloadInfo(accountId: account.id)
            node.children = Self.mailboxTree(byAccount[account.id] ?? [], accountId: account.id)
            sources.children.append(node)
        }
        let roots = [unified, sources]
        if let reuse {
            // Rows that were here keep their counts (displayed counts too); only new ones are counted.
            func keep(_ nodes: [SidebarNode]) {
                for n in nodes {
                    if let old = reuse[n.key] { n.badge = old.badge }
                    keep(n.children)
                }
            }
            keep(roots)
        }
        if withCounts { DisplayedCounts.apply(to: roots, store: store, counting: { reuse?[$0.key] == nil }) }
        return roots
    }

    /// Smart mailboxes, nested as the user arranged them, each with its unread count (from `count`) and
    /// the submailboxes of its Submailboxes tab (as they were, for a row in `reuse`).
    /// The top-level ones, or with `inside` those inside that special mailbox (by its scope key).
    private static func smartNodes(
        _ smart: [SmartMailboxRecord], inside special: String? = nil, store: MailStore, accounts: [String: AccountRecord],
        count: (String, MessageScope) -> Int?, reuse: [String: SidebarNode]?
    ) -> [SidebarNode] {
        let byParent = Dictionary(grouping: smart, by: \.parentId)
        func nodes(_ parent: Int64?) -> [SidebarNode] {
            (byParent[parent] ?? []).filter { parent != nil || $0.parentKey == special }.map { record in
                let node = SidebarNode(
                    key: "smart.\(record.id)", kind: .smart, title: record.name, symbol: record.definition.icon ?? smartSymbol,
                    scope: .smart(record.id))
                node.badge = count(node.key, .smart(record.id)) ?? 0
                let generated = reuse?[node.key].map { $0.children.filter(\.isGenerated) }
                node.children = nodes(record.id) + (generated ?? splitNodes(record, store: store, accounts: accounts))
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
                    title: value.isEmpty ? "Other" : value, scope: scope, accountId: account)
                node.isGenerated = true
                node.badge = unread
                return node
            }
        }
        guard split.byAccount, let list = try? store.smartAccounts(id: record.id) else { return valueNodes(account: nil) }
        let sorted = list.compactMap { entry in accounts[entry.accountId].map { ($0, entry.unread) } }
            .sorted { AccountRecord.ordered($0.0, $1.0) }
        return sorted.map { account, unread in
            let node = SidebarNode(
                key: "smart.\(record.id).account.\(account.id)", kind: .mailbox, title: account.name,
                scope: .smartAccount(record.id, account.id), accountId: account.id)
            node.isGenerated = true
            node.badge = unread
            node.children = valueNodes(account: account.id)
            return node
        }
    }

    // MARK: Order

    /// The Mailboxes section's order, as dragged: special and smart mailboxes mixed, by key.
    static let orderDefaultsKey = "SidebarMailboxOrder"

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
    private static func narrow(_ node: SidebarNode, store: MailStore, count: (String, MessageScope) -> Int?) {
        guard let key = node.scope?.key, store.hasSpecialCondition(key: key) else { return }
        if let scope = node.scope, let n = count(node.key, scope) { node.badge = n }
        func wrap(_ nodes: [SidebarNode]) {
            for child in nodes {
                if let scope = child.scope {
                    child.scope = .within(key, scope)
                    if let n = count(child.key, .within(key, scope)) { child.badge = n }
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
    /// By another field (From, Subject, ...): a child per value, as a smart mailbox's; with "each
    /// account", the accounts (or their mailboxes of the role), each with its own values.
    private static func submailboxes(
        of node: SidebarNode, store: MailStore, mailboxes: [MailboxRecord], accounts: [String: AccountRecord],
        counts: MailStore.Counts, reuse: [String: SidebarNode]?
    ) -> [SidebarNode] {
        let settings = SubmailboxSettings.settings(for: node.key)
        guard settings.splits, let scope = node.scope else { return [] }
        let order: (MailboxRecord, MailboxRecord) -> Bool = { a, b in
            let x = accounts[a.accountId]!, y = accounts[b.accountId]!
            if x.id != y.id { return AccountRecord.ordered(x, y) }
            return a.name.lowercased() < b.name.lowercased()
        }
        let known = mailboxes.filter { accounts[$0.accountId] != nil }
        func child(_ key: String, _ title: String, _ scope: MessageScope, accountId: String, badge: Int, role: String?) -> SidebarNode {
            let child = SidebarNode(
                key: "\(node.key).\(key)", kind: .mailbox, title: title, scope: scope, accountId: accountId)
            child.isGenerated = true
            child.role = role
            child.badge = badge
            return child
        }
        func source(_ box: MailboxRecord) -> String { "\(box.name) – \(accounts[box.accountId]!.name)" }
        /// The values of `field` among the messages of `parent` (the unified mailbox, or one of its accounts);
        /// as they were, for a row in `reuse`.
        func valueNodes(_ field: SmartField, of parent: SidebarNode) -> [SidebarNode] {
            if let old = reuse?[parent.key] { return old.children.filter(\.isGenerated) }
            guard let scope = parent.scope, let values = try? store.values(of: field, in: scope),
                !(settings.unlessOnlyOne && values.count < 2)
            else { return [] }
            return values.map { value, unread in
                let child = SidebarNode(
                    key: "\(parent.key).value.\(value.lowercased())", kind: .mailbox, title: value.isEmpty ? "Other" : value,
                    scope: .value(scope, field, value), accountId: parent.accountId)
                child.isGenerated = true
                child.badge = unread
                return child
            }
        }

        var children: [SidebarNode]
        switch scope {
        case .role(let role):
            children = known.filter { $0.role == role }.sorted(by: order).map { box in
                child(box.accountId, accounts[box.accountId]!.name, .mailbox(box.id), accountId: box.accountId,
                      badge: box.unreadEmails, role: role)
            }
            if let field = settings.valueField {
                guard settings.byAccount else { return valueNodes(field, of: node) }
                for account in children { account.children = valueNodes(field, of: account) }
                return children
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
                children = accounts.values.filter { ids.contains($0.id) }.sorted(by: AccountRecord.ordered)
                    .map { account in
                        let node = child(
                            "acct.\(account.id)", account.name, flagged ? .flaggedInAccount(account.id) : .allInAccount(account.id),
                            accountId: account.id,
                            badge: flagged ? counts.flaggedByAccount[account.id] ?? 0
                                : sources.filter { $0.accountId == account.id }.reduce(0) { $0 + $1.unreadEmails },
                            role: nil)
                        if settings.splitsBySource { node.children = sourceNodes(sources.filter { $0.accountId == account.id }) }
                        if let field = settings.valueField { node.children = valueNodes(field, of: node) }
                        return node
                    }
                if settings.valueField != nil { return children }
            } else if let field = settings.valueField {
                return valueNodes(field, of: node)
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

    /// What can be dragged, here and in the mailbox editor's sidebar (as in MailMate): the special and
    /// smart mailboxes, in Mailboxes. Either sidebar's move refreshes both.
    private func isDraggable(_ node: SidebarNode) -> Bool {
        // Special mailboxes at the top or placed in a smart mailbox (not All / Junk / Deleted, part of All Messages).
        // Accounts aren't: they're always by description, A to Z.
        return (node.kind == .unified && node.key != "unified.everything") || node.kind == .smart
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
    /// smart mailbox likewise.
    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let node = dragged(info), let target = item as? SidebarNode else { return [] }
        switch node.kind {
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
        if revealing { return }  // opened to show a selection, not by the user
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

    /// The Mailbox menu's items, for the clicked mailbox: New Smart Mailbox, its commands, Synchronize.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outline.item(atRow: outline.clickedRow) as? SidebarNode else { return }
        fillContextMenu(menu, for: node)
    }

    private func fillContextMenu(_ menu: NSMenu, for node: SidebarNode) {
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.representedObject = node
            item.target = self
            return item
        }
        var groups = menuGroups(for: node)
        if (node.kind != .header || node.key == "header.mailboxes") && !node.isGenerated {
            groups.insert([item("New Smart Mailbox", #selector(newSmartMailboxClicked(_:)))], at: 0)
        }
        if node.kind != .header {
            let sync = item(synchronizeTitle(for: node), #selector(synchronizeClicked(_:)))
            if !canSynchronize(node) { sync.action = nil }
            groups.append([sync] + syncStatusItems(for: node))
        }
        for (index, group) in groups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            group.forEach(menu.addItem)
        }
    }

    /// A mailbox's commands, grouped as MailMate's Mailbox menu groups them: the account; Displayed
    /// Count, Color and Symbol; editing the mailbox; its messages; its rules. The Mailbox menu (for the
    /// selected mailbox) and the sidebar's context menu (for the clicked one) show these, between New
    /// Smart Mailbox and Synchronize.
    func menuGroups(for node: SidebarNode) -> [[NSMenuItem]] {
        func item(_ title: String, _ action: Selector, _ object: Any? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.representedObject = object ?? node
            item.target = self
            return item
        }
        var groups: [[NSMenuItem]] = []
        if node.kind == .account, let accountId = node.accountId {
            // MailMate's "Edit IMAP Account…", naming the account's type.
            let kind = (try? model.store.account(id: accountId))?.isGmail == true ? "Gmail" : "JMAP"
            groups.append([item("Edit \(kind) Account…", #selector(editAccountClicked(_:)), accountId)])
        }
        if node.kind != .header {
            let count = NSMenuItem(title: "Displayed Count", action: nil, keyEquivalent: "")
            count.submenu = countMenu(for: node)
            let color = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
            color.submenu = colorMenu(for: node)
            let symbol = NSMenuItem(title: "Symbol", action: nil, keyEquivalent: "")
            symbol.submenu = symbolMenu(for: node)
            groups.append([count, color, symbol])
        }
        if node.kind == .smart {
            groups.append([
                // MailMate's titles: "Mailbox", as for any mailbox (only New Smart Mailbox says "Smart").
                item("Edit Mailbox…", #selector(editMailboxClicked(_:))),
                item("Rename Mailbox…", #selector(renameClicked(_:))),
                item("Delete Mailbox", #selector(deleteSmartClicked(_:))),
                item("Duplicate Mailbox", #selector(duplicateClicked(_:))),
            ])
        } else if node.kind == .unified {
            groups.append([item("Edit Mailbox…", #selector(editMailboxClicked(_:)))])
        } else if node.kind == .account {
            groups.append([item("Rename Source…", #selector(renameClicked(_:))), item("Remove Source", #selector(removeClicked(_:)))])
        }
        if node.kind != .header {
            groups.append(messageItems(node))
            groups.append([item("Edit Rules…", #selector(editRulesClicked(_:)))])
        }
        return groups.filter { !$0.isEmpty }
    }

    /// MailMate's title for Synchronize: the mailbox's name in quotes, except for a smart (or unified)
    /// mailbox, which is synchronized through the mailboxes it's built on.
    func synchronizeTitle(for node: SidebarNode?) -> String {
        guard let node, node.kind != .header, node.kind != .smart, node.kind != .unified else { return "Synchronize" }
        return "Synchronize “\(node.title)”"
    }

    /// Synchronizes the accounts a mailbox's mail comes from (all of them for none).
    func synchronize(_ node: SidebarNode?) {
        guard let node, node.kind != .header, let accounts = sourceAccounts(of: node) else { return model.syncAll() }
        accounts.forEach(model.sync(accountId:))
    }

    @objc private func synchronizeClicked(_ sender: NSMenuItem) {
        synchronize(sender.representedObject as? SidebarNode)
    }

    /// Not for an offline account or its mailboxes: only Take Online brings them back.
    func canSynchronize(_ node: SidebarNode?) -> Bool {
        guard let id = node?.accountId else { return true }
        return !model.isOffline(accountId: id)
    }

    /// Edit Rules…: the mailbox editor's Rules tab for the mailbox.
    @objc private func editRulesClicked(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        MailboxEditorWindowController.show(key: node.key, model: model, over: view.window, tab: .rules)
    }

    /// What goes under Synchronize, as in MailMate: Take “account” Offline for an account (then why its
    /// last sync failed, as a greyed-out line), or Take “account” Online for an offline account or one
    /// of its mailboxes.
    func syncStatusItems(for node: SidebarNode) -> [NSMenuItem] {
        guard let accountId = node.accountId else { return [] }
        let offline = model.isOffline(accountId: accountId)
        guard offline || node.kind == .account else { return [] }
        let name = (try? model.store.account(id: accountId))?.name ?? node.title
        let take = NSMenuItem(
            title: "Take “\(name)” \(offline ? "Online" : "Offline")",
            action: offline ? #selector(takeOnlineClicked(_:)) : #selector(takeOfflineClicked(_:)), keyEquivalent: "")
        take.target = self
        take.representedObject = accountId
        guard !offline, let warning = node.warning else { return [take] }
        let line = NSMenuItem(title: warning.split(separator: "\n").first.map(String.init) ?? warning, action: nil, keyEquivalent: "")
        line.isEnabled = false
        return [take, line]
    }

    @objc private func takeOfflineClicked(_ sender: NSMenuItem) {
        guard let accountId = sender.representedObject as? String else { return }
        model.takeOffline(accountId: accountId)
    }

    /// Take Online; for a Gmail account Google refused (or dropped) the sign-in of, Google's sign-in in
    /// the browser, where only a failure has more to say (cancelling leaves it offline).
    @objc private func takeOnlineClicked(_ sender: NSMenuItem) {
        guard let accountId = sender.representedObject as? String else { return }
        Task {
            do {
                try await model.takeOnline(accountId: accountId)
                NSApp.activate()  // back from the browser, if it went there
            } catch GoogleOAuthError.cancelled {
                NSApp.activate()
            } catch {
                NSApp.activate()
                guard let window = view.window else { return }
                let alert = NSAlert()
                alert.messageText = "Couldn’t sign in again."
                alert.informativeText = AppModel.describe(error)
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    // MARK: Mark All Read, Empty

    /// MailMate's group for a mailbox's messages: Mark All Messages as Read (greyed out with nothing
    /// unread) and, for Deleted Messages, Empty "Deleted Messages"….
    private func messageItems(_ node: SidebarNode) -> [NSMenuItem] {
        guard let scope = node.scope else { return [] }
        let read = NSMenuItem(title: "Mark All Messages as Read", action: #selector(markAllReadClicked(_:)), keyEquivalent: "")
        read.target = self
        read.representedObject = node
        if ((try? model.store.count(scope: scope, counting: .unread)) ?? 0) == 0 { read.action = nil }
        return [read] + (emptyItem(node).map { [$0] } ?? [])
    }

    @objc private func markAllReadClicked(_ sender: NSMenuItem) {
        guard let scope = (sender.representedObject as? SidebarNode)?.scope else { return }
        model.markAllRead(scope)
    }

    /// Empty "Deleted Messages"…, for a Deleted Messages mailbox (unified, or an account's), greyed out
    /// when it's empty.
    private func emptyItem(_ node: SidebarNode) -> NSMenuItem? {
        let isTrash: Bool
        switch node.scope {
        case .role("trash")?: isTrash = true
        case .within(_, .role("trash"))?: isTrash = true
        default: isTrash = node.role == "trash"
        }
        guard isTrash, let scope = node.scope else { return nil }
        let item = NSMenuItem(title: "Empty “\(emptyName(node))”…", action: #selector(emptyClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = node
        if ((try? model.store.count(scope: scope, counting: .all)) ?? 0) == 0 { item.action = nil }
        return item
    }

    /// The mailbox's own name, as MailMate names it: an account's row under Deleted Messages is that
    /// account's trash ("Deleted Items"), not the account.
    private func emptyName(_ node: SidebarNode) -> String {
        var scope = node.scope
        if case .within(_, let inner)? = scope { scope = inner }
        guard case .mailbox(let id)? = scope, let box = try? model.store.mailboxes().first(where: { $0.id == id }) else {
            return node.title
        }
        return box.name
    }

    @objc private func emptyClicked(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode, let scope = node.scope, let window = view.window else { return }
        let count = (try? model.store.count(scope: scope, counting: .all)) ?? 0
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Erase the \(count == 1 ? "message" : "\(count) messages") in “\(emptyName(node))”?"
        alert.informativeText = "They’re deleted for good, on the server too. This can’t be undone."
        alert.addButton(withTitle: "Erase")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.model.emptyMailbox(scope)
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
        let current = MailboxColors.color(for: node.key) ?? .accent
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
            item.image = MailboxSymbols.menuImage(symbol)
            item.representedObject = SymbolChoice(node: node, symbol: choice)
            item.state = on ? .on : .off
        }
        add("Default", node.symbol, nil, on: chosen == nil)
        let custom = menu.addItem(withTitle: "Custom…", action: #selector(customSymbolClicked(_:)), keyEquivalent: "")
        custom.target = self
        // A symbol chosen in the Symbols panel shows (and is checked) here, as in MailMate.
        let isCustom = chosen.map { symbol in !MailboxSymbols.presets.contains { $0.symbol == symbol } } ?? false
        custom.image = MailboxSymbols.menuImage(isCustom ? showing : "questionmark.square.dashed")
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
    /// selected, with its editor open at once.
    /// On a special mailbox (MailMate's New Smart Mailbox on All Messages) it goes inside that one,
    /// starting from its messages.
    /// On a source it starts from that source's messages, under Any.
    /// The editor opens on Mailboxes when the new one starts from a mailbox's messages, else on Conditions.
    /// One made inside a mailbox takes its color. None goes inside a generated submailbox, which comes and
    /// goes with the mail.
    func newSmartMailbox(inside node: SidebarNode?) {
        if node?.isGenerated == true { return }
        var parentId: Int64?, parentKey: String?
        if case .smart(let id)? = node?.scope { parentId = id }
        if node?.kind == .unified { parentKey = node?.scope?.key }
        // From a source: a top-level smart mailbox taking that source's messages.
        let sources = node?.kind == .account ? node?.scope.map { [$0.key] } : nil
        // Creating it reloads the sidebars (the store change), so the new row is already in.
        guard let id = model.createSmartMailbox(name: "Untitled", parentId: parentId, parentKey: parentKey, sources: sources) else { return }
        if let parent = node, parent.kind == .smart || parent.kind == .unified, let fresh = find(parent.key, in: roots) {
            outline.expandItem(fresh)
        }
        let key = "smart.\(id)"
        // Made inside a mailbox, it takes that one's color.
        if parentId != nil || parentKey != nil, let parent = node, let color = MailboxColors.color(for: parent.key) {
            MailboxColors.set(color, for: key)
        }
        guard select(key: key) else { return }
        let startsFromMailbox = parentId != nil || parentKey != nil || sources != nil
        MailboxEditorWindowController.show(key: key, model: model, over: view.window, tab: startsFromMailbox ? .mailboxes : .conditions)
    }

    #if DEBUG
        func debugNewSmartMailbox(inside key: String) { newSmartMailbox(inside: find(key, in: roots)) }

        /// Logs the Symbol submenu for `key` ([x] when checked) and writes its first items' icons, side
        /// by side, to `path`.
        /// Opens the mailbox's Color menu, captures its window as the screen shows it, then closes it.
        func debugCaptureColorMenu(key: String, path: String) {
            guard let node = find(key, in: roots) else { return NSLog("MMJ color menu: no \(key)") }
            debugCapture(colorMenu(for: node), path: path)
        }

        /// Opens `menu` in the window and captures it, as it shows on screen, to `path`.
        private func debugCapture(_ menu: NSMenu, path: String) {
            guard let window = view.window else { return }
            let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
                let pid = ProcessInfo.processInfo.processIdentifier
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
                if let id = windows.first(where: {
                    ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.popUpMenuWindow))
                })?[kCGWindowNumber as String] as? Int {
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l\(id)", path]
                    try? capture.run()
                    capture.waitUntilExit()
                }
                menu.cancelTracking()
            }
            RunLoop.main.add(timer, forMode: .common)
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            menu.popUp(positioning: nil, at: NSPoint(x: 40, y: 200), in: window.contentView)
        }

        func debugSymbolMenu(key: String, path: String) {
            guard let node = find(key, in: roots) else { return NSLog("MMJ symbol menu: no \(key)") }
            let menu = symbolMenu(for: node)
            let items = menu.items.filter { !$0.isSeparatorItem }
            NSLog("MMJ symbol menu: " + items.map { ($0.state == .on ? "[x] " : "") + $0.title }.joined(separator: ", "))
            debugCapture(menu, path: path)
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
        MailboxSettings.forgetSmartMailbox(copy)  // one deleted earlier may have had its id
        let key = "smart.\(copy)"
        // Looks and counts as the original does: color, symbol, displayed count.
        if let color = MailboxColors.color(for: node.key) { MailboxColors.set(color, for: key) }
        if MailboxColors.usesColorInList(node.key) { MailboxColors.setUsesColorInList(true, for: key) }
        if let symbol = MailboxSymbols.symbol(for: node.key) { MailboxSymbols.set(symbol, for: key) }
        if let kind = DisplayedCounts.kind(for: node.key) { DisplayedCounts.set(kind, for: key) }
        if let include = DisplayedCounts.includesSubmailboxes(node.key) { DisplayedCounts.setIncludesSubmailboxes(include, for: key) }
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

    /// Smart mailboxes, accounts and an account's folders can be renamed (not unified mailboxes or Inbox).
    private func canRename(_ node: SidebarNode) -> Bool {
        if node.kind == .smart || node.kind == .account { return true }
        guard node.key.hasPrefix("mailbox."), case .mailbox? = node.scope else { return false }
        return node.role != "inbox"
    }

    /// Edits a smart mailbox's, account's or folder's name in its row.
    private func beginRename(key: String, thenEdit: Bool) {
        guard let node = find(key, in: roots) else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCell,
            let field = cell.textField
        else { return }
        renaming = (key, thenEdit)
        field.stringValue = node.title  // without " (offline)"
        field.textColor = .textColor
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
            case .account(let id)?: model.renameAccount(id: id, to: name)
            default: break
            }
            onRename?(node)
        }
        (field.superview as? SidebarCell)?.configure(node, plain: !showsStatus)  // the name as shown, " (offline)" and all
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

    /// The accounts a mailbox's mail comes from, for Mailbox › Synchronize: its own account, or the ones a
    /// smart mailbox's list brings in by name; nil for all of them (a unified mailbox, or a smart mailbox
    /// whose list names no account, such as one built on Inbox).
    func sourceAccounts(of node: SidebarNode) -> Set<String>? {
        let mailboxAccounts = Dictionary(((try? model.store.mailboxes()) ?? []).map { ($0.id, $0.accountId) }, uniquingKeysWith: { a, _ in a })
        let smart = Dictionary(((try? model.store.smartMailboxes()) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func accounts(_ scope: MessageScope?, visited: Set<Int64>) -> Set<String>? {
            switch scope?.base {
            case .account(let account)?, .allInAccount(let account)?, .flaggedInAccount(let account)?,
                .smartAccount(_, let account)?, .smartAccountValue(_, let account, _, _)?:
                return [account]
            case .mailbox(let box)?, .flaggedInMailbox(let box)?:
                return mailboxAccounts[box].map { [$0] } ?? []
            case .value(let scope, _, _)?:
                return accounts(scope, visited: visited)
            case let scope? where scope.smartID != nil:
                let id = scope.smartID!
                guard !visited.contains(id), let record = smart[id] else { return nil }
                return record.definition.sources.namedAccounts { key in
                    accounts(MessageScope(key: key), visited: visited.union([id]))
                }
            default:
                return nil  // names no account (Inbox, All Messages)
            }
        }
        if let account = node.accountId { return [account] }
        guard let found = accounts(node.scope, visited: []), !found.isEmpty else { return nil }
        return found
    }

    @objc private func removeClicked(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode, let id = node.accountId else { return }
        // MailMate's: a panel of its own with the app's icon, Remove the default button.
        let gmail = (try? model.store.account(id: id))?.isGmail == true
        if Self.removeAccountAlert(name: node.title, kind: gmail ? "Gmail" : "JMAP").runModal() == .alertFirstButtonReturn {
            model.removeAccount(id: id)
        }
    }

    /// `kind` names the account's type as MailMate's alert does ("the IMAP account"): JMAP or Gmail.
    static func removeAccountAlert(name: String, kind: String = "JMAP") -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Remove Account?"
        alert.informativeText = """
            You are about to remove the \(kind) account “\(name)”. Are you sure you want to do that?

            Messages on the server are not going to be affected.
            """
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert
    }
}

/// Icon, title, and an unread-count capsule.
final class SidebarCell: NSTableCellView {
    private let badge = BadgeView()
    /// The title after the icon, or in its place on a row without one (a generated submailbox's): MailMate
    /// puts that title 11 pt right of its parent's icon, where the child's icon would be (measured at 1x).
    private var titleAfterIcon: NSLayoutConstraint!
    private var titleInIconsPlace: NSLayoutConstraint!
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
        // Solid text, as MailMate's (254 on the dark sidebar, not 240): the sidebar's frosted material
        // blends vibrant label colours with what's behind the window, which made the names look washed out.
        let field = SolidLabel(labelWithString: "")
        field.textColor = .textColor
        field.lineBreakMode = .byTruncatingTail
        for v in [image, field, badge, spinner] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        imageView = image
        textField = field
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleAfterIcon = field.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5)
        titleInIconsPlace = field.leadingAnchor.constraint(equalTo: image.leadingAnchor)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            titleAfterIcon,
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

    /// The title in the selection's text colour on a highlighted row (white on the accent in light mode);
    /// red for an offline account, as in MailMate, selected or not.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { styleTitle() }
    }

    private var isOffline = false

    private func styleTitle() {
        textField?.textColor = isOffline ? .systemRed
            : backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .textColor
    }

    /// `plain`: icon and name only (the mailbox editor's sidebar).
    func configure(_ node: SidebarNode, plain: Bool = false) {
        isOffline = node.isOffline && !plain
        textField?.stringValue = isOffline ? node.title + " (offline)" : node.title
        // A long name gives way in the middle, so " (offline)" still shows.
        textField?.lineBreakMode = isOffline ? .byTruncatingMiddle : .byTruncatingTail
        styleTitle()
        if let warning = node.warning, !plain {
            imageView?.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Sync error")
            imageView?.contentTintColor = .systemOrange
            toolTip = warning
        } else {
            if let imageView {
                MailboxColors.style(imageView, key: node.key, symbol: node.symbol)
                // Its icon too, drawn in (a tint turns white on a selected row).
                if isOffline, let image = imageView.image {
                    imageView.image = MailboxColors.tinted(image, .systemRed)
                    imageView.contentTintColor = nil
                }
            }
            toolTip = plain ? nil : node.offlineReason ?? node.info
        }
        let hasIcon = imageView?.image != nil
        if titleAfterIcon.isActive != hasIcon {
            (hasIcon ? titleInIconsPlace : titleAfterIcon).isActive = false
            (hasIcon ? titleAfterIcon : titleInIconsPlace).isActive = true
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
    /// Shows as about (200, 200, 200) on the dark sidebar, as MailMate's headers do side by side with
    /// these (explicit sRGB greys draw about 15 lighter on this display).
    static let color = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 185 / 255, green: 185 / 255, blue: 185 / 255, alpha: 1) : .secondaryLabelColor
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

/// A label drawn as it is, not blended with a vibrant (frosted) background behind it.
final class SolidLabel: NSTextField {
    override var allowsVibrancy: Bool { false }
}
