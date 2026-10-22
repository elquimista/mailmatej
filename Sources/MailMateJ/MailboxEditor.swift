import AppKit
import MailStore

/// MailMate's mailbox editor: a window with its own mailbox sidebar and four toolbar tabs. Mailboxes and
/// Conditions define a smart mailbox; Submailboxes splits a smart or unified mailbox; Rules (actions on
/// new messages) comes next. Every change is saved at once, so lists update as you edit.
@MainActor
final class MailboxEditorWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    enum Tab: String, CaseIterable {
        case mailboxes, conditions, submailboxes, rules

        var symbol: String {
            switch self {
            case .mailboxes: "folder"
            case .conditions: "line.3.horizontal.decrease"
            case .submailboxes: "folder.badge.gearshape"
            case .rules: "envelope.arrow.triangle.branch"
            }
        }

        /// MailMate's tooltips.
        var tip: String {
            switch self {
            case .mailboxes: "Mailboxes"
            case .conditions: "Conditions for messages displayed"
            case .submailboxes: "Dynamically displayed submailboxes"
            case .rules: "Rules for applying actions to new messages"
            }
        }

        var identifier: NSToolbarItem.Identifier { .init("tab." + rawValue) }
    }

    private static var shared: MailboxEditorWindowController?

    private let model: AppModel
    private let sidebar: SidebarViewController
    private let content = EditorContentView()
    private var node: SidebarNode?
    private var tab = Tab.mailboxes
    private var storeObserver: Any?

    /// Opens the editor on the sidebar mailbox `key` (a smart mailbox on Mailboxes, or `tab`; others on
    /// Submailboxes), or brings it forward there.
    static func show(key: String, model: AppModel, over parent: NSWindow?, tab: Tab? = nil) {
        let controller = shared ?? MailboxEditorWindowController(model: model)
        shared = controller
        if controller.window?.isVisible != true, let parent, let window = controller.window {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(
                x: frame.midX - window.frame.width / 2, y: frame.maxY - window.frame.height - min(80, frame.height * 0.1)))
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.sidebar.reload()
        _ = controller.sidebar.select(key: key)
        // Selecting what's already selected (the sidebar starts on Inbox) changes nothing: load it directly.
        if controller.node?.key != key, let node = controller.sidebar.node(forKey: key) { controller.edit(node) }
        if let tab { controller.select(tab) }
    }

    private init(model: AppModel) {
        self.model = model
        sidebar = SidebarViewController(model: model)
        sidebar.showsStatus = false
        // MailMate's editor (measured at 1x): 1010 × 607, a 219 pt sidebar.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1010, height: 607),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 700, height: 360)
        window.setFrameAutosaveName("MailboxEditor")
        super.init(window: window)
        window.delegate = self

        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        // MailMate's line under the toolbar crosses the sidebar only once its list is scrolled.
        sidebarItem.titlebarSeparatorStyle = .automatic
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 400
        split.addSplitViewItem(sidebarItem)
        let contentController = NSViewController()
        contentController.view = content
        split.addSplitViewItem(NSSplitViewItem(viewController: contentController))
        window.contentViewController = split
        split.splitView.setPosition(219, ofDividerAt: 0)

        let toolbar = NSToolbar(identifier: "MailboxEditor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.setContentSize(NSSize(width: 1010, height: 607))

        sidebar.onSelect = { [weak self] node in self?.edit(node) }
        storeObserver = NotificationCenter.default.addObserver(forName: .mailStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeDidChange() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    #if DEBUG
        static func debugDumpMailboxMenu() {
            (shared?.content.subviews.first?.subviews.first { $0 is SmartRuleEditor } as? SmartRuleEditor)?.debugDumpMailboxMenu()
        }

        /// Logs the Submailboxes tab's field pop-up: title and top-level items ((off) when greyed out).
        static func debugDumpSplitMenu() {
            guard let popup = shared?.content.subviews.first?.subviews.compactMap({ $0 as? NSPopUpButton }).first, let menu = popup.menu
            else { return NSLog("MMJ split menu: none") }
            var lines: [String] = ["title \(popup.titleOfSelectedItem ?? "") enabled \(popup.isEnabled)"]
            for item in menu.items {
                var line = item.isSeparatorItem ? "---" : item.title
                if !item.isEnabled { line += " (off)" }
                if item.isHidden { line += " (hidden)" }
                if let sub = item.submenu {
                    let names = sub.items.filter { !$0.isSeparatorItem }.map { $0.title + ($0.isEnabled ? "" : "·off") }
                    line += " [" + names.joined(separator: ", ") + "]"
                }
                lines.append(line)
            }
            NSLog("MMJ split menu: " + lines.joined(separator: "\n"))
        }

        static func debugPressAddRule() { (shared?.content.debugPane as? RulesPane)?.debugPressAdd() }

        static func debugClickAddRule() { (shared?.content.debugPane as? RulesPane)?.debugClickAdd() }

        static func debugSelectRule(row: Int) {
            (shared?.content.debugPane as? RulesPane)?.debugSelect(row: row)
        }

        static func debugDuplicateAndUngroup() {
            (shared?.content.subviews.first?.subviews.first { $0 is SmartRuleEditor } as? SmartRuleEditor)?.debugDuplicateAndUngroup()
        }

        static func debugAddRow(text: String) {
            (shared?.content.subviews.first?.subviews.first { $0 is SmartRuleEditor } as? SmartRuleEditor)?.debugAddRow(text: text)
        }

        static func debugHoverTabs() { shared?.tabStrip.debugHover() }

        static func debugScrollSidebar(by points: CGFloat) {
            guard let scroll = shared?.sidebar.view as? NSScrollView else { return }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.origin.y + points))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        static func debugShow(tab name: String) {
            guard let controller = shared, let tab = Tab(rawValue: name) else { return NSLog("MMJ editor: no tab \(name)") }
            controller.select(tab)
        }
    #endif

    func windowWillClose(_ notification: Notification) {
        content.commitEditing()
        Self.shared = nil
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    private func storeDidChange() {
        sidebar.reload()
        // The node may have been renamed or deleted elsewhere.
        if let node, let fresh = sidebar.node(forKey: node.key) {
            if fresh !== node { self.node = fresh }
            updateTitle()
            tabStrip.update(selected: tab, enabled: availableTabs)
        } else if node != nil {
            node = nil
            content.show(nil, tab: tab, model: model)
            updateTitle()
        }
    }

    private func edit(_ node: SidebarNode) {
        content.commitEditing()
        let changedKind = self.node?.kind != node.kind
        self.node = node
        let tabs = availableTabs
        if changedKind || !tabs.contains(tab) {
            tab = node.kind == .smart ? .mailboxes : (tabs.first ?? .rules)
        }
        tabStrip.update(selected: tab, enabled: tabs)
        updateTitle()
        content.show(node, tab: tab, model: model)
    }

    /// Smart mailboxes have every tab (Submailboxes greyed out while they include their submailboxes'
    /// messages); unified ones (Inbox, Flagged, ...) their submailboxes; others rules.
    private var availableTabs: [Tab] {
        switch node?.kind {
        case .smart?:
            guard case .smart(let id)? = node?.scope,
                (try? model.store.smartMailboxes())?.first(where: { $0.id == id })?.definition.sources.includeSubmailboxes == true
            else { return Tab.allCases }
            return Tab.allCases.filter { $0 != .submailboxes }
        // The special mailboxes: their messages come from the accounts, so only Mailboxes is greyed out.
        case .unified?: return [.conditions, .submailboxes, .rules]
        default: return [.rules]
        }
    }

    private func updateTitle() {
        window?.title = node?.title ?? "Mailbox"
        window?.subtitle = switch node?.kind {
        case .smart?: "Smart Mailbox"
        case .unified?: "Unified Mailbox"
        case .account?: "Account"
        case nil: ""
        default: "Mailbox"
        }
    }

    private func select(_ tab: Tab) {
        guard availableTabs.contains(tab) else { return }
        content.commitEditing()
        self.tab = tab
        tabStrip.update(selected: tab, enabled: availableTabs)
        content.show(node, tab: tab, model: model)
    }

    // MARK: Toolbar

    private static let tabsIdentifier = NSToolbarItem.Identifier("tabs")
    private lazy var tabStrip = EditorTabStrip { [weak self] tab in self?.select(tab) }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.tabsIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.tabsIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = tabStrip
        item.label = "Tabs"
        return item
    }
}

/// MailMate's four editor tabs as they look (measured at 1x): 45 pt buttons at a 46 pt pitch, the
/// selected one on a 28 pt rounded highlight, 1 × 20 pt dividers between the others.
@MainActor
private final class EditorTabStrip: NSView {
    typealias Tab = MailboxEditorWindowController.Tab

    private let onSelect: (Tab) -> Void
    private var selected = Tab.mailboxes
    private var enabled = Set(Tab.allCases)
    private var images: [Tab: NSImageView] = [:]
    /// Room left of the buttons and after them, so the strip ends 35 pt from the window's edge as MailMate's.
    private static let trailing: CGFloat = 23

    init(onSelect: @escaping (Tab) -> Void) {
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: 183 + Self.trailing, height: 28))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: frame.width).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        for (index, tab) in Tab.allCases.enumerated() {
            let image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.tip)!
                .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))!  // MailMate's folder: 19 × 14
            let view = NSImageView(image: image)
            view.imageScaling = .scaleNone
            view.frame.size = image.size
            view.frame.origin = NSPoint(
                x: (Self.buttonX(index) + (45 - view.frame.width) / 2).rounded(), y: ((28 - view.frame.height) / 2).rounded())
            addSubview(view)
            images[tab] = view
            addToolTip(NSRect(x: Self.buttonX(index), y: 0, width: 45, height: 28), owner: tab.tip as NSString, userData: nil)
        }
        update(selected: selected, enabled: Tab.allCases)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static func buttonX(_ index: Int) -> CGFloat { CGFloat(index) * 46 }

    func update(selected: Tab, enabled: [Tab]) {
        self.selected = selected
        self.enabled = Set(enabled)
        for (tab, view) in images {
            view.contentTintColor = tab == selected ? .labelColor : .secondaryLabelColor
            view.alphaValue = self.enabled.contains(tab) ? 1 : 0.35  // greyed out, as MailMate's
        }
        needsDisplay = true
    }

    private var hovering = false {
        didSet { if hovering != oldValue { animateHover() } }
    }
    /// How far the hover look is shown, 0…1: it fades in and out as MailMate's does.
    private var hoverAmount: CGFloat = 0
    private var hoverTimer: Timer?

    private func animateHover() {
        hoverTimer?.invalidate()
        let start = hoverAmount, target: CGFloat = hovering ? 1 : 0, began = CACurrentMediaTime()
        let duration = 0.15 * abs(target - start)
        guard duration > 0 else { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = min(1, (CACurrentMediaTime() - began) / duration)
                let eased = t * t * (3 - 2 * t)
                self.hoverAmount = start + (target - start) * eased
                self.needsDisplay = true
                if t >= 1 { self.hoverTimer?.invalidate() }
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: NSRect(x: 0, y: 0, width: 183, height: bounds.height), options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    #if DEBUG
        func debugHover() {
            hovering = true
            hoverTimer?.invalidate()
            hoverAmount = 1
            needsDisplay = true
        }
    #endif
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// As MailMate's (measured at 1x): at rest only the selected button is lit (92 on the toolbar's 78);
    /// hovered, the whole strip takes that fill, the selected button brightens to 119 (1 pt in at top
    /// and bottom) and the dividers to 106.
    override func draw(_ dirtyRect: NSRect) {
        let selectedIndex = Tab.allCases.firstIndex(of: selected) ?? -10
        let h = hoverAmount
        if h > 0 {
            NSColor(white: 1, alpha: 0.06 * h).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 183, height: 28), xRadius: 6, yRadius: 6).fill()
        }
        if selectedIndex >= 0 {
            // At rest the selection is the strip's hover fill; hovered, it brightens over the strip.
            NSColor(white: 1, alpha: 0.06 * (1 - h) + 0.15 * h).setFill()
            let rect = NSRect(x: Self.buttonX(selectedIndex), y: h, width: 45, height: 28 - 2 * h)
            NSBezierPath(roundedRect: rect, xRadius: 6 - h, yRadius: 6 - h).fill()
        }
        // A divider between each pair of buttons, except beside the selected one (as a segmented control).
        NSColor(white: 1, alpha: 0.075 + 0.01 * h).setFill()
        for index in 1..<Tab.allCases.count where index != selectedIndex && index != selectedIndex + 1 {
            NSRect(x: Self.buttonX(index) - 1, y: 4, width: 1, height: 20).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.x / 46)
        guard index >= 0, index < Tab.allCases.count, point.x - Self.buttonX(index) < 45 else { return }
        let tab = Tab.allCases[index]
        if enabled.contains(tab) { onSelect(tab) }
    }
}

