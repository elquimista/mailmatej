import AppKit
import MailStore

/// What the rule editors offer: the mailboxes to pick (the sidebar's, without the smart mailbox being
/// edited and those inside it, which would refer to themselves), accounts, and values to suggest.
@MainActor
struct SmartRuleContext {
    struct Mailbox {
        var key: String
        var title: String
        var symbol: String
        var depth: Int
    }

    let model: AppModel
    let smartID: Int64
    let mailboxKey: String?
    let mailboxes: [Mailbox]
    /// The sidebar's sections, for MailMate's mailbox menu.
    let roots: [SidebarNode]
    /// The smart mailbox being edited and those inside it: shown greyed out, as they'd refer to themselves.
    let disabledKeys: Set<String>
    let accounts: [(id: String, name: String)]

    /// For a smart mailbox's tabs (`smartID`), or a rule of the mailbox `mailboxKey` (values come from it).
    init(model: AppModel, editing smartID: Int64, mailboxKey: String? = nil) {
        self.model = model
        self.smartID = smartID
        self.mailboxKey = mailboxKey
        var list: [Mailbox] = []
        func add(_ nodes: [SidebarNode], depth: Int, path: [String] = []) {
            for node in nodes {
                if node.kind == .header {
                    add(node.children, depth: depth)
                    continue
                }
                guard let scope = node.scope, scope != .smart(smartID) else { continue }
                switch scope {
                case .smartValue, .smartAccount, .smartAccountValue: continue  // dynamic submailboxes come and go
                default: break
                }
                // Nested mailboxes go by their path, as MailMate names them: "All Messages ‣ Alice".
                let title = (path + [node.title]).joined(separator: " \u{2023} ")
                list.append(Mailbox(key: scope.key, title: title, symbol: node.symbol, depth: depth))
                add(node.children, depth: depth + 1, path: path + [node.title])
            }
        }
        roots = SidebarViewController.buildTree(model: model)
        add(roots, depth: 0)
        mailboxes = list
        var disabled: Set<String> = []
        func disable(_ nodes: [SidebarNode], inside: Bool) {
            for node in nodes {
                let isEdited = node.scope == .smart(smartID)
                if inside || isEdited, let key = node.scope?.key { disabled.insert(key) }
                disable(node.children, inside: inside || isEdited)
            }
        }
        disable(roots, inside: false)
        disabledKeys = disabled
        accounts = ((try? model.store.accounts()) ?? []).map { ($0.id, $0.name) }
    }

    /// Keywords on the mail besides the standard ones (the keyword menu's "Other").
    var otherKeywords: [String] { (try? model.store.otherKeywords()) ?? [] }

    /// Values for an "is" combo box, as MailMate's: the field's values among the messages the smart
    /// mailbox's Mailboxes tab selects (read now, so changes there show), A to Z.
    func suggestions(_ field: SmartField) -> [String] {
        guard field.kind == .text, field != .body, field != .headersOrText else { return [] }
        let sources = mailboxKey.map { SmartSources(scopes: [$0]) }
            ?? (try? model.store.smartMailboxes())?.first { $0.id == smartID }?.definition.sources ?? SmartSources(scopes: [])
        return (try? model.store.fieldValues(field, sources: sources)) ?? []
    }

}

/// MailMate's rule editor, drawn as its rows look (measured at 1x): 25 pt rows (24 + a separator) in a
/// bordered box, 30 pt indentation per level, a small checkbox 9 pt in (Conditions only), controls from
/// 19 pt after it, 8 pt apart, and ⊖ ⊕ 10 pt from the right. ⊕ adds a row below (inside, on an
/// Any/All row); with ⌥ held it shows "…" and adds an Any/All group.
@MainActor
final class SmartRuleEditor: NSView, NSComboBoxDelegate, NSComboBoxDataSource, NSSearchFieldDelegate, NSTextFieldDelegate {
    enum Kind { case sources, conditions }

    /// A change worth saving; `true` for clicks and choices, `false` for typing (saved after a pause).
    var onChange: (Bool) -> Void = { _ in }
    /// The editor's height changed (rows came or went).
    var onResize: () -> Void = {}

    @MainActor private final class Row {
        weak var parent: Row?
        var children: [Row] = []
        var isCompound: Bool
        var match = SmartMatch.all
        var field = SmartField.subject
        var op = SmartOperator.contains
        var value = ""
        var enabled = true
        var options: SmartOptions = []
        /// The row's controls, left to right (checkbox first in Conditions).
        var controls: [NSView] = []
        var valueControl: NSView?
        /// The mailbox menu behind a mailbox pull-down (kept alive with the row).
        var mailboxMenu: MailboxMenu?
        /// The field menu behind the field pop-up (kept alive with the row).
        var fieldMenu: FieldMenu?
        let minus = NSButton()
        let plus = NSButton()

