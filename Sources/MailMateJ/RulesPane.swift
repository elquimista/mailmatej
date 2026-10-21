import AppKit
import MailStore

/// MailMate's Rules tab (measured at 1x): the mailbox's rules in a 209 pt list with a black edge on its
/// right, each with a checkbox, and a +, −, ⋯ bar; beside it a box from 238 pt to 20 pt from the right.
/// With no rule chosen the box offers "Create Rule…". A rule shows its Description, Conditions and
/// Actions; edits wait for Commit (or Revert), as in MailMate, but the list's checkboxes apply at once.
@MainActor
final class RulesPane: NSObject, EditorPane, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    let view: NSView = EditorFlippedView()
    private let mailboxKey: String
    private let model: AppModel
    private var rules: [RuleRecord] = []
    private var selectedID: Int64?

    /// Rules with their subrules nested under them (always open).
    private let table = RuleOutlineView()
    private let bar = RulesButtonBar(frame: .zero)
    private let box = NSBox()
    private let detail = EditorFlippedView()
    private let createButton = NSButton(title: "Create Rule\u{2026}", target: nil, action: nil)

    // The chosen rule's editors.
    private let descriptionField = NSTextField()
    private var conditions: SmartRuleEditor?
    private var actions: RuleActionEditor?
    private let conditionsLabel = NSTextField(labelWithString: "Conditions:")
    private let actionsLabel = NSTextField(labelWithString: "Actions:")
    private let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    private let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    private var dirty = false {
        didSet {
            revertButton.isEnabled = dirty
            commitButton.isEnabled = dirty
        }
    }

    init(mailboxKey: String, model: AppModel) {
        self.mailboxKey = mailboxKey
        self.model = model
        super.init()
        view.frame = NSRect(x: 0, y: 0, width: 789, height: 541)

        let column = NSTableColumn(identifier: .init("rule"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.outlineTableColumn = column
        table.indentationPerLevel = 18
        table.headerView = nil
        table.rowHeight = 24
        table.intercellSpacing = .zero
        table.backgroundColor = SmartRuleEditor.rowFill.blended(withFraction: 0.08, of: .black) ?? SmartRuleEditor.rowFill
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = table.backgroundColor
        scroll.frame = NSRect(x: 21, y: 21, width: 207, height: view.bounds.height - 42 - RulesButtonBar.height)
        scroll.autoresizingMask = [.height]
        let listBorder = NSBox()
        listBorder.boxType = .custom
        listBorder.borderColor = NSColor(white: 1, alpha: 0.07)
        listBorder.fillColor = .clear
        listBorder.frame = NSRect(x: 20, y: 20, width: 210, height: view.bounds.height - 40)
        listBorder.autoresizingMask = [.height]
        let edge = NSBox()
        edge.boxType = .custom
        edge.borderWidth = 0
        edge.fillColor = .black
        edge.frame = NSRect(x: 229, y: 20, width: 1, height: view.bounds.height - 40)
        edge.autoresizingMask = [.height]
        bar.frame = NSRect(x: 20, y: view.bounds.height - 20 - RulesButtonBar.height, width: 209, height: RulesButtonBar.height)
        bar.autoresizingMask = [.minYMargin]
        bar.onAdd = { [weak self] in self?.createRule() }
        bar.onRemove = { [weak self] in self?.removeRule() }
        bar.menuItems = { [weak self] in self?.actionMenuItems() ?? [] }
        for v in [scroll, listBorder, edge, bar] as [NSView] { view.addSubview(v) }

        box.boxType = .custom
        box.borderColor = .separatorColor
        box.fillColor = .clear
        box.contentViewMargins = .zero
        box.frame = NSRect(x: 238, y: 20, width: view.bounds.width - 258, height: view.bounds.height - 40)
        box.autoresizingMask = [.width, .height]
        view.addSubview(box)
        detail.frame = box.contentView?.bounds ?? .zero
        detail.autoresizingMask = [.width, .height]
        box.contentView?.addSubview(detail)

        createButton.target = self
        createButton.action = #selector(createClicked)
        createButton.sizeToFit()
        revertButton.target = self
        revertButton.action = #selector(revertClicked)
        commitButton.target = self
        commitButton.action = #selector(commitClicked)
        commitButton.keyEquivalent = "\r"
        descriptionField.delegate = self
        reload(select: nil)
    }

    func commit() { if dirty { save() } }

    #if DEBUG
        /// Clicks the bar's + (as the mouse would), then logs the rules.
        func debugClickAdd() {
            bar.debugClick(0)
            NSLog("MMJ rules after +: \(rules.map(\.definition.name)), selected \(selected?.definition.name ?? "none")")
        }

        func debugPressAdd() { bar.debugPress(0) }

        /// Selects the rule in row `row`, as a click in the list would.
        func debugSelect(row: Int) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
    #endif

    // MARK: Rules

    private func reload(select id: Int64?) {
        rules = (try? model.store.rules(mailboxKey: mailboxKey)) ?? []
        table.reloadData()
        table.expandItem(nil, expandChildren: true)
        let target = id.map { table.row(forItem: NSNumber(value: $0)) } ?? -1
        if target >= 0 {
            table.selectRowIndexes([target], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        selectedID = target >= 0 ? id : nil
        showSelected()
    }

    private func children(of parent: Int64?) -> [RuleRecord] { rules.filter { $0.parentId == parent } }

    private var selected: RuleRecord? { selectedID.flatMap { id in rules.first { $0.id == id } } }

    private func createRule(inside parent: Int64? = nil) {
        commit()
        // MailMate's new rule: empty (no description, conditions or actions).
        let definition = RuleDefinition(name: "", actions: [])
        guard let id = try? model.store.createRule(mailboxKey: mailboxKey, parentId: parent, definition: definition) else { return }
        reload(select: id)
        view.window?.makeFirstResponder(descriptionField)
        descriptionField.currentEditor()?.selectAll(nil)
    }

    private func removeRule() {
        guard let rule = selected else { return }
        try? model.store.deleteRule(id: rule.id)
        dirty = false
        reload(select: nil)
    }

    @objc private func createClicked() { createRule() }

    /// MailMate's ⋯ menu: Duplicate, Add Subrule…, Remove.
    private func actionMenuItems() -> [NSMenuItem] {
        let items: [(String, Selector)] = [
            ("Duplicate", #selector(duplicateRule)), ("Add Subrule\u{2026}", #selector(addSubrule)), ("Remove", #selector(removeClicked)),
        ]
        return items.map { title, action in
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = selected != nil
            return item
        }
    }

    @objc private func duplicateRule() {
        commit()
        guard let rule = selected, let id = try? model.store.duplicateRule(id: rule.id) else { return }
        reload(select: id)
    }

    /// A new, empty rule inside the chosen one: it runs on the messages its parent matched.
    @objc private func addSubrule() {
        guard let rule = selected else { return }
        createRule(inside: rule.id)
    }

    @objc private func removeClicked() { removeRule() }

    // MARK: List

    // Items are rule ids (NSNumber), so they stay the same across reloads.
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: (item as? NSNumber)?.int64Value).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        NSNumber(value: children(of: (item as? NSNumber)?.int64Value)[index].id)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !children(of: (item as? NSNumber)?.int64Value).isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let id = (item as? NSNumber)?.int64Value, let rule = rules.first(where: { $0.id == id }) else { return nil }
        let cell = RuleListCell()
        cell.checkbox.state = rule.definition.enabled ? .on : .off
        cell.checkbox.target = self
        cell.checkbox.action = #selector(ruleToggled(_:))
        cell.checkbox.tag = Int(id)
        cell.name.stringValue = rule.definition.name.isEmpty ? "Untitled" : rule.definition.name
        cell.name.textColor = rule.definition.name.isEmpty ? .tertiaryLabelColor : .labelColor
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let id = (table.item(atRow: table.selectedRow) as? NSNumber)?.int64Value
        guard id != selectedID else { return }
        commit()  // a change left uncommitted is kept rather than lost
        selectedID = id
        showSelected()
    }

    /// The list's checkboxes turn a rule on or off at once.
    @objc private func ruleToggled(_ sender: NSButton) {
        guard let index = rules.firstIndex(where: { $0.id == Int64(sender.tag) }) else { return }
        rules[index].definition.enabled = sender.state == .on
        try? model.store.updateRule(id: rules[index].id, definition: rules[index].definition)
    }

    // MARK: Detail

    private func showSelected() {
        detail.subviews.forEach { $0.removeFromSuperview() }
        conditions = nil
        actions = nil
        bar.canRemove = selected != nil
        guard let rule = selected else {
            createButton.frame.origin = NSPoint(
                x: ((detail.bounds.width - createButton.frame.width) / 2).rounded(),
                y: ((detail.bounds.height - createButton.frame.height) / 2).rounded())
            createButton.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            detail.addSubview(createButton)
            return
        }
        let label = NSTextField(labelWithString: "Description:")
        label.sizeToFit()
        descriptionField.stringValue = rule.definition.name
        let conditionsEditor = SmartRuleEditor(
            kind: .conditions, context: SmartRuleContext(model: model, editing: -1, mailboxKey: mailboxKey))
        conditionsEditor.onChange = { [weak self] _ in self?.changed() }
        conditionsEditor.onResize = { [weak self] in self?.layoutDetail() }
        conditionsEditor.load(rule.definition.condition)
        let actionsEditor = RuleActionEditor(context: SmartRuleContext(model: model, editing: -1, mailboxKey: mailboxKey))
        actionsEditor.onChange = { [weak self] in self?.changed() }
        actionsEditor.onResize = { [weak self] in self?.layoutDetail() }
        actionsEditor.load(rule.definition.actions)
        conditionsLabel.sizeToFit()
        actionsLabel.sizeToFit()
        for b in [revertButton, commitButton] { b.sizeToFit() }
        for v in [label, descriptionField, conditionsLabel, conditionsEditor, actionsLabel, actionsEditor, revertButton, commitButton] as [NSView] {
            detail.addSubview(v)
        }
        descriptionLabel = label
        conditions = conditionsEditor
        actions = actionsEditor
        dirty = false
        layoutDetail()
    }

    private var descriptionLabel: NSTextField?

    /// MailMate's positions in the box (measured at 1x): labels 20 pt in; the editors 20 pt in to 28 pt
    /// from the right; the description field from 103 pt, its top 21 pt down; "Conditions:" 52 pt down,
    /// its editor 73; "Actions:" 15 pt under that editor, its editor 33; Revert and Commit 20 pt up from
    /// the bottom.
    private func layoutDetail() {
        guard let conditions, let actions, let descriptionLabel else { return }
        let width = detail.bounds.width
        descriptionField.frame = NSRect(x: 102, y: 19, width: width - 102 - 27, height: 21)
        descriptionLabel.frame.origin = NSPoint(x: 16, y: 21)
        conditionsLabel.frame.origin = NSPoint(x: 16, y: 48)
        conditions.frame = NSRect(x: 19, y: 72, width: width - 19 - 27, height: conditions.frame.height)
        actionsLabel.frame.origin = NSPoint(x: 16, y: conditions.frame.maxY + 8)
        actions.frame = NSRect(x: 19, y: conditions.frame.maxY + 32, width: width - 19 - 27, height: actions.frame.height)
        commitButton.frame.size.width = max(commitButton.frame.width, 70)
        revertButton.frame.size.width = max(revertButton.frame.width, 62)
        let buttonY = detail.bounds.height - 20 - commitButton.frame.height + 8
        commitButton.frame.origin = NSPoint(x: width - 27 - commitButton.frame.width + 7, y: buttonY)
        revertButton.frame.origin = NSPoint(x: commitButton.frame.minX - 9 - revertButton.frame.width + 4, y: buttonY)
    }

    private func changed() { dirty = true }

    func controlTextDidChange(_ obj: Notification) { changed() }

    @objc private func revertClicked() {
        dirty = false
        showSelected()
    }

    @objc private func commitClicked() { save() }

    private func save() {
        guard var rule = selected, let conditions, let actions else { return }
        rule.definition.name = descriptionField.stringValue
        rule.definition.condition = conditions.tree() ?? .compound(.all, [])
        rule.definition.actions = actions.actions()
        try? model.store.updateRule(id: rule.id, definition: rule.definition)
        dirty = false
        rules = (try? model.store.rules(mailboxKey: mailboxKey)) ?? rules
        table.reloadItem(NSNumber(value: rule.id))
    }
}

/// The rule list, always fully open: subrules indent under their rule, with no disclosure triangles.
/// Rows keep MailMate's positions (a top-level rule's checkbox 18 pt in), taking the room AppKit keeps
/// for the triangles.
private final class RuleOutlineView: NSOutlineView {
    static let shift: CGFloat = 17

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var frame = super.frameOfCell(atColumn: column, row: row)
        frame.origin.x -= Self.shift
        frame.size.width += Self.shift
        return frame
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
}

/// A rule in the list: its checkbox and description (measured at 1x: checkbox 18 pt in, name at 41).
private final class RuleListCell: NSTableCellView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let name = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        name.translatesAutoresizingMaskIntoConstraints = false
        name.lineBreakMode = .byTruncatingTail
        addSubview(checkbox)
        addSubview(name)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 40),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The rule list's button bar, as MailMate draws it: a lighter strip with +, − and an action menu
/// (⋯ ⌄), each segment divided by a line. − works when a rule is chosen.
final class RulesButtonBar: NSView {
    var onAdd: () -> Void = {}
    var onRemove: () -> Void = {}
    var menuItems: () -> [NSMenuItem] = { [] }
    var canRemove = false {
        didSet {
            buttons[1].isEnabled = canRemove
            updateTints()
        }
    }

    /// MailMate's segments (measured at 1x, its left border included): 32, 32, 43 pt, in a 21 pt bar.
    private static let segments: [(symbols: [String], width: CGFloat)] = [
        (["plus"], 32), (["minus"], 32), (["ellipsis.circle", "chevron.down"], 43),
    ]
    static let height: CGFloat = 21

    private static let minusImage: NSImage = {
        let image = NSImage(size: NSSize(width: 11, height: 11), flipped: true) { _ in
            NSColor.black.setFill()
            NSRect(x: 0, y: 5, width: 11, height: 1).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
    private var buttons: [NSButton] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        var x: CGFloat = 0
        for (index, segment) in Self.segments.enumerated() {
            let button = BarSegmentButton(frame: NSRect(x: x, y: 0, width: segment.width, height: Self.height))
            button.isBordered = false
            button.title = ""
            button.target = self
            button.action = #selector(clicked(_:))
            button.tag = index
            button.toolTip = ["Add Rule", "Remove Rule", "Actions"][index]
            addSubview(button)
            buttons.append(button)
            // Each segment's symbols, centred in it.
            // MailMate's glyphs (measured at 1x): + and ⋯ 11–13 px, the chevron 7 px, at their natural size.
            let images = segment.symbols.map { symbol -> NSImageView in
                let size: CGFloat = symbol == "chevron.down" ? 9 : 13
                // MailMate's − is a crisp 11 × 1 line, which no symbol size draws.
                let image = symbol == "minus" ? Self.minusImage : NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
                    .withSymbolConfiguration(.init(pointSize: size, weight: symbol == "chevron.down" ? .semibold : .regular))!
                let view = NSImageView(image: image)
                view.imageScaling = .scaleNone
                view.frame.size = image.size
                return view
            }
            let gap: CGFloat = 2
            let total = images.reduce(0) { $0 + $1.frame.width } + CGFloat(images.count - 1) * gap
            var left = ((segment.width - total) / 2).rounded() - (index == 2 ? 0 : 1)  // MailMate's, to the pixel
            for image in images {
                image.frame.origin = NSPoint(x: left, y: ((Self.height - image.frame.height) / 2).rounded())
                button.addSubview(image)
                left += image.frame.width + gap
            }
            x += segment.width
        }
        canRemove = false
        updateTints()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTints() {
        for button in buttons {
            for case let image as NSImageView in button.subviews {
                // As MailMate's: white when it works, dim when it doesn't (− with no rule chosen).
                image.contentTintColor = button.isEnabled ? .labelColor : .tertiaryLabelColor
            }
        }
    }

    override func layout() {
        super.layout()
        updateTints()
    }

    #if DEBUG
        func debugClick(_ index: Int) { buttons[index].performClick(nil) }
        func debugPress(_ index: Int) { buttons[index].highlight(true) }
    #endif

    @objc private func clicked(_ sender: NSButton) {
        switch sender.tag {
        case 0: onAdd()
        case 1: onRemove()
        default:
            let menu = NSMenu()
            menu.autoenablesItems = false
            menuItems().forEach(menu.addItem)
            menu.popUp(positioning: nil, at: NSPoint(x: sender.frame.minX, y: sender.frame.maxY + 2), in: self)
        }
        updateTints()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.303, alpha: 1).setFill()  // shows as MailMate's 97
        bounds.fill()
        NSColor(white: 0.413, alpha: 1).setFill()  // the top edge, 123
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSColor(white: 0.395, alpha: 1).setFill()  // the other edges and the dividers, 119
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        var x: CGFloat = 0
        for segment in Self.segments {
            x += segment.width
            NSRect(x: x - 1, y: 0, width: 1, height: bounds.height).fill()
        }
    }
}

/// A segment of the bar: shows it's being pressed (a lighter fill while the mouse is down), as MailMate's.
private final class BarSegmentButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted, isEnabled {
            NSColor(white: 1, alpha: 0.16).setFill()
            NSRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 2).fill()
        }
        super.draw(dirtyRect)
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }
}

