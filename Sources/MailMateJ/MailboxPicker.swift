import AppKit

/// Picks a mailbox by typing part of its name, for the keyboard's "move to mailbox" (v) and
/// "go to mailbox" (g then l): a sheet with a filter field over the sidebar's mailboxes. ↑ and ↓ move,
/// Return chooses, Escape cancels.
@MainActor
final class MailboxPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    struct Choice {
        let node: SidebarNode
        /// "Projects/2026 — Alice", as the mailbox is found in the sidebar.
        let path: String
    }

    private let all: [Choice]
    private var shown: [Choice]
    private let onChoose: (SidebarNode) -> Void
    private let panel: NSPanel
    private let field = NSSearchField()
    private let table = NSTableView()
    private weak var parent: NSWindow?
    /// Keeps the picker alive while its sheet is up.
    private static var open: MailboxPicker?

    /// - Parameter include: which sidebar rows can be picked.
    static func show(
        over window: NSWindow, title: String, roots: [SidebarNode], include: (SidebarNode) -> Bool,
        onChoose: @escaping (SidebarNode) -> Void
    ) {
        var choices: [Choice] = []
        func walk(_ nodes: [SidebarNode], path: [String], account: String?) {
            for node in nodes {
                let here = node.kind == .header ? [] : path + [node.title]
                let account = node.kind == .account ? node.title : account
                if node.scope != nil, include(node) {
                    let name = here.dropFirst(node.kind == .mailbox ? 1 : 0).joined(separator: "/")
                    choices.append(Choice(node: node, path: node.kind == .mailbox ? "\(name) — \(account ?? "")" : name))
                }
                walk(node.children, path: here, account: account)
            }
        }
        walk(roots, path: [], account: nil)
        guard !choices.isEmpty else { return NSSound.beep() }
        let picker = MailboxPicker(choices: choices, title: title, onChoose: onChoose)
        open = picker
        picker.parent = window
        window.beginSheet(picker.panel) { _ in open = nil }
        picker.panel.makeFirstResponder(picker.field)
    }

    private init(choices: [Choice], title: String, onChoose: @escaping (SidebarNode) -> Void) {
        all = choices
        shown = choices
        self.onChoose = onChoose
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        panel.title = title

        field.placeholderString = title
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("name"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(chooseClicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(field)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        panel.contentView = content
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
    }

    // MARK: Filtering and keys

    func controlTextDidChange(_ obj: Notification) {
        let words = field.stringValue.lowercased().split(separator: " ")
        shown = words.isEmpty ? all : all.filter { choice in words.allSatisfy { choice.path.lowercased().contains($0) } }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): step(1)
        case #selector(NSResponder.moveUp(_:)): step(-1)
        case #selector(NSResponder.insertNewline(_:)): choose()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func step(_ by: Int) {
        guard !shown.isEmpty else { return }
        let row = max(0, min(shown.count - 1, table.selectedRow + by))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func chooseClicked(_ sender: Any?) { choose() }

    private func choose() {
        guard shown.indices.contains(table.selectedRow) else { return NSSound.beep() }
        let node = shown[table.selectedRow].node
        close()
        onChoose(node)
    }

    private func close() {
        parent?.endSheet(panel)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("choice")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            for v in [image, text] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(v)
            }
            cell.imageView = image
            cell.textField = text
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        let choice = shown[row]
        cell.textField?.stringValue = choice.path
        cell.imageView?.image = NSImage(systemSymbolName: choice.node.symbol, accessibilityDescription: nil)
        return cell
    }

    #if DEBUG
        /// Types a filter and chooses the first match, as a user would.
        static func debugChoose(filter: String) {
            guard let picker = open else { return NSLog("MMJ picker: none open") }
            picker.field.stringValue = filter
            picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
            NSLog("MMJ picker: \(picker.shown.count) matches for \"\(filter)\": \(picker.shown.prefix(5).map(\.path))")
            picker.choose()
        }
    #endif
}