// MARK: - Content

/// The editor's right side: the selected tab's pane for the selected mailbox.
@MainActor
private final class EditorContentView: NSView {
    private var pane: EditorPane?

    override var isFlipped: Bool { true }

    func commitEditing() { pane?.commit() }

    #if DEBUG
        var debugPane: EditorPane? { pane }
    #endif

    // The window's content runs under the toolbar: panes start below it.
    override func layout() {
        super.layout()
        pane?.view.frame = NSRect(x: 0, y: safeAreaInsets.top, width: bounds.width, height: bounds.height - safeAreaInsets.top)
    }

    func show(_ node: SidebarNode?, tab: MailboxEditorWindowController.Tab, model: AppModel) {
        pane?.commit()
        pane?.view.removeFromSuperview()
        pane = nil
        guard let node else { return }
        let made: EditorPane? = switch (tab, node.scope) {
        case (.mailboxes, .smart(let id)?): SmartRulesPane(kind: .sources, smartID: id, model: model)
        case (.conditions, .smart(let id)?): SmartRulesPane(kind: .conditions, smartID: id, model: model)
        case (.conditions, let scope?) where node.kind == .unified:
            SmartRulesPane(kind: .conditions, smartID: -1, model: model, specialKey: scope.key)
        case (.submailboxes, .smart(let id)?): SmartSubmailboxesPane(smartID: id, model: model)
        case (.submailboxes, _) where node.kind == .unified: UnifiedSubmailboxesPane(key: node.key)
        default: node.scope.map { RulesPane(mailboxKey: $0.key, model: model) }
        }
        guard let made else { return }
        pane = made
        made.view.frame = NSRect(x: 0, y: safeAreaInsets.top, width: bounds.width, height: bounds.height - safeAreaInsets.top)
        made.view.autoresizingMask = [.width, .height]
        addSubview(made.view)
    }
}

