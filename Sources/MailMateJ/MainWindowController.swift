import AppKit
import MailStore
import MailSync
import SwiftUI

/// The Correspondence layout: sidebar | (message list over (correspondence | message)).
@MainActor
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation, NSWindowDelegate {
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

    private enum ReloadReason { case scopeChanged, searchChanged, sortChanged, dataChanged, threadsChanged }
    /// The main list groups conversations (View → Show Threads), remembered across launches.
    private var showsThreads = UserDefaults.standard.object(forKey: "ShowThreads") as? Bool ?? true
    /// Threads opened in the lists, for this run of the app (threads start collapsed, as in MailMate).
    private var expandedThreads: Set<String> = []
    /// Messages inside open threads whose replies show, for this run of the app (all levels start folded).
    private var openedMessages: Set<Int64> = []
    /// The selection to restore after threads were collapsed, expanded or switched on or off.
    private var selectAfterThreads: [Int64]?
    /// The row whose replies were just opened or closed, so the change can animate.
    private var toggledRow: Int64?
    private var toggledCorrespondenceRow: Int64?
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
        // As in MailMate, the toolbar spans the whole window (back/forward at its left) over the sidebar.
        sidebarItem.allowsFullHeightLayout = false
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
        list.onToggleThread = { [weak self] row, collapse in self?.toggle(row, collapse: collapse) }
        // Showing a message marks it read, as in MailMate.
        messageView.onDisplay = { [weak self] id in
            guard let self else { return }
            recordInHistory(id)
            guard let row = try? model.store.rows(ids: [id]).first, !row.isSeen else { return }
            // The row turns read at once; the store and the server follow.
            list.showSeen(true, id: id)
            correspondence.showSeen(true, id: id)
            model.perform(.markRead, on: [id]) { _ in false }
        }
        correspondence.onToggleThread = { [weak self] row, collapse in
            self?.toggle(row, collapse: collapse, inCorrespondence: true)
        }
        sidebar.onEditAccount = { [weak self] id in self?.editAccount(id: id) }
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
        let (threaded, expanded, opened) = (showsThreads, expandedThreads, openedMessages)
        Task {
            let (rows, newest) = await Task.detached(priority: .userInitiated) {
                let rows = threaded
                    ? (try? store.threadedMessages(scope: scope, sort: sort, search: search, expanded: expanded, opened: opened)) ?? []
                    : ((try? store.messageIDs(scope: scope, sort: sort, search: search)) ?? []).map {
                        MailStore.ThreadedRow(id: $0, thread: "", depth: 0, size: 1, anyUnread: false)
                    }
                var newest = try? store.newestMessageID(scope: scope, search: search)
                // New mail inside a collapsed thread is followed to the thread's row.
                if threaded, let id = newest, !rows.contains(where: { $0.id == id }),
                    let thread = (try? store.threadInfo(ids: [id]))?.first?.thread
                {
                    newest = rows.first { $0.thread == thread }?.id ?? id
                }
                return (rows, newest)
            }.value
            guard generation == loadGeneration else { return }
            let ids = rows.map(\.id)
            list.showsThreads = threaded
            list.expandedThreads = expanded
            list.openedMessages = opened
            list.threadRows = threaded ? Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) : [:]
            let before = list.selectedIDs
            var restoredDisplay: Int64?
            // Where the newest mail is: the list's end when sorted by date (with threads, the newest
            // message may sit inside a thread elsewhere), otherwise the newest message's row.
            let newestEnd = sort.key == .receivedAt ? (sort.ascending ? ids.last : ids.first) : newest

            switch reason {
            case .scopeChanged where pendingHistorySelection.map(ids.contains) == true:
                list.setIDs(ids, selecting: [pendingHistorySelection!], scroll: .toSelection)
                pendingHistorySelection = nil
            case .scopeChanged:
                if let saved = remembered[scope], saved.selection.contains(where: ids.contains) {
                    list.setIDs(ids, selecting: saved.selection, scroll: .restore(saved.anchor))
                    if let main = list.selectedID, !saved.correspondenceSelection.isEmpty {
                        pendingCorrespondence = (main, saved)
                        restoredDisplay = saved.displayed
                    }
                } else {
                    list.setIDs(ids, selecting: [], scroll: .toMessage(newestEnd))
                }
            case .threadsChanged:
                let wanted = (selectAfterThreads ?? before).filter(ids.contains)
                selectAfterThreads = nil
                let toggled = toggledRow
                toggledRow = nil
                if toggled.map({ list.animateBranch(of: $0, to: ids, selecting: wanted) }) != true {
                    list.setIDs(ids, selecting: wanted, scroll: .keepPosition)
                }
            case .searchChanged, .sortChanged:
                // Keep the selection if it is still in the list; otherwise show the newest message.
                let kept = before.filter(ids.contains)
                list.setIDs(ids, selecting: kept, scroll: kept.isEmpty ? .toMessage(newestEnd) : .toSelection)
            case .dataChanged where selectAfterMove != nil:
                // Right after Archive/Junk/Delete: if the messages left the list, select the next one.
                let next = selectAfterMove!
                selectAfterMove = nil
                let left = !before.isEmpty && !before.contains(where: ids.contains)
                list.setIDs(ids, selecting: left && ids.contains(next) ? [next] : nil, scroll: .keepPosition)
            case .dataChanged:
                // A list that just got its first messages (initial sync) opens at the newest one.
                // When sorted by date and the end new mail arrives at (the top, or the bottom when oldest
                // first) is in view, it stays in view as mail arrives; if the user scrolled away, their
                // position is kept. (The end, not the newest message: with threads that can be a reply
                // listed under its thread's first message, far from where the user is reading.)
                let wasEmpty = list.ids.isEmpty
                let edge = sort.ascending ? list.ids.last : list.ids.first
                let following = sort.key == .receivedAt && list.isFullyVisible(edge)
                let newEdge = sort.ascending ? ids.last : ids.first
                #if DEBUG
                    if ProcessInfo.processInfo.environment["MMJ_DEBUG_FOLLOW"] != nil {
                        NSLog("MMJ follow: following=\(following) edge \(edge ?? -1) -> \(newEdge ?? -1) rows \(list.ids.count) -> \(ids.count)")
                    }
                #endif
                list.setIDs(
                    ids,
                    scroll: wasEmpty ? .toMessage(newestEnd) : following && newEdge != edge ? .toMessage(newEdge) : .keepPosition)
            }
            lastNewestID = newest

            if list.selectedIDs != before || reason == .scopeChanged {
                messageView.show(messageID: restoredDisplay ?? list.selectedID, selectionCount: list.selectedIDs.count)
                scheduleCorrespondenceUpdate(for: list.selectedID)
            }
            if reason == .scopeChanged {
                // A Back/Forward that switched mailboxes is done (its message selected, or gone).
                pendingHistorySelection = nil
                navigatingHistory = false
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
        let flat = (try? model.store.correspondenceIDs(email: email, via: mine, sort: correspondence.sort)) ?? []
        let ids = threadCorrespondence(flat)
        // A message inside a collapsed thread is selected through its thread's first row.
        let selectable: (Int64) -> Int64 = { [correspondence] id in
            if correspondence.threadRows.isEmpty || flat.isEmpty { return id }
            guard !ids.contains(id), let thread = self.correspondenceThreadOf[id] else { return id }
            return ids.first { correspondence.threadRows[$0]?.thread == thread } ?? id
        }
        if let pending = pendingCorrespondence, pending.mainID == id {
            pendingCorrespondence = nil
            let kept = pending.saved.correspondenceSelection.filter(ids.contains)
            if !kept.isEmpty {
                correspondence.setIDs(ids, selecting: kept, scroll: .restore(pending.saved.correspondenceAnchor))
                return
            }
        }
        if keepSelection {
            let kept = (selectAfterCorrespondenceThreads ?? correspondence.selectedIDs).map(selectable).filter(ids.contains)
            selectAfterCorrespondenceThreads = nil
            let selecting = kept.isEmpty ? [selectable(id)] : kept
            let toggled = toggledCorrespondenceRow
            toggledCorrespondenceRow = nil
            if toggled.map({ correspondence.animateBranch(of: $0, to: ids, selecting: selecting) }) != true {
                correspondence.setIDs(ids, selecting: selecting, scroll: .keepPosition)
            }
        } else {
            correspondence.setIDs(ids, selecting: [selectable(id)], scroll: .toSelection)
        }
    }

    /// Thread of each message in the Correspondence pane (collapsed ones included).
    private var correspondenceThreadOf: [Int64: String] = [:]
    private var selectAfterCorrespondenceThreads: [Int64]?

    /// The Correspondence pane's rows, grouped into threads when threads are shown (as in the main list).
    private func threadCorrespondence(_ flat: [Int64]) -> [Int64] {
        correspondence.showsThreads = showsThreads
        correspondence.expandedThreads = expandedThreads
        correspondence.openedMessages = openedMessages
        guard showsThreads, let info = try? model.store.threadInfo(ids: flat) else {
            correspondence.threadRows = [:]
            correspondenceThreadOf = [:]
            return flat
        }
        correspondenceThreadOf = Dictionary(info.map { ($0.id, $0.thread) }, uniquingKeysWith: { a, _ in a })
        let rows = MailStore.thread(info, expanded: expandedThreads, opened: openedMessages)
        correspondence.threadRows = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return rows.map(\.id)
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
        var debugInboxBadge: Int { sidebar.debugInboxBadge }

        var debugCorrespondenceThreads: String {
            let multi = correspondence.ids.compactMap { correspondence.threadRows[$0] }.filter { $0.size > 1 }
            return "rows=\(correspondence.ids.count) threads(size>1)=\(multi.map(\.size)) expanded=\(expandedThreads.count)"
        }

        /// Collapses (or expands) the first thread of the main list, as its chevron would.
        func debugCollapseFirstThread(expand: Bool = false) {
            guard let root = list.ids.compactMap({ list.threadRows[$0] }).first(where: { $0.size > 1 }) else { return }
            setThread(root.thread, collapsed: !expand)
        }

        /// Selects row `index` of the main list and presses ← `times` times, logging each step.
        func debugLeftArrows(fromRow index: Int, times: Int) async {
            list.tableView.selectRowIndexes([index], byExtendingSelection: false)
            window?.makeFirstResponder(list.tableView)
            for step in 1...times {
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window?.windowNumber ?? 0,
                    context: nil, characters: String(UnicodeScalar(NSLeftArrowFunctionKey)!), charactersIgnoringModifiers:
                        String(UnicodeScalar(NSLeftArrowFunctionKey)!), isARepeat: false, keyCode: 123)
                else { return }
                list.tableView.keyDown(with: event)
                try? await Task.sleep(for: .milliseconds(600))
                let sel = list.selectedID
                NSLog("MMJ ← \(step): selected row \(list.tableView.selectedRow) depth \(sel.flatMap { list.threadRows[$0]?.depth } ?? -1), rows \(list.ids.count)")
            }
        }

        /// Opens the first folded branch below a thread's first row, as its chevron would (animated).
        func debugOpenFirstBranch() {
            guard let row = list.ids.compactMap({ list.threadRows[$0] }).first(where: { $0.depth > 0 && $0.hasReplies }) else {
                return NSLog("MMJ branch: none")
            }
            let before = list.ids.count
            toggle(row, collapse: false)
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                NSLog("MMJ branch opened: rows \(before) -> \(list.ids.count), depths \(list.ids.prefix(4).compactMap { list.threadRows[$0]?.depth })")
            }
        }
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

    // MARK: Threads

    /// Collapses or expands a thread of the main list. A reply hidden by collapsing hands the selection
    /// to its thread's first message.
    /// Folds or opens a row's replies: the whole thread on its first row, else the branch under it.
    private func toggle(_ row: MailStore.ThreadedRow, collapse: Bool, inCorrespondence: Bool = false) {
        if inCorrespondence { toggledCorrespondenceRow = row.id } else { toggledRow = row.id }
        if row.depth == 0 { return setThread(row.thread, collapsed: collapse, inCorrespondence: inCorrespondence) }
        if collapse { openedMessages.remove(row.id) } else { openedMessages.insert(row.id) }
        let source = inCorrespondence ? correspondence : list
        // A selected message inside the folded branch hands the selection to the folded message.
        if collapse, source.selectedIDs.contains(where: { isInside($0, branchOf: row.id, rows: source) }) {
            let kept = source.selectedIDs.filter { !isInside($0, branchOf: row.id, rows: source) } + [row.id]
            if inCorrespondence { selectAfterCorrespondenceThreads = kept } else { selectAfterThreads = kept }
        }
        if inCorrespondence {
            if selectAfterCorrespondenceThreads == nil { selectAfterCorrespondenceThreads = correspondence.selectedIDs }
            reloadCorrespondence(for: list.selectedID ?? correspondence.selectedID, keepSelection: true)
        } else {
            reloadList(.threadsChanged)
            if correspondent != nil { reloadCorrespondence(for: list.selectedID ?? correspondence.selectedID, keepSelection: true) }
        }
    }

    /// Whether `id` is listed after `parent` and deeper, before the list returns to its level.
    private func isInside(_ id: Int64, branchOf parent: Int64, rows: MessageListViewController) -> Bool {
        guard let start = rows.ids.firstIndex(of: parent), let depth = rows.threadRows[parent]?.depth else { return false }
        for other in rows.ids[(start + 1)...] {
            guard let d = rows.threadRows[other]?.depth, d > depth else { return false }
            if other == id { return true }
        }
        return false
    }

    /// Collapses or expands a thread in both lists (they share which threads are collapsed).
    private func setThread(_ thread: String, collapsed: Bool, inCorrespondence: Bool = false) {
        if collapsed {
            expandedThreads.remove(thread)
            let root = list.threadRows.values.first { $0.thread == thread && $0.depth == 0 }?.id
            let selected = list.selectedIDs
            if let root, selected.contains(where: { list.threadRows[$0]?.thread == thread && list.threadRows[$0]?.depth == 1 }) {
                selectAfterThreads = Array(Set(selected.filter { list.threadRows[$0]?.thread != thread } + [root]))
            }
        } else {
            expandedThreads.insert(thread)
        }
        if inCorrespondence {
            // Only the pane: the main list follows on its next reload, keeping the user's place there.
            selectAfterCorrespondenceThreads = correspondence.selectedIDs
            reloadCorrespondence(for: list.selectedID ?? correspondence.selectedID, keepSelection: true)
        } else {
            reloadList(.threadsChanged)
            if correspondent != nil { reloadCorrespondence(for: list.selectedID ?? correspondence.selectedID, keepSelection: true) }
        }
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleThreads(_:)) { item.state = showsThreads ? .on : .off }
        return true
    }

    @objc func toggleThreads(_ sender: Any?) {
        showsThreads.toggle()
        UserDefaults.standard.set(showsThreads, forKey: "ShowThreads")
        reloadList(.threadsChanged)
        if correspondent != nil { reloadCorrespondence(for: list.selectedID ?? correspondence.selectedID, keepSelection: true) }
    }

    /// Opens an account's settings for editing (one settings window at a time).
    func editAccount(id: String) {
        guard let account = try? model.store.account(id: id) else { return }
        if let open = accountSettings, open.editing?.id != id {
            open.close()
        }
        if accountSettings == nil {
            accountSettings = AccountSettingsWindowController(model: model, editing: account) { [weak self] in
                self?.accountSettings = nil
            }
        }
        accountSettings?.show(over: window)
    }

    @objc func addAccount(_ sender: Any?) {
        if let open = accountSettings, open.editing != nil { open.close() }
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

    private static let navigationItem = NSToolbarItem.Identifier("navigation")
    private static let listStyleItem = NSToolbarItem.Identifier("listStyle")
    private static let searchItem = NSToolbarItem.Identifier("search")

    private typealias ActionButton = (label: String, symbol: String, action: Selector)
    /// The message buttons' symbols at MailMate's sizes (measured at 1x): 17 pt (archive 17 px wide,
    /// Reply All 22), but 16 pt for New Message and Mark as Read, which SF draws larger.
    private static let iconSize: CGFloat = 17
    private static func iconSize(for symbol: String) -> CGFloat {
        ["square.and.pencil", "envelope.open"].contains(symbol) ? 16 : iconSize
    }

    /// MailMate's message buttons, in its order and groups, between back/forward and the list buttons.
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
        (.init("flag"), [("Flag", "flag.fill", #selector(toggleFlag(_:)))]),
    ]

    /// MailMate's toolbar (measured at 1x): back and forward at the left; the message buttons and Flag's
    /// menu midway; the threaded and flat list buttons and the search field at the right.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.navigationItem, .flexibleSpace] + Self.actionGroups.map(\.id)
            + [.flexibleSpace, Self.listStyleItem, Self.searchItem]
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
        case Self.navigationItem:
            return navigationToolbarItem(id)
        case Self.listStyleItem:
            return listStyleToolbarItem(id)
        case Self.searchItem:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "Search All Messages"
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.sendsWholeSearchString = false
            item.preferredWidthForSearchField = 320
            searchField = item.searchField
            return item
        default:
            return nil
        }
    }

    private static func toolbarButton(
        symbol: String, pointSize: CGFloat, weight: NSFont.Weight = .regular, label: String, width: CGFloat
    ) -> NSButton {
        let button = ToolbarIconButton()
        button.bezelStyle = .toolbar
        button.showsBorderOnlyWhileMouseInside = true
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        return button
    }

    /// Back and forward through the messages viewed (30 pt apart, as in MailMate).
    private func navigationToolbarItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        // MailMate's 7 × 14 px chevrons, with a divider between them.
        let back = Self.toolbarButton(symbol: "chevron.left", pointSize: 17, weight: .light, label: "Back", width: 24)
        let forward = Self.toolbarButton(symbol: "chevron.right", pointSize: 17, weight: .light, label: "Forward", width: 24)
        back.target = self
        back.action = #selector(goBack(_:))
        forward.target = self
        forward.action = #selector(goForward(_:))
        let stack = SeparatedStackView(views: [back, forward])
        stack.spacing = 4
        let item = ValidatingToolbarItem(itemIdentifier: id)
        item.view = stack
        item.label = "Back/Forward"
        item.onValidate = { [weak self] in
            guard let self else { return }
            back.isEnabled = historyIndex > 0
            forward.isEnabled = historyIndex < history.count - 1
        }
        return item
    }

    /// The threaded and flat list buttons (48 pt apart, as in MailMate); the one in use is shown pressed.
    private func listStyleToolbarItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let threaded = Self.toolbarButton(symbol: "list.bullet.indent", pointSize: 16, label: "Show Threads", width: 32)
        let flat = Self.toolbarButton(symbol: "list.bullet", pointSize: 16, label: "Show Messages Without Threads", width: 32)
        for (button, action) in [(threaded, #selector(showThreadedList(_:))), (flat, #selector(showFlatList(_:)))] {
            button.setButtonType(.pushOnPushOff)
            button.target = self
            button.action = action
        }
        let stack = NSStackView(views: [threaded, flat])
        stack.spacing = 16
        let item = ValidatingToolbarItem(itemIdentifier: id)
        item.view = stack
        item.label = "List Style"
        item.onValidate = { [weak self] in
            guard let self else { return }
            threaded.state = showsThreads ? .on : .off
            flat.state = showsThreads ? .off : .on
        }
        return item
    }

    @objc private func showThreadedList(_ sender: Any?) { if !showsThreads { toggleThreads(sender) } }
    @objc private func showFlatList(_ sender: Any?) { if showsThreads { toggleThreads(sender) } }

    @objc private func showFlagMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let ids = targetIDs
        for (title, action) in [("Flag", AppModel.MessageAction.flag), ("Unflag", .unflag)] {
            let item = menu.addItem(withTitle: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuAction { [weak self] in self?.perform(action, on: ids) }
            item.isEnabled = !ids.isEmpty
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func menuAction(_ sender: NSMenuItem) { (sender.representedObject as? MenuAction)?.run() }

    // MARK: History

    /// Messages viewed, for Back and Forward: the sidebar row they were in and the message.
    private var history: [(key: String, id: Int64)] = []
    private var historyIndex = -1
    private var navigatingHistory = false
    private var pendingHistorySelection: Int64?

    private func recordInHistory(_ id: Int64) {
        guard !navigatingHistory, let key = sidebar.selectedKey else { return }
        if historyIndex >= 0, history[historyIndex].id == id { return }
        history = Array(history.prefix(historyIndex + 1)) + [(key, id)]
        if history.count > 200 { history.removeFirst(history.count - 200) }
        historyIndex = history.count - 1
    }

    @objc func goBack(_ sender: Any?) {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        go(to: history[historyIndex])
    }

    @objc func goForward(_ sender: Any?) {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        go(to: history[historyIndex])
    }

    private func go(to entry: (key: String, id: Int64)) {
        navigatingHistory = true
        if sidebar.selectedKey == entry.key, list.ids.contains(entry.id) {
            list.setIDs(list.ids, selecting: [entry.id], scroll: .toSelection)
            messageView.show(messageID: entry.id)
            scheduleCorrespondenceUpdate(for: entry.id)
            updateTitle()
            navigatingHistory = false
        } else {
            pendingHistorySelection = entry.id  // Selected once that mailbox's list has loaded.
            if !sidebar.select(key: entry.key) {
                pendingHistorySelection = nil
                navigatingHistory = false
            }
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
            let button = ToolbarIconButton()
            button.bezelStyle = .toolbar
            button.showsBorderOnlyWhileMouseInside = true
            button.image = NSImage(systemSymbolName: b.symbol, accessibilityDescription: b.label)?
                .withSymbolConfiguration(.init(pointSize: Self.iconSize(for: b.symbol), weight: .regular))
            button.imagePosition = .imageOnly
            button.toolTip = b.label
            button.target = self
            button.action = b.action
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            return button
        }
        var arranged: [NSView] = views
        var arrow: NSButton?
        if views.contains(where: { $0.action == #selector(toggleFlag(_:)) }) {
            // MailMate's small arrow beside Flag, with Flag and Unflag.
            let button = Self.toolbarButton(symbol: "chevron.down", pointSize: 8, label: "Flag Options", width: 14)
            button.target = self
            button.action = #selector(showFlagMenu(_:))
            arranged.append(button)
            arrow = button
        }
        let stack = SeparatedStackView(views: arranged)
        stack.spacing = 8
        stack.setCustomSpacing(5, after: views.last!)
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
                    button.image = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: button.toolTip)?
                        .withSymbolConfiguration(.init(pointSize: Self.iconSize, weight: .regular))
                    button.isEnabled = hasTarget
                default: button.isEnabled = hasTarget
                }
            }
            arrow?.isEnabled = hasTarget
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

/// A closure carried by a menu item.
final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

/// A toolbar group whose buttons are divided by thin lines, as MailMate's are (measured at 1x: 1 px wide,
/// 14 px tall, centered between the buttons).
/// A toolbar button in MailMate's two shades (measured at 1x on its 72 toolbar): icons at 196 when
/// enabled, 111 when not. AppKit's own dimming of disabled images is off, so the shades are exact.
final class ToolbarIconButton: NSButton {
    static let enabledColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.64) : NSColor(white: 0, alpha: 0.66)
    }
    static let disabledColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.175) : NSColor(white: 0, alpha: 0.2)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        (cell as? NSButtonCell)?.imageDimsWhenDisabled = false
        updateTint()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool {
        didSet { updateTint() }
    }

    private func updateTint() {
        contentTintColor = isEnabled ? Self.enabledColor : Self.disabledColor
    }
}

final class SeparatedStackView: NSStackView {
    /// Slightly lighter than the toolbar in dark mode, as MailMate draws its dividers (86 on 72);
    /// slightly darker in light mode.
    static let lineColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.055) : NSColor(white: 0, alpha: 0.12)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Self.lineColor.setFill()
        let views = arrangedSubviews.filter { !$0.isHidden }
        for (a, b) in zip(views, views.dropFirst()) {
            let x = ((a.frame.maxX + b.frame.minX) / 2).rounded(.down)
            NSRect(x: x, y: (bounds.midY - 7).rounded(), width: 1, height: 14).fill()
        }
    }
}

