import AppKit
import MailStore

/// MailMate's Displayed Count: what a sidebar mailbox's badge counts, by sidebar key, kept in the app's
/// preferences. A mailbox without a choice inherits the one of the mailbox it sits in; with none
/// anywhere above, it counts unread messages. Include Submailboxes counts the mailbox's messages
/// together with those of every mailbox inside it (each message once), inherited the same way.
enum DisplayedCounts {
    enum Kind: String, CaseIterable {
        case none, all, unread, flagged, unreplied

        var title: String {
            switch self {
            case .none: "No Count"
            case .all: "All"
            case .unread: "Unread"
            case .flagged: "Flagged"
            case .unreplied: "Unreplied"
            }
        }
    }

    static let kindsKey = "MailboxDisplayedCounts"
    static let includesKey = "MailboxCountsIncludeSubmailboxes"

    /// The count chosen for a mailbox; nil: Inherit.
    static func kind(for key: String) -> Kind? {
        (UserDefaults.standard.dictionary(forKey: kindsKey)?[key] as? String).flatMap(Kind.init(rawValue:))
    }

    static func set(_ kind: Kind?, for key: String) {
        var all = UserDefaults.standard.dictionary(forKey: kindsKey) ?? [:]
        all[key] = kind?.rawValue
        UserDefaults.standard.set(all, forKey: kindsKey)
    }

    /// Include Submailboxes as chosen for a mailbox; nil: inherited.
    static func includesSubmailboxes(_ key: String) -> Bool? {
        UserDefaults.standard.dictionary(forKey: includesKey)?[key] as? Bool
    }

    static func setIncludesSubmailboxes(_ on: Bool, for key: String) {
        var all = UserDefaults.standard.dictionary(forKey: includesKey) ?? [:]
        all[key] = on
        UserDefaults.standard.set(all, forKey: includesKey)
    }

    // MARK: Counting

    /// Sets the badges of `roots` (as built, with their usual counts) to their displayed counts; only
    /// those of the rows `counting` accepts (the others have theirs already).
    static func apply(to roots: [SidebarNode], store: MailStore, counting: (SidebarNode) -> Bool = { _ in true }) {
        let kinds = UserDefaults.standard.dictionary(forKey: kindsKey) ?? [:]
        let includes = UserDefaults.standard.dictionary(forKey: includesKey) ?? [:]
        guard !kinds.isEmpty || !includes.isEmpty else { return }  // usual counts everywhere

        func scopes(_ node: SidebarNode) -> [MessageScope] {
            (node.scope.map { [$0] } ?? []) + node.children.flatMap(scopes)
        }
        func walk(_ nodes: [SidebarNode], inherited: Kind?, including inheritedInclude: Bool?) {
            for node in nodes {
                let kind = (kinds[node.key] as? String).flatMap(Kind.init(rawValue:)) ?? inherited
                let include = includes[node.key] as? Bool ?? inheritedInclude
                if node.kind != .header, kind != nil || include == true, let scope = node.scope {
                    node.countedFromMailboxes = false  // counted here, even a mailbox's
                    if counting(node) {
                        let counted = kind ?? .unread
                        let lists = include == true ? scopes(node) : [scope]
                        node.badge = count(counted, of: lists, store: store)
                    }
                }
                walk(node.children, inherited: kind, including: include)
            }
        }
        walk(roots, inherited: nil, including: nil)
    }

    /// The rows (by key) whose badge is the usual count: their unread messages, no other Displayed Count
    /// chosen for them or above them, nor Include Submailboxes.
    static func countingUnread(_ roots: [SidebarNode]) -> Set<String> {
        let kinds = UserDefaults.standard.dictionary(forKey: kindsKey) ?? [:]
        let includes = UserDefaults.standard.dictionary(forKey: includesKey) ?? [:]
        var keys = Set<String>()
        func walk(_ nodes: [SidebarNode], inherited: Kind?, including inheritedInclude: Bool?) {
            for node in nodes {
                let kind = (kinds[node.key] as? String).flatMap(Kind.init(rawValue:)) ?? inherited
                let include = includes[node.key] as? Bool ?? inheritedInclude
                if (kind ?? .unread) == .unread, include != true { keys.insert(node.key) }
                walk(node.children, inherited: kind, including: include)
            }
        }
        walk(roots, inherited: nil, including: nil)
        return keys
    }

    private static func count(_ kind: Kind, of lists: [MessageScope], store: MailStore) -> Int {
        let counting: MessageCount
        switch kind {
        case .none: return 0
        case .all: counting = .all
        case .unread: counting = .unread
        case .flagged: counting = .flagged
        case .unreplied: counting = .unreplied
        }
        return (try? store.count(scopes: lists, counting: counting)) ?? 0
    }
}
