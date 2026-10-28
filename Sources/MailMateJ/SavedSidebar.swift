import Foundation
import MailStore

/// The sidebar as the app last showed it, kept with the mail: the next launch shows these rows at once,
/// with these counts and the submailboxes worked out then, and counts them again off the main thread,
/// rather than the window waiting for dozens of queries (hundreds of milliseconds, more with more mail).
struct SavedSidebar: Codable, Sendable {
    struct Row: Codable, Sendable {
        var key: String
        var badge: Int
        /// A row a Submailboxes tab made comes back whole; the others are built anew, keeping the count.
        var generated: Generated?
        var children: [Row]
    }

    struct Generated: Codable, Sendable {
        var title: String
        var scope: String
        var accountId: String?
        var role: String?
    }

    var rows: [Row]

    init(_ roots: [SidebarNode]) {
        func row(_ node: SidebarNode) -> Row {
            let generated = node.isGenerated
                ? node.scope.map { Generated(title: node.title, scope: $0.key, accountId: node.accountId, role: node.role) } : nil
            return Row(key: node.key, badge: node.badge, generated: generated, children: node.children.map(row))
        }
        rows = roots.map(row)
    }

    /// The rows by key, as `SidebarViewController.buildTree` reuses those of a tree shown.
    func nodes() -> [String: SidebarNode] {
        var byKey: [String: SidebarNode] = [:]
        func node(_ row: Row) -> SidebarNode? {
            let made: SidebarNode
            if let generated = row.generated {
                guard let scope = MessageScope(key: generated.scope) else { return nil }
                made = SidebarNode(key: row.key, kind: .mailbox, title: generated.title, scope: scope, accountId: generated.accountId)
                made.isGenerated = true
                made.role = generated.role
            } else {
                made = SidebarNode(key: row.key, kind: .mailbox, title: "")
            }
            made.badge = row.badge
            made.children = row.children.compactMap(node)
            byKey[row.key] = made
            return made
        }
        for row in rows { _ = node(row) }
        return byKey
    }

    static func load(from directory: URL) -> SavedSidebar? {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return nil }
        return try? JSONDecoder().decode(SavedSidebar.self, from: data)
    }

    func save(to directory: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.url(in: directory), options: .atomic)
    }

    private static func url(in directory: URL) -> URL { directory.appendingPathComponent("Sidebar.json") }
}
