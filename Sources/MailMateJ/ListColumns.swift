import Foundation

/// The columns the main list shows in each mailbox (by sidebar key), as the header's menu sets them.
/// A mailbox not customized shows the default columns; Sent and Drafts, and the mailboxes inside them,
/// show To in place of From.
enum ListColumns {
    typealias Column = MessageListViewController.Column

    /// The menu's "Use as Default Columns", until it is used.
    private static let builtInDefault: Set<Column> = [.unread, .flag, .from, .subject, .date, .source, .attachment]
    private static let defaultKey = "ListColumnsDefault"
    private static let mailboxesKey = "ListColumns"

    private static func columns(_ stored: Any?) -> Set<Column>? {
        (stored as? [String]).map { Set($0.compactMap(Column.init(rawValue:))) }
    }

    private static var standard: Set<Column> {
        columns(UserDefaults.standard.array(forKey: defaultKey)) ?? builtInDefault
    }

    /// A mailbox's columns while it isn't customized.
    static func defaults(sent: Bool) -> Set<Column> {
        var shown = standard
        if sent, shown.contains(.from), !shown.contains(.to) {
            shown.remove(.from)
            shown.insert(.to)
        }
        return shown
    }

    static func isCustomized(_ key: String) -> Bool {
        UserDefaults.standard.dictionary(forKey: mailboxesKey)?[key] != nil
    }

    static func columns(for key: String, sent: Bool) -> Set<Column> {
        columns(UserDefaults.standard.dictionary(forKey: mailboxesKey)?[key]) ?? defaults(sent: sent)
    }

    /// Shows these columns in the mailbox; back to its defaults, it follows them again.
    static func set(_ shown: Set<Column>, for key: String, sent: Bool) {
        var all = UserDefaults.standard.dictionary(forKey: mailboxesKey) ?? [:]
        all[key] = shown == defaults(sent: sent) ? nil : shown.map(\.rawValue).sorted()
        UserDefaults.standard.set(all, forKey: mailboxesKey)
    }

    /// Use as Default Columns: the mailbox's columns become every uncustomized mailbox's.
    static func useAsDefault(_ key: String, sent: Bool) {
        UserDefaults.standard.set(columns(for: key, sent: sent).map(\.rawValue).sorted(), forKey: defaultKey)
        revert(key)
    }

    /// Revert to Default Columns.
    static func revert(_ key: String) {
        var all = UserDefaults.standard.dictionary(forKey: mailboxesKey) ?? [:]
        all[key] = nil
        UserDefaults.standard.set(all, forKey: mailboxesKey)
    }
}
