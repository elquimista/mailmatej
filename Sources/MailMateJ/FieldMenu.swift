import AppKit
import MailStore

/// MailMate's field menu, for condition rows and the Submailboxes tab (from its screenshots):
/// Message is / is not ▸ statuses; the address headers ▸ their parts (Name ▸ First, Last), Subject,
/// Date ▸, Filename; Tags/Keywords; text; » Source ▸. Only the exact choice is ticked. A choice inside a
/// submenu ("From ‣ Name", "Message is Read") is also shown first, ticked, with its own submenu if it
/// has one, then a separator; a top-level choice ("From") is just ticked in place. Headers can be
/// clicked themselves (their No Specifier). Choices `enabled` rejects are left out. Choices are ids:
/// "field|from.name" or "status|is|read".
@MainActor
final class FieldMenu: NSObject {
    private let onChoose: (String) -> Void
    private let clicks = MenuParentClicks()

    init(onChoose: @escaping (String) -> Void) {
        self.onChoose = onChoose
    }

    static func id(field: SmartField, op: SmartOperator = .is, value: String = "") -> String {
        field == .status ? "status|\(op.rawValue)|\(value)" : "field|\(field.rawValue)"
    }

    /// The pop-up's title for a choice: "From ‣ Name", "Message is Read".
    static func title(field: SmartField, op: SmartOperator = .is, value: String = "") -> String {
        guard field == .status else { return field.title }
        return "\(op == .is ? "Message is" : "Message is not") \(SmartStatus(rawValue: value)?.title ?? value)"
    }

    /// Builds the menu into `popup`, showing `current`, without the choices `enabled` rejects.
    func install(in popup: NSPopUpButton, current: String, title: String, enabled: @escaping (String) -> Bool = { _ in true }) {
        (popup.cell as? NSPopUpButtonCell)?.altersStateOfSelectedItem = false
        let menu = NSMenu()
        menu.autoenablesItems = false

        func choice(_ title: String, _ id: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(chosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.isEnabled = enabled(id)
            if id == current { item.state = .on }
            return item
        }
        /// A parent opening `items`; with `id` it can be chosen itself (a header: its No Specifier).
        func parent(_ title: String, _ items: [NSMenuItem], id: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = id
            if let id, id == current { item.state = .on }
            item.isEnabled = items.contains { !$0.isSeparatorItem && $0.isEnabled }
            let submenu = NSMenu()
            submenu.delegate = clicks
            submenu.autoenablesItems = false
            items.forEach(submenu.addItem)
            item.submenu = submenu
            return item
        }
        func nameParts(_ header: SmartField.AddressHeader) -> [NSMenuItem] {
            [choice("No Specifier", "field|\(SmartField.address(header, .name).rawValue)"), .separator(),
             choice("First", "field|\(SmartField.address(header, .firstName).rawValue)"),
             choice("Last", "field|\(SmartField.address(header, .lastName).rawValue)")]
        }
        func parts(_ header: SmartField.AddressHeader) -> [NSMenuItem] {
            var items: [NSMenuItem] = []
            for part in SmartField.AddressPart.menuOrder {
                let id = "field|\(SmartField.address(header, part).rawValue)"
                items.append(part == .name ? parent("Name", nameParts(header), id: id) : choice(part.title, id))
                if part == .all { items.append(.separator()) }
            }
            return items
        }

        for (title, op) in [("Message is", SmartOperator.is), ("Message is not", .isNot)] {
            menu.addItem(parent(title, SmartStatus.allCases.map { choice($0.title, "status|\(op.rawValue)|\($0.rawValue)") }))
        }
        menu.addItem(.separator())
        for header in [SmartField.AddressHeader.from, .recipient, .to, .any] {
            menu.addItem(parent(header.title, parts(header), id: "field|\(SmartField.address(header, .all).rawValue)"))
        }
        menu.addItem(choice("Subject", "field|\(SmartField.subject.rawValue)"))
        menu.addItem(parent("Date", [choice("Received", "field|\(SmartField.received.rawValue)"),
                                     choice("Sent", "field|\(SmartField.sent.rawValue)")]))
        menu.addItem(choice("Filename", "field|\(SmartField.filename.rawValue)"))
        menu.addItem(.separator())
        menu.addItem(choice("Tags/Keywords", "field|\(SmartField.keyword.rawValue)"))
        menu.addItem(.separator())
        // MailMate's text fields (Message Text, from before, still shows on the conditions that use it).
        for field in [SmartField.unquoted, .quoted, .headersOrUnquoted, .headersOrText] {
            menu.addItem(choice(field.title, "field|\(field.rawValue)"))
        }
        menu.addItem(.separator())
        // » Source: No Specifier is the account (clicking Source chooses it), then the mailbox.
        menu.addItem(parent("\u{00BB} Source", [choice("No Specifier", "field|\(SmartField.account.rawValue)"), .separator(),
                                               choice("Mailbox", "field|\(SmartField.mailbox.rawValue)")],
                            id: "field|\(SmartField.account.rawValue)"))
        prune(menu, enabled: enabled)

        // The pop-up shows the choice: the ticked top-level item, or a ticked copy first for one in a submenu.
        let titleItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if menu.items.contains(where: { $0.state == .on }) {
            titleItem.isHidden = true
            menu.insertItem(titleItem, at: 0)
        } else {
            titleItem.state = .on
            let parts = current.split(separator: "|").map(String.init)
            if parts.count == 2, let (header, part) = SmartField(rawValue: parts[1]).address,
                part == .name || part == .firstName || part == .lastName
            {
                let submenu = NSMenu()
                submenu.delegate = clicks
                submenu.autoenablesItems = false
                nameParts(header).forEach(submenu.addItem)
                titleItem.submenu = submenu
            }
            menu.insertItem(titleItem, at: 0)
            menu.insertItem(.separator(), at: 1)
        }

        // Clicking a parent that can be chosen itself (From: No Specifier; Name) chooses it.
        clicks.attach(to: menu) { [weak self] item in
            guard item !== titleItem, item.isEnabled, let id = item.representedObject as? String, enabled(id) else { return nil }
            return { self?.onChoose(id) }
        }
        popup.menu = menu
        popup.select(titleItem)
    }

    /// Leaves out what can't be chosen: rejected choices, parents left empty, and the separators that
    /// end up doubled or at the ends.
    private func prune(_ menu: NSMenu, enabled: (String) -> Bool) {
        for item in menu.items.reversed() {
            if let submenu = item.submenu {
                prune(submenu, enabled: enabled)
                if !submenu.items.contains(where: { !$0.isSeparatorItem }) { menu.removeItem(item) }
            } else if !item.isSeparatorItem, let id = item.representedObject as? String, !enabled(id) {
                menu.removeItem(item)
            }
        }
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = item.isSeparatorItem }
        }
        if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }

    @objc private func chosen(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onChoose(id) }
    }
}
