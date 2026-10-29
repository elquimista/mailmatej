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
        /// The list followed new mail: the user hadn't scrolled away from it.
        var following: Bool
        var correspondenceSelection: [Int64]
        var correspondenceAnchor: MessageListViewController.ScrollAnchor?
        var displayed: Int64?
    }

    private enum ReloadReason { case scopeChanged, searchChanged, sortChanged, dataChanged, threadsChanged }
    /// The main list groups conversations (View → Organize by Thread), remembered across launches.
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
        SidebarViewController.main = sidebar
        sidebar.remembersSelection = true
        list = MessageListViewController(
            store: model.store, columns: [.unread, .flag, .from, .to, .subject, .date, .source, .attachment],
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
        ) { [weak self] note in
            let countsUnchanged = note.userInfo?[AppModel.countsUnchangedKey] != nil
            let madeHere = note.userInfo?[AppModel.madeHereKey] != nil
            MainActor.assumeIsolated { self?.storeDidChange(countsUnchanged: countsUnchanged, madeHere: madeHere) }
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
            // The row turns read at once, and the counts; the store and the server follow.
            list.showSeen(true, id: id)
            correspondence.showSeen(true, id: id)
            sidebar.adjustUnread(of: [id], by: -1)
            model.perform(.markRead, on: [id]) { _ in false }
        }
        correspondence.onToggleThread = { [weak self] row, collapse in
            self?.toggle(row, collapse: collapse, inCorrespondence: true)
        }
        sidebar.onEditAccount = { [weak self] id in self?.editAccount(id: id) }
        sidebar.onRebuilt = { [weak self] in
            guard let self, followSelectedScope() else { return }
            reloadList(.dataChanged)
        }
        sidebar.onSelectNone = { [weak self] in
            guard let self else { return }
            leaveResult()
            hasMailbox = false
            list.tableView.deselectAll(nil)
            messageView.show(messageID: nil)
            reloadList(.scopeChanged)
            updateProgress()
        }
        sidebar.onSelect = { [weak self] node in
            guard let self, let scope = node.scope else { return }
            leaveResult()
            // A search stays on, now within the mailbox chosen; ending it then stays here too.
            if !movingForSearch { searchBack = nil }
            hasMailbox = true
            saveView()
            self.scope = scope
            self.scopeTitle = node.title
            list.colorKey = node.key
            showColumns()
            selectAfterMove = nil
            self.reloadList(.scopeChanged)
            updateProgress()
        }
        sidebar.onRename = { [weak self] node in
            guard let self, list.colorKey == node.key else { return }  // the mailbox on show
            scopeTitle = node.title
            updateTitle()
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
            messageList.onOpen = { [weak self] id in  // a draft opens in a compose window, to go on with it
                guard let self, (try? model.store.isDraft(id: id)) == true else { return }
                model.openDraft(messageId: id, window: window)
            }
            messageList.addContextItems = { [weak self] menu, ids in self?.addMessageItems(to: menu, for: ids) }
        }
        // As the main list's: nothing selected (a click on the pane's blank area) shows no message, as in
        // MailMate, and several show how many.
        correspondence.onSelectionChange = { [weak self] id in
            guard let self else { return }
            messageView.show(messageID: id, selectionCount: correspondence.selectedIDs.count)
        }
    }

    // MARK: Loading

    /// Whether a mailbox is selected (not after the selected one was deleted).
    private var hasMailbox = true

    /// How many messages the list holds, as of its last load.
    private var messageCount = 0

    /// What the list shows: the mailbox (or a thread or correspondence result), narrowed by any search;
    /// no mailbox, nothing.
    private var shownScope: MessageScope { hasMailbox ? scope : .smart(-1) }  // .smart(-1) matches nothing

    /// List loads under way, and whether a sync's change came in meanwhile (see `reloadList`).
    private var listLoads = 0
    private var listLoadAgain = false

    /// Loads the list off the main thread. With `coalescing` (a change a sync brought), no load starts
    /// while one runs (each one threads the whole mailbox; during a sync they piled up): one more
    /// follows it instead, and what it found shows meanwhile.
    private func reloadList(_ reason: ReloadReason, coalescing: Bool = false) {
        messageView.highlights = searchHighlights  // each search change reloads the list
        if coalescing, listLoads > 0 {
            listLoadAgain = true
            return
        }
        listLoads += 1
        loadGeneration += 1
        let generation = loadGeneration
        let (store, sort) = (model.store, list.sort)
        let scope = shownScope
        let search = searchCondition
        let (threaded, savedExpanded, savedOpened) = (showsThreads, expandedThreads, openedMessages)
        let result = self.result.map { ($0.kind, $0.anchor, $0.condition, $0.opening) }
        let started = Date()
        Task {
            let (rows, messages, newest, stages, scope, expanded, opened, threadRows, listed) = await Task.detached(priority: .userInitiated) {
                let began = Date()
                var (scope, expanded, opened) = (scope, savedExpanded, savedOpened)
                if let (kind, anchor, condition, opening) = result {
                    // Found again on each load, so new mail in the conversation shows up: the thread, or
                    // All Messages narrowed by the result's condition (what its Details shows), with the
                    // message it was opened for wherever that is.
                    var ids = kind == .thread
                        ? (try? store.threadMemberIDs(of: anchor)) ?? [anchor]
                        : (try? store.messageIDs(scope: .allMessages, search: condition)) ?? []
                    if !ids.contains(anchor) { ids.append(anchor) }
                    scope = .messages(ids)
                    // The message's own conversation shown whole (the thread result is just that one), so
                    // the message itself is in view to select, as MailMate opens it.
                    if opening, threaded, let threads = (try? store.threadedMessages(scope: scope, sort: sort))?.threadOf,
                        let own = threads[anchor]
                    {
                        expanded.insert(own)
                        opened.formUnion(threads.filter { $0.value == own }.map(\.key))
                    }
                }
                let list = threaded
                    ? (try? store.threadedMessages(scope: scope, sort: sort, search: search, expanded: expanded, opened: opened))
                    : nil
                let rows = list?.rows ?? ((try? store.messageIDs(scope: scope, sort: sort, search: search)) ?? []).map {
                    MailStore.ThreadedRow(id: $0, thread: "", depth: 0, size: 1, anyUnread: false)
                }
                let listed = Date()
                var newest = try? store.newestMessageID(scope: scope, search: search)
                // New mail inside a collapsed thread is followed to the thread's row.
                if let list, let id = newest, !rows.contains(where: { $0.id == id }), let thread = list.threadOf[id] {
                    newest = rows.first { $0.thread == thread }?.id ?? id
                }
                let ms = { (a: Date, b: Date) in Int(b.timeIntervalSince(a) * 1000) }
                let stages = "waited \(ms(started, began)), list \(ms(began, listed)), newest \(ms(listed, Date()))"
                // Looked up by id on the main thread, made here (hundreds of thousands in a big mailbox).
                let threadRows = threaded ? Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) : [:]
                let rowIDs = Set(rows.map(\.id))
                // Every message of the list, collapsed threads' replies included (threadOf has each one).
                return (rows, list?.threadOf.count ?? rows.count, newest, stages, scope, expanded, opened, threadRows, rowIDs)
            }.value
            #if DEBUG
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_TIMING"] != nil {
                    NSLog("MMJ timing: reload stages: \(stages) ms, back on main after \(Int(Date().timeIntervalSince(started) * 1000))")
                }
            #endif
            listLoads -= 1
            // Once this one shows: the load for changes that came in meanwhile.
            let loadAgain = listLoads == 0 && listLoadAgain
            if loadAgain { listLoadAgain = false }
            defer { if loadAgain { reloadList(.dataChanged, coalescing: true) } }
            guard generation == loadGeneration else { return }
            messageCount = messages
            if result != nil {
                self.scope = scope  // the result's messages, for actions taking rows out
                if self.result?.opening == true {
                    self.result?.opening = false
                    (expandedThreads, openedMessages) = (expanded, opened)  // folding and unfolding start from here
                }
            }
            let ids = rows.map(\.id)
            // Selections can be tens of thousands: looked up in a set (`listed`), not the list.
            list.showsThreads = threaded
            list.expandedThreads = expanded
            list.openedMessages = opened
            list.threadRows = threadRows
            let before = list.selectedIDs
            var restoredDisplay: Int64?
            // Where the newest mail is: the list's end when sorted by date (with threads, the newest
            // message may sit inside a thread elsewhere), otherwise the newest message's row.
            let newestEnd = sort.key == .receivedAt ? (sort.ascending ? ids.last : ids.first) : newest

            switch reason {
            case .scopeChanged where pendingHistorySelection.map(listed.contains) == true:
                list.setIDs(ids, selecting: [pendingHistorySelection!], scroll: .toSelection)
                pendingHistorySelection = nil
                // Gone back to that message: following new mail if the end it arrives at is still in view.
                list.followsNewest = list.showsNewestEnd
            case .scopeChanged:
                if let saved = remembered[scope], saved.selection.contains(where: listed.contains) {
                    // Mail that arrived while away shows at once, unless the user had scrolled away from it.
                    // (Sorted otherwise, the newest message shows if the selection stays in view.)
                    let byDate = sort.key == .receivedAt
                    list.setIDs(
                        ids, selecting: saved.selection,
                        scroll: byDate && saved.following ? .toMessage(newestEnd) : .restore(saved.anchor))
                    list.followsNewest = saved.following
                    if !byDate { list.scrollToEdge(newestEnd) }
                    #if DEBUG
                        if ProcessInfo.processInfo.environment["MMJ_DEBUG_FOLLOW"] != nil {
                            NSLog("MMJ follow: back in the mailbox, following=\(saved.following), newest end in view \(list.showsNewestEnd)")
                        }
                    #endif
                    if let main = list.selectedID, !saved.correspondenceSelection.isEmpty {
                        pendingCorrespondence = (main, saved)
                        restoredDisplay = saved.displayed
                    }
                } else {
                    list.setIDs(ids, selecting: [], scroll: .toMessage(newestEnd))
                    list.followsNewest = true
                }
            case .threadsChanged:
                let wanted = (selectAfterThreads ?? before).filter(listed.contains)
                selectAfterThreads = nil
                let toggled = toggledRow
                toggledRow = nil
                if toggled.map({ list.animateBranch(of: $0, to: ids, selecting: wanted) }) != true {
                    list.setIDs(ids, selecting: wanted, scroll: .keepPosition)
                }
            case .searchChanged, .sortChanged:
                // Keep the selection if it is still in the list; otherwise show the newest message.
                let kept = before.filter(listed.contains)
                list.setIDs(ids, selecting: kept, scroll: kept.isEmpty ? .toMessage(newestEnd) : .toSelection)
            case .dataChanged where selectAfterMove.map { pending in !pending.moved.contains(where: listed.contains) } == true:
                // After Archive/Junk/Delete/Move, once the messages have left the list: the next one.
                let next = selectAfterMove!.next
                selectAfterMove = nil
                list.setIDs(ids, selecting: listed.contains(next) ? [next] : nil, scroll: list.followingScroll(to: ids))
            case .dataChanged:
                // A list that just got its first messages (initial sync) opens at the newest one.
                // When sorted by date, the end new mail arrives at (the top, or the bottom when oldest
                // first) stays in view as mail arrives, unless the user scrolled away from it: then their
                // position is kept. (The end, not the newest message: with threads that can be a reply
                // listed under its thread's first message, far from where the user is reading.)
                let wasEmpty = list.ids.isEmpty
                #if DEBUG
                    let endShown = list.showsNewestEnd
                #endif
                list.setIDs(ids, scroll: wasEmpty ? .toMessage(newestEnd) : list.followingScroll(to: ids))
                #if DEBUG
                    if ProcessInfo.processInfo.environment["MMJ_DEBUG_FOLLOW"] != nil {
                        NSLog("MMJ follow: following=\(list.followsNewest), rows \(ids.count), newest end in view \(endShown) -> \(list.showsNewestEnd)")
                    }
                #endif
            }
            #if DEBUG
                if ProcessInfo.processInfo.environment["MMJ_DEBUG_TIMING"] != nil { NSLog("MMJ timing: list shown (\(reason), \(ids.count) rows) after \(Int(Date().timeIntervalSince(started) * 1000)) ms") }
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
        correspondenceReads += 1  // one read off the main thread before this is out of date
        showCorrespondence(
            id.flatMap {
                Self.readCorrespondence(
                    of: $0, store: model.store, myAddresses: model.myAddresses, sort: correspondence.sort, threads: showsThreads)
            }, for: id, keepSelection: keepSelection)
    }

    /// `reloadCorrespondence` for a change in the store (new mail, marks): read off the main thread, which
    /// it runs on for every change while mail syncs, and shown if nothing has changed the pane since.
    private func refreshCorrespondence(for id: Int64?) {
        guard let id else { return reloadCorrespondence(for: nil) }
        correspondenceReads += 1
        let (read, store, mine, sort, threads) = (correspondenceReads, model.store, model.myAddresses, correspondence.sort, showsThreads)
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                Self.readCorrespondence(of: id, store: store, myAddresses: mine, sort: sort, threads: threads)
            }.value
            guard read == correspondenceReads, (list.selectedID ?? correspondence.selectedID) == id else { return }
            showCorrespondence(found, for: id, keepSelection: true)
        }
    }

    /// Reads of the pane started (the last one's is the one to show).
    private var correspondenceReads = 0

    /// What the Correspondence pane shows for a message: its correspondent's mail with me, through the
    /// address of mine this message used, and, with threads shown, how it threads.
    struct CorrespondenceRead: Sendable {
        let email: String
        let flat: [Int64]
        let threads: [MailStore.ThreadInput]?
    }

    nonisolated private static func readCorrespondence(
        of id: Int64, store: MailStore, myAddresses: Set<String>, sort: MessageSort, threads: Bool
    ) -> CorrespondenceRead? {
        guard let email = try? store.correspondent(messageId: id, myAddresses: myAddresses) else { return nil }
        let mine = try? store.myAddress(in: id, myAddresses: myAddresses)
        let flat = (try? store.correspondenceIDs(email: email, via: mine, sort: sort, keeping: id)) ?? []
        return CorrespondenceRead(email: email, flat: flat, threads: threads ? try? store.threadInfo(ids: flat) : nil)
    }

    private func showCorrespondence(_ found: CorrespondenceRead?, for id: Int64?, keepSelection: Bool) {
        guard let id, let found else {
            correspondent = nil
            correspondence.setIDs([])
            return
        }
        correspondent = found.email
        let flat = found.flat
        // The main list's message is shown in its thread: opened down to it, unless the pane is just
        // refreshing (new mail, re-sorting) and keeps what the user opened or closed.
        let ids = threadCorrespondence(flat, threads: found.threads, revealing: keepSelection ? nil : id)
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
    private func threadCorrespondence(_ flat: [Int64], threads: [MailStore.ThreadInput]?, revealing reveal: Int64? = nil) -> [Int64] {
        correspondence.showsThreads = showsThreads
        guard showsThreads, let info = threads else {
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

    private func storeDidChange(countsUnchanged: Bool, madeHere: Bool) {
        selectionMarks = nil
        // Rows come and go at once after a change made here (only new rows are counted then); counts are
        // queried off the main thread.
        if countsUnchanged || madeHere { sidebar.reload(keepingCounts: true) }
        if !countsUnchanged { sidebar.reloadInBackground() }
        followSelectedScope()
        reloadList(.dataChanged, coalescing: !madeHere)
        if list.selectedID != nil || correspondent != nil {
            refreshCorrespondence(for: list.selectedID ?? correspondence.selectedID)
        }
    }

    /// The selected mailbox's scope can change in place (a special mailbox's conditions now narrow it).
    @discardableResult
    private func followSelectedScope() -> Bool {
        guard let current = sidebar.selectedNode?.scope, current != scope, current.base == scope.base else { return false }
        scope = current
        return true
    }

    private func syncStatusDidChange() {
        sidebar.refreshStatuses()
        updateProgress()
    }

    /// The sidebar's progress bar: first, while accounts behind the selected mailbox are still
    /// downloading their message headers (a first sync, which fills the lists), how far they've got;
    /// then how much of the selected mailbox is downloaded, while whole messages are downloading and it
    /// isn't all here yet.
    /// Bumped by each `updateProgress`: a count that comes back after a newer one started is dropped.
    private var progressGeneration = 0

    private func updateProgress() {
        progressGeneration += 1
        #if DEBUG
            if let shown = Double(ProcessInfo.processInfo.environment["MMJ_DEBUG_PROGRESS"] ?? "") {  // e.g. "0.4"
                return sidebar.showProgress(true, fraction: shown, texts: ["Downloading \(Int(shown * 560)) of 560", "\(Int(shown * 560)) of 560"])
            }
        #endif
        if hasMailbox, let headers = model.headerProgress(accountIds: accountsShown(in: scope)),
            headers.downloaded < headers.total
        {
            let count = "\(headers.downloaded.formatted()) of \(headers.total.formatted())"
            return sidebar.showProgress(
                true, fraction: Double(headers.downloaded) / Double(headers.total),
                texts: headers.whole ? ["Downloading \(count)", count] : ["Downloading headers \(count)", "Headers \(count)", count])
        }
        guard hasMailbox, model.downloadProgress != nil else { return sidebar.showProgress(false) }
        // Counted off the main thread: it reads the whole mailbox, twice a second while mail downloads.
        let (generation, store, scope) = (progressGeneration, model.store, scope)
        Task {
            let counts = await Task.detached(priority: .utility) { try? store.downloadCounts(scope: scope) }.value
            guard generation == progressGeneration else { return }
            guard let counts, counts.total > 0, counts.downloaded < counts.total else { return sidebar.showProgress(false) }
            let count = "\(counts.downloaded.formatted()) of \(counts.total.formatted())"
            sidebar.showProgress(
                true, fraction: Double(counts.downloaded) / Double(counts.total), texts: ["Downloading \(count)", count])
        }
    }

    /// The accounts a mailbox shows mail of, when that's one account (its mailboxes, its account row);
    /// nil for mailboxes across accounts.
    private func accountsShown(in scope: MessageScope) -> Set<String>? {
        switch scope {
        case .mailbox(let id), .flaggedInMailbox(let id):
            return (try? model.store.mailboxes())?.first { $0.id == id }.map { [$0.accountId] }
        case .account(let id), .flaggedInAccount(let id), .allInAccount(let id), .smartAccount(_, let id),
            .smartAccountValue(_, let id, _, _):
            return [id]
        case .within(_, let child), .value(let child, _, _):
            return accountsShown(in: child)
        default:
            return nil
        }
    }

    /// "Subject — Mailbox (N messages)", as MailMate titles its window; "(2 of N messages)" while the
    /// selection stands for more than one (a folded thread, say).
    private func updateTitle() {
        guard hasMailbox else {
            window?.title = "No mailbox selected"  // MailMate's
            return
        }
        // Messages, as MailMate counts them, not rows: a collapsed thread is one row.
        let count = messageCount
        let selected = list.selectedMessageCount
        let of = selected > 1 ? "\(selected.formatted()) of " : ""
        let mailbox = "\(scopeTitle) (\(of)\(count.formatted()) message\(count == 1 ? "" : "s"))"
        let subject = list.selectedID.flatMap { try? model.store.detail(id: $0)?.subject }
        window?.title = subject.map { ($0.isEmpty ? "(no subject)" : $0) + " — " + mailbox } ?? mailbox
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
            case _ where name.hasPrefix("select@"): _ = sidebar.select(key: String(name.dropFirst("select@".count)))
            case _ where name.hasPrefix("applyRules"):
                // "applyRules" / "applyRulesAll": Mailbox › Apply Rules of “…” ▸ Selected Messages / All
                // Messages, as the menu bar has them; "…@<key>": as that sidebar row's context menu has them.
                let parts = name.split(separator: "@", maxSplits: 1).map(String.init)
                var apply: NSMenuItem?
                if parts.count > 1 {
                    apply = sidebar.node(forKey: parts[1]).flatMap { sidebar.menuGroups(for: $0).joined().first { $0.title.hasPrefix("Apply Rules") } }
                } else if let menu = NSApp.mainMenu?.item(withTitle: "Mailbox")?.submenu {
                    menu.delegate?.menuNeedsUpdate?(menu)  // as opening it does
                    apply = menu.items.first { $0.title.hasPrefix("Apply Rules") }
                    NSLog("MMJ Mailbox menu: \(menu.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | "))")
                }
                let items = apply?.submenu?.items ?? []
                func shown(_ item: NSMenuItem) -> String {
                    let keys = item.keyEquivalentModifierMask
                    return (keys.contains(.control) ? "⌃" : "") + (keys.contains(.option) ? "⌥" : "") + "⌘" + item.keyEquivalent.uppercased()
                }
                // Greyed out as the menu shows it: no submenu, or its own validation (the menu bar's).
                let on = apply.map { $0.submenu != nil && (($0.target as? NSMenuItemValidation)?.validateMenuItem($0) ?? true) } ?? false
                NSLog("MMJ apply rules menu: \(apply?.title ?? "none")=\(on) [\(items.map { "\($0.title) \(shown($0))=\(validateMenuItem($0))" }.joined(separator: ", "))]")
                let wanted = items.first { $0.title == (parts[0] == "applyRules" ? "Selected Messages" : "All Messages") }
                if on, let wanted, validateMenuItem(wanted), let action = wanted.action { NSApp.sendAction(action, to: self, from: wanted) }
            case "keyApplyRules", "keyApplyRulesAll":
                // ⌥⌘L / ⌃⌥⌘L through the menu bar, as pressing them does (before the Mailbox menu has opened).
                var flags: NSEvent.ModifierFlags = [.command, .option]
                if name == "keyApplyRulesAll" { flags.insert(.control) }
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window?.windowNumber ?? 0, context: nil, characters: name == "keyApplyRulesAll" ? "\u{0C}" : "¬",
                    charactersIgnoringModifiers: "l", isARepeat: false, keyCode: 37)
                // A run in the background has no key or main window for the items to reach: aimed at this one.
                let items = NSApp.mainMenu?.item(withTitle: "Mailbox")?.submenu?.items.first { $0.title.hasPrefix("Apply Rules") }?.submenu?.items ?? []
                items.forEach { $0.target = self }
                defer { items.forEach { $0.target = nil } }
                NSLog("MMJ key \(name) handled: \(event.map { NSApp.mainMenu?.performKeyEquivalent(with: $0) ?? false } ?? false)")
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
            list.tableView.scrollRowToVisible(row)
            NSLog("MMJ select: row \(row), message \(list.ids[row])")
        }

        func debugSelectSidebar(key: String) { sidebar.debugSelect(key: key) }
        func debugHeaderMenu(run: String?) -> [String] { list.debugHeaderMenu(run: run) }
        var debugColumns: String { list.debugColumns }
        func debugSidebarContextMenu(key: String) -> [String] { sidebar.debugContextMenu(key: key) }
        func debugMoveSidebar(_ spec: String) { sidebar.debugMove(spec) }
        var debugSidebarBadges: String { sidebar.debugBadges }
        var debugSidebarOrder: String { sidebar.debugOrder }
        func debugEmpty(key: String, choose: String?) { sidebar.debugEmpty(key: key, choose: choose) }

        /// Shows the selected message's thread ("thread") or correspondence ("people"), or ends it ("cancel").
        /// Searches as typing in the search field and pressing Return would ("" clears it).
        func debugSearch(_ text: String) {
            if text.hasPrefix("@") { return _ = sidebar.select(key: String(text.dropFirst())) }  // "@key": choose a mailbox
            if text.hasPrefix("#"), let row = Int(text.dropFirst()) { return debugSelectRow(row) }  // "#row": select a list row
            // "!Details", "!Save", "!Cancel": the bar's buttons; "!+text": ⊕ on the conditions, the first one
            // then "text"; "!name=X" / "!edit=X" / "!name": the name sheet's Save, Save and Edit…, Cancel.
            if text.hasPrefix("!") {
                let step = String(text.dropFirst())
                if step.hasPrefix("+") { return searchEditor?.debugAddRow(text: String(step.dropFirst())) ?? () }
                if step.hasPrefix("type=") { return searchEditor?.debugType(String(step.dropFirst(5))) ?? () }  // "!type=text"
                // "!find=text": ⌘F and typing text; "!findnext", "!findprev", "!finddone": ⌘G, ⇧⌘G, Done.
                if step.hasPrefix("find=") { return messageView.debugFind(String(step.dropFirst(5))) }
                if step == "findnext" { return findNextInMessage(nil) }
                if step == "findprev" { return findPreviousInMessage(nil) }
                if step == "finddone" { return messageView.hideFind() }
                if step == "findesc" { return messageView.debugFindEscape() }
                if step.hasPrefix("tab"), let count = Int(step.dropFirst(3)), let window {  // "!tab3": Tab 3 times, logged
                    return debugLogTabOrder(in: window, count: count)
                }
                if step.hasPrefix("name=") { return MailboxNameSheet.debugFinish(name: String(step.dropFirst(5)), edit: false) }
                if step.hasPrefix("edit=") { return MailboxNameSheet.debugFinish(name: String(step.dropFirst(5)), edit: true) }
                if step == "name" { return MailboxNameSheet.debugFinish(name: nil, edit: false) }
                return list.debugClickResultBar(step)
            }
            searchField?.stringValue = text
            if let field = searchField { searchChanged(field) }
        }

        func debugResult(_ kind: String) {
            switch kind {
            case "thread": showResult(.thread)
            case "people": showResult(.correspondents)
            case "from": showResult(.from)
            case "fromorto": showResult(.fromOrTo)
            case "collapse", "expand":  // the first row's thread, as its chevron does
                if let id = list.ids.first, let row = list.threadRows[id] { toggle(row, collapse: kind == "collapse") }
            case "details": list.debugClickResultBar("Details")
            case "save": list.debugClickResultBar("Save")
            case "name": MailboxNameSheet.debugFinish(name: "Saved result", edit: false)
            default: if result == nil, isSearching { clearSearch() } else { endResult() }
            }
        }

        var debugListState: String {
            "search \(searchCondition.map { String(describing: $0) } ?? "-") sheet \(MailboxNameSheet.debugIsShown) sidebar \(sidebar.selectedKey ?? "-") scope \(scopeTitle) rows \(list.ids.count) messages \(messageCount) selected \(list.selectedIDs) title \(window?.title ?? "") \(list.debugResultBar)"
        }
        /// Sorts the main list by a column, as a click on its header does ("unread", "flag", "date", ...).
        func debugShowProgress() { updateProgress() }

        func debugSort(column: String) {
            guard let prototype = list.tableView.tableColumn(withIdentifier: .init(column))?.sortDescriptorPrototype else {
                return NSLog("MMJ sort: no sortable column \(column)")
            }
            list.tableView.sortDescriptors = [prototype]
        }
        func debugDuplicateSidebar(_ key: String) { sidebar.debugDuplicate(key: key) }
        func debugChooseCount(key: String, kind: String, full: Bool) async {
            await sidebar.debugChooseCount(key: key, kind: kind, full: full)
        }
        var debugSidebarTitleColors: String { sidebar.debugTitleColors }
        func debugRefreshSidebarStatuses() { sidebar.debugRefreshStatuses() }
        func debugScrollSidebarToTop() { sidebar.debugScrollToTop() }
        func debugRenameSidebar(_ key: String, to name: String, rebuild: Bool) {
            sidebar.debugRenameWhileRefreshing(key: key, name: name, rebuild: rebuild)
        }
        func debugNewSmartMailbox(inside key: String) { sidebar.debugNewSmartMailbox(inside: key) }
        func debugSymbolMenu(key: String, path: String) { sidebar.debugSymbolMenu(key: key, path: path) }
        func debugCaptureColorMenu(key: String, path: String) { sidebar.debugCaptureColorMenu(key: key, path: path) }
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

        /// Clears the Correspondence pane's selection, as a click on its blank area does, logging what each
        /// list selects and the message view shows, before and after.
        func debugDeselectCorrespondence() {
            func report(_ when: String) {
                NSLog("MMJ corr deselect \(when): list \(list.selectedIDs) correspondence \(correspondence.selectedIDs) view \(messageView.debugShowing)")
            }
            report("before")
            correspondence.tableView.deselectAll(nil)
            report("after")
        }

        /// Deletes the displayed message's .eml, then fetches it through the Show in Finder path.
        func debugCheckAttachments() async { await messageView.debugCheckAttachments() }

        var debugAttachmentRows: [String] { messageView.debugAttachmentRows }
        func debugTimeAttachment() async { await messageView.debugTimeAttachment() }
        func debugAttachment(click index: Int?, key: UInt16? = nil) { messageView.debugAttachment(click: index, key: key) }

        func debugCheckRawMessage() async {
            guard let id = messageView.displayedMessageID, let detail = try? model.store.detail(id: id) else {
                return NSLog("MMJ raw: no message displayed")
            }
            model.store.blobs.remove(accountId: detail.accountId, blobId: detail.blobId)
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
            let before = list.selectedIDs
            let items = list.debugContextMenu(row: row, run: run)
            let seen = (try? model.store.rows(ids: [id]).first?.isSeen).flatMap { $0 }
            return items + ["message \(id)", "selected before \(before) after \(list.selectedIDs)", "seen \(seen.map(String.init) ?? "-")"]
        }

        /// Copies the row's message into its account's mailbox with this role too, as a rule's Copy does.
        func debugCopy(row: Int, role: String) {
            guard row < list.ids.count, let ref = try? model.store.refs(ids: [list.ids[row]]).first,
                let box = try? model.store.mailbox(accountId: ref.accountId, role: role)
            else { return NSLog("MMJ copy: nothing to copy") }
            model.perform(.copy(toMailboxId: box.id), on: [ref.id]) { _ in false }
        }

        /// The row's Source Mailbox text.
        func debugSource(row: Int) -> String {
            guard row < list.ids.count, let r = try? model.store.rows(ids: [list.ids[row]]).first else { return "-" }
            return "\(r.mailboxName) – \(r.accountName)"
        }

        func debugHoverLink(containing text: String) async { await messageView.debugHoverLink(containing: text) }

        func debugScrollMessage(by points: CGFloat) { messageView.debugScrollContent(by: points) }
        var debugMessageLayout: String { messageView.debugLayout }

        func debugSnapshotWeb(to path: String) async { await messageView.debugSnapshotWeb(to: path) }

        func debugScrollSidebar(by points: CGFloat) { sidebar.debugScroll(by: points) }
        func debugSelectLastInSidebar() { sidebar.debugSelectLast() }
        func debugSidebarProgress(_ fraction: Double?) { sidebar.debugProgress(fraction) }

        func debugScrollList(by points: CGFloat) {
            guard let scrollView = list.tableView.enclosingScrollView else { return }
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + points))
            scrollView.reflectScrolledClipView(clip)
        }

        /// Selects a row (negative: counted from the end, -1 the last) and brings it into view.
        func debugSelectRow(_ row: Int) {
            let row = row < 0 ? list.ids.count + row : row
            guard list.ids.indices.contains(row) else { return }
            list.tableView.selectRowIndexes([row], byExtendingSelection: false)
            list.tableView.scrollRowToVisible(row)
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

    /// Mailbox › Synchronize (⇧⌘N), as MailMate's: synchronizes the accounts the selected mailbox's mail
    /// comes from (all of them with nothing selected).
    @objc func synchronize(_ sender: Any?) {
        sidebar.synchronize(sidebar.selectedNode)
    }

    /// Synchronize's title for the selected mailbox.
    var synchronizeTitle: String { sidebar.synchronizeTitle(for: sidebar.selectedNode) }

    /// Mailbox › New Smart Mailbox (⌥⌘N): inside the selected smart mailbox, else at the top level; not on
    /// a generated submailbox.
    @objc func newSmartMailbox(_ sender: Any?) {
        sidebar.newSmartMailbox(inside: sidebar.selectedNode)
    }

    /// The selected mailbox's commands, for the Mailbox menu (see `SidebarViewController.menuGroups`).
    var mailboxMenuGroups: [[NSMenuItem]] {
        sidebar.selectedNode.map { sidebar.menuGroups(for: $0) } ?? []
    }

    /// Take Online, or why the selected account's last sync failed, for under Mailbox › Synchronize.
    var syncStatusItems: [NSMenuItem] { sidebar.selectedNode.map(sidebar.syncStatusItems(for:)) ?? [] }

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
        let ids = menuIDs(item)  // a context menu's own messages (a right-clicked one may not be selected)
        switch item.action {
        case #selector(archiveMessages(_:)), #selector(junkMessages(_:)), #selector(notJunkMessages(_:)), #selector(deleteMessages(_:)),
            #selector(moveToMailbox(_:)), #selector(flagMessages(_:)), #selector(unflagMessages(_:)):
            return !editing && !ids.isEmpty
        case #selector(toggleReadState(_:)):
            let marks = marks(of: ids)
            item.title = marks.count > 0 && !marks.anySeen ? "Mark as Read" : "Mark as Unread"
            return !editing && marks.count > 0
        case #selector(reply(_:)), #selector(replyAll(_:)), #selector(forward(_:)):
            return ids.count == 1 && model.canCompose
        case #selector(nextMessage(_:)), #selector(previousMessage(_:)), #selector(nextUnreadMessage(_:)),
            #selector(previousUnreadMessage(_:)), #selector(nextThread(_:)), #selector(previousThread(_:)),
            #selector(nextUnreadThread(_:)), #selector(previousUnreadThread(_:)):
            return !editing && !activeList.ids.isEmpty
        case #selector(goBack(_:)): return historyIndex > 0
        case #selector(goForward(_:)): return historyIndex < history.count - 1
        case #selector(rootOfThread(_:)), #selector(lastOfThread(_:)):
            return !editing && showsThreads && activeList.selectedID != nil
        case #selector(quickLookAttachments(_:)), #selector(saveAttachments(_:)), #selector(openAttachments(_:)):
            // They act on the message on screen: from a context menu, only when that's the one clicked.
            if let menuIDs = item.representedObject as? [Int64], menuIDs != messageView.displayedMessageID.map({ [$0] }) {
                return false
            }
            return messageView.hasAttachments
        case #selector(goToMailbox(_:)):
            return !editing
        case #selector(newSmartMailbox(_:)):
            return sidebar.selectedNode?.isGenerated != true
        case #selector(synchronize(_:)):
            return sidebar.canSynchronize(sidebar.selectedNode)
        case #selector(findInMessage(_:)), #selector(findNextInMessage(_:)), #selector(findPreviousInMessage(_:)),
            #selector(useSelectionForFind(_:)):
            return messageView.showsMessage
        case #selector(applyRulesToSelection(_:)), #selector(applyRulesToList(_:)):
            guard let key = rulesKey(item), model.hasRules(mailboxKey: key) else { return false }
            return item.action == #selector(applyRulesToSelection(_:)) ? !ids.isEmpty : messageCount > 0
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

    /// Edit ▸ Find ▸ Find… (⌘F), Find Next (⌘G), Find Previous (⇧⌘G), Use Selection for Find (⌘E): in
    /// the message shown, as MailMate's.
    @objc func findInMessage(_ sender: Any?) { messageView.showFind() }
    @objc func findNextInMessage(_ sender: Any?) { messageView.findNext(forward: true) }
    @objc func findPreviousInMessage(_ sender: Any?) { messageView.findNext(forward: false) }
    @objc func useSelectionForFind(_ sender: Any?) { messageView.useSelectionForFind() }

    private func clearSearch() {
        searchField?.stringValue = ""
        if window?.firstResponder === searchField?.currentEditor() { window?.makeFirstResponder(list.tableView) }
        applySearch("")
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        guard sender.stringValue != search else { return }
        applySearch(sender.stringValue)
    }

    /// The mailbox (sidebar key) a search left, to go back to when it ends.
    private var searchBack: String?
    /// Set while a search selects All Messages in the sidebar (which doesn't end the search).
    private var movingForSearch = false

    /// The search's conditions once Details has opened them (MailMate's "Custom Search"); nil while the
    /// search is the field's text.
    private var customSearch: SmartCondition?
    private var searchEditor: SmartRuleEditor?
    /// What the list is narrowed to: the custom search, or the field's text as Details would show it.
    private var searchCondition: SmartCondition? { customSearch ?? .quickSearch(search) }
    /// What the search marks in the message shown: the field's words, or the custom search's Contains rows.
    private var searchHighlights: [SearchHighlight] { customSearch?.highlights ?? SearchHighlight.terms(search) }
    private var isSearching: Bool { !search.isEmpty || customSearch != nil }

    /// As MailMate: a search starts in All Messages, so the sidebar goes there, and the list's bar says
    /// what it finds ("Message contains “php”"); choosing another mailbox searches that one. Ending it
    /// (Cancel, Escape, emptying the field) stays in the mailbox chosen, or, still in the All Messages it
    /// went to, goes back to where it started. Within a thread or correspondence result it searches that.
    /// Typing in the field replaces a custom search.
    private func applySearch(_ text: String) {
        let starting = !isSearching && !text.isEmpty
        search = text
        customSearch = nil
        searchEditor = nil
        guard result == nil else { return reloadList(.searchChanged) }
        if text.isEmpty {
            list.showResultBar(nil)
            let back = searchBack
            searchBack = nil
            if let back, back != sidebar.selectedKey, sidebar.select(key: back) { return }  // reloads as it's chosen
            return reloadList(.searchChanged)
        }
        showSearchBar()
        if starting, sidebar.selectedKey != "unified.all" {
            searchBack = sidebar.selectedKey
            movingForSearch = true
            defer { movingForSearch = false }
            if sidebar.select(key: "unified.all") { return }  // reloads as it's chosen
        }
        reloadList(.searchChanged)
    }

    /// The search's bar: Details (until it has opened the conditions), Save, Cancel.
    private func showSearchBar() {
        let cancel: ResultBar.Button = ("Cancel", { [weak self] in self?.clearSearch() })
        let save: ResultBar.Button = ("Save", { [weak self] in
            guard let self, let condition = searchEditor?.tree() ?? searchCondition else { return }
            saveSearch(condition)
        })
        if let searchEditor {
            list.showResultBar("Custom Search", symbol: "magnifyingglass", buttons: [("Details", nil), save, cancel], editor: searchEditor)
        } else {
            list.showResultBar("Message contains “\(search)”", symbol: "magnifyingglass",
                               buttons: [("Details", { [weak self] in self?.showSearchDetails() }), save, cancel])
        }
    }

    /// MailMate's Details: the search as the condition it is (Common Headers or Unquoted Text contains
    /// the text), in the bar, to change or add to; the list follows each change.
    private func showSearchDetails(_ condition: SmartCondition? = nil) {
        guard let condition = condition ?? searchCondition else { return }
        let editor = SmartRuleEditor(kind: .conditions, context: SmartRuleContext(model: model, editing: -1, mailboxKey: scope.key))
        editor.inBar = true
        editor.load(condition)
        editor.onResize = { [weak self] in self?.list.resultBarResized() }
        editor.onChange = { [weak self, weak editor] immediate in
            guard let self, let editor, editor === searchEditor else { return }
            searchEditTimer?.invalidate()
            if immediate { return applySearchEdits() }
            // Typing: once it pauses.
            searchEditTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.applySearchEdits() }
            }
        }
        customSearch = condition
        searchEditor = editor
        showSearchBar()
    }

    private var searchEditTimer: Timer?

    private func applySearchEdits() {
        guard let searchEditor else { return }
        customSearch = searchEditor.tree() ?? .compound(.all, [])
        reloadList(.searchChanged)
    }

    /// MailMate's Save: asks for the mailbox's name, then keeps the search as a smart mailbox of the
    /// mailbox searched, and shows it (Save and Edit… opens its editor too).
    private func saveSearch(_ condition: SmartCondition) {
        guard let window else { return }
        // A result searches All Messages, a search the mailbox chosen.
        let sources = SmartSources(scopes: [result == nil ? scope.key : MessageScope.allMessages.key])
        MailboxNameSheet.ask(over: window, name: "Custom Search") { [weak self] name, edit in
            guard let self, let id = model.createSmartMailbox(name: name, parentId: nil) else { return }
            let root: SmartCondition = if case .compound = condition { condition } else { .compound(.all, [condition]) }
            model.updateSmartMailbox(id: id, definition: SmartDefinition(sources: sources, condition: root))
            searchBack = nil
            if result != nil { endResult() } else { clearSearch() }
            sidebar.rebuild()
            let key = "smart.\(id)"
            guard sidebar.select(key: key) else { return }
            if edit { MailboxEditorWindowController.show(key: key, model: model, over: window, tab: .conditions) }
        }
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
            // Its text otherwise shows grey (156 on screen) while the field isn't being edited, like a
            // placeholder; MailMate's is the label colour (235).
            item.searchField.textColor = .labelColor
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

    /// MailMate's Thread and Correspondence buttons (48 pt apart): the selected message's whole
    /// conversation, or all mail with its correspondent, as a search result (see `showResult`).
    private func listStyleToolbarItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem {
        let thread = Self.toolbarButton(
            symbol: ResultKind.thread.symbol, pointSize: 16, label: "Find and display messages from the same conversation", width: 32)
        let people = Self.toolbarButton(
            symbol: ResultKind.correspondents.symbol, pointSize: 16,
            label: "Find and display messages between the same correspondents", width: 32)
        thread.target = self
        thread.action = #selector(showThreadResult(_:))
        people.target = self
        people.action = #selector(showCorrespondentsResult(_:))
        let stack = NSStackView(views: [thread, people])
        stack.spacing = 16
        let item = ValidatingToolbarItem(itemIdentifier: id)
        item.view = stack
        item.label = "Thread"
        item.onValidate = { [weak self] in
            let enabled = !(self?.targetIDs.isEmpty ?? true)
            thread.isEnabled = enabled
            people.isEnabled = enabled
        }
        return item
    }

    // MARK: Thread and correspondence results

    private enum ResultKind {
        /// The toolbar's: the conversation, and all mail with the correspondent.
        case thread, correspondents
        /// The context menu's Find Messages ▸ (MailMate's): mail from the correspondent, or from or to them.
        case from, fromOrTo

        func title(_ email: String?) -> String {
            switch self {
            case .thread: "Same thread"
            case .correspondents: "Correspondence"
            case .from: "From “\(email ?? "")”"
            case .fromOrTo: "From or To “\(email ?? "")”"
            }
        }

        var symbol: String {
            switch self {
            case .thread: "list.bullet.indent"
            case .correspondents: "list.bullet"
            case .from, .fromOrTo: "magnifyingglass"
            }
        }
    }

    /// The search result on show: what it finds for which message (and its correspondent), and the
    /// mailbox to go back to.
    private struct Result {
        var kind: ResultKind
        var anchor: Int64
        var email: String?
        /// What it finds, as MailMate's Details shows it (see `resultCondition`); for a thread, worked
        /// out only when asked (it reads the whole account's threads).
        var condition: SmartCondition?
        var back: (scope: MessageScope, title: String, colorKey: String?, hasMailbox: Bool)
        /// Until it has loaded once: its message's conversation opens whole; after that it folds and
        /// unfolds as usual.
        var opening = true
    }

    private var result: Result?

    @objc func showThreadResult(_ sender: Any?) { showResult(.thread, anchor: menuIDs(sender).first) }

    /// Choosing a mailbox while a result shows: the result goes (its bar too), without going back.
    private func leaveResult() {
        guard result != nil else { return }
        result = nil
        list.showResultBar(nil)
    }
    @objc func showCorrespondentsResult(_ sender: Any?) { showResult(.correspondents, anchor: menuIDs(sender).first) }
    @objc private func showFromResult(_ sender: Any?) { showResult(.from, anchor: menuIDs(sender).first) }
    @objc private func showFromOrToResult(_ sender: Any?) { showResult(.fromOrTo, anchor: menuIDs(sender).first) }

    /// As MailMate: the selected message's conversation, or all mail between it and its correspondent,
    /// across All Messages, under a bar naming the search; that message stays selected. Cancel (or
    /// Escape, or choosing a mailbox) goes back to the mailbox it came from.
    private func showResult(_ kind: ResultKind, anchor: Int64? = nil) {
        guard let anchor = anchor ?? targetIDs.first else { return NSSound.beep() }
        var email: String?
        if kind != .thread {
            guard let found = try? model.store.correspondent(messageId: anchor, myAddresses: model.myAddresses) else {
                return NSSound.beep()
            }
            email = found
        }
        let back = result?.back ?? (scope, scopeTitle, list.colorKey, hasMailbox)
        if result == nil { saveView() }
        let condition = kind == .thread ? nil : resultCondition(kind, anchor: anchor, email: email ?? "")
        result = Result(kind: kind, anchor: anchor, email: email, condition: condition, back: back)
        hasMailbox = true
        scopeTitle = "All Messages"
        list.colorKey = nil
        showColumns()
        selectAfterMove = nil
        pendingHistorySelection = anchor  // selected once the result has loaded
        list.showResultBar(kind.title(email), symbol: kind.symbol, buttons: [
            ("Details", { [weak self] in self?.showResultDetails() }),
            ("Save", { [weak self] in
                guard let self, let result else { return }
                saveSearch(result.condition ?? resultCondition(result.kind, anchor: result.anchor, email: ""))
            }),
            ("Cancel", { [weak self] in self?.endResult() }),
        ])
        reloadList(.scopeChanged)
    }

    /// A result as MailMate's Details shows it: the thread's #Thread-Id; mail between the correspondent
    /// and the address of mine the message used, either way (when none of mine shows, as MailMate, the
    /// message's other side: the address it was sent to, or its sender); mail from them; or from or
    /// to them.
    private func resultCondition(_ kind: ResultKind, anchor: Int64, email: String) -> SmartCondition {
        let from = SmartField.fromAddress, recipient = SmartField.address(.recipient, .address)
        switch kind {
        case .thread:
            return .rule(.threadId, .is, String((try? model.store.threadNumber(of: anchor)) ?? anchor))
        case .correspondents:
            guard let mine = (try? model.store.myAddress(in: anchor, myAddresses: model.myAddresses))
                ?? (try? model.store.otherSide(of: email, in: anchor))
            else {
                return .compound(.any, [.rule(from, .is, email), .rule(recipient, .is, email)])
            }
            return .compound(.any, [
                .compound(.all, [.rule(from, .is, email), .rule(recipient, .is, mine)]),
                .compound(.all, [.rule(from, .is, mine), .rule(recipient, .is, email)]),
            ])
        case .from:
            return .rule(from, .is, email)
        case .fromOrTo:
            return .compound(.any, [.rule(from, .is, email), .rule(recipient, .is, email)])
        }
    }

    /// Details on a result: it becomes a custom search of All Messages with its condition, as in
    /// MailMate; Cancel then goes back to the mailbox the result was opened from.
    private func showResultDetails() {
        guard let result else { return }
        let backKey = sidebar.selectedKey
        let selected = list.selectedIDs.first ?? result.anchor
        self.result = nil
        search = ""
        searchField?.stringValue = ""
        showSearchDetails(result.condition ?? resultCondition(result.kind, anchor: result.anchor, email: ""))
        if sidebar.selectedKey != "unified.all" {
            searchBack = backKey
            movingForSearch = true
            defer { movingForSearch = false }
            if sidebar.select(key: "unified.all") {  // reloads as it's chosen
                pendingHistorySelection = selected  // the message stays selected
                return
            }
        }
        scope = .allMessages
        scopeTitle = "All Messages"
        pendingHistorySelection = selected
        reloadList(.scopeChanged)
    }

    /// Back to the mailbox the result was opened from, as it was.
    private func endResult() {
        guard let back = result?.back else { return }
        result = nil
        list.showResultBar(nil)
        scope = back.scope
        scopeTitle = back.title
        list.colorKey = back.colorKey
        showColumns()
        hasMailbox = back.hasMailbox
        reloadList(.scopeChanged)
    }

    /// The list takes the columns of the mailbox on show; a result (no mailbox) has its own.
    private func showColumns() {
        let key = list.colorKey ?? "result"
        list.columnsMailbox = (key, sidebar.holdsSentMail(key))
    }

    /// Remembers the list's selection and position in the current mailbox, for coming back to it.
    private func saveView() {
        remembered[scope] = SavedView(
            selection: list.selectedIDs, anchor: list.scrollAnchor, following: list.followsNewest,
            correspondenceSelection: correspondence.selectedIDs, correspondenceAnchor: correspondence.scrollAnchor,
            displayed: messageView.displayedMessageID)
    }

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
            let marks = marks(of: ids)
            for button in views {
                switch button.action {
                // As in MailMate, a mark button is off when it would change nothing.
                case #selector(markRead(_:)): button.isEnabled = marks.anyUnread
                case #selector(markUnread(_:)): button.isEnabled = marks.anySeen
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
        let marks = marks(of: ids)
        return marks.count > 0 && marks.allFlagged
    }

    /// What's marked among some messages, for the buttons and menus.
    private struct SelectionMarks {
        var count = 0, anySeen = false, anyUnread = false, allFlagged = true
    }

    /// The last selection's marks: the toolbar's groups and the menus ask for the same messages many
    /// times over (a selection can be tens of thousands); forgotten with every change.
    private var selectionMarks: (ids: [Int64], marks: SelectionMarks)?

    private func marks(of ids: [Int64]) -> SelectionMarks {
        if let cached = selectionMarks, cached.ids == ids { return cached.marks }
        var marks = SelectionMarks()
        for mark in (try? model.store.marks(ids: ids)) ?? [] {
            marks.count += 1
            if mark.seen { marks.anySeen = true } else { marks.anyUnread = true }
            if !mark.flagged { marks.allFlagged = false }
        }
        selectionMarks = (ids, marks)
        return marks
    }

    @objc func newMessage(_ sender: Any?) { model.compose(.new, messageId: targetIDs.first, window: window) }
    @objc func reply(_ sender: Any?) { compose(.reply, ids: menuIDs(sender)) }
    @objc func replyAll(_ sender: Any?) { compose(.replyAll, ids: menuIDs(sender)) }
    @objc func forward(_ sender: Any?) { compose(.forward, ids: menuIDs(sender)) }

    private func compose(_ kind: ComposeKind, ids: [Int64]) {
        guard ids.count == 1 else { return NSSound.beep() }
        model.compose(kind, messageId: ids[0], window: window)
    }

    @objc func archiveMessages(_ sender: Any?) { moveAway(.archive, ids: menuIDs(sender)) }
    @objc func junkMessages(_ sender: Any?) { moveAway(.junk, ids: menuIDs(sender)) }
    @objc func notJunkMessages(_ sender: Any?) { moveAway(.notJunk, ids: menuIDs(sender)) }

    /// The messages a context menu item acts on (the right-clicked one, or the selection it's in), else
    /// the usual targets.
    private func menuIDs(_ sender: Any?) -> [Int64] {
        (sender as? NSMenuItem)?.representedObject as? [Int64] ?? targetIDs
    }
    @objc func deleteMessages(_ sender: Any?) { moveAway(.delete, ids: menuIDs(sender)) }
    @objc func markRead(_ sender: Any?) { perform(.markRead, on: targetIDs) }
    @objc func markUnread(_ sender: Any?) { perform(.markUnread, on: targetIDs) }
    @objc func flagMessages(_ sender: Any?) { perform(.flag, on: menuIDs(sender)) }
    @objc func unflagMessages(_ sender: Any?) { perform(.unflag, on: menuIDs(sender)) }
    /// Mailbox › Apply Rules of “…” ▸ Selected Messages (⌥⌘L; also in the list's context menu) and All
    /// Messages (⌃⌥⌘L): a mailbox's rules on the list's selected messages or on all of it, as if they had
    /// just arrived; a beep if none meets a rule's conditions.
    @objc func applyRulesToSelection(_ sender: Any?) { applyRules(sender, to: menuIDs(sender)) }
    @objc func applyRulesToList(_ sender: Any?) {
        applyRules(sender, to: (try? model.store.messageIDs(scope: shownScope, search: searchCondition)) ?? [])
    }

    private func applyRules(_ sender: Any?, to ids: [Int64]) {
        #if DEBUG
            NSLog("MMJ apply rules of \(rulesKey(sender) ?? "-") to \(ids.count) messages")
        #endif
        guard let key = rulesKey(sender), model.applyRules(mailboxKey: key, to: ids) > 0 else { return NSSound.beep() }
    }

    /// The mailbox whose rules an Apply Rules item applies: a sidebar row's (its menu), else the one shown.
    private func rulesKey(_ sender: Any?) -> String? {
        ((sender as? NSMenuItem)?.representedObject as? SidebarNode ?? sidebar.selectedNode)?.scope?.key
    }

    /// Whether the mailbox shown has rules to apply (else Mailbox › Apply Rules is greyed out).
    var shownMailboxHasRules: Bool { rulesKey(nil).map(model.hasRules) ?? false }
    /// Message → Mark as Unread (Mark as Read when every selected message is unread).
    @objc func toggleReadState(_ sender: Any?) {
        let ids = menuIDs(sender)
        perform(marks(of: ids).anySeen ? .markUnread : .markRead, on: ids)
    }
    @objc func toggleFlag(_ sender: Any?) {
        let ids = targetIDs
        perform(allFlagged(ids) ? .unflag : .flag, on: ids)
    }

    /// MailMate's message context menu: its Message menu without the moving-around groups and Go to
    /// Mailbox…, with Find Messages ▸ first, for the commands MailMateJ has. Every item acts on `ids`
    /// (the right-clicked message, or the selection it's in).
    private func addMessageItems(to menu: NSMenu, for ids: [Int64]) {
        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = ids
            return item
        }
        // MailMate's Find Messages ▸ for the message's correspondent (its sender, or for mail I sent, its
        // recipient), named in the titles.
        var findGroup: [NSMenuItem] = []
        if let first = ids.first, let email = try? model.store.correspondent(messageId: first, myAddresses: model.myAddresses) {
            let find = NSMenu()
            find.addItem(item(ResultKind.from.title(email), #selector(showFromResult(_:))))
            find.addItem(item(ResultKind.fromOrTo.title(email), #selector(showFromOrToResult(_:))))
            let findItem = NSMenuItem(title: "Find Messages", action: nil, keyEquivalent: "")
            findItem.submenu = find
            findGroup = [findItem]
        }

        let inJunk = (try? model.store.messageIDs(ids, inRole: "junk")) ?? []
        let allJunk = !ids.isEmpty && ids.allSatisfy(inJunk.contains)
        var actions = [
            item("Reply", #selector(reply(_:))), item("Reply All", #selector(replyAll(_:))), item("Forward", #selector(forward(_:))),
            item("Move to Archive", #selector(archiveMessages(_:))),
            allJunk ? item("Move Out of Junk", #selector(notJunkMessages(_:))) : item("Move to Junk", #selector(junkMessages(_:))),
            item("Move to Mailbox…", #selector(moveToMailbox(_:))),
        ]
        if let remove = removeFromMailboxItem(for: ids) { actions.append(remove) }
        actions.append(item("Delete", #selector(deleteMessages(_:))))

        let flags = NSMenu()
        flags.addItem(item("Flag", #selector(flagMessages(_:))))
        flags.addItem(item("Unflag", #selector(unflagMessages(_:))))
        let flagItem = NSMenuItem(title: "Flag", action: nil, keyEquivalent: "")
        flagItem.submenu = flags
        let read = item("Mark as Unread", #selector(toggleReadState(_:)))  // its title follows the messages (validation)

        // Apply Rules, of the mailbox shown (greyed out when it has none).
        let rules = sidebar.selectedNode.map { [item("Apply Rules of “\($0.title)”", #selector(applyRulesToSelection(_:)))] } ?? []

        let attachments = [
            item("Save Attachments…", #selector(saveAttachments(_:))),
            item("Quick Look Attachments…", #selector(quickLookAttachments(_:))),
            item("Open Attachments", #selector(openAttachments(_:))),
        ]
        for (index, group) in [findGroup, actions, [flagItem, read], rules, attachments].filter({ !$0.isEmpty }).enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            group.forEach(menu.addItem)
        }
    }

    /// Remove from Mailbox ▸ each mailbox the messages are in, for messages in several (a message in
    /// Sent and Archive, say): takes them out of that one only. Shown only when some message is in more
    /// than one; a mailbox is offered when some message could leave it and still be in another.
    private func removeFromMailboxItem(for ids: [Int64]) -> NSMenuItem? {
        guard let current = try? model.store.mailboxIDs(messageIds: ids), current.values.contains(where: { $0.count > 1 }),
            let all = try? model.store.mailboxes(), let accounts = try? model.store.accounts()
        else { return nil }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let accountNames = Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let removable = Set(current.values.filter { $0.count > 1 }.flatMap { $0 })
        // Per account, its special mailboxes first, then by name.
        let boxes: [MailboxRecord] = removable.compactMap { byID[$0] }.sorted { a, b in
            if a.accountId != b.accountId { return a.accountId < b.accountId }
            if (a.role == nil) != (b.role == nil) { return a.role != nil }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        let severalAccounts = Set(boxes.map { $0.accountId }).count > 1
        let submenu = NSMenu()
        for box in boxes {
            let title = severalAccounts ? "\(box.name) – \(accountNames[box.accountId] ?? "")" : box.name
            let item = submenu.addItem(withTitle: title, action: #selector(removeFromMailboxChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (box.id, ids) as (Int64, [Int64])
        }
        let item = NSMenuItem(title: "Remove from Mailbox", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func removeFromMailboxChosen(_ sender: NSMenuItem) {
        guard let (mailboxId, ids) = sender.representedObject as? (Int64, [Int64]) else { return }
        perform(.removeFromMailbox(mailboxId), on: ids)
    }

    /// Archive, Junk and Delete take messages out of the list; select the next one, as MailMate does.
    private func moveAway(_ action: AppModel.MessageAction, ids: [Int64]? = nil) {
        let ids = ids ?? targetIDs
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
        if !other.isEmpty {
            model.moveAcrossAccounts(other, toMailboxId: mailboxId)
            removeLeavingRows(other.map(\.id))
        }
    }

    private func perform(_ action: AppModel.MessageAction, on ids: [Int64]) {
        guard !ids.isEmpty else { return }
        #if DEBUG
            if ProcessInfo.processInfo.environment["MMJ_DEBUG_TIMING"] != nil { NSLog("MMJ timing: action \(action) start") }
        #endif
        registerUndo(for: action, on: ids)
        selectionMarks = nil
        // Marks and flags show in the rows at once.
        for rows in [list, correspondence] {
            switch action {
            case .markRead: rows.showSeen(true, ids: ids)
            case .markUnread: rows.showSeen(false, ids: ids)
            case .flag: rows.showFlagged(true, ids: ids)
            case .unflag: rows.showFlagged(false, ids: ids)
            default: break
            }
        }
        // Smart mailboxes' unread counts too, by the messages it turns read or unread.
        switch action {
        case .markRead, .markUnread:
            let read: Bool = if case .markRead = action { true } else { false }
            if ids.count <= 500 {
                let turning = ((try? model.store.marks(ids: ids)) ?? []).filter { $0.seen != read }.map(\.id)
                sidebar.adjustUnread(of: turning, by: read ? -1 : 1)
            }
        default: break
        }
        model.perform(action, on: ids) { [weak self] count in
            await self?.confirmPermanentDelete(count) ?? false
        }
        removeLeavingRows(ids)
    }

    /// Takes messages an action moved out of the list out of it at once (the store has changed already),
    /// so they go as fast as the keypress whatever the list's size; the list's reload confirms it.
    /// Messages that stay in the list (archived in All Messages, say) stay.
    private func removeLeavingRows(_ ids: [Int64]) {
        let listed = Set(list.ids)
        let shown = ids.filter(listed.contains)
        guard !shown.isEmpty, let staying = try? model.store.ids(shown, in: shownScope) else { return }
        let leaving = Set(shown).subtracting(staying)
        guard !leaving.isEmpty else { return }
        let next = selectAfterMove.flatMap { leaving.isSuperset(of: $0.moved) ? $0.next : nil }
        #if DEBUG
            if ProcessInfo.processInfo.environment["MMJ_DEBUG_TIMING"] != nil { NSLog("MMJ timing: \(leaving.count) rows left the list at once") }
        #endif
        let before = list.selectedIDs
        // The next message when the selection itself went; else the selection stays (a right-clicked
        // message moved away from outside it, say).
        let kept = before.filter { !leaving.contains($0) }
        let selecting = next.map { [$0] } ?? kept
        let remaining = list.ids.filter { !leaving.contains($0) }
        list.setIDs(remaining, selecting: selecting, scroll: list.followingScroll(to: remaining))
        if list.selectedIDs != before {  // the message pane follows the selection, as after a reload
            messageView.show(messageID: list.selectedID, selectionCount: list.selectedIDs.count)
            scheduleCorrespondenceUpdate(for: list.selectedID)
        }
        updateTitle()
    }

    /// Records how to take an action back (Edit → Undo, or u): moves put the messages back in the
    /// mailboxes they were in, marks and flags go back to each message's previous state. Undoing runs
    /// through `perform` again, which records the redo. Deleting for good can't be undone.
    private func registerUndo(for action: AppModel.MessageAction, on ids: [Int64]) {
        guard let undo = window?.undoManager else { return }
        func keyword(_ name: String, _ flagged: Bool, set: AppModel.MessageAction, clear: AppModel.MessageAction) {
            let marks = (try? model.store.marks(ids: ids)) ?? []
            let wasOn = marks.filter { flagged ? $0.flagged : $0.seen }.map(\.id)
            let wasOff = marks.filter { !(flagged ? $0.flagged : $0.seen) }.map(\.id)
            undo.registerUndo(withTarget: self) { target in
                if !wasOn.isEmpty { target.perform(set, on: wasOn) }
                if !wasOff.isEmpty { target.perform(clear, on: wasOff) }
            }
            undo.setActionName(name)
        }
        switch action {
        case .markRead: keyword("Mark as Read", false, set: .markRead, clear: .markUnread)
        case .markUnread: keyword("Mark as Unread", false, set: .markRead, clear: .markUnread)
        case .flag: keyword("Flag", true, set: .flag, clear: .unflag)
        case .unflag: keyword("Unflag", true, set: .flag, clear: .unflag)
        case .keyword, .copy, .deletePermanently: break  // only rules do these
        case .archive, .junk, .notJunk, .delete, .move, .moveToRole, .restoreMailboxes, .removeFromMailbox:
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
            case .removeFromMailbox: undo.setActionName("Remove from Mailbox")
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
            isSearching
        {
            let editor = window.firstResponder as? NSText
            if editor == nil || editor?.delegate === searchField {
                clearSearch()
                return true
            }
        }
        // With no search to clear, Escape ends a thread or correspondence result (as its Cancel does).
        if let window, event.window === window, window.attachedSheet == nil, modifiers.isEmpty, event.keyCode == 53,
            !isSearching, result != nil, !(window.firstResponder is NSText)
        {
            endResult()
            return true
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
        case ("*", "r"): selectRows { seen, _ in seen }
        case ("*", "u"): selectRows { seen, _ in !seen }
        case ("*", "s"): selectRows { _, flagged in flagged }
        case ("*", "t"): selectRows { _, flagged in !flagged }
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
    private func selectRows(where matches: (_ seen: Bool, _ flagged: Bool) -> Bool) {
        let rows = activeList
        let wanted = Set(((try? model.store.marks(ids: rows.ids)) ?? []).filter { matches($0.seen, $0.flagged) }.map(\.id))
        rows.tableView.selectRowIndexes(IndexSet(rows.ids.indices.filter { wanted.contains(rows.ids[$0]) }), byExtendingSelection: false)
    }

    private func goTo(_ key: String) -> Bool {
        sidebar.select(key: key)
    }

    /// v: moves the selected messages to a mailbox (a Unified one moves each into its account's); g then l:
    /// shows a mailbox. Lists as MailMate's picker does: Unified mailboxes, then each account's mailboxes
    /// alphabetically (recently chosen ones first, see `MailboxPicker`).
    fileprivate func pickMailbox(move: Bool, ids: [Int64]? = nil) {
        guard let window else { return }
        let roots = SidebarViewController.currentTree(model: model)
        let boxes = (try? model.store.mailboxes()) ?? []
        let boxByID = Dictionary(boxes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = ids ?? targetIDs
        let accounts = Set(((try? model.store.refs(ids: ids)) ?? []).map(\.accountId))
        if move && accounts.isEmpty { return NSSound.beep() }

        var choices: [MailboxPicker.Choice] = []
        // The Mailboxes section's own, plus the unified mailboxes placed inside smart ones, in sidebar order.
        func listed(_ nodes: [SidebarNode], top: Bool) -> [SidebarNode] {
            nodes.flatMap { node -> [SidebarNode] in
                let inner = node.kind == .smart ? listed(node.children, top: false) : []
                return (top || node.kind == .unified ? [node] : []) + inner
            }
        }
        for node in listed(roots.first(where: { $0.key == "header.mailboxes" })?.children ?? [], top: true) {
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
                    case .mailbox(let id): self.move(ids, toMailboxId: id)
                    case .role("archive"): moveAway(.archive, ids: ids)
                    case .role("junk"): moveAway(.junk, ids: ids)
                    case .role("trash"): moveAway(.delete, ids: ids)
                    case .role(let role): moveAway(.moveToRole(role), ids: ids)
                    default: NSSound.beep()
                    }
                },
                onCreate: { [weak self] name, parent in
                    guard let self, case .mailbox(let parentId)? = parent.node.scope else { return }
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
    @objc func moveToMailbox(_ sender: Any?) { pickMailbox(move: true, ids: menuIDs(sender)) }
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
        let unread = (try? model.store.unreadMessageIDs()) ?? []
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