        init(compound: Bool) { isCompound = compound }

        var depth: Int { parent.map { $0.depth + 1 } ?? 0 }
    }

    private let kind: Kind
    private let context: SmartRuleContext
    private var root = Row(compound: true)
    private var suggestionCache: [SmartField: [String]] = [:]
    /// Each combo box's values, and those starting with what's typed.
    private var comboValues: [ObjectIdentifier: (all: [String], shown: [String])] = [:]
    private var flagsMonitor: Any?
    private var optionHeld = false

    static let rowHeight: CGFloat = 25

    override var isFlipped: Bool { true }

    init(kind: Kind, context: SmartRuleContext) {
        self.kind = kind
        self.context = context
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 26))
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.setOptionHeld(event.modifierFlags.contains(.option))
            return event
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
    }

    // MARK: Tree ⇄ rows

    func load(_ condition: SmartCondition) {
        for row in flatten() { remove(controlsOf: row) }
        root = makeRow(condition, parent: nil)
        if !root.isCompound {  // A tree is always rooted in an Any/All row.
            let group = Row(compound: true)
            group.match = kind == .sources ? .any : .all
            group.children = [root]
            root.parent = group
            root = group
        }
        rebuildAll()
    }

    private func makeRow(_ condition: SmartCondition, parent: Row?) -> Row {
        let row: Row
        switch condition {
        case .compound(let match, let children, let enabled):
            row = Row(compound: true)
            row.match = match
            row.enabled = enabled
            row.parent = parent
            row.children = children.map { makeRow($0, parent: row) }
        case .rule(let field, let op, let value, let enabled, let options):
            row = Row(compound: false)
            row.field = kind == .sources ? .mailbox : field
            row.op = op
            row.value = value
            row.enabled = enabled
            row.options = options
            row.parent = parent
        }
        return row
    }

    func tree() -> SmartCondition? { condition(root) }

    private func condition(_ row: Row) -> SmartCondition {
        if row.isCompound { return .compound(row.match, row.children.map(condition), enabled: row.enabled) }
        return .rule(row.field, row.op, row.op.takesValue ? currentValue(row) : "", enabled: row.enabled, options: row.options)
    }

    private func currentValue(_ row: Row) -> String {
        switch row.valueControl {
        case _ where row.mailboxMenu != nil: return row.value  // mailbox menus set it directly
        case let popup as NSPopUpButton: return popup.selectedItem?.representedObject as? String ?? row.value
        case let field as NSTextField: return field.stringValue
        case let holder?: return (holder.subviews.first as? NSTextField)?.stringValue ?? row.value
        default: return row.value
        }
    }

    private func flatten() -> [Row] {
        var out: [Row] = []
        func walk(_ row: Row) {
            out.append(row)
            row.children.forEach(walk)
        }
        walk(root)
        return out
    }

    // MARK: Controls

    private func remove(controlsOf row: Row) {
        if let combo = row.valueControl as? NSComboBox { comboValues[ObjectIdentifier(combo)] = nil }
        row.controls.forEach { $0.removeFromSuperview() }
        row.controls = []
        row.valueControl = nil
        row.mailboxMenu = nil
        row.fieldMenu = nil
        row.minus.removeFromSuperview()
        row.plus.removeFromSuperview()
    }

    /// Remakes every row's controls (after rows came or went). What's typed in a value field isn't kept
    /// in its row as it's typed, so it's taken from the field first: otherwise the rows would come back
    /// with their earlier values (⊕ left the row it copied as it was before the typing).
    private func rebuildAll() {
        let rows = flatten()
        for row in rows where !row.isCompound && row.op.takesValue && row.valueControl != nil { row.value = currentValue(row) }
        for row in rows { build(row) }
        layoutRows()
    }

    static let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    /// Makes a row's controls for its current choices. An empty editor is one row, as MailMate's:
    /// "No mailboxes added" (or conditions) with ⊕.
    private func build(_ row: Row) {
        remove(controlsOf: row)
        if row === root, row.children.isEmpty {
            let label = NSTextField(labelWithString: kind == .sources ? "No mailboxes added" : "No conditions added")
            label.font = Self.font
            label.sizeToFit()
            row.controls.append(label)
            addPlusMinus(row)
            return
        }
        if kind == .conditions {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxChanged(_:)))
            box.controlSize = .small
            box.state = row.enabled ? .on : .off
            box.sizeToFit()
            row.controls.append(box)
        }
        if row.isCompound {
            row.controls.append(popup(SmartMatch.allCases.map { ($0.title, $0.rawValue) }, selected: row.match.rawValue,
                                      width: kind == .sources ? 53 : 45, action: #selector(matchChanged(_:))))
            let label = NSTextField(labelWithString: kind == .sources ? "of the following mailboxes" : "of the following are true")
            label.font = Self.font
            label.sizeToFit()
            row.controls.append(label)
        } else if kind == .sources {
            let control = mailboxPopup(selected: row.value, width: 150, for: row)
            row.controls.append(control)
            row.valueControl = control
        } else {
            row.controls.append(fieldPopup(row))
            if row.field != .status {  // "Message is Read" is one pop-up: no operator, no value
                row.controls.append(operatorPopup(row))
            }
            if row.op.takesValue, row.field != .status {  // "exists" has no value
                let control = valueControl(row)
                row.controls.append(control)
                row.valueControl = control
            }
        }
        addPlusMinus(row)
    }

    private func addPlusMinus(_ row: Row) {
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
        row.plus.toolTip = "Add a condition; with \u{2325}, a group"
        for view in row.controls + [row.minus, row.plus] { addSubview(view) }
    }

    private func popup(_ items: [(String, String)], selected: String, width: CGFloat?, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.bezelStyle = .roundRect  // MailMate's outlined pop-ups
        popup.controlSize = .small
        popup.font = Self.font
        for (title, id) in items {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = id
        }
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == selected }) { popup.select(item) }
        popup.target = self
        popup.action = action
        popup.sizeToFit()
        // MailMate's widths, unless the chosen title needs more (None in a 45 pt Any/All pop-up).
        let natural = ceil((popup.titleOfSelectedItem as NSString? ?? "").size(withAttributes: [.font: Self.font]).width) + 24
        if let width { popup.frame.size.width = max(width, natural) }
        return popup
    }

    /// MailMate's mailbox pull-down: the sidebar as a menu with submenus (see `MailboxMenu`), titled by
    /// the chosen mailbox's path.
    private func mailboxPopup(selected: String, width: CGFloat, for row: Row) -> NSPopUpButton {
        // A pop-up (MailMate's ⌃⌄ arrows) showing the menu's hidden first item: the chosen mailbox.
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.bezelStyle = .roundRect
        popup.controlSize = .small
        popup.font = Self.font
        (popup.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false  // the chosen mailbox keeps its ✓
        let menu = MailboxMenu()
        menu.choose = { [weak self, weak row] key in
            guard let self, let row else { return }
            row.value = key
            rebuildRow(row)  // the title and width follow the choice
            onChange(true)
        }
        popup.menu = menu.build(
            roots: context.roots, selection: selected, disabled: context.disabledKeys,
            title: { node, path in (path.map(\.title) + [node.title]).joined(separator: " \u{2023} ") })
        popup.menu?.font = .menuFont(ofSize: 0)  // the menu at menu size, as MailMate's
        if let titleItem = popup.itemArray.first {
            if titleItem.title == "None" { titleItem.title = context.mailboxes.first { $0.key == selected }?.title ?? "Missing Mailbox" }
            titleItem.isHidden = true
            popup.select(titleItem)
        }
        row.mailboxMenu = menu
        popup.sizeToFit()
        // MailMate's fit the title: its width plus 69, at least 150 (measured at 1x).
        let title = popup.itemArray.first?.title ?? ""
        popup.frame.size.width = max(width, ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 69)
        return popup
    }

    /// The value control, as MailMate's: a combo box for "is"/"is not" (with values to pick), a field
    /// with a clear button for the others, a number of days, or a pop-up.
    private func valueControl(_ row: Row) -> NSView {
        let field = row.field, op = row.op, value = row.value
        switch field.kind {
        case .status:
            return popup(SmartStatus.allCases.map { ($0.title, $0.rawValue) }, selected: value, width: nil, action: #selector(valueChosen(_:)))
        case .account:
            return popup(context.accounts.map { ($0.name, $0.id) }, selected: value, width: nil, action: #selector(valueChosen(_:)))
        case .mailbox:
            return mailboxPopup(selected: value, width: 150, for: row)
        case .days:
            let holder = NSView(frame: NSRect(x: 0, y: 0, width: 84, height: 19))
            let number = NSTextField(string: value)
            number.controlSize = .small
            number.font = Self.font
            number.alignment = .right
            number.delegate = self
            number.frame = NSRect(x: 0, y: 0, width: 44, height: 19)
            let label = NSTextField(labelWithString: "days")
            label.font = Self.font
            label.sizeToFit()
            label.frame.origin = NSPoint(x: 50, y: (19 - label.frame.height) / 2)
            holder.addSubview(number)
            holder.addSubview(label)
            return holder
        case .text where op == .is || op == .isNot || op == .lessOrEqual || op == .moreOrEqual:
            // MailMate's: at least 173 pt, wider for longer values.
            let width = max(173, ceil((value as NSString).size(withAttributes: [.font: Self.font]).width) + 35)
            let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: width, height: 20))
            combo.controlSize = .small
            combo.font = Self.font
            combo.completes = true
            combo.numberOfVisibleItems = 12
            let suggestions = suggestionCache[field] ?? context.suggestions(field)
            suggestionCache[field] = suggestions
            // MailMate's list narrows to what's typed (values starting with it), completing the first.
            combo.usesDataSource = true
            combo.dataSource = self
            comboValues[ObjectIdentifier(combo)] = (all: suggestions, shown: suggestions)
            combo.stringValue = value
            combo.delegate = self
            return combo
        case .text:
            let search = NSSearchField(frame: NSRect(x: 0, y: 0, width: 148, height: 19))
            search.controlSize = .small
            search.font = Self.font
            (search.cell as? NSSearchFieldCell)?.searchButtonCell = nil  // a clear button, no magnifier
            search.placeholderString = ""
            search.sendsSearchStringImmediately = true
            search.stringValue = value
            search.delegate = self
            return search
        }
    }

    /// MailMate's operator menu (from its screenshot): is … more or equal to; is in, is not in; exists,
    /// does not exist; then Options: Case Sensitive, All Body Parts (toggles, kept with the row).
    private func operatorPopup(_ row: Row) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.bezelStyle = .roundRect
        popup.controlSize = .small
        popup.font = Self.font
        (popup.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false
        let menu = NSMenu()
        menu.autoenablesItems = false
        var selected: NSMenuItem?
        for (index, group) in row.field.operatorGroups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for op in group {
                let item = NSMenuItem(title: op.title, action: #selector(operatorChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = op.rawValue
                if op == row.op {
                    item.state = .on
                    selected = item
                }
                menu.addItem(item)
            }
        }
        if row.field.kind == .text {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Options"))
            for (title, option) in [("Case Sensitive", SmartOptions.caseSensitive), ("All Body Parts", .allBodyParts)] {
                let item = NSMenuItem(title: title, action: #selector(optionToggled(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = option.rawValue
                item.indentationLevel = 1
                item.state = row.options.contains(option) ? .on : .off
                menu.addItem(item)
            }
        }
        if selected == nil {  // a test no longer offered (begins with): show it anyway
            let item = NSMenuItem(title: row.op.title, action: nil, keyEquivalent: "")
            item.isHidden = true
            menu.insertItem(item, at: 0)
            selected = item
        }
        popup.menu = menu
        popup.select(selected)
        popup.sizeToFit()
        popup.frame.size.width = 113  // MailMate's (measured at 1x)
        return popup
    }

    @objc private func operatorChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let op = SmartOperator(rawValue: raw),
            let row = flatten().first(where: { $0.controls.contains { ($0 as? NSPopUpButton)?.menu === sender.menu } })
        else { return }
        if row.op.takesValue { row.value = currentValue(row) }
        row.op = op
        rebuildRow(row)  // "is" shows a combo box, "contains" a plain field, "exists" none
        onChange(true)
    }

    /// Options toggle and keep the test chosen.
    @objc private func optionToggled(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Int,
            let row = flatten().first(where: { $0.controls.contains { ($0 as? NSPopUpButton)?.menu === sender.menu } })
        else { return }
        let option = SmartOptions(rawValue: raw)
        if row.options.contains(option) { row.options.remove(option) } else { row.options.insert(option) }
        if row.op.takesValue { row.value = currentValue(row) }
        rebuildRow(row)
        onChange(true)
    }

    /// The condition's field pop-up: MailMate's field menu (see `FieldMenu`) at its 120 pt.
    private func fieldPopup(_ row: Row) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.bezelStyle = .roundRect
        popup.controlSize = .small
        popup.font = Self.font
        let fieldMenu = FieldMenu { [weak self, weak row] id in
            guard let self, let row else { return }
            choose(id, in: row)
        }
        row.fieldMenu = fieldMenu
        let current = FieldMenu.id(field: row.field, op: row.op, value: row.value)
        fieldMenu.install(in: popup, current: current, title: FieldMenu.title(field: row.field, op: row.op, value: row.value))
        popup.sizeToFit()
        let natural = ceil((popup.titleOfSelectedItem as NSString? ?? "").size(withAttributes: [.font: Self.font]).width) + 24
        popup.frame.size.width = max(120, natural)
        return popup
    }

    // MARK: Layout and drawing

    private func layoutRows() {
        let rows = flatten()
        let height = CGFloat(rows.count) * Self.rowHeight + 1
        if frame.height != height {
            setFrameSize(NSSize(width: frame.width, height: height))
            onResize()
        }
        for (index, row) in rows.enumerated() {
            let top = 1 + CGFloat(index) * Self.rowHeight
            // Measured from the box's edge: checkbox 9, controls 28 (8 without a checkbox), 7 apart; the
            // empty editor's text 8.
            let isPlaceholder = row === root && row.children.isEmpty
            var x = isPlaceholder ? 8 : (kind == .conditions ? 9 : 8) + CGFloat(row.depth) * 30
            for (i, control) in row.controls.enumerated() {
                let isCheckbox = kind == .conditions && i == 0 && !isPlaceholder
                var frame = control.frame
                frame.origin.x = isCheckbox ? x - 1 : x
                frame.origin.y = (top + (Self.rowHeight - 1 - frame.height) / 2).rounded()
                // As MailMate's: a text value field fills the row up to ⊖ ⊕, following the editor's width.
                if control === row.valueControl, control is NSTextField, control === row.controls.last {
                    frame.size.width = max(60, bounds.width - 10 - 18 - 20 - 6 - frame.origin.x)
                }
                control.frame = frame
                x = isCheckbox ? x + 19 : x + frame.width + 7
            }
            row.plus.frame.origin = NSPoint(x: bounds.width - 10 - 18, y: top + 3)
            row.minus.frame.origin = NSPoint(x: bounds.width - 10 - 18 - 20, y: top + 3)
            row.minus.isHidden = isPlaceholder || !canRemove(row)
        }
        needsDisplay = true
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutRows()
    }

    /// Any mailbox can go, the last one too (no mailboxes, no messages), but the Mailboxes tab keeps
    /// its Any/All row; Conditions can clear its root.
    private func canRemove(_ row: Row) -> Bool {
        kind == .conditions || row.parent != nil
    }

    /// MailMate's colours as they show on screen (measured at 1x): rows 53, separators 82, border 86.
    static let rowFill = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.157, green: 0.157, blue: 0.162, alpha: 1) : NSColor(white: 0.97, alpha: 1) }
    static let separator = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 1, alpha: 0.11) : NSColor(white: 0, alpha: 0.1) }
    static let border = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 1, alpha: 0.135) : NSColor(white: 0, alpha: 0.15) }

    override func draw(_ dirtyRect: NSRect) {
        Self.rowFill.setFill()
        bounds.fill()
        Self.separator.setFill()
        let count = flatten().count
        for index in 1..<max(1, count) {
            NSRect(x: 1, y: CGFloat(index) * Self.rowHeight, width: bounds.width - 2, height: 1).fill()
        }
        Self.border.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
        if let drop {
            // Where a dragged row will go: an accent line at the gap, starting at its level's indent with a
            // small ring, as outline views show it.
            let y = 1 + CGFloat(drop.gap) * Self.rowHeight - 1
            let x = indent(drop.depth) - 4
            NSColor.controlAccentColor.set()
            NSRect(x: x + 6, y: y - 1, width: bounds.width - 10 - x - 6, height: 2).fill()
            let ring = NSBezierPath(ovalIn: NSRect(x: x, y: y - 3, width: 6, height: 6))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    // MARK: Dragging rows

    /// Rows are dragged by their empty space (controls take their own clicks): up or down among the
    /// others, and, by how far right the pointer is, into or out of Any/All groups, as in MailMate.
    private var dragged: Row?
    private var pressPoint: NSPoint?
    private var drop: (gap: Int, depth: Int, parent: Row, index: Int)?

    private func indent(_ depth: Int) -> CGFloat { (kind == .conditions ? 9 : 8) + CGFloat(depth) * 30 }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let rows = flatten()
        let index = Int((point.y - 1) / Self.rowHeight)
        guard rows.indices.contains(index), rows[index] !== root else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)  // ends any editing, keeping what was typed
        dragged = rows[index]
        pressPoint = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragged, let start = pressPoint else { return super.mouseDragged(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        guard drop != nil || hypot(point.x - start.x, point.y - start.y) > 3 else { return }
        NSCursor.closedHand.set()
        autoscroll(with: event)
        drop = dropTarget(for: dragged, at: point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragged = nil
            pressPoint = nil
            drop = nil
            needsDisplay = true
            NSCursor.arrow.set()
        }
        guard let dragged, let drop else { return super.mouseUp(with: event) }
        move(dragged, into: drop.parent, at: drop.index)
    }

    /// The rows in a row's branch: it and everything inside it.
    private func branch(_ row: Row) -> [Row] { [row] + row.children.flatMap(branch) }

    /// Where `row` would go if dropped at `point`: the gap between rows nearest the pointer, at the
    /// level the pointer is over, within what that gap allows (into the group above, beside the row
    /// above, or out of groups that end there).
    private func dropTarget(for row: Row, at point: NSPoint) -> (gap: Int, depth: Int, parent: Row, index: Int)? {
        let rows = flatten()
        let moving = branch(row)
        let gap = min(max(Int(((point.y - 1) / Self.rowHeight).rounded()), 1), rows.count)
        // The rows either side of the gap, not counting the dragged branch (dropping next to itself).
        guard let above = rows[..<gap].last(where: { r in !moving.contains { $0 === r } }) else { return nil }
        let below = rows[gap...].first { r in !moving.contains { $0 === r } }
        let maxDepth = above.isCompound ? above.depth + 1 : above.depth
        let minDepth = max(1, below?.depth ?? 1)
        guard minDepth <= maxDepth else { return nil }
        let pointed = Int(((point.x - indent(0)) / 30).rounded(.down))
        let depth = min(max(pointed, minDepth), maxDepth)
        if depth == above.depth + 1 { return (gap, depth, above, 0) }  // first inside the group above
        // Beside `above`, or beside the group around it at that level.
        var sibling = above
        while sibling.depth > depth, let parent = sibling.parent { sibling = parent }
        guard let parent = sibling.parent, let index = parent.children.firstIndex(where: { $0 === sibling }) else { return nil }
        return (gap, depth, parent, index + 1)
    }

    /// Moves a row (with what's inside it) to `index` among `parent`'s children.
    private func move(_ row: Row, into parent: Row, at index: Int) {
        guard let old = row.parent, let from = old.children.firstIndex(where: { $0 === row }) else { return }
        var at = index
        if old === parent, from < index { at -= 1 }  // its own place no longer counts
        guard !(old === parent && at == from) else { return }  // dropped where it was
        rebuildAll()  // keeps what's typed before the rows change
        old.children.remove(at: from)
        row.parent = parent
        parent.children.insert(row, at: min(at, parent.children.count))
        rebuildAll()
        onChange(true)
    }

    // MARK: Actions

    private func row(containing view: NSView) -> Row? {
        flatten().first { $0.controls.contains(view) || $0.minus === view || $0.plus === view }
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        row(containing: sender)?.enabled = sender.state == .on
        onChange(true)
    }

    @objc private func matchChanged(_ sender: NSPopUpButton) {
        guard let row = row(containing: sender), let raw = sender.selectedItem?.representedObject as? String,
            let match = SmartMatch(rawValue: raw)
        else { return }
        row.match = match
        rebuildRow(row)  // None may need a wider pop-up
        onChange(true)
    }

    /// Applies a field choice. A new field keeps the test and value when they still apply, as from one
    /// text field to another.
    private func choose(_ id: String, in row: Row) {
        let parts = id.split(separator: "|", maxSplits: 2).map(String.init)
        if parts[0] == "status", parts.count == 3 {
            row.field = .status
            row.op = SmartOperator(rawValue: parts[1]) ?? .is
            row.value = parts[2]
        } else if parts.count == 2 {
            let field = SmartField(rawValue: parts[1])
            guard field != row.field else { return }
            let sameKind = field.kind == row.field.kind && field.operators.contains(row.op)
            row.value = sameKind ? currentValue(row) : Self.defaultValue(field, context: context)
            row.field = field
            if !sameKind { row.op = field.operators[0] }
        }
        rebuildRow(row)
        onChange(true)
    }

    @objc private func valueChosen(_ sender: NSPopUpButton) {
        guard let row = row(containing: sender) else { return }
        row.value = currentValue(row)
        if kind == .sources || row.field == .mailbox { rebuildRow(row) }  // its width follows the title
        onChange(true)
    }

    private func rebuildRow(_ row: Row) {
        build(row)
        layoutRows()
    }

    private static func defaultValue(_ field: SmartField, context: SmartRuleContext) -> String {
        switch field.kind {
        case .status: SmartStatus.unread.rawValue
        case .days: "7"
        case .mailbox: "all"
        case .account: context.accounts.first?.id ?? ""
        case .text: ""
        }
    }

    @objc private func plusClicked(_ sender: NSButton) {
        guard let row = row(containing: sender) else { return }
        // The new condition is a copy of this one (on an Any/All row, of its first condition), the
        // common case; with ⌥, that copy in a new group.
        let source = row.isCompound ? row.children.first : row
        let copied = source.map(copy) ?? newSimpleRow()
        let fresh: Row
        if NSEvent.modifierFlags.contains(.option) {
            fresh = Row(compound: true)
            fresh.match = kind == .sources ? .any : .all
            copied.parent = fresh
            fresh.children = [copied]
        } else {
            fresh = copied
        }
        // On an Any/All row the new row goes inside it, first; otherwise right below.
        if row.isCompound {
            fresh.parent = row
            row.children.insert(fresh, at: 0)
        } else if let parent = row.parent, let index = parent.children.firstIndex(where: { $0 === row }) {
            fresh.parent = parent
            parent.children.insert(fresh, at: index + 1)
        }
        rebuildAll()
        onChange(true)
        // As MailMate: the new condition's value is selected, ready to type over.
        let target = fresh.isCompound ? fresh.children.first : fresh
        if let field = target?.valueControl as? NSTextField {
            window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    /// An exact copy of a row and the rows inside it, with what's typed in its value.
    private func copy(_ row: Row) -> Row {
        let new = Row(compound: row.isCompound)
        new.match = row.match
        new.field = row.field
        new.op = row.op
        new.value = row.isCompound ? row.value : currentValue(row)
        new.enabled = row.enabled
        new.options = row.options
        new.children = row.children.map { child in
            let c = copy(child)
            c.parent = new
            return c
        }
        return new
    }

    private func newSimpleRow() -> Row {
        let row = Row(compound: false)
        if kind == .sources {
            row.field = .mailbox
            row.op = .is
            row.value = "all"
        } else {
            // MailMate's new condition: From ‣ Name is "John Appleseed", the example selected to type over.
            row.field = .fromName
            row.op = .is
            row.value = "John Appleseed"
        }
        return row
    }

    @objc private func minusClicked(_ sender: NSButton) {
        guard let row = row(containing: sender) else { return }
        // Removing an Any/All row keeps its conditions: they move up into its place. The root
        // (Conditions only) just empties.
        var removed: [Row] = []
        func walk(_ r: Row) {
            removed.append(r)
            r.children.forEach(walk)
        }
        if let parent = row.parent, let index = parent.children.firstIndex(where: { $0 === row }) {
            parent.children.remove(at: index)
            for child in row.children { child.parent = parent }
            parent.children.insert(contentsOf: row.children, at: index)
            row.children = []
            removed = [row]
        } else {
            row.children.forEach(walk)
            row.children = []
        }
        removed.forEach(remove(controlsOf:))
        rebuildAll()  // the last row gone, the editor shows "No … added"
        onChange(true)
    }

    private func setOptionHeld(_ held: Bool) {
        guard held != optionHeld else { return }
        optionHeld = held
        for row in flatten() {
            row.plus.image = NSImage(systemSymbolName: held ? "ellipsis" : "plus", accessibilityDescription: held ? "Add Group" : "Add")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        }
    }

    #if DEBUG
        /// Logs the first mailbox pull-down's menu: title, then items (indented by submenu, [x] when
        /// chosen, (off) when disabled).
        func debugDumpMailboxMenu() {
            let index = ProcessInfo.processInfo.environment["MMJ_DEBUG_MAILBOX_MENU"] == "op" ? 2 : 1
            let controls = flatten().first(where: { !$0.isCompound })?.controls ?? []
            let fieldPopup = kind == .conditions && controls.count > index ? controls[index] as? NSPopUpButton : nil
            guard let popup = fieldPopup ?? flatten().first(where: { $0.mailboxMenu != nil })?.valueControl as? NSPopUpButton,
                let menu = popup.menu
            else { return NSLog("MMJ menu: none") }
            var lines: [String] = ["title: \(popup.titleOfSelectedItem ?? popup.itemArray.first?.title ?? "")"]
            func walk(_ menu: NSMenu, _ depth: Int) {
                for item in menu.items.dropFirst(depth == 0 ? 1 : 0) {
                    let mark = item.state == .on ? "[x] " : ""
                    let off = item.isEnabled ? "" : " (off)"
                    lines.append(String(repeating: "  ", count: depth) + mark + (item.isSeparatorItem ? "---" : item.title) + off
                                 + (item.image == nil ? "" : " *"))
                    if let sub = item.submenu { walk(sub, depth + 1) }
                }
            }
            walk(menu, 0)
            NSLog("MMJ menu:\n\(lines.joined(separator: "\n"))")
            for row in flatten() {
                if let combo = row.valueControl as? NSComboBox, let values = comboValues[ObjectIdentifier(combo)] {
                    NSLog("MMJ combo \(row.field.rawValue): \(values.all.count) values, first \(values.all.prefix(6))")
                }
            }
        }

        /// Clicks ⊕ on the first condition, then ⊖ on the first Any/All group inside the root, logging the
        /// tree after each.
        func debugDuplicateAndUngroup() {
            func describe(_ c: SmartCondition, _ depth: Int = 0) -> String {
                let pad = String(repeating: "  ", count: depth)
                switch c {
                case .compound(let m, let kids, _): return pad + m.title + "\n" + kids.map { describe($0, depth + 1) }.joined(separator: "\n")
                case .rule(let f, let o, let v, _, _): return pad + "\(f.title) \(o.title) \(v)"
                }
            }
            NSLog("MMJ before:\n\(describe(tree()!))")
            if let first = root.children.first(where: { !$0.isCompound }) { plusClicked(first.plus) }
            NSLog("MMJ after ⊕:\n\(describe(tree()!))")
            if let group = root.children.first(where: { $0.isCompound }) { minusClicked(group.minus) }
            NSLog("MMJ after ⊖ group:\n\(describe(tree()!))")
        }

        /// Clicks ⊖ on the first row inside the root, if it shows one.
        func debugRemoveFirstRow() {
            guard let row = root.children.first, !row.minus.isHidden else { return NSLog("MMJ remove: no ⊖") }
            minusClicked(row.minus)
        }

        /// Clicks ⊕ on the root row (with ⌥ for a group) and types `text` into the new row's value.
        /// Types `text` into the first condition's value (as typing does), clicks its ⊕, and logs every
        /// condition's value.
        func debugTypeThenAdd(_ text: String) {
            guard let row = flatten().first(where: { !$0.isCompound && $0.valueControl is NSTextField }),
                let field = row.valueControl as? NSTextField
            else { return NSLog("MMJ add: no text condition") }
            field.stringValue = text
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            plusClicked(row.plus)
            NSLog("MMJ add: values \(flatten().filter { !$0.isCompound }.map { ($0.valueControl as? NSTextField)?.stringValue ?? $0.value })")
        }

        /// Drags row `from` (by its empty space at the right) to `x`, `y` in the editor, as the mouse would;
        /// steps "from:x:y" separated by ";". Logs the conditions after each.
        func debugDrag(_ steps: String) {
            for step in steps.split(separator: ";") {
                let n = step.split(separator: ":").compactMap { Double($0) }
                guard n.count >= 3, let window else { continue }
                func event(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
                    NSEvent.mouseEvent(
                        with: type, location: convert(p, to: nil), modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                }
                let start = NSPoint(x: bounds.width - 80, y: 1 + (n[0] + 0.5) * Self.rowHeight)
                let end = NSPoint(x: n[1], y: n[2])
                mouseDown(with: event(.leftMouseDown, start))
                mouseDragged(with: event(.leftMouseDragged, NSPoint(x: start.x, y: start.y + 5)))
                mouseDragged(with: event(.leftMouseDragged, end))
                let target = drop.map { "gap \($0.gap) depth \($0.depth)" } ?? "none"
                if n.count > 3 { return NSLog("MMJ drag \(step) held at \(target)") }  // left mid-drag, to see the line
                mouseUp(with: event(.leftMouseUp, end))
                NSLog("MMJ drag \(step) → \(target): \(debugTreeText(root))")
            }
        }

        private func debugTreeText(_ row: Row) -> String {
            row.isCompound ? "\(row.match.rawValue)[" + row.children.map(debugTreeText).joined(separator: ", ") + "]" : currentValue(row)
        }

        func debugAddRow(text: String) {
            plusClicked(root.plus)
            guard let row = root.children.first else { return }
            (row.valueControl as? NSTextField)?.stringValue = text
            onChange(true)
            NSLog("MMJ editor rows: \(flatten().count), tree: \(String(describing: tree()))")
        }
    #endif

    // MARK: Text changes

    func controlTextDidChange(_ obj: Notification) {
        if let combo = obj.object as? NSComboBox, var values = comboValues[ObjectIdentifier(combo)] {
            let typed = combo.stringValue
            values.shown = typed.isEmpty ? values.all : values.all.filter { $0.range(of: typed, options: [.caseInsensitive, .anchored]) != nil }
            comboValues[ObjectIdentifier(combo)] = values
            combo.reloadData()
        }
        onChange(false)
    }

    // MARK: Combo box values

    func numberOfItems(in comboBox: NSComboBox) -> Int { comboValues[ObjectIdentifier(comboBox)]?.shown.count ?? 0 }

    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        comboValues[ObjectIdentifier(comboBox)]?.shown[safe: index]
    }

    func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
        comboValues[ObjectIdentifier(comboBox)]?.all.first { $0.range(of: string, options: [.caseInsensitive, .anchored]) != nil }
    }

    func comboBox(_ comboBox: NSComboBox, indexOfItemWithStringValue string: String) -> Int {
        comboValues[ObjectIdentifier(comboBox)]?.shown.firstIndex { $0.caseInsensitiveCompare(string) == .orderedSame } ?? NSNotFound
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // The new value is in place only after this returns.
        DispatchQueue.main.async { [weak self] in self?.onChange(true) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