/// A rule's Actions, drawn as the conditions are (25 pt rows in a box): a checkbox, the action
/// (MailMate's 137 pt pop-up), its value (a 110 pt keyword pop-up, or a mailbox), ⊖ ⊕. ⊕ copies the row.
@MainActor
final class RuleActionEditor: NSView, NSTextFieldDelegate {
    var onChange: () -> Void = {}
    var onResize: () -> Void = {}

    @MainActor private final class Row {
        var action: RuleAction
        var controls: [NSView] = []
        let minus = NSButton()
        let plus = NSButton()
        var mailboxMenu: MailboxMenu?
        init(_ action: RuleAction) { self.action = action }
    }

    private let context: SmartRuleContext
    private var rows: [Row] = []
    /// ⊕ for an empty list ("No actions added").
    private let emptyPlus = NSButton()

    override var isFlipped: Bool { true }

    init(context: SmartRuleContext) {
        self.context = context
        super.init(frame: NSRect(x: 0, y: 0, width: 500, height: 26))
        emptyPlus.bezelStyle = .roundRect
        emptyPlus.controlSize = .small
        emptyPlus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        emptyPlus.imagePosition = .imageOnly
        emptyPlus.target = self
        emptyPlus.action = #selector(addFirst)
        emptyPlus.frame.size = NSSize(width: 18, height: 17)
        addSubview(emptyPlus)
    }

