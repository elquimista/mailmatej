import AppKit
import MailStore
import MailSync

/// Messages in a window of their own (Return, Enter or File ▸ Open Message on the selection), as
/// MailMate's: its message toolbar (Archive, Junk and Delete; Reply, Reply All and Forward; Flag; Quick
/// Look) over the message, or several stacked as in the main window. Its commands act on its messages
/// through the main window, so the list and the counts change at once, and Undo takes them back from
/// either window.
@MainActor
final class MessageWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSMenuItemValidation {
    /// The windows open, kept while they show.
    private static var shown: [MessageWindowController] = []

    private(set) var messageIDs: [Int64]
    private weak var main: MainWindowController?
    private let model: AppModel
    private let messageView: MessageViewController
    private var keyMonitor: Any?

    /// Shows the messages' window, opening one if they have none.
    static func show(_ ids: [Int64], main: MainWindowController, model: AppModel) {
        guard !ids.isEmpty else { return }
        if let open = shown.first(where: { Set($0.messageIDs) == Set(ids) }) {
            open.showWindow(nil)
            return
        }
        let controller = MessageWindowController(ids: ids, main: main, model: model)
        shown.append(controller)
        controller.showWindow(nil)
    }

    private static let frameKey = "MessageWindowFrame"
    private static let quickLookItem = NSToolbarItem.Identifier("quickLook")

    private init(ids: [Int64], main: MainWindowController, model: AppModel) {
        messageIDs = ids
        self.main = main
        self.model = model
        messageView = MessageViewController(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.toolbarStyle = .expanded  // Title row above the toolbar, as in MailMate.
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)
        updateTitle()
        window.delegate = self
        window.contentViewController = messageView
        place(window)
        let toolbar = NSToolbar(identifier: "MessageToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        // Showing it marks it read, as the main window's message view does.
        messageView.onDisplay = { [weak self] id in self?.main?.showRead(id) }
        messageView.show(messageID: ids.count == 1 ? ids[0] : nil, selection: ids)
        window.initialFirstResponder = messageView.messageKeyView
        installKeys()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The subject, or how many for several (MailMate's words).
    private func updateTitle() {
        if messageIDs.count == 1 {
            let subject = (try? model.store.rows(ids: messageIDs).first?.subject) ?? ""
            window?.title = subject.isEmpty ? "(no subject)" : subject
        } else {
            window?.title = "\(messageIDs.count) messages selected"
        }
    }

    /// Where the last message window was left, the next one a step down and right of any still open.
    private func place(_ window: NSWindow) {
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            window.setFrame(NSRectFromString(saved), display: false)
        } else {
            window.setContentSize(NSSize(width: 800, height: 760))
            window.center()
        }
        if let last = Self.shown.last?.window {
            let topLeft = window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY))
            window.setFrameTopLeftPoint(topLeft)
        }
    }