@MainActor
protocol EditorPane: AnyObject {
    var view: NSView { get }
    /// Saves edits still pending (text being typed).
    func commit()
}

/// MailMate's small labels above the rule editors ("Hold down ⌥ to create compounds"): 11 pt.
func smallLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    label.textColor = .labelColor
    return label
}

final class EditorFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: Mailboxes and Conditions

/// The Mailboxes tab (which mailboxes' messages) or the Conditions tab (which of them to show): a rule
/// editor, saved on every change.
@MainActor
private final class SmartRulesPane: EditorPane {
    let view: NSView = EditorFlippedView()
    private let smartID: Int64
    /// A special mailbox's key ("role:inbox", "all") when editing its conditions instead of a smart mailbox's.
    private let specialKey: String?
    private let model: AppModel
    private let kind: SmartRuleEditor.Kind
    private let editor: SmartRuleEditor
    private let includeSubmailboxes = NSButton(
        checkboxWithTitle: "Include messages in any submailboxes of this mailbox", target: nil, action: nil)
    private var pendingSave: DispatchWorkItem?

    init(kind: SmartRuleEditor.Kind, smartID: Int64, model: AppModel, specialKey: String? = nil) {
        self.kind = kind
        self.smartID = smartID
        self.specialKey = specialKey
        self.model = model
        editor = SmartRuleEditor(kind: kind, context: SmartRuleContext(model: model, editing: smartID, mailboxKey: specialKey))
        let record = (try? model.store.smartMailboxes())?.first { $0.id == smartID }
        let definition = record?.definition ?? SmartDefinition()

        // Measured at 1x: the checkbox and hint 28 pt down, the editor 49 pt down, 20 pt margins.
        view.frame = NSRect(x: 0, y: 0, width: 733, height: 500)
        // As MailMate: offered only while the Submailboxes tab splits nothing (that tab is greyed out
        // while it's on).
        if kind == .sources, !definition.split.splits {
            includeSubmailboxes.controlSize = .small
            includeSubmailboxes.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            includeSubmailboxes.state = definition.sources.includeSubmailboxes ? .on : .off
            includeSubmailboxes.target = self
            includeSubmailboxes.action = #selector(changed)
            includeSubmailboxes.sizeToFit()
            includeSubmailboxes.frame.origin = NSPoint(x: 18, y: 28)
            view.addSubview(includeSubmailboxes)
        }
        let hint = smallLabel("Hold down \u{2325} to create compounds")
        hint.sizeToFit()
        hint.frame.origin = NSPoint(x: view.bounds.width - 20 - hint.frame.width, y: 28)
        hint.autoresizingMask = [.minXMargin]
        view.addSubview(hint)

        editor.frame = NSRect(x: 20, y: 49, width: view.bounds.width - 40, height: editor.frame.height)
        editor.autoresizingMask = [.width]
        editor.onChange = { [weak self] immediate in self?.scheduleSave(immediate: immediate) }
        view.addSubview(editor)
        editor.load(specialKey.map { model.store.specialCondition(key: $0) }
            ?? (kind == .sources ? definition.sources.root : definition.condition))
    }

