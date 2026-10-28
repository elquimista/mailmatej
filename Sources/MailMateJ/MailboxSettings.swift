import Foundation

/// The settings kept by sidebar key, cleared for a smart mailbox. SQLite gives a new smart mailbox the
/// id of the last one deleted, so a deleted one's settings go with it, and a new one starts with none
/// left behind (a copy took the color of a mailbox deleted earlier).
@MainActor
enum MailboxSettings {
    static let didForget = Notification.Name("MailboxSettingsDidForget")

    /// By key: color, symbol, displayed count and whether it counts submailboxes, columns, Submailboxes tab.
    private static let byKey = [
        MailboxColors.defaultsKey, MailboxSymbols.defaultsKey, DisplayedCounts.kindsKey, DisplayedCounts.includesKey,
        ListColumns.mailboxesKey, SubmailboxSettings.defaultsKey,
    ]
    /// Lists of keys: color in the message list, the sidebar's order and its open rows.
    private static let lists = [
        MailboxColors.listDefaultsKey, SidebarViewController.orderDefaultsKey, SidebarViewController.expandedDefaultsKey,
    ]

    /// Forgets smart mailbox `id`'s settings, and those of the submailboxes made inside it.
    static func forgetSmartMailbox(_ id: Int64) {
        let key = "smart.\(id)"
        func isIt(_ other: String) -> Bool { other == key || other.hasPrefix(key + ".") }
        let defaults = UserDefaults.standard
        var forgot = false
        for name in byKey {
            guard let all = defaults.dictionary(forKey: name), all.keys.contains(where: isIt) else { continue }
            defaults.set(all.filter { !isIt($0.key) }, forKey: name)
            forgot = true
        }
        for name in lists {
            guard let all = defaults.stringArray(forKey: name), all.contains(where: isIt) else { continue }
            defaults.set(all.filter { !isIt($0) }, forKey: name)
            forgot = true
        }
        if forgot { NotificationCenter.default.post(name: didForget, object: nil) }
    }
}
