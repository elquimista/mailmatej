import AppKit
import MailStore
import SwiftUI

/// The Correspondence layout: sidebar | (message list over (correspondence | message)).
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
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
        let ids = (try? model.store.correspondenceIDs(email: email, sort: correspondence.sort)) ?? []
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
        func debugSelectSidebar(key: String) { sidebar.debugSelect(key: key) }

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

    @objc func addAccount(_ sender: Any?) {
        guard let window else { return }
        let sheet = SheetHolder()
        let view = AddAccountView(
            onAdd: { [weak self] draft in
                try await self?.model.addAccount(draft)
                sheet.end(from: window)
            },
            onCancel: { sheet.end(from: window) })
        sheet.window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.beginSheet(sheet.window!)
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

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.getMailItem, .flexibleSpace, Self.addAccountItem, Self.searchItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
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

@MainActor
private final class SheetHolder {
    var window: NSWindow?

    func end(from parent: NSWindow) {
        if let window { parent.endSheet(window) }
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