    @objc private func changed() { scheduleSave(immediate: true) }

    /// Popups and buttons save at once; typing waits for a pause.
    private func scheduleSave(immediate: Bool) {
        pendingSave?.cancel()
        guard !immediate else { return save() }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func commit() {
        if pendingSave != nil {
            pendingSave?.cancel()
            save()
        }
    }

    private func save() {
        pendingSave = nil
        if let specialKey, let tree = editor.tree() { return model.setSpecialCondition(tree, key: specialKey) }
        guard var definition = (try? model.store.smartMailboxes())?.first(where: { $0.id == smartID })?.definition,
            let tree = editor.tree()
        else { return }
        switch kind {
        case .sources:
            definition.sources.root = tree
            if includeSubmailboxes.superview != nil { definition.sources.includeSubmailboxes = includeSubmailboxes.state == .on }
        case .conditions: definition.condition = tree
        }
        model.updateSmartMailbox(id: smartID, definition: definition)
    }
}

// MARK: Submailboxes

/// The Submailboxes tab, laid out as MailMate's (measured at 1x): rows centred at 28 and 55 pt, a
/// separator, then "each account".
@MainActor
private class SubmailboxesLayout {
    let view: NSView = EditorFlippedView()
    let byValue = NSButton(checkboxWithTitle: "Submailbox for each unique value of", target: nil, action: nil)
    let valuePopup = NSPopUpButton()
    let unlessOne = NSButton(checkboxWithTitle: "Unless only one submailbox will be created", target: nil, action: nil)
    let byAccount = NSButton(checkboxWithTitle: "Submailbox for the messages of each account", target: nil, action: nil)

