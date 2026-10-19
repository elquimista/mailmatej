import AppKit
import MailStore
import MailSync
import SwiftUI

/// The Correspondence layout: sidebar | (message list over (correspondence | message)).
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation, NSWindowDelegate {
    private let model: AppModel
    private let sidebar: SidebarViewController
    private let list: MessageListViewController
    private let correspondence: MessageListViewController
    private let correspondenceTitle = NSTextField(labelWithString: "Correspondence")
    private let messageView: MessageViewController
    private weak var searchField: NSSearchField?

    private var scope: MessageScope = .role("inbox")
    private var scopeTitle = "Inbox"
    private var search = ""
    private var loadGeneration = 0
    /// The newest message as of the last load, to tell whether the user is "following" new mail.
    private var lastNewestID: Int64?
    /// The message to select once moved messages have left the list (Archive, Junk, Delete).
    private var selectAfterMove: Int64?
    private var correspondent: String?
    private var correspondenceTask: Task<Void, Never>?
    /// Last selection per mailbox, for this run of the app only (like MailMate): coming back to a
    /// mailbox restores it; a mailbox not visited yet this run opens scrolled to its newest message.
    private var remembered: [MessageScope: SavedView] = [:]
    /// A Correspondence selection waiting to be restored once that pane reloads for `mainID`.
    private var pendingCorrespondence: (mainID: Int64, saved: SavedView)?

    /// How a mailbox looked when the user left it: both lists' selections and scroll positions,
    /// and the message open in the reader (which may come from the Correspondence pane).
    private struct SavedView {
        var selection: [Int64]
        var anchor: MessageListViewController.ScrollAnchor?
        var correspondenceSelection: [Int64]
        var correspondenceAnchor: MessageListViewController.ScrollAnchor?
        var displayed: Int64?
    }

    private enum ReloadReason { case scopeChanged, searchChanged, sortChanged, dataChanged }
    private var splits: (root: NSSplitView, content: NSSplitView, bottom: NSSplitView)?

    init(model: AppModel) {
        self.model = model
        sidebar = SidebarViewController(model: model)
        list = MessageListViewController(
            store: model.store, columns: [.unread, .flag, .from, .subject, .date, .source, .attachment],
            autosaveName: "MainMessageList")
        // As MailMate's Correspondence pane (measured at 1x): no unread column, flag last, relative dates,
        // oldest first.
        correspondence = MessageListViewController(
            store: model.store, columns: [.subject, .date, .source, .attachment, .flag],
            autosaveName: "CorrespondenceList", widths: [.subject: 254, .date: 94, .source: 127],
            defaultSort: MessageSort(key: .receivedAt, ascending: true), relativeDates: true)
        messageView = MessageViewController(model: model)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "MailMateJ"
        window.toolbarStyle = .expanded  // Title row above the toolbar, centered, as in MailMate.
        super.init(window: window)
        window.delegate = self

        window.contentViewController = buildLayout()
        // Assigning the content view controller resizes the window to its (empty) content; restore a real size.
        if !window.setFrameUsingName("MainWindow") {
            window.setContentSize(NSSize(width: 1400, height: 880))
            window.center()
        }
        window.setFrameAutosaveName("MainWindow")
        applyDefaultSplitPositionsIfNeeded()
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = Set(Self.actionGroups.map(\.id))
        window.toolbar = toolbar

        wireUp()
        sidebar.selectInitial()
        NotificationCenter.default.addObserver(
            forName: .mailStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeDidChange() }
        }
        NotificationCenter.default.addObserver(
            forName: .syncStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncStatusDidChange() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildLayout() -> NSViewController {
        let correspondencePane = NSViewController()
        // MailMate's title band (measured at 1x): 24 pt, 11 pt regular title in the label color, and a
        // 1 pt line (showing as (79, 82, 83)) above the column headers.
        correspondenceTitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        correspondenceTitle.textColor = .labelColor
        correspondenceTitle.alignment = .center
        correspondenceTitle.lineBreakMode = .byTruncatingMiddle
        let band = NSView()
        let line = NSBox()
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = NSColor(srgbRed: 63 / 255, green: 66 / 255, blue: 67 / 255, alpha: 1)
        for v in [correspondenceTitle, line] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            band.addSubview(v)
        }
        NSLayoutConstraint.activate([
            band.heightAnchor.constraint(equalToConstant: 25),
            correspondenceTitle.leadingAnchor.constraint(equalTo: band.leadingAnchor, constant: 4),
            correspondenceTitle.trailingAnchor.constraint(equalTo: band.trailingAnchor, constant: -4),
            correspondenceTitle.centerYAnchor.constraint(equalTo: band.topAnchor, constant: 12),
            line.leadingAnchor.constraint(equalTo: band.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: band.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: band.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        let stack = NSStackView(views: [band, correspondence.view])
        stack.orientation = .vertical
        stack.spacing = 0
        correspondenceTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The title mustn't pull the pane narrower than the user left it (its hugging would tie with the
        // split item's holding priority).
        correspondenceTitle.setContentHuggingPriority(.init(1), for: .horizontal)
        for v in [band, correspondence.view] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        correspondencePane.view = stack

        let bottom = NSSplitViewController()
        bottom.splitView = CorrespondenceSplitView()
        bottom.splitView.isVertical = true
        bottom.addSplitViewItem(NSSplitViewItem(viewController: correspondencePane))
        bottom.addSplitViewItem(NSSplitViewItem(viewController: messageView))
        bottom.splitViewItems[0].minimumThickness = 220
        bottom.splitViewItems[1].minimumThickness = 320
        bottom.splitView.autosaveName = "BottomSplit"
        bottom.splitView.identifier = .init("BottomSplit")

        let content = NSSplitViewController()
        content.splitView.isVertical = false
        // MailMate's divider between the list and the panes below: a 10 pt bar with a grip in the middle.
        content.splitView.dividerStyle = .paneSplitter
        content.addSplitViewItem(NSSplitViewItem(viewController: list))
        content.addSplitViewItem(NSSplitViewItem(viewController: bottom))
        content.splitViewItems[0].minimumThickness = 120
        content.splitViewItems[1].minimumThickness = 200
        content.splitView.autosaveName = "ContentSplit"
        content.splitView.identifier = .init("ContentSplit")

        let root = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        root.addSplitViewItem(sidebarItem)
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 600
        root.addSplitViewItem(contentItem)
        root.splitView.autosaveName = "RootSplit"
        root.splitView.identifier = .init("RootSplit")
        splits = (root.splitView, content.splitView, bottom.splitView)
        return root
    }

    /// First launch only: sidebar 230 pt, list takes ~45% of the height, correspondence ~35% of the bottom.
    private func applyDefaultSplitPositionsIfNeeded() {
        guard let splits, UserDefaults.standard.object(forKey: "NSSplitView Subview Frames ContentSplit") == nil
        else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        splits.root.setPosition(230, ofDividerAt: 0)
        splits.root.layoutSubtreeIfNeeded()
        splits.content.setPosition(splits.content.bounds.height * 0.45, ofDividerAt: 0)
        splits.content.layoutSubtreeIfNeeded()
        splits.bottom.setPosition(splits.bottom.bounds.width * 0.36, ofDividerAt: 0)
    }

    private func wireUp() {
        sidebar.onSelect = { [weak self] node in
            guard let self, let scope = node.scope else { return }
            remembered[self.scope] = SavedView(
                selection: list.selectedIDs, anchor: list.scrollAnchor,
                correspondenceSelection: correspondence.selectedIDs, correspondenceAnchor: correspondence.scrollAnchor,
                displayed: messageView.displayedMessageID)
            self.scope = scope
            self.scopeTitle = node.title
            self.reloadList(.scopeChanged)
        }
        list.onSelectionChange = { [weak self] id in
            guard let self else { return }
            pendingCorrespondence = nil  // A new main selection starts the Correspondence pane fresh.
            messageView.show(messageID: id, selectionCount: list.selectedIDs.count)
            scheduleCorrespondenceUpdate(for: id)
            updateTitle()
        }
        list.onSortChange = { [weak self] _ in
            self?.reloadList(.sortChanged)
        }
        correspondence.onSortChange = { [weak self] _ in
            guard let self else { return }
            reloadCorrespondence(for: list.selectedID ?? correspondence.selectedID, keepSelection: true)
        }
        for messageList in [list, correspondence] {
            messageList.onShowInFinder = { [weak self] id in self?.model.showInFinder(messageId: id, window: self?.window) }
        }
        correspondence.onSelectionChange = { [weak self] id in
            guard let self, let id else { return }
            messageView.show(messageID: id)
        }
    }

    // MARK: Loading

    private func reloadList(_ reason: ReloadReason) {
        loadGeneration += 1
        let generation = loadGeneration
        let (store, scope, sort) = (model.store, scope, list.sort)
        let search: String? = search.isEmpty ? nil : search
        Task {
            let (ids, newest) = await Task.detached(priority: .userInitiated) {
                ((try? store.messageIDs(scope: scope, sort: sort, search: search)) ?? [],
                 try? store.newestMessageID(scope: scope, search: search))
            }.value
            guard generation == loadGeneration else { return }
            let before = list.selectedIDs
            var restoredDisplay: Int64?

            switch reason {
            case .scopeChanged:
                if let saved = remembered[scope], saved.selection.contains(where: ids.contains) {
                    list.setIDs(ids, selecting: saved.selection, scroll: .restore(saved.anchor))
                    if let main = list.selectedID, !saved.correspondenceSelection.isEmpty {
                        pendingCorrespondence = (main, saved)
                        restoredDisplay = saved.displayed
                    }
                } else {
                    list.setIDs(ids, selecting: [], scroll: .toMessage(newest))
                }
            case .searchChanged, .sortChanged:
                // Keep the selection if it is still in the list; otherwise show the newest message.
                let kept = before.filter(ids.contains)
                list.setIDs(ids, selecting: kept, scroll: kept.isEmpty ? .toMessage(newest) : .toSelection)
            case .dataChanged where selectAfterMove != nil:
                // Right after Archive/Junk/Delete: if the messages left the list, select the next one.
                let next = selectAfterMove!
                selectAfterMove = nil
                let left = !before.isEmpty && !before.contains(where: ids.contains)
                list.setIDs(ids, selecting: left && ids.contains(next) ? [next] : nil, scroll: .keepPosition)
            case .dataChanged:
                // A list that just got its first messages (initial sync) opens at the newest one.
                // When sorted by date and the newest message was in view, follow new mail to the
                // top (or bottom); if the user scrolled away from it, keep their position.
                let wasEmpty = list.ids.isEmpty
                let following = sort.key == .receivedAt && list.isFullyVisible(lastNewestID)
                list.setIDs(ids, scroll: wasEmpty || (following && newest != lastNewestID) ? .toMessage(newest) : .keepPosition)
            }
            lastNewestID = newest

            if list.selectedIDs != before || reason == .scopeChanged {
                messageView.show(messageID: restoredDisplay ?? list.selectedID, selectionCount: list.selectedIDs.count)
                scheduleCorrespondenceUpdate(for: list.selectedID)
            }
            updateTitle()
        }
    }

    private func scheduleCorrespondenceUpdate(for id: Int64?) {
        correspondenceTask?.cancel()
        correspondenceTask = Task {
            try? await Task.sleep(for: .milliseconds(60))  // Keep arrow-key scrolling smooth.
            guard !Task.isCancelled else { return }
            reloadCorrespondence(for: id)
        }
    }

    /// Reloads the Correspondence pane for the main list's message `id`. Normally that message is
    /// selected there; a selection saved for the mailbox is restored instead, and with `keepSelection`
    /// (new mail, re-sorting) whatever the user selected in the pane stays selected.
    private func reloadCorrespondence(for id: Int64?, keepSelection: Bool = false) {
        guard let id, let email = try? model.store.correspondent(messageId: id, myAddresses: model.myAddresses) else {
            correspondent = nil
            correspondence.setIDs([])
            return
        }
        correspondent = email
        // Only mail with this person through the address of mine this message used.
        let mine = try? model.store.myAddress(in: id, myAddresses: model.myAddresses)
        let ids = (try? model.store.correspondenceIDs(email: email, via: mine, sort: correspondence.sort)) ?? []
        if let pending = pendingCorrespondence, pending.mainID == id {
            pendingCorrespondence = nil
            let kept = pending.saved.correspondenceSelection.filter(ids.contains)
            if !kept.isEmpty {
                correspondence.setIDs(ids, selecting: kept, scroll: .restore(pending.saved.correspondenceAnchor))
                return
            }
        }
        if keepSelection {
            let kept = correspondence.selectedIDs.filter(ids.contains)
            correspondence.setIDs(ids, selecting: kept.isEmpty ? [id] : kept, scroll: .keepPosition)
        } else {
            correspondence.setIDs(ids, selecting: [id], scroll: .toSelection)
        }
    }

    private func storeDidChange() {
        sidebar.reload()
        reloadList(.dataChanged)
        if list.selectedID != nil || correspondent != nil {
            reloadCorrespondence(for: list.selectedID ?? correspondence.selectedID, keepSelection: true)
        }
    }

    private func syncStatusDidChange() {
        sidebar.refreshStatuses()
        updateTitle()
    }

    /// "Subject — Mailbox (N messages)", as MailMate titles its window.
    private func updateTitle() {
        let count = list.ids.count
        let mailbox = "\(scopeTitle) (\(count.formatted()) message\(count == 1 ? "" : "s"))"
        let subject = list.selectedID.flatMap { try? model.store.detail(id: $0)?.subject }
        window?.title = subject.map { ($0.isEmpty ? "(no subject)" : $0) + " — " + mailbox } ?? mailbox
        let syncing = model.syncingCount
        let remaining = model.downloadsRemaining
        window?.subtitle =
            syncing > 0 ? "Syncing \(syncing) account\(syncing == 1 ? "" : "s")…"
            : remaining > 0 ? "Downloading messages… \(remaining.formatted()) left" : ""
    }

    #if DEBUG
        /// Runs a toolbar action on the selection, as its button would.
        func debugPerform(_ name: String) {
            window?.toolbar?.validateVisibleItems()
            let states = window?.toolbar?.items.compactMap { $0.view as? NSStackView }.flatMap(\.arrangedSubviews)
                .compactMap { $0 as? NSButton }.map { "\($0.toolTip ?? "")=\($0.isEnabled)" } ?? []
            NSLog("MMJ action \(name) on \(targetIDs), buttons: \(states)")
            switch name {
            case "archive": archiveMessages(nil)
            case "junk": junkMessages(nil)
            case "delete": deleteMessages(nil)
            case "read": markRead(nil)
            case "unread": markUnread(nil)
            case "flag": toggleFlag(nil)
            case "new": newMessage(nil)
            case "reply": reply(nil)
            case "replyAll": replyAll(nil)
            case "forward": forward(nil)
            default: break
            }
        }

        var debugSelection: [Int64] { list.selectedIDs }

        /// Selects the newest list row with this subject.
        func debugSelect(subject: String) {
            guard let row = list.ids.firstIndex(where: { (try? model.store.detail(id: $0))?.subject == subject }) else {
                return NSLog("MMJ select: no message with subject \(subject)")
            }
            list.tableView.selectRowIndexes([row], byExtendingSelection: false)
            NSLog("MMJ select: row \(row), message \(list.ids[row])")
        }

        func debugSelectSidebar(key: String) { sidebar.debugSelect(key: key) }
        func debugExpandSidebar(key: String) { sidebar.debugExpand(key: key) }

        /// Selects a row of the Correspondence pane, as a click would.
        func debugSelectCorrespondence(row: Int) {
            guard row < correspondence.ids.count else { return }
            correspondence.tableView.selectRowIndexes([row], byExtendingSelection: false)
        }

        /// Deletes the displayed message's .eml, then fetches it through the Show in Finder path.
        func debugCheckAttachments() async { await messageView.debugCheckAttachments() }

        func debugCheckRawMessage() async {
            guard let id = messageView.displayedMessageID, let detail = try? model.store.detail(id: id) else {
                return NSLog("MMJ raw: no message displayed")
            }
            let path = model.store.blobs.url(accountId: detail.accountId, blobId: detail.blobId)
            try? FileManager.default.removeItem(at: path)
            do {
                let url = try await model.rawMessageURL(messageId: id)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
                NSLog("MMJ raw: \(url.path) exists=\(FileManager.default.fileExists(atPath: url.path)) bytes=\(size)")
            } catch {
                NSLog("MMJ raw: error \(error)")
            }
        }

        func debugFocusSidebar() {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
            sidebar.debugFocus()
        }

        func debugLoadRemote() { messageView.debugLoadRemote() }

        func debugRender(html: String) { messageView.debugRender(html: html) }

        func debugScrollMessage(by points: CGFloat) { messageView.debugScrollContent(by: points) }

        func debugSnapshotWeb(to path: String) async { await messageView.debugSnapshotWeb(to: path) }

        func debugScrollList(by points: CGFloat) {
            guard let scrollView = list.tableView.enclosingScrollView else { return }
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + points))
            scrollView.reflectScrolledClipView(clip)
        }

        /// Moves the main list selection down one row, as the down-arrow key would.
        func debugSelectNextMessage() {
            let next = list.tableView.selectedRow + 1
            guard next < list.ids.count else { return }
            list.tableView.selectRowIndexes([next], byExtendingSelection: false)
            list.tableView.scrollRowToVisible(next)
        }
    #endif

    // MARK: Actions

    /// Message → Show in Finder: the message on screen.
    @objc func showInFinder(_ sender: Any?) {
        guard let id = messageView.displayedMessageID else { return NSSound.beep() }
        model.showInFinder(messageId: id, window: window)
    }

    @objc func getAllMail(_ sender: Any?) {
        model.syncAll()
    }

    /// The open JMAP Account Settings window, if any (one at a time).
    private(set) var accountSettings: AccountSettingsWindowController?

    @objc func addAccount(_ sender: Any?) {
        if accountSettings == nil {
            accountSettings = AccountSettingsWindowController(model: model) { [weak self] in
                self?.accountSettings = nil
            }
        }
        accountSettings?.show(over: window)
    }

    @objc func focusSearch(_ sender: Any?) {
        guard let searchField else { return }
        window?.makeFirstResponder(searchField)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        search = sender.stringValue
        reloadList(.searchChanged)
    }

    // MARK: Toolbar

    private static let getMailItem = NSToolbarItem.Identifier("getMail")
    private static let addAccountItem = NSToolbarItem.Identifier("addAccount")
    private static let searchItem = NSToolbarItem.Identifier("search")

    private typealias ActionButton = (label: String, symbol: String, action: Selector)

    /// MailMate's message buttons, in its order and groups, centered in the toolbar.
    private static let actionGroups: [(id: NSToolbarItem.Identifier, buttons: [ActionButton])] = [
        (.init("mailboxActions"), [
            ("Archive", "archivebox", #selector(archiveMessages(_:))),
            ("Mark as Junk", "xmark.bin", #selector(junkMessages(_:))),
            ("Delete", "trash", #selector(deleteMessages(_:))),
        ]),
        (.init("compose"), [("New Message", "square.and.pencil", #selector(newMessage(_:)))]),
        (.init("replyActions"), [
            ("Reply", "arrowshape.turn.up.left", #selector(reply(_:))),
            ("Reply All", "arrowshape.turn.up.left.2", #selector(replyAll(_:))),
            ("Forward", "arrowshape.turn.up.right", #selector(forward(_:))),
        ]),
        (.init("readActions"), [
            ("Mark as Unread", "envelope.badge", #selector(markUnread(_:))),
            ("Mark as Read", "envelope.open", #selector(markRead(_:))),
        ]),
        (.init("flag"), [("Flag", "flag", #selector(toggleFlag(_:)))]),
    ]

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.getMailItem, .flexibleSpace]
            + Self.actionGroups.map(\.id) + [.flexibleSpace, Self.addAccountItem, Self.searchItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if let group = Self.actionGroups.first(where: { $0.id == id }) {
            return actionGroupItem(id, group.buttons)
        }
        switch id {
        case Self.getMailItem:
            return button(id, "Get Mail", "arrow.clockwise", #selector(getAllMail(_:)))
        case Self.addAccountItem:
            return button(id, "Add Account", "person.crop.circle.badge.plus", #selector(addAccount(_:)))
        case Self.searchItem:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "Search Messages"
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.sendsWholeSearchString = false
            item.preferredWidthForSearchField = 260
            searchField = item.searchField
            return item
        default:
            return nil
        }
    }

    // MARK: Message actions

    /// The messages a button acts on: the selection in the list that has focus, else the main list's,
    /// else the message on screen.
    private var targetIDs: [Int64] {
        if window?.firstResponder === correspondence.tableView, !correspondence.selectedIDs.isEmpty {
            return correspondence.selectedIDs
        }
        if !list.selectedIDs.isEmpty { return list.selectedIDs }
        return messageView.displayedMessageID.map { [$0] } ?? []
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { true }

    /// One toolbar item per group of MailMate's buttons, so the spacing can match: 40 pt from button
    /// to button within a group, 46 pt between groups, symbols 15 px tall (measured at 1x).
    private func actionGroupItem(_ id: NSToolbarItem.Identifier, _ buttons: [ActionButton]) -> NSToolbarItem {
        let views = buttons.map { b -> NSButton in
            let button = NSButton()
            button.bezelStyle = .toolbar
            button.showsBorderOnlyWhileMouseInside = true
            button.image = NSImage(systemSymbolName: b.symbol, accessibilityDescription: b.label)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
            button.imagePosition = .imageOnly
            button.toolTip = b.label
            button.target = self
            button.action = b.action
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            return button
        }
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 3, bottom: 0, right: 3)
        let item = ValidatingToolbarItem(itemIdentifier: id)
        item.view = stack
        item.label = buttons.map(\.label).joined(separator: ", ")
        item.onValidate = { [weak self] in
            guard let self else { return }
            let ids = targetIDs
            let hasTarget = !ids.isEmpty
            let rows = hasTarget ? (try? model.store.rows(ids: ids)) ?? [] : []
            for button in views {
                switch button.action {
                // As in MailMate, a mark button is off when it would change nothing.
                case #selector(markRead(_:)): button.isEnabled = rows.contains { !$0.isSeen }
                case #selector(markUnread(_:)): button.isEnabled = rows.contains(where: \.isSeen)
                case #selector(newMessage(_:)): button.isEnabled = model.canCompose
                // Replying and forwarding act on one message.
                case #selector(reply(_:)), #selector(replyAll(_:)), #selector(forward(_:)):
                    button.isEnabled = ids.count == 1 && model.canCompose
                case #selector(toggleFlag(_:)):
                    let flagged = allFlagged(targetIDs)
                    button.toolTip = flagged ? "Unflag" : "Flag"
                    button.image = NSImage(systemSymbolName: flagged ? "flag.slash" : "flag", accessibilityDescription: button.toolTip)?
                        .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
                    button.isEnabled = hasTarget
                default: button.isEnabled = hasTarget
                }
            }
        }
        return item
    }

    private func allFlagged(_ ids: [Int64]) -> Bool {
        guard !ids.isEmpty, let rows = try? model.store.rows(ids: ids) else { return false }
        return rows.allSatisfy(\.isFlagged)
    }

    @objc func newMessage(_ sender: Any?) { model.compose(.new, messageId: targetIDs.first, window: window) }
    @objc func reply(_ sender: Any?) { compose(.reply) }
    @objc func replyAll(_ sender: Any?) { compose(.replyAll) }
    @objc func forward(_ sender: Any?) { compose(.forward) }

    private func compose(_ kind: ComposeKind) {
        let ids = targetIDs
        guard ids.count == 1 else { return NSSound.beep() }
        model.compose(kind, messageId: ids[0], window: window)
    }

    @objc private func archiveMessages(_ sender: Any?) { moveAway(.archive) }
    @objc private func junkMessages(_ sender: Any?) { moveAway(.junk) }
    @objc private func deleteMessages(_ sender: Any?) { moveAway(.delete) }
    @objc private func markRead(_ sender: Any?) { perform(.markRead, on: targetIDs) }
    @objc private func markUnread(_ sender: Any?) { perform(.markUnread, on: targetIDs) }
    @objc private func toggleFlag(_ sender: Any?) {
        let ids = targetIDs
        perform(allFlagged(ids) ? .unflag : .flag, on: ids)
    }

    /// Archive, Junk and Delete take messages out of the list; select the next one, as MailMate does.
    private func moveAway(_ action: AppModel.MessageAction) {
        let ids = targetIDs
        if ids == list.selectedIDs {
            let selected = Set(ids)
            let rows = list.ids.indices.filter { selected.contains(list.ids[$0]) }
            if let last = rows.last, let first = rows.first {
                selectAfterMove = list.ids[(last + 1)...].first { !selected.contains($0) }
                    ?? list.ids[..<first].last
            }
        }
        perform(action, on: ids)
    }

    private func perform(_ action: AppModel.MessageAction, on ids: [Int64]) {
        guard !ids.isEmpty else { return }
        model.perform(action, on: ids) { [weak self] count in
            await self?.confirmPermanentDelete(count) ?? false
        }
    }

    private func confirmPermanentDelete(_ count: Int) async -> Bool {
        guard let window else { return false }
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Delete this message permanently?" : "Delete \(count) messages permanently?"
        alert.informativeText = "It’s already in Deleted Messages. This can’t be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        return await withCheckedContinuation { done in
            alert.beginSheetModal(for: window) { done.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }
}

/// The divider between the Correspondence list and the message, as MailMate draws it (measured at 1x):
/// 4 pt wide, a black line beside the list, then light grey.
final class CorrespondenceSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 4 }

    override func drawDivider(in rect: NSRect) {
        NSColor.black.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
        NSColor(srgbRed: 154 / 255, green: 154 / 255, blue: 158 / 255, alpha: 1).setFill()  // Shows as (168, 168, 172).
        NSRect(x: rect.minX + 1, y: rect.minY, width: rect.width - 1, height: rect.height).fill()
    }
}

/// A toolbar item made of its own buttons, which the toolbar's regular validation passes keep current.
final class ValidatingToolbarItem: NSToolbarItem {
    var onValidate: () -> Void = {}
    override func validate() { onValidate() }
}
