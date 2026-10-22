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
    /// Waits until the moved messages have left the list (at once for a move within an account; after
    /// the copy for one to another account), then selects `next`. Dropped on a new selection or mailbox.
    private var selectAfterMove: (next: Int64, moved: Set<Int64>)?
    private var correspondent: String?
    private var correspondenceTask: Task<Void, Never>?
    private var lastSelectionChange: CFAbsoluteTime = 0
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
    /// The same for the Correspondence pane, which threads its own messages (so the first message of a
    /// conversation can differ from the main list's).
    private var correspondenceExpanded: Set<String> = []
    private var correspondenceOpened: Set<Int64> = []
    /// The selection to restore after threads were collapsed, expanded or switched on or off.
    private var selectAfterThreads: [Int64]?
    /// The row whose replies were just opened or closed, so the change can animate.
    private var toggledRow: Int64?
    private var toggledCorrespondenceRow: Int64?
    private var splits: (root: NSSplitView, content: NSSplitView, bottom: NSSplitView)?
    /// The first key of a two-key shortcut (g, *, d, r) and when it was pressed.
    private var pendingKey: (key: String, at: Date)?
    private var keyMonitor: Any?

    init(model: AppModel) {
        self.model = model
        sidebar = SidebarViewController(model: model)
        sidebar.remembersSelection = true
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
        installKeyBindings()
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
        // MailMate's 1 px black line beside the sidebar (AppKit draws none for a sidebar that isn't full height).
        root.splitView = SidebarSplitView()
        root.splitView.isVertical = true
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
        sidebar.onSelectNone = { [weak self] in
            guard let self else { return }
            hasMailbox = false
            list.tableView.deselectAll(nil)
            messageView.show(messageID: nil)
            reloadList(.scopeChanged)
        }
        sidebar.onSelect = { [weak self] node in
            guard let self, let scope = node.scope else { return }
            hasMailbox = true
            remembered[self.scope] = SavedView(
                selection: list.selectedIDs, anchor: list.scrollAnchor,
                correspondenceSelection: correspondence.selectedIDs, correspondenceAnchor: correspondence.scrollAnchor,
                displayed: messageView.displayedMessageID)
            self.scope = scope
            self.scopeTitle = node.title
            list.colorKey = node.key
            selectAfterMove = nil
            self.reloadList(.scopeChanged)
        }
        list.onSelectionChange = { [weak self] id in
            guard let self else { return }
            selectAfterMove = nil  // The user moved on.
            #if DEBUG
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_TIMING"] != nil { NSLog("MMJ timing: selection reported \(id ?? -1)") }
            #endif
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
            messageList.addContextItems = { [weak self] menu, ids in self?.addMessageItems(to: menu, for: ids) }
        }
        correspondence.onSelectionChange = { [weak self] id in
            guard let self, let id else { return }
            messageView.show(messageID: id)
        }
    }

    // MARK: Loading

    /// Whether a mailbox is selected (not after the selected one was deleted).
    private var hasMailbox = true

    private func reloadList(_ reason: ReloadReason) {
        loadGeneration += 1
        let generation = loadGeneration
        let (store, sort) = (model.store, list.sort)
        // No mailbox: an empty list (a scope that matches nothing).
        let scope = hasMailbox ? self.scope : MessageScope.smart(-1)
        let search: String? = search.isEmpty ? nil : search
        let (threaded, expanded, opened) = (showsThreads, expandedThreads, openedMessages)
        Task {
            let (rows, newest) = await Task.detached(priority: .userInitiated) {
                let list = threaded
                    ? (try? store.threadedMessages(scope: scope, sort: sort, search: search, expanded: expanded, opened: opened))
                    : nil
                let rows = list?.rows ?? ((try? store.messageIDs(scope: scope, sort: sort, search: search)) ?? []).map {
                    MailStore.ThreadedRow(id: $0, thread: "", depth: 0, size: 1, anyUnread: false)
                }
                var newest = try? store.newestMessageID(scope: scope, search: search)
                // New mail inside a collapsed thread is followed to the thread's row.
                if let list, let id = newest, !rows.contains(where: { $0.id == id }), let thread = list.threadOf[id] {
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
            case .dataChanged where selectAfterMove.map { pending in !pending.moved.contains(where: ids.contains) } == true:
                // After Archive/Junk/Delete/Move, once the messages have left the list: the next one.
                let next = selectAfterMove!.next
                selectAfterMove = nil
                list.setIDs(ids, selecting: ids.contains(next) ? [next] : nil, scroll: .keepPosition)
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
            #if DEBUG
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_TIMING"] != nil { NSLog("MMJ timing: list shown (\(reason), \(ids.count) rows)") }
            #endif

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

    /// Updates the Correspondence pane at once for a click or a single key press, as MailMate does.
    /// Only while selections come in quick succession (a held arrow key) does it wait for a pause, to
    /// keep the scrolling smooth.
    private func scheduleCorrespondenceUpdate(for id: Int64?) {
        correspondenceTask?.cancel()
        let now = CFAbsoluteTimeGetCurrent()
        let rapid = now - lastSelectionChange < 0.15
        lastSelectionChange = now
        guard rapid else { return reloadCorrespondence(for: id) }
        correspondenceTask = Task {
            try? await Task.sleep(for: .milliseconds(60))
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
        let flat = (try? model.store.correspondenceIDs(email: email, via: mine, sort: correspondence.sort, keeping: id)) ?? []
        // The main list's message is shown in its thread: opened down to it, unless the pane is just
        // refreshing (new mail, re-sorting) and keeps what the user opened or closed.
        let ids = threadCorrespondence(flat, revealing: keepSelection ? nil : id)
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
    private func threadCorrespondence(_ flat: [Int64], revealing reveal: Int64? = nil) -> [Int64] {
        correspondence.showsThreads = showsThreads
        guard showsThreads, let info = try? model.store.threadInfo(ids: flat) else {
            correspondence.threadRows = [:]
            correspondenceThreadOf = [:]
            return flat
        }
        correspondenceThreadOf = MailStore.threadKeys(info)
        if let reveal, let thread = correspondenceThreadOf[reveal] {
            let above = MailStore.ancestors(of: reveal, in: info)
            if !above.isEmpty {
                correspondenceExpanded.insert(thread)
                correspondenceOpened.formUnion(above.dropFirst())  // The branches between the first message and it.
            }
        }
        correspondence.expandedThreads = correspondenceExpanded
        correspondence.openedMessages = correspondenceOpened
        let rows = MailStore.thread(info, expanded: correspondenceExpanded, opened: correspondenceOpened)
        correspondence.threadRows = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return rows.map(\.id)
    }

    private func storeDidChange() {
        sidebar.reload()
        // The selected mailbox's scope can change in place (a special mailbox's conditions now narrow it).
        if let current = sidebar.selectedNode?.scope, current != scope, current.base == scope.base { scope = current }
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
        guard hasMailbox else {
            window?.title = "No mailbox selected"  // MailMate's
            return
        }
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
        func debugMoveSidebar(_ spec: String) { sidebar.debugMove(spec) }
        func debugNewSmartMailbox(inside key: String) { sidebar.debugNewSmartMailbox(inside: key) }
        func debugSymbolMenu(key: String, path: String) { sidebar.debugSymbolMenu(key: key, path: path) }
        func debugHeader(toggle: Bool) { sidebar.debugHeader(toggle: toggle) }
        func debugRowFrames() { sidebar.debugRowFrames() }
        var debugUnreadThreads: [String] { list.debugUnreadThreads() }

        /// Selects main-list rows one by one and checks the Correspondence pane selects the same message.
        func debugCheckCorrespondenceSelection(rows count: Int) async {
            var checked = 0, nested = 0, wrong: [Int64] = []
            for index in 0..<min(count, list.ids.count) {
                list.tableView.selectRowIndexes([index], byExtendingSelection: false)
                try? await Task.sleep(for: .milliseconds(120))
                guard let id = list.selectedID, correspondent != nil, !correspondence.ids.isEmpty else { continue }
                checked += 1
                if (correspondence.threadRows[id]?.depth ?? 0) > 0 { nested += 1 }
                if correspondence.selectedIDs != [id] { wrong.append(id) }
            }
            NSLog("MMJ correspondence selection: checked \(checked), nested \(nested), wrong \(wrong.prefix(10))")
        }
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

        func debugContextMenu(row: Int, run: String?) -> [String] {
            let id = row < list.ids.count ? list.ids[row] : -1
            return list.debugContextMenu(row: row, run: run) + ["message \(id)"]
        }

        func debugHoverLink(containing text: String) async { await messageView.debugHoverLink(containing: text) }

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

    /// Mailbox › New Smart Mailbox (⌥⌘N): inside the selected smart mailbox, else at the top level.
    @objc func newSmartMailbox(_ sender: Any?) {
        sidebar.newSmartMailbox(inside: sidebar.selectedNode)
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
        if inCorrespondence {
            if collapse { correspondenceOpened.remove(row.id) } else { correspondenceOpened.insert(row.id) }
        } else {
            if collapse { openedMessages.remove(row.id) } else { openedMessages.insert(row.id) }
        }
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

    /// Collapses or expands a thread of the main list or of the Correspondence pane.
    private func setThread(_ thread: String, collapsed: Bool, inCorrespondence: Bool = false) {
        if inCorrespondence {
            if collapsed { correspondenceExpanded.remove(thread) } else { correspondenceExpanded.insert(thread) }
            selectAfterCorrespondenceThreads = correspondence.selectedIDs
            return reloadCorrespondence(for: list.selectedID ?? correspondence.selectedID, keepSelection: true)
        }
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
        reloadList(.threadsChanged)
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleThreads(_:)) { item.state = showsThreads ? .on : .off }
        // While text is being typed, keys such as ⌫ belong to the text, not the menu.
        let editing = window?.firstResponder is NSText
        let ids = targetIDs
        switch item.action {
        case #selector(archiveMessages(_:)), #selector(junkMessages(_:)), #selector(deleteMessages(_:)),
            #selector(moveToMailbox(_:)), #selector(flagMessages(_:)), #selector(unflagMessages(_:)):
            return !editing && !ids.isEmpty
        case #selector(toggleReadState(_:)):
            let rows = (try? model.store.rows(ids: ids)) ?? []
            item.title = !rows.isEmpty && !rows.contains(where: \.isSeen) ? "Mark as Read" : "Mark as Unread"
            return !editing && !rows.isEmpty
        case #selector(reply(_:)), #selector(replyAll(_:)), #selector(forward(_:)):
            return ids.count == 1 && model.canCompose
        case #selector(nextMessage(_:)), #selector(previousMessage(_:)), #selector(nextUnreadMessage(_:)),
            #selector(previousUnreadMessage(_:)), #selector(nextThread(_:)), #selector(previousThread(_:)),
            #selector(nextUnreadThread(_:)), #selector(previousUnreadThread(_:)):
            return !editing && !activeList.ids.isEmpty
        case #selector(rootOfThread(_:)), #selector(lastOfThread(_:)):
            return !editing && showsThreads && activeList.selectedID != nil
        case #selector(quickLookAttachments(_:)), #selector(saveAttachments(_:)), #selector(openAttachments(_:)):
            return messageView.hasAttachments
        case #selector(goToMailbox(_:)):
            return !editing
        default:
            return true
        }
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

    private func clearSearch() {
        searchField?.stringValue = ""
        if window?.firstResponder === searchField?.currentEditor() { window?.makeFirstResponder(list.tableView) }
        search = ""
        reloadList(.searchChanged)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        guard sender.stringValue != search else { return }
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
            // As MailMate: searches on Return (and when cleared), not on every keystroke.
            item.searchField.sendsWholeSearchString = true
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

    @objc func archiveMessages(_ sender: Any?) { moveAway(.archive) }
    @objc func junkMessages(_ sender: Any?) { moveAway(.junk) }
    @objc func notJunkMessages(_ sender: Any?) { moveAway(.notJunk) }
    @objc func deleteMessages(_ sender: Any?) { moveAway(.delete) }
    @objc func markRead(_ sender: Any?) { perform(.markRead, on: targetIDs) }
    @objc func markUnread(_ sender: Any?) { perform(.markUnread, on: targetIDs) }
    @objc func flagMessages(_ sender: Any?) { perform(.flag, on: targetIDs) }
    @objc func unflagMessages(_ sender: Any?) { perform(.unflag, on: targetIDs) }
    /// Message → Mark as Unread (Mark as Read when every selected message is unread).
    @objc func toggleReadState(_ sender: Any?) {
        let rows = (try? model.store.rows(ids: targetIDs)) ?? []
        perform(rows.contains(where: \.isSeen) ? .markUnread : .markRead, on: targetIDs)
    }
    @objc func toggleFlag(_ sender: Any?) {
        let ids = targetIDs
        perform(allFlagged(ids) ? .unflag : .flag, on: ids)
    }

    /// MailMate's message context menu: Move to Archive, Move to Junk (Move Out of Junk when every
    /// message is in Junk) and Move to Mailbox…, acting on the selection.
    private func addMessageItems(to menu: NSMenu, for ids: [Int64]) {
        let inJunk = (try? model.store.messageIDs(ids, inRole: "junk")) ?? []
        let allJunk = !ids.isEmpty && ids.allSatisfy(inJunk.contains)
        for (title, action) in [
            ("Move to Archive", #selector(archiveMessages(_:))),
            allJunk ? ("Move Out of Junk", #selector(notJunkMessages(_:))) : ("Move to Junk", #selector(junkMessages(_:))),
            ("Move to Mailbox…", #selector(moveToMailbox(_:))),
        ] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
    }

    /// Archive, Junk and Delete take messages out of the list; select the next one, as MailMate does.
    private func moveAway(_ action: AppModel.MessageAction) {
        let ids = targetIDs
        selectNextAfterMoving(ids)
        perform(action, on: ids)
    }

    private func selectNextAfterMoving(_ ids: [Int64]) {
        guard ids == list.selectedIDs else { return }
        let selected = Set(ids)
        let rows = list.ids.indices.filter { selected.contains(list.ids[$0]) }
        if let last = rows.last, let first = rows.first,
            let next = list.ids[(last + 1)...].first(where: { !selected.contains($0) }) ?? list.ids[..<first].last
        {
            selectAfterMove = (next, selected)
        }
    }

    /// Moves the messages into a mailbox: as usual within its account, and for messages of other accounts
    /// by copying them there and deleting the originals once the copy is confirmed (not undoable).
    fileprivate func move(_ ids: [Int64], toMailboxId mailboxId: Int64) {
        guard let target = (try? model.store.mailboxes())?.first(where: { $0.id == mailboxId }),
            let refs = try? model.store.refs(ids: ids), !refs.isEmpty
        else { return NSSound.beep() }
        selectNextAfterMoving(ids)
        let same = refs.filter { $0.accountId == target.accountId }
        let other = refs.filter { $0.accountId != target.accountId }
        if !same.isEmpty { perform(.move(toMailboxId: mailboxId), on: same.map(\.id)) }
        if !other.isEmpty { model.moveAcrossAccounts(other, toMailboxId: mailboxId) }
    }

    private func perform(_ action: AppModel.MessageAction, on ids: [Int64]) {
        guard !ids.isEmpty else { return }
        #if DEBUG
            if ProcessInfo.processInfo.environment["MMJ_DEBUG_TIMING"] != nil { NSLog("MMJ timing: action \(action) start") }
        #endif
        registerUndo(for: action, on: ids)
        // Marks and flags show in the rows at once.
        for id in ids {
            for rows in [list, correspondence] {
                switch action {
                case .markRead: rows.showSeen(true, id: id)
                case .markUnread: rows.showSeen(false, id: id)
                case .flag: rows.showFlagged(true, id: id)
                case .unflag: rows.showFlagged(false, id: id)
                default: break
                }
            }
        }
        model.perform(action, on: ids) { [weak self] count in
            await self?.confirmPermanentDelete(count) ?? false
        }
    }

    /// Records how to take an action back (Edit → Undo, or u): moves put the messages back in the
    /// mailboxes they were in, marks and flags go back to each message's previous state. Undoing runs
    /// through `perform` again, which records the redo. Deleting for good can't be undone.
    private func registerUndo(for action: AppModel.MessageAction, on ids: [Int64]) {
        guard let undo = window?.undoManager else { return }
        let rows = (try? model.store.rows(ids: ids)) ?? []
        func keyword(_ name: String, _ on: KeyPath<MessageRow, Bool>, set: AppModel.MessageAction, clear: AppModel.MessageAction) {
            let wasOn = rows.filter { $0[keyPath: on] }.map(\.id), wasOff = rows.filter { !$0[keyPath: on] }.map(\.id)
            undo.registerUndo(withTarget: self) { target in
                if !wasOn.isEmpty { target.perform(set, on: wasOn) }
                if !wasOff.isEmpty { target.perform(clear, on: wasOff) }
            }
            undo.setActionName(name)
        }
        switch action {
        case .markRead: keyword("Mark as Read", \.isSeen, set: .markRead, clear: .markUnread)
        case .markUnread: keyword("Mark as Unread", \.isSeen, set: .markRead, clear: .markUnread)
        case .flag: keyword("Flag", \.isFlagged, set: .flag, clear: .unflag)
        case .unflag: keyword("Unflag", \.isFlagged, set: .flag, clear: .unflag)
        case .keyword, .copy, .deletePermanently: break  // only rules do these
        case .archive, .junk, .notJunk, .delete, .move, .moveToRole, .restoreMailboxes:
            let inTrash: Set<Int64>
            if case .delete = action { inTrash = (try? model.store.messageIDs(ids, inRole: "trash")) ?? [] } else { inTrash = [] }
            let movable = ids.filter { !inTrash.contains($0) }  // Those deleted for good stay deleted.
            guard !movable.isEmpty, let saved = try? model.store.mailboxIDs(messageIds: movable) else { return }
            var junk: Bool?
            if case .junk = action { junk = false }
            if case .notJunk = action { junk = true }
            undo.registerUndo(withTarget: self) { target in
                target.perform(.restoreMailboxes(saved, junk: junk), on: movable)
            }
            switch action {
            case .archive: undo.setActionName("Archive")
            case .junk: undo.setActionName("Mark as Junk")
            case .notJunk: undo.setActionName("Move Out of Junk")
            case .delete: undo.setActionName("Delete")
            default: undo.setActionName("Move")
            }
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

/// The divider between the sidebar and the lists, as MailMate draws it (measured at 1x): 1 px, black.
final class SidebarSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 1 }

    /// A plain line: the default style would add a grip dot in the middle.
    override func drawDivider(in rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
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


// MARK: - Keyboard (Gmail+Vimium)

/// MailMate's "Gmail+Vimium" key bindings, built in: single keys and two-key sequences act on the
/// message list while no text is being edited. ⌘↩ sends from a compose window.
extension MainWindowController {
    fileprivate func installKeyBindings() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handleKey(event) == true }
            return handled ? nil : event
        }
    }

    /// Whether the key was a shortcut (and was handled).
    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        // ⌘↩ (or ⌘ Enter) sends the message being written.
        if let compose = event.window?.windowController as? ComposeWindowController {
            guard modifiers == .command, event.keyCode == 36 || event.keyCode == 76 else { return false }
            compose.sendMessage(nil)
            return true
        }
        // Escape clears the search from anywhere in the window, as in MailMate (other text fields keep it
        // for cancelling their own editing).
        if let window, event.window === window, window.attachedSheet == nil, modifiers.isEmpty, event.keyCode == 53,
            !search.isEmpty
        {
            let editor = window.firstResponder as? NSText
            if editor == nil || editor?.delegate === searchField {
                clearSearch()
                return true
            }
        }
        guard let window, event.window === window, window.attachedSheet == nil,
            !(window.firstResponder is NSText), modifiers.isSubset(of: [.control])
        else { return false }

        if modifiers == .control {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r": window.undoManager?.redo()
            case "s": NSSound.beep()  // Save draft: drafts aren't saved yet.
            default: return false
            }
            return true
        }
        // Backspace (⌫, labelled delete on Mac keyboards; key code 51) and forward delete (⌦, 117) delete,
        // like dd. Handled here, before the views, so it works wherever the focus is.
        if modifiers.isEmpty, event.keyCode == 51 || event.keyCode == 117 {
            pendingKey = nil
            deleteMessages(nil)
            return true
        }
        guard let key = event.characters, key.count == 1 else { return false }

        if let pending = pendingKey {
            pendingKey = nil
            if Date().timeIntervalSince(pending.at) < 2 {
                if !sequence(pending.key, key) { NSSound.beep() }
                return true
            }
        }
        switch key {
        case "g", "*", "d", "r": pendingKey = (key, Date())
        case "c": newMessage(nil)
        case "/": focusSearch(nil)
        case "n": moveSelection(down: true, extending: false)
        case "p": moveSelection(down: false, extending: false)
        case "N", "J": moveSelection(down: true, extending: true)
        case "P", "K": moveSelection(down: false, extending: true)
        case "j": moveToThread(down: true)
        case "k": moveToThread(down: false)
        case "o": toggleSelectedThread()
        case "a", "m": moveAway(.archive)  // m mutes and archives in MailMate; there's no muting here yet.
        case "s": toggleFlag(nil)
        case "!": moveAway(.junk)
        case "f": forward(nil)
        case "v": pickMailbox(move: true)
        case "u": window.undoManager?.undo()
        case "l": messageView.loadRemoteContentOnce()
        case "I": perform(.markRead, on: targetIDs)
        case "U": perform(.markUnread, on: targetIDs)
        case "G": selectRow(activeList.ids.count - 1)
        default: return false
        }
        return true
    }

    /// The second key of a sequence; false if the pair means nothing.
    private func sequence(_ first: String, _ second: String) -> Bool {
        switch (first, second) {
        case ("g", "a"): return goTo("unified.all")
        case ("g", "s"): return model.flaggedSmartMailboxID.map { goTo("smart.\($0)") } ?? false  // Flagged, if kept
        case ("g", "d"): return goTo("unified.drafts")
        case ("g", "i"): return goTo("unified.inbox")
        case ("g", "t"): return goTo("unified.sent")
        case ("g", "l"): pickMailbox(move: false)
        case ("g", "g"): selectRow(0)
        case ("*", "a"): activeList.tableView.selectAll(nil)
        case ("*", "n"): activeList.tableView.deselectAll(nil)
        case ("*", "r"): selectRows { $0.isSeen }
        case ("*", "u"): selectRows { !$0.isSeen }
        case ("*", "s"): selectRows { $0.isFlagged }
        case ("*", "t"): selectRows { !$0.isFlagged }
        case ("d", "d"): moveAway(.delete)
        case ("r", "r"): reply(nil)
        case ("r", "a"): replyAll(nil)
        default: return false
        }
        return true
    }

    /// The list the keys act on: Correspondence while it has focus, else the main list.
    fileprivate var activeList: MessageListViewController {
        window?.firstResponder === correspondence.tableView ? correspondence : list
    }

    /// n/p (and with ⇧ extending the selection), as ↓ and ↑ do in the list.
    fileprivate func moveSelection(down: Bool, extending: Bool) {
        let table = activeList.tableView
        let code = down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey
        guard let arrow = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: extending ? [.shift, .numericPad, .function] : [.numericPad, .function],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: String(UnicodeScalar(code)!), charactersIgnoringModifiers: String(UnicodeScalar(code)!),
            isARepeat: false, keyCode: down ? 125 : 126)
        else { return }
        table.keyDown(with: arrow)
    }

    /// j/k: the next or previous thread (a message that isn't a reply shown under another).
    fileprivate func moveToThread(down: Bool) {
        let rows = activeList
        let selected = rows.tableView.selectedRowIndexes
        let start = down ? (selected.last ?? -1) : (selected.first ?? rows.ids.count)
        let candidates = down ? Array(stride(from: start + 1, to: rows.ids.count, by: 1)) : Array(stride(from: start - 1, through: 0, by: -1))
        guard let row = candidates.first(where: { (rows.threadRows[rows.ids[$0]]?.depth ?? 0) == 0 }) else { return NSSound.beep() }
        selectRow(row)
    }

    fileprivate func selectRow(_ row: Int) {
        let table = activeList.tableView
        guard row >= 0, row < activeList.ids.count else { return NSSound.beep() }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// o: opens or closes the selected message's thread (or the replies under it).
    private func toggleSelectedThread() {
        let rows = activeList
        guard let id = rows.selectedID, let row = rows.threadRows[id], row.size > 1 || row.hasReplies else { return NSSound.beep() }
        let inCorrespondence = rows === correspondence
        let open = row.depth == 0
            ? (inCorrespondence ? correspondenceExpanded : expandedThreads).contains(row.thread)
            : (inCorrespondence ? correspondenceOpened : openedMessages).contains(id)
        toggle(row, collapse: open, inCorrespondence: rows === correspondence)
    }

    /// *r, *u, *s, *t: selects the list's messages that are read, unread, flagged or not flagged.
    private func selectRows(where matches: (MessageRow) -> Bool) {
        let rows = activeList
        let wanted = Set(((try? model.store.rows(ids: rows.ids)) ?? []).filter(matches).map(\.id))
        rows.tableView.selectRowIndexes(IndexSet(rows.ids.indices.filter { wanted.contains(rows.ids[$0]) }), byExtendingSelection: false)
    }

    private func goTo(_ key: String) -> Bool {
        sidebar.select(key: key)
    }

    /// v: moves the selected messages to a mailbox (a Unified one moves each into its account's); g then l:
    /// shows a mailbox. Lists as MailMate's picker does: Unified mailboxes, then each account's mailboxes
    /// alphabetically (recently chosen ones first, see `MailboxPicker`).
    fileprivate func pickMailbox(move: Bool) {
        guard let window else { return }
        let roots = SidebarViewController.buildTree(model: model)
        let boxes = (try? model.store.mailboxes()) ?? []
        let boxByID = Dictionary(boxes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = targetIDs
        let accounts = Set(((try? model.store.refs(ids: ids)) ?? []).map(\.accountId))
        if move && accounts.isEmpty { return NSSound.beep() }

        var choices: [MailboxPicker.Choice] = []
        for node in roots.first(where: { $0.key == "header.mailboxes" })?.children ?? [] {
            guard let scope = node.scope else { continue }
            if move {
                // Moving into a Unified mailbox means its role's mailbox in each message's account.
                guard case .role(let role) = scope, scope != self.scope else { continue }
                let count = boxes.filter { $0.role == role }.reduce(0) { $0 + $1.totalEmails }
                choices.append(.init(node: node, title: node.title, subtitle: "Unified", isUnified: true, path: "Unified ▸ \(node.title)", count: count))
            } else {
                // Only the role mailboxes say "Unified" (Flagged, All Messages and the like don't), as in MailMate.
                var isRole = false
                if case .role = scope { isRole = true }
                choices.append(.init(
                    node: node, title: node.title, subtitle: isRole ? "Unified" : "", isUnified: isRole,
                    path: isRole ? "Unified ▸ \(node.title)" : node.title,
                    count: try? model.store.count(scope: scope, counting: .all)))
            }
        }
        for account in roots.first(where: { $0.key == "header.sources" })?.children ?? [] {
            if !move {
                choices.append(.init(
                    node: account, title: account.title, subtitle: "", isUnified: false, path: account.title,
                    count: account.scope.flatMap { try? model.store.count(scope: $0, counting: .all) }))
            }
            var mailboxes: [(path: [String], node: SidebarNode)] = []
            func walk(_ nodes: [SidebarNode], _ path: [String]) {
                for node in nodes where node.kind == .mailbox {
                    mailboxes.append((path + [node.title], node))
                    walk(node.children, path + [node.title])
                }
            }
            walk(account.children, [])
            for (path, node) in mailboxes.sorted(by: { $0.path.joined(separator: "/").localizedCaseInsensitiveCompare($1.path.joined(separator: "/")) == .orderedAscending }) {
                if move, node.scope == self.scope { continue }
                var count: Int?
                if case .mailbox(let id)? = node.scope { count = boxByID[id]?.totalEmails }
                choices.append(.init(
                    node: node, title: node.title, subtitle: account.title, isUnified: false,
                    path: ([account.title] + path).joined(separator: " ▸ "), count: count))
            }
        }

        if move {
            MailboxPicker.show(
                over: window, title: "Move to Mailbox", choices: choices, recentsKey: "RecentMoveMailboxes",
                onChoose: { [weak self] choice in
                    guard let self, let scope = choice.node.scope else { return }
                    switch scope {
                    case .mailbox(let id): self.move(targetIDs, toMailboxId: id)
                    case .role("archive"): moveAway(.archive)
                    case .role("junk"): moveAway(.junk)
                    case .role("trash"): moveAway(.delete)
                    case .role(let role): moveAway(.moveToRole(role))
                    default: NSSound.beep()
                    }
                },
                onCreate: { [weak self] name, parent in
                    guard let self, case .mailbox(let parentId)? = parent.node.scope else { return }
                    let ids = targetIDs
                    model.moveToNewMailbox(named: name, inside: parentId, messages: ids) { [weak self] action in
                        guard case .move(let created) = action else { return }
                        self?.move(ids, toMailboxId: created)
                    }
                })
        } else {
            MailboxPicker.show(
                over: window, title: "Go to Mailbox", choices: choices, recentsKey: "RecentGoToMailboxes",
                onChoose: { [weak self] choice in _ = self?.sidebar.select(key: choice.node.key) },
                onCreate: { [weak self] name, parent in
                    // A new submailbox inside the selected one, then shown.
                    guard let self, case .mailbox(let parentId)? = parent.node.scope else { return }
                    Task {
                        do {
                            let created = try await self.model.createSubmailbox(named: name, inside: parentId)
                            _ = self.sidebar.select(key: "mailbox.\(created.accountId).\(created.remoteId)")
                        } catch {
                            NSSound.beep()
                        }
                    }
                })
        }
    }

    #if DEBUG
        /// The Message menu's items and whether each is enabled now.
        func debugMessageMenu() -> String {
            guard let menu = NSApp.mainMenu?.item(withTitle: "Message")?.submenu else { return "no menu" }
            // Validated by this controller directly (the app may not be frontmost in a test run).
            return menu.items.filter { !$0.isSeparatorItem && $0.action != nil }.map { item in
                let on = responds(to: item.action) ? validateMenuItem(item) : false
                return "\(item.title)\(on ? "" : " (off)")"
            }.joined(separator: ", ")
        }

        /// Presses keys as typed (each char a key; "^r" for ⌃R), 400 ms apart, logging the selection.
        func debugType(_ keys: String) async {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(list.tableView)
            var chars = Array(keys)
            while !chars.isEmpty {
                var key = String(chars.removeFirst())
                var flags: NSEvent.ModifierFlags = []
                if key == "^", let next = chars.first { key = String(next); chars.removeFirst(); flags = .control }
                if key == "⏎" { key = "\r"; flags = .command }
                if key == "↩" { key = "\r" }  // plain Return
                if key == "⎋" { key = "\u{1B}" }  // Escape
                if key == "«" {  // hand the keyboard to the sidebar
                    sidebar.debugFocus()
                    continue
                }
                if key == "⌦" { key = "\u{7F}" }  // Backspace as the key handler sees it (key code 51).
                if key == "⌧" { key = String(UnicodeScalar(NSDeleteFunctionKey)!) }  // Forward delete (key code 117).
                if let selector = ["N": "nextUnreadMessage:", "T": "nextUnreadThread:", "R": "rootOfThread:", "L": "lastOfThread:",
                    "Y": "quickLookAttachments:"][key], keys.hasPrefix("@") {
                    perform(Selector(selector), with: nil)  // A Message menu command, as its menu item would.
                    try? await Task.sleep(for: .milliseconds(600))
                    NSLog("MMJ menu \(selector): selected=\(activeList.selectedIDs.prefix(6)) rows=\(activeList.ids.count)")
                    continue
                }
                if key == "@" { continue }
                if key == "⌫" || key == "⌘" || key == "⌥" {
                    // Through the main menu, as a key equivalent: ⌫, ⌘↓ (next), ⌥⌘↓ (next unread).
                    let (chars, code, mods): (String, UInt16, NSEvent.ModifierFlags) =
                        key == "⌫" ? ("\u{7F}", 51, []) : (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125,
                            key == "⌘" ? [.command, .function, .numericPad] : [.command, .option, .function, .numericPad])
                    let menuEvent = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window?.windowNumber ?? 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                        isARepeat: false, keyCode: code)
                    let handled = menuEvent.map { NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false } ?? false
                    try? await Task.sleep(for: .milliseconds(600))
                    NSLog("MMJ menu key \(key): handled=\(handled) selected=\(activeList.selectedIDs.prefix(6)) rows=\(activeList.ids.count)")
                    continue
                }
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: NSApp.keyWindow?.windowNumber ?? window?.windowNumber ?? 0, context: nil, characters: key,
                    charactersIgnoringModifiers: key, isARepeat: false,
                    keyCode: key == "\r" ? 36 : key == "\u{1B}" ? 53 : key == "\u{7F}" ? 51 : key == String(UnicodeScalar(NSDeleteFunctionKey)!) ? 117 : 0)
                else { continue }
                // Through the event queue, as a real key press arrives (so undo groups per key press).
                NSApp.postEvent(event, atStart: false)
                let handled = true
                try? await Task.sleep(for: .milliseconds(400))
                NSLog("MMJ key \(flags == .control ? "^" : "")\(key): handled=\(handled) scope=\(sidebar.selectedKey ?? "-") selected=\(activeList.selectedIDs.prefix(6)) rows=\(activeList.ids.count)")
            }
        }
    #endif
}

// MARK: - Message menu

/// The Message menu's commands that aren't toolbar buttons, as MailMate has them.
extension MainWindowController {
    @objc func moveToMailbox(_ sender: Any?) { pickMailbox(move: true) }
    @objc func goToMailbox(_ sender: Any?) { pickMailbox(move: false) }

    @objc func nextMessage(_ sender: Any?) { moveSelection(down: true, extending: false) }
    @objc func previousMessage(_ sender: Any?) { moveSelection(down: false, extending: false) }
    @objc func nextThread(_ sender: Any?) { moveToThread(down: true) }
    @objc func previousThread(_ sender: Any?) { moveToThread(down: false) }
    @objc func nextUnreadMessage(_ sender: Any?) { moveToUnread(down: true, threads: false) }
    @objc func previousUnreadMessage(_ sender: Any?) { moveToUnread(down: false, threads: false) }
    @objc func nextUnreadThread(_ sender: Any?) { moveToUnread(down: true, threads: true) }
    @objc func previousUnreadThread(_ sender: Any?) { moveToUnread(down: false, threads: true) }

    /// The next or previous unread message, or thread with unread mail, in the list.
    fileprivate func moveToUnread(down: Bool, threads: Bool) {
        let rows = activeList
        let unread = Set(((try? model.store.rows(ids: rows.ids)) ?? []).filter { !$0.isSeen }.map(\.id))
        let selected = rows.tableView.selectedRowIndexes
        let start = down ? (selected.last ?? -1) : (selected.first ?? rows.ids.count)
        let candidates = down ? Array(stride(from: start + 1, to: rows.ids.count, by: 1)) : Array(stride(from: start - 1, through: 0, by: -1))
        let match = candidates.first { index in
            let id = rows.ids[index]
            let row = rows.threadRows[id]
            if threads {
                // A thread's first row stands for the thread: unread if any of its messages is.
                guard (row?.depth ?? 0) == 0 else { return false }
                return unread.contains(id) || row?.anyUnread == true
            }
            return unread.contains(id) || (row.map { $0.depth == 0 && $0.size > 1 && $0.anyUnread } ?? false)
        }
        guard let match else { return NSSound.beep() }
        selectRow(match)
    }

    /// The first message of the selected message's thread.
    @objc func rootOfThread(_ sender: Any?) {
        let rows = activeList
        guard let selected = rows.tableView.selectedRowIndexes.first else { return NSSound.beep() }
        let root = stride(from: selected, through: 0, by: -1).first { (rows.threadRows[rows.ids[$0]]?.depth ?? 0) == 0 }
        selectRow(root ?? selected)
    }

    /// The last message listed in the selected message's thread.
    @objc func lastOfThread(_ sender: Any?) {
        let rows = activeList
        guard let selected = rows.tableView.selectedRowIndexes.last else { return NSSound.beep() }
        var last = selected
        while last + 1 < rows.ids.count, (rows.threadRows[rows.ids[last + 1]]?.depth ?? 0) > 0 { last += 1 }
        if last == selected, let row = rows.threadRows[rows.ids[selected]], row.depth == 0, row.size > 1 {
            return NSSound.beep()  // A closed thread: its messages aren't listed.
        }
        selectRow(last)
    }

    @objc func quickLookAttachments(_ sender: Any?) { messageView.quickLookAllAttachments() }
    @objc func saveAttachments(_ sender: Any?) { messageView.saveAllAttachments() }
    @objc func openAttachments(_ sender: Any?) { messageView.openAllAttachments() }
}
