import AppKit
import MailStore

extension Notification.Name {
    static let submailboxSettingsDidChange = Notification.Name("SubmailboxSettingsDidChange")
}

/// MailMate's Submailboxes settings for a unified mailbox (Inbox, Sent Messages, ...): a child in the
/// sidebar for each account's mailbox of that kind.
struct SubmailboxSettings: Codable, Equatable {
    /// What "Submailbox for each unique value of" splits by.
    enum Value: String, Codable, CaseIterable {
        case account, source
        var title: String { self == .account ? "Account" : "Source" }
    }

    /// "Submailbox for each unique value of …".
    var bySource = false
    /// … of Account (one child per account) or of Source (one per mailbox).
    var value = Value.account
    /// "Unless only one submailbox will be created".
    var unlessOnlyOne = true
    /// "Submailbox for the messages of each account".
    var byAccount = false

    private static let defaultsKey = "SubmailboxSettings"

    init(bySource: Bool = false, value: Value = .account, unlessOnlyOne: Bool = true, byAccount: Bool = false) {
        self.bySource = bySource
        self.value = value
        self.unlessOnlyOne = unlessOnlyOne
        self.byAccount = byAccount
    }

    // Settings saved before the value pop-up had Account read as Account.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bySource = try c.decodeIfPresent(Bool.self, forKey: .bySource) ?? false
        value = try c.decodeIfPresent(Value.self, forKey: .value) ?? .account
        unlessOnlyOne = try c.decodeIfPresent(Bool.self, forKey: .unlessOnlyOne) ?? true
        byAccount = try c.decodeIfPresent(Bool.self, forKey: .byAccount) ?? false
    }

    /// The settings of a unified mailbox (by its sidebar key). They start split by account.
    static func settings(for key: String) -> SubmailboxSettings {
        if let data = UserDefaults.standard.dictionary(forKey: defaultsKey)?[key] as? Data,
            let saved = try? JSONDecoder().decode(SubmailboxSettings.self, from: data)
        {
            return saved
        }
        return SubmailboxSettings(bySource: true)
    }

    /// Top-level children per account (the pop-up's Account, or "each account").
    var splitsByAccount: Bool { byAccount || (bySource && value == .account) }
    /// Children (or grandchildren under accounts) per source mailbox.
    var splitsBySource: Bool { bySource && value == .source }

    static func save(_ settings: SubmailboxSettings, for key: String) {
        var all = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        all[key] = try? JSONEncoder().encode(settings)
        UserDefaults.standard.set(all, forKey: defaultsKey)
        NotificationCenter.default.post(name: .submailboxSettingsDidChange, object: nil)
    }

    var splits: Bool { bySource || byAccount }

}