    private func saveFrame() {
        guard let window, window.isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
    }

    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        Self.shown.removeAll { $0 === self }
    }

    /// The main window's: what's done here undoes there too, and the other way round.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { main?.window?.undoManager }

    /// ⌫ and ⌦ delete the message, as in the main window, while no text is being edited.
    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, event.window === window, window.attachedSheet == nil,
                    !(window.firstResponder is NSText),
                    event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                    event.keyCode == 51 || event.keyCode == 117
                else { return false }
                self.deleteMessages(nil)
                return true
            }
            return handled ? nil : event
        }
    }

    // MARK: Toolbar

    /// MailMate's message toolbar: Archive, Junk and Delete; Reply, Reply All and Forward; Flag; and at
    /// the right, Quick Look (its Tag and Print buttons aren't here: MailMateJ has neither).
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("mailboxActions"), .space, .init("replyActions"), .space, .init("flag"), .flexibleSpace, Self.quickLookItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if let group = MainWindowController.actionGroups.first(where: { $0.id == id }) {
            return main?.actionGroupItem(id, group.buttons, target: self, ids: { [weak self] in self?.messageIDs ?? [] })
        }
        guard id == Self.quickLookItem else { return nil }
        let button = MainWindowController.toolbarButton(symbol: "eye", pointSize: 17, label: "Quick Look", width: 32)
        button.target = self
        button.action = #selector(quickLookAttachments(_:))
        let stack = SeparatedStackView(views: [button])
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 3, bottom: 0, right: 3)
        let item = ValidatingToolbarItem(itemIdentifier: id)
        item.view = stack
        item.label = "Quick Look"
        item.onValidate = { [weak self] in button.isEnabled = self?.messageView.hasAttachments == true }
        return item
    }

    // MARK: Commands

    /// Archive, Junk and Delete move the messages away and show the next one, as MailMate's: the one
    /// after them in the list they're in (else the one before). With none there, the window closes.
    @objc func archiveMessages(_ sender: Any?) { moveAway(.archive) }
    @objc func junkMessages(_ sender: Any?) { moveAway(.junk) }
    @objc func deleteMessages(_ sender: Any?) { moveAway(.delete) }

    private func moveAway(_ action: AppModel.MessageAction) {
        guard let main else { return NSSound.beep() }
        let next = main.message(after: messageIDs)
        main.moveAway(action, ids: messageIDs)
        guard let next else { return close() }
        messageIDs = [next]
        updateTitle()
        messageView.show(messageID: next, selection: [next])
        window?.toolbar?.validateVisibleItems()
    }

    @objc func reply(_ sender: Any?) { compose(.reply) }
    @objc func replyAll(_ sender: Any?) { compose(.replyAll) }
    @objc func forward(_ sender: Any?) { compose(.forward) }

    /// Replying and forwarding act on one message.
    private func compose(_ kind: ComposeKind) {
        guard messageIDs.count == 1 else { return NSSound.beep() }
        model.compose(kind, messageId: messageIDs[0], window: window)
    }

    @objc func toggleFlag(_ sender: Any?) {
        guard let main else { return }
        main.perform(main.allFlagged(messageIDs) ? .unflag : .flag, on: messageIDs)
    }
    @objc func flagMessages(_ sender: Any?) { main?.perform(.flag, on: messageIDs) }
    @objc func unflagMessages(_ sender: Any?) { main?.perform(.unflag, on: messageIDs) }

    @objc func toggleReadState(_ sender: Any?) {
        guard let main else { return }
        main.perform(main.marks(of: messageIDs).anySeen ? .markUnread : .markRead, on: messageIDs)
    }

    @objc func quickLookAttachments(_ sender: Any?) { messageView.quickLookAllAttachments() }
    @objc func saveAttachments(_ sender: Any?) { messageView.saveAllAttachments() }
    @objc func openAttachments(_ sender: Any?) { messageView.openAllAttachments() }
    @objc func showInFinder(_ sender: Any?) {
        guard let id = messageView.displayedMessageID else { return NSSound.beep() }
        model.showInFinder(messageId: id, window: window)
    }
    @objc func toggleRawMessage(_ sender: Any?) { messageView.toggleRawMessage() }
    @objc func findInMessage(_ sender: Any?) { messageView.showFind() }
    @objc func findNextInMessage(_ sender: Any?) { messageView.findNext(forward: true) }
    @objc func findPreviousInMessage(_ sender: Any?) { messageView.findNext(forward: false) }
    @objc func useSelectionForFind(_ sender: Any?) { messageView.useSelectionForFind() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let editing = window?.firstResponder is NSText
        switch item.action {
        case #selector(archiveMessages(_:)), #selector(junkMessages(_:)), #selector(deleteMessages(_:)),
            #selector(flagMessages(_:)), #selector(unflagMessages(_:)):
            return !editing && main != nil
        case #selector(toggleReadState(_:)):
            guard let main else { return false }
            let marks = main.marks(of: messageIDs)
            item.title = marks.count > 0 && !marks.anySeen ? "Mark as Read" : "Mark as Unread"
            return !editing && marks.count > 0
        case #selector(reply(_:)), #selector(replyAll(_:)), #selector(forward(_:)):
            return messageIDs.count == 1 && model.canCompose
        case #selector(showInFinder(_:)):
            return messageView.displayedMessageID != nil
        case #selector(quickLookAttachments(_:)), #selector(saveAttachments(_:)), #selector(openAttachments(_:)):
            return messageView.hasAttachments
        case #selector(toggleRawMessage(_:)):
            item.title = messageView.showsRaw ? "Show Formatted Message" : "Show Raw Message"
            return messageView.displayedMessageID != nil
        case #selector(findInMessage(_:)), #selector(findNextInMessage(_:)), #selector(findPreviousInMessage(_:)),
            #selector(useSelectionForFind(_:)):
            return messageView.showsMessage
        default:
            return true
        }
    }

    #if DEBUG
        static var debugShown: [MessageWindowController] { shown }
        var debugShowing: String { messageView.debugShowing }
        var debugStackIDs: [Int64] { messageView.debugStackIDs }
    #endif
}