    init(values: [(title: String, id: String)], target: AnyObject, action: Selector) {
        let width: CGFloat = 733
        view.frame = NSRect(x: 0, y: 0, width: width, height: 500)
        func place(_ v: NSView, _ frame: NSRect, stretch: Bool = false) {
            v.frame = frame
            if stretch { v.autoresizingMask = [.width] }
            view.addSubview(v)
        }
        byValue.sizeToFit()
        place(byValue, NSRect(x: 18, y: 19, width: byValue.frame.width, height: 18))
        for value in values {
            valuePopup.addItem(withTitle: value.title)
            valuePopup.lastItem?.representedObject = value.id
        }
        place(valuePopup, NSRect(x: 269, y: 15, width: 154, height: 25))  // Shows 150 pt at 271.
        unlessOne.sizeToFit()
        place(unlessOne, NSRect(x: 36, y: 46, width: unlessOne.frame.width, height: 18))
        // (MailMate's name format row, removed here, sat between: the rest moves up its 27 pt.)
        let separator = NSBox()
        separator.boxType = .separator
        place(separator, NSRect(x: 20, y: 73, width: width - 40, height: 1), stretch: true)
        byAccount.sizeToFit()
        place(byAccount, NSRect(x: 18, y: 81, width: byAccount.frame.width, height: 18))
        for control in [byValue, valuePopup, unlessOne, byAccount] as [NSControl] {
            control.target = target
            control.action = action
        }
    }

