import AppKit
import MailStore

extension Notification.Name {
    static let submailboxSettingsDidChange = Notification.Name("SubmailboxSettingsDidChange")
}

/// MailMate's Submailboxes settings for a unified mailbox (Inbox, Sent Messages, ...): a child in the
/// sidebar for each account's mailbox of that kind, or for each value of a field.
struct SubmailboxSettings: Codable, Equatable {
    /// "Submailbox for each unique value of …".
    var bySource = false
    /// … of a field: » Source (one child per account), » Source ‣ Mailbox (one per mailbox), or any
    /// other the Conditions tab offers that can split (From, Subject, ...).
    var field = SmartField.account
    /// "Unless only one submailbox will be created".
    var unlessOnlyOne = true
    /// "Submailbox for the messages of each account".
    var byAccount = false

    private static let defaultsKey = "SubmailboxSettings"

    init(bySource: Bool = false, field: SmartField = .account, unlessOnlyOne: Bool = true, byAccount: Bool = false) {
        self.bySource = bySource
        self.field = field
        self.unlessOnlyOne = unlessOnlyOne
        self.byAccount = byAccount
    }

    private enum CodingKeys: String, CodingKey { case bySource, field, value, unlessOnlyOne, byAccount }

    // Settings saved before any field could be chosen kept "account" or "source" as their value.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bySource = try c.decodeIfPresent(Bool.self, forKey: .bySource) ?? false
        if let field = try c.decodeIfPresent(SmartField.self, forKey: .field) {
            self.field = field
        } else {
            field = try c.decodeIfPresent(String.self, forKey: .value) == "source" ? .mailbox : .account
        }
        unlessOnlyOne = try c.decodeIfPresent(Bool.self, forKey: .unlessOnlyOne) ?? true
        byAccount = try c.decodeIfPresent(Bool.self, forKey: .byAccount) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bySource, forKey: .bySource)
        try c.encode(field, forKey: .field)
        try c.encode(unlessOnlyOne, forKey: .unlessOnlyOne)
        try c.encode(byAccount, forKey: .byAccount)
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

    /// Top-level children per account (the pop-up's » Source, or "each account").
    var splitsByAccount: Bool { byAccount || (bySource && field == .account) }
    /// Children (or grandchildren under accounts) per source mailbox.
    var splitsBySource: Bool { bySource && field == .mailbox }
    /// The field splitting the mail by value, when it isn't the source (children, or grandchildren
    /// under accounts, per value).
    var valueField: SmartField? { bySource && field != .account && field != .mailbox ? field : nil }

    static func save(_ settings: SubmailboxSettings, for key: String) {
        var all = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        all[key] = try? JSONEncoder().encode(settings)
        UserDefaults.standard.set(all, forKey: defaultsKey)
        NotificationCenter.default.post(name: .submailboxSettingsDidChange, object: nil)
    }

    var splits: Bool { bySource || byAccount }

}