    @objc private func addFirst() {
        rows = [Row(RuleAction(kind: .setKeyword, value: RuleKeyword.seen.rawValue))]
        rebuild()
        onChange()
    }

    required init?(coder: NSCoder) { fatalError() }

    func load(_ actions: [RuleAction]) {
        rows.forEach(clear)
        rows = actions.map(Row.init)
        rebuild()
    }

    func actions() -> [RuleAction] { rows.map(\.action) }

    private func clear(_ row: Row) {
        (row.controls + [row.minus, row.plus]).forEach { $0.removeFromSuperview() }
        row.controls = []
        row.mailboxMenu = nil
    }

    private func rebuild() {
        for row in rows { build(row) }
        layoutRows()
    }

    private func build(_ row: Row) {
        clear(row)
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxChanged(_:)))
        box.controlSize = .small
        box.state = row.action.enabled ? .on : .off
        box.sizeToFit()
        row.controls.append(box)
        row.controls.append(kindPopup(row.action.kind))
        switch row.action.kind.value {
        case .keyword:
            row.controls.append(keywordPopup(selected: row.action.value))
        case .mailbox:
            row.controls.append(mailboxPopup(row))
        case .address:
            let field = NSTextField(string: row.action.value)
            field.controlSize = .small
            field.font = SmartRuleEditor.font
            field.placeholderString = "Address"
            field.delegate = self
            field.frame.size = NSSize(width: 173, height: 19)
            row.controls.append(field)
        case .none: break
        }
        for (button, symbol, action) in [(row.minus, "minus", #selector(minusClicked(_:))), (row.plus, "plus", #selector(plusClicked(_:)))] {
            button.bezelStyle = .roundRect
            button.controlSize = .small
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol == "plus" ? "Add" : "Remove")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            button.imagePosition = .imageOnly
            button.target = self
            button.action = action
            button.frame.size = NSSize(width: 18, height: 17)
        }
        for view in row.controls + [row.minus, row.plus] { addSubview(view) }
    }

    /// MailMate's action menu (from its screenshot, without Export, Play Sound and Run Command), its
    /// groups separated, at its 137 pt.
    private func kindPopup(_ kind: RuleAction.Kind) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.bezelStyle = .roundRect
        popup.controlSize = .small
        popup.font = SmartRuleEditor.font
        for (index, group) in RuleAction.Kind.menuGroups.enumerated() {
            if index > 0 { popup.menu?.addItem(.separator()) }
            for item in group {
                popup.addItem(withTitle: item.title)
                popup.lastItem?.representedObject = item.rawValue
            }
        }
        if !RuleAction.Kind.menuGroups.joined().contains(kind) {  // Archive or Junk from an older rule
            popup.addItem(withTitle: kind.title)
            popup.lastItem?.representedObject = kind.rawValue
            popup.lastItem?.isHidden = true
        }
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == kind.rawValue }) { popup.select(item) }
        popup.target = self
        popup.action = #selector(kindChanged(_:))
        popup.sizeToFit()
        popup.frame.size.width = 137
        return popup
    }

    /// MailMate's keyword menu: "Standard" (Seen (Read) … Not junk), then "Other", every other keyword
    /// on the mail, A to Z. At MailMate's 110 pt.
    private func keywordPopup(selected: String) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.bezelStyle = .roundRect
        popup.controlSize = .small
        popup.font = SmartRuleEditor.font
        popup.menu?.autoenablesItems = false
        func add(_ title: String, _ value: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = value
            popup.menu?.addItem(item)
            if value == selected { popup.select(item) }
        }
        popup.menu?.addItem(.sectionHeader(title: "Standard"))
        for keyword in RuleKeyword.allCases { add(keyword.title, keyword.rawValue) }
        let others = context.otherKeywords
        if !others.isEmpty {
            popup.menu?.addItem(.sectionHeader(title: "Other"))
            for keyword in others { add(keyword, keyword) }
        }
        if popup.selectedItem?.representedObject as? String != selected, !selected.isEmpty { add(selected, selected) }
        popup.target = self
        popup.action = #selector(valueChanged(_:))
        popup.sizeToFit()
        popup.frame.size.width = 110
        return popup
    }

    private func popup(_ items: [(String, String)], selected: String, width: CGFloat, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.bezelStyle = .roundRect
        popup.controlSize = .small
        popup.font = SmartRuleEditor.font
        for (title, id) in items {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = id
        }
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == selected }) { popup.select(item) }
        popup.target = self
        popup.action = action
        popup.sizeToFit()
        popup.frame.size.width = width
        return popup
    }

    /// Move's and Copy's mailbox: MailMate's mailbox menu, titled by path ("Inbox – Alice" as "Alice (local) ‣ Inbox").
    private func mailboxPopup(_ row: Row) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.bezelStyle = .roundRect
        popup.controlSize = .small
        popup.font = SmartRuleEditor.font
        (popup.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false
        let menu = MailboxMenu()
        // A mailbox ("mailbox:42"), or a unified one ("role:archive": each message's own Archive).
        menu.choose = { [weak self, weak row] key in
            guard let self, let row, let scope = MessageScope(key: key) else { return }
            switch scope {
            case .mailbox(let id): row.action.value = String(id)
            case .role: row.action.value = key
            default: return
            }
            build(row)
            layoutRows()
            onChange()
        }
        // MailMate's: the unified mailboxes (each message's own Inbox, Archive, ...) without their
        // submailboxes, then the accounts ▸ their folders. Smart mailboxes, Flagged and All Messages can't
        // receive messages, so they aren't offered.
        var roots: [SidebarNode] = []
        if let unified = context.roots.first(where: { $0.key == "header.mailboxes" }) {
            let header = SidebarNode(key: unified.key, kind: .header, title: unified.title)
            header.children = unified.children.compactMap { node in
                guard case .role? = node.scope else { return nil }
                return SidebarNode(key: node.key, kind: node.kind, title: node.title, symbol: node.symbol, scope: node.scope)
            }
            roots.append(header)
        }
        roots += context.roots.filter { $0.key == "header.sources" }
        let selected = Int64(row.action.value).map { MessageScope.mailbox($0).key } ?? row.action.value
        popup.menu = menu.build(
            roots: roots, selection: selected,
            title: { node, path in (path.map(\.title) + [node.title]).joined(separator: " \u{2023} ") },
            choosable: { key in  // accounts open their folders but aren't mailboxes themselves
                if case .account? = MessageScope(key: key) { return false }
                return true
            })
        if let titleItem = popup.itemArray.first {
            if titleItem.title == "None" { titleItem.title = "Choose Mailbox" }
            titleItem.isHidden = true
            popup.select(titleItem)
        }
        row.mailboxMenu = menu
        popup.sizeToFit()
        let title = popup.itemArray.first?.title ?? ""
        popup.frame.size.width = max(150, ceil((title as NSString).size(withAttributes: [.font: SmartRuleEditor.font]).width) + 69)
        return popup
    }

    private func layoutRows() {
        let height = CGFloat(max(rows.count, 1)) * SmartRuleEditor.rowHeight + 1
        if frame.height != height {
            setFrameSize(NSSize(width: frame.width, height: height))
            onResize()
        }
        for (index, row) in rows.enumerated() {
            let top = 1 + CGFloat(index) * SmartRuleEditor.rowHeight
            var x: CGFloat = 9
            for (i, control) in row.controls.enumerated() {
                var frame = control.frame
                frame.origin.x = i == 0 ? x - 1 : x
                frame.origin.y = (top + (SmartRuleEditor.rowHeight - 1 - frame.height) / 2).rounded()
                if control is NSTextField, !(control is NSPopUpButton) {  // the address gives way to ⊖ ⊕
                    frame.size.width = max(80, min(173, bounds.width - 10 - 18 - 20 - 6 - frame.origin.x))
                }
                control.frame = frame
                x = i == 0 ? x + 19 : x + frame.width + 7
            }
            row.plus.frame.origin = NSPoint(x: bounds.width - 10 - 18, y: top + 3)
            row.minus.frame.origin = NSPoint(x: bounds.width - 10 - 18 - 20, y: top + 3)
        }
        emptyPlus.isHidden = !rows.isEmpty
        emptyPlus.frame.origin = NSPoint(x: bounds.width - 10 - 18, y: 4)
        needsDisplay = true
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutRows()
    }

    override func draw(_ dirtyRect: NSRect) {
        SmartRuleEditor.rowFill.setFill()
        bounds.fill()
        SmartRuleEditor.separator.setFill()
        for index in 1..<max(1, rows.count) {
            NSRect(x: 1, y: CGFloat(index) * SmartRuleEditor.rowHeight, width: bounds.width - 2, height: 1).fill()
        }
        SmartRuleEditor.border.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
        if rows.isEmpty {
            let text = NSAttributedString(string: "No actions added", attributes: [.font: SmartRuleEditor.font, .foregroundColor: NSColor.labelColor])
            text.draw(at: NSPoint(x: 10, y: (SmartRuleEditor.rowHeight - text.size().height) / 2))
        }
    }

    private func row(containing view: NSView) -> Row? {
        rows.first { $0.controls.contains(view) || $0.minus === view || $0.plus === view }
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        row(containing: sender)?.action.enabled = sender.state == .on
        onChange()
    }

    @objc private func kindChanged(_ sender: NSPopUpButton) {
        guard let row = row(containing: sender), let raw = sender.selectedItem?.representedObject as? String,
            let kind = RuleAction.Kind(rawValue: raw), kind != row.action.kind
        else { return }
        let keeps = kind.value == row.action.kind.value  // Move ⇄ Copy keep the mailbox, and so on
        row.action.kind = kind
        if !keeps { row.action.value = kind.value == .keyword ? RuleKeyword.seen.rawValue : "" }
        build(row)
        layoutRows()
        onChange()
    }

    /// Redirect's and Forward's address, as it's typed.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let row = row(containing: field) else { return }
        row.action.value = field.stringValue
        onChange()
    }

    @objc private func valueChanged(_ sender: NSPopUpButton) {
        guard let row = row(containing: sender), let raw = sender.selectedItem?.representedObject as? String else { return }
        row.action.value = raw
        onChange()
    }

    /// ⊕ adds a copy of the row below it (the common case).
    @objc private func plusClicked(_ sender: NSButton) {
        guard let row = row(containing: sender), let index = rows.firstIndex(where: { $0 === row }) else { return }
        rows.insert(Row(row.action), at: index + 1)
        rebuild()
        onChange()
    }

    @objc private func minusClicked(_ sender: NSButton) {
        guard let row = row(containing: sender) else { return }
        clear(row)
        rows.removeAll { $0 === row }
        rebuild()
        onChange()
    }
}