    func update(byValue on: Bool, value: String, unlessOnlyOne: Bool, byAccount account: Bool) {
        byValue.state = on ? .on : .off
        unlessOne.state = unlessOnlyOne ? .on : .off
        byAccount.state = account ? .on : .off
        if let item = valuePopup.itemArray.first(where: { $0.representedObject as? String == value }) { valuePopup.select(item) }
        valuePopup.isEnabled = on
        unlessOne.isEnabled = on
    }
}

@MainActor
private final class SmartSubmailboxesPane: NSObject, EditorPane {
    private var layout: SubmailboxesLayout!
    private let smartID: Int64
    private let model: AppModel
    var view: NSView { layout.view }

    init(smartID: Int64, model: AppModel) {
        self.smartID = smartID
        self.model = model
        super.init()
        layout = SubmailboxesLayout(values: [], target: self, action: #selector(changed))
        fieldMenu = FieldMenu { [weak self] id in self?.fieldChosen(id) }
        refresh()
    }

    /// MailMate's: the same field menu as the Conditions tab, with what can't split greyed out.
    private var fieldMenu: FieldMenu!

    private func fieldChosen(_ id: String) {
        let parts = id.split(separator: "|").map(String.init)
        guard parts.count == 2 else { return }
        var definition = self.definition
        definition.split.field = SmartField(rawValue: parts[1])
        model.updateSmartMailbox(id: smartID, definition: definition)
        refresh()
    }

    private var definition: SmartDefinition {
        (try? model.store.smartMailboxes())?.first { $0.id == smartID }?.definition ?? SmartDefinition()
    }

    private func refresh() {
        let split = definition.split
        fieldMenu.install(
            in: layout.valuePopup, current: FieldMenu.id(field: split.field), title: FieldMenu.title(field: split.field),
            enabled: { id in
                let parts = id.split(separator: "|").map(String.init)
                return parts.count == 2 && MailStore.canSplit(by: SmartField(rawValue: parts[1]))
            })
        layout.update(
            byValue: split.byValue, value: split.field.rawValue, unlessOnlyOne: split.unlessOnlyOne, byAccount: split.byAccount)
    }

    @objc private func changed() { save() }

    func commit() {}

    private func save() {
        var definition = self.definition
        definition.split.byValue = layout.byValue.state == .on  // the field is set by its menu
        definition.split.unlessOnlyOne = layout.unlessOne.state == .on
        definition.split.byAccount = layout.byAccount.state == .on
        model.updateSmartMailbox(id: smartID, definition: definition)
        refresh()
    }
}

/// Submailboxes of a unified mailbox (Inbox, Flagged, All Messages, ...): by account or by source.
@MainActor
private final class UnifiedSubmailboxesPane: NSObject, EditorPane {
    private var layout: SubmailboxesLayout!
    private let key: String
    private var settings: SubmailboxSettings
    var view: NSView { layout.view }

    init(key: String) {
        self.key = key
        settings = SubmailboxSettings.settings(for: key)
        super.init()
        layout = SubmailboxesLayout(
            values: SubmailboxSettings.Value.allCases.map { ($0.title, $0.rawValue) }, target: self, action: #selector(changed))
        refresh()
    }

    private func refresh() {
        layout.update(
            byValue: settings.bySource, value: settings.value.rawValue, unlessOnlyOne: settings.unlessOnlyOne,
            byAccount: settings.byAccount)
        layout.unlessOne.isEnabled = settings.splits
    }

    @objc private func changed() {
        settings.bySource = layout.byValue.state == .on
        settings.value = (layout.valuePopup.selectedItem?.representedObject as? String).flatMap(SubmailboxSettings.Value.init) ?? .account
        settings.unlessOnlyOne = layout.unlessOne.state == .on
        settings.byAccount = layout.byAccount.state == .on
        save()
    }

    func commit() {}

    private func save() {
        SubmailboxSettings.save(settings, for: key)
        refresh()
    }
}
