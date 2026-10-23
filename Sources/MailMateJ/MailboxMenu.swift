import AppKit
import MailStore

/// MailMate's mailbox menu, for pull-down buttons: the sidebar's "Mailboxes" and "Sources" sections,
/// each mailbox with its icon and, when it has children, a submenu. As in MailMate, such a parent can
/// itself be chosen by clicking it, which AppKit doesn't do on its own (see `poll`). Its first item is
/// the pull-down's title: the chosen mailbox.
@MainActor
final class MailboxMenu: NSObject {
    var choose: (String) -> Void = { _ in }
    var signature = ""
    private let clicks = MenuParentClicks()

    /// The menu for `roots` (sidebar sections), with `selection` checked and as the title. Mailboxes in
    /// `disabled` show greyed out (MailMate's smart mailbox being edited); `title` names the chosen one
    /// in the button (MailMate's "All Messages ‣ Alice").
    /// `choosable` says which parents (items with a submenu) can be chosen by clicking them.
    func build(
        roots: [SidebarNode], selection: String, disabled: Set<String> = [], title: ((SidebarNode, [SidebarNode]) -> String)? = nil,
        choosable: @escaping (String) -> Bool = { _ in true }
    ) -> NSMenu {
        let menu = NSMenu()
        clicks.attach(to: menu) { [weak self] item in
            guard let key = item.representedObject as? String, choosable(key) else { return nil }
            return { self?.choose(key) }
        }
        let titleItem = NSMenuItem(title: "None", action: nil, keyEquivalent: "")  // The pull-down's own title.
        menu.addItem(titleItem)
        func menuItem(for node: SidebarNode, path: [SidebarNode]) -> NSMenuItem {
            let item = NSMenuItem(title: node.title, action: #selector(chosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = node.scope?.key
            item.image = NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil)
            if let key = node.scope?.key, disabled.contains(key) {
                item.isEnabled = false
                item.action = nil
            }
            if node.scope?.key == selection {
                item.state = .on
                titleItem.title = title?(node, path) ?? node.title
                titleItem.image = item.image
            }
            let children = node.children.filter(Self.isListed)
            if !children.isEmpty {
                let submenu = NSMenu()
                submenu.delegate = clicks
                submenu.autoenablesItems = false
                for child in children { submenu.addItem(menuItem(for: child, path: path + [node])) }
                item.submenu = submenu
            }
            return item
        }
        menu.autoenablesItems = false
        for root in roots {
            if root !== roots.first { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: root.title))
            for node in root.children where Self.isListed(node) { menu.addItem(menuItem(for: node, path: [])) }
        }
        return menu
    }

    /// Dynamic submailboxes of smart mailboxes come and go with the mail, so they aren't offered.
    private static func isListed(_ node: SidebarNode) -> Bool {
        switch node.scope {
        case .smartValue?, .smartAccount?, .smartAccountValue?, nil: false
        default: true
        }
    }

    @objc private func chosen(_ sender: NSMenuItem) {
        if let key = sender.representedObject as? String { choose(key) }
    }

}

/// Lets a menu item that opens a submenu be chosen itself, as MailMate's menus do: while the menu is
/// open it follows the highlighted item and polls the mouse button (menu tracking doesn't hand the app
/// its mouse events), and a release over a parent item asks `onParent` for what choosing it does; if
/// anything, the menu closes first and then that runs (choosing may replace the menu's own pop-up). The release of the click that opened the menu doesn't count (a pop-up opens with
/// its current item, which may be a parent, under the pointer). Set it as the delegate of the
/// menu's submenus too.
@MainActor
final class MenuParentClicks: NSObject, NSMenuDelegate {
    private var onParent: (NSMenuItem) -> (() -> Void)? = { _ in nil }
    private weak var rootMenu: NSMenu?
    private var highlighted: NSMenuItem?
    private var timer: Timer?
    private var wasPressed = false
    private var openingClick = false

    /// `onParent` returns what choosing the item does, or nil if it can't be chosen.
    func attach(to menu: NSMenu, onParent: @escaping (NSMenuItem) -> (() -> Void)?) {
        menu.delegate = self
        rootMenu = menu
        self.onParent = onParent
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        // A submenu opening with nothing highlighted leaves its parent as the item under the pointer.
        if item != nil || menu === rootMenu { highlighted = item }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === rootMenu else { return }
        highlighted = nil
        wasPressed = NSEvent.pressedMouseButtons & 1 != 0  // Still down from the click that opened it.
        openingClick = wasPressed
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === rootMenu else { return }
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pressed = NSEvent.pressedMouseButtons & 1 != 0
        defer { wasPressed = pressed }
        guard wasPressed, !pressed else { return }
        if openingClick {
            openingClick = false
            return
        }
        // A parent stays highlighted while its submenu is open, also once the pointer has left the menus:
        // a release out there chooses nothing.
        guard Self.pointerIsOverMenu(), let item = highlighted, item.hasSubmenu, item.isEnabled,
            let choose = onParent(item)
        else { return }
        rootMenu?.cancelTracking()
        DispatchQueue.main.async(execute: choose)
    }

    /// Whether the frontmost window under the pointer is one of this app's open menus.
    private static func pointerIsOverMenu() -> Bool {
        guard let screen = NSScreen.screens.first else { return false }
        let mouse = NSEvent.mouseLocation
        return isMenu(at: CGPoint(x: mouse.x, y: screen.frame.maxY - mouse.y))  // window list bounds are top-down
    }

    static func isMenu(at point: CGPoint) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windows {
            guard let bounds = (info[kCGWindowBounds as String] as? NSDictionary)
                .flatMap({ CGRect(dictionaryRepresentation: $0) }), bounds.contains(point)
            else { continue }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let owner = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            return layer == Int(CGWindowLevelForKey(.popUpMenuWindow)) && owner == ProcessInfo.processInfo.processIdentifier
        }
        return false
    }
}
