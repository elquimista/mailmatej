import Foundation
import JMAPKit
import MailStore

/// What the compose window starts from.
public enum ComposeKind: Sendable {
    case new, reply, replyAll, forward
}

/// A file from disk to attach; uploaded to the sending account when the message is sent.
public struct OutgoingFile: Sendable {
    public var name: String
    public var type: String
    public var data: Data
    /// The Content-ID of a picture shown in the HTML body (`cid:` in it): sent inline, not as an attachment.
    public var cid: String?

    public init(name: String, type: String, data: Data, cid: String? = nil) {
        self.name = name
        self.type = type
        self.data = data
        self.cid = cid
    }
}

/// A message ready to send (see `JMAPAccountSync.send`).
public struct OutgoingMessage: Sendable {
    public var identityId: String
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var replyTo: [EmailAddress] = []
    public var subject: String
    public var text: String
    /// An HTML version of the text (composed Markdown), sent with it as alternatives.
    public var html: String?
    /// Parts of other messages in the same account to attach (Forward), by blob id.
    public var attachments: [MessagePart]
    /// Files from disk to attach.
    public var files: [OutgoingFile] = []
    public var inReplyTo: [String]
    public var references: [String]
    /// The envelope sender, when it isn't the From address (see `IdentityRecord.envelopeEmail`).
    public var mailFrom: String?
    /// Saved as a draft: the format the text is written in ("markdown"), to reopen it as written.
    public var draftFormat: String?

    public init(
        identityId: String, from: EmailAddress, to: [EmailAddress], cc: [EmailAddress], bcc: [EmailAddress],
        subject: String, text: String, attachments: [MessagePart] = [], inReplyTo: [String] = [],
        references: [String] = []
    ) {
        self.identityId = identityId
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.text = text
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
    }

    /// Everyone the message goes to (the SMTP envelope), each address once.
    public var recipients: [String] {
        var seen = Set<String>()
        return (to + cc + bcc).compactMap { $0.email?.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// A draft as saved on the server (see `JMAPAccountSync.loadDraft`).
public struct SavedDraft: Sendable {
    /// The From address, lowercased.
    public var from: String?
    public var to: [EmailAddress] = []
    public var cc: [EmailAddress] = []
    public var bcc: [EmailAddress] = []
    public var replyTo: [EmailAddress] = []
    public var subject = ""
    /// The text as written (Markdown as typed when `isMarkdown`).
    public var text = ""
    public var isMarkdown = false
    public var attachments: [MessagePart] = []
    public var inReplyTo: [String] = []
    public var references: [String] = []

    public init() {}
}

/// Reply, Reply All and Forward: who it goes to, the subject and the quoted text.
public enum Compose {
    /// The message being replied to or forwarded.
    public struct Original: Sendable {
        public var from: [EmailAddress]
        public var replyTo: [EmailAddress]
        public var to: [EmailAddress]
        public var cc: [EmailAddress]
        public var subject: String
        public var date: Date
        public var text: String

        public init(
            from: [EmailAddress], replyTo: [EmailAddress] = [], to: [EmailAddress], cc: [EmailAddress] = [],
            subject: String, date: Date, text: String
        ) {
            self.from = from
            self.replyTo = replyTo
            self.to = to
            self.cc = cc
            self.subject = subject
            self.date = date
            self.text = text
        }

        public init(_ detail: MessageDetail, text: String) {
            func list(_ role: AddressRole) -> [EmailAddress] {
                detail.addresses(role).map { EmailAddress(name: $0.name, email: $0.email) }
            }
            self.init(
                from: list(.from), replyTo: list(.replyTo), to: list(.to), cc: list(.cc), subject: detail.subject,
                date: detail.sentAt ?? detail.receivedAt, text: text)
        }
    }

    public struct Draft: Sendable, Equatable {
        public var to: [EmailAddress] = []
        public var cc: [EmailAddress] = []
        public var subject = ""
        public var text = ""

        public init(to: [EmailAddress] = [], cc: [EmailAddress] = [], subject: String = "", text: String = "") {
            self.to = to
            self.cc = cc
            self.subject = subject
            self.text = text
        }
    }

    public static func draft(
        _ kind: ComposeKind, original: Original, myAddresses: Set<String>, accountAddresses: Set<String>? = nil,
        timeZone: TimeZone = .current
    ) -> Draft {
        switch kind {
        case .new:
            return Draft()
        case .reply, .replyAll:
            let (to, cc) = replyRecipients(
                original, all: kind == .replyAll, myAddresses: myAddresses, accountAddresses: accountAddresses)
            let text = "\n\n" + attribution(original, timeZone: timeZone) + "\n\n" + quote(original.text) + "\n"
            return Draft(to: to, cc: cc, subject: replySubject(original.subject), text: text)
        case .forward:
            var headers = ["From: " + format(original.from)]
            if !original.to.isEmpty { headers.append("To: " + format(original.to)) }
            if !original.cc.isEmpty { headers.append("Cc: " + format(original.cc)) }
            headers.append("Subject: " + original.subject)
            headers.append("Date: " + headerDate(original.date, timeZone: timeZone))
            let quoted = quote(headers.joined(separator: "\n") + "\n\n" + original.text)
            return Draft(subject: forwardSubject(original.subject), text: "\n\nForwarded message:\n\n" + quoted + "\n")
        }
    }

    /// Reply goes to Reply-To (else From); a reply to the account's own message goes to its recipients
    /// again. Reply All adds the original To and Cc, without any of my addresses or duplicates.
    /// `accountAddresses` are the replying account's own (by default all of mine): with several
    /// accounts, mail between two of them is a reply to someone else, not to myself.
    public static func replyRecipients(
        _ original: Original, all: Bool, myAddresses: Set<String>, accountAddresses: Set<String>? = nil
    ) -> (to: [EmailAddress], cc: [EmailAddress]) {
        let mine = Set(myAddresses.map { $0.lowercased() })
        let account = Set((accountAddresses ?? myAddresses).map { $0.lowercased() })
        func email(_ a: EmailAddress) -> String { a.email?.lowercased() ?? "" }
        let fromMe = !original.from.isEmpty && original.from.allSatisfy { account.contains(email($0)) }

        var to: [EmailAddress]
        var cc: [EmailAddress] = []
        if fromMe {
            to = original.to
            if all { cc = original.cc }
        } else {
            to = original.replyTo.isEmpty ? original.from : original.replyTo
            if all { cc = original.to + original.cc }
        }
        var seen = Set<String>()
        to = to.filter { !email($0).isEmpty && !account.contains(email($0)) && seen.insert(email($0)).inserted }
        if to.isEmpty, fromMe { to = original.to.filter { seen.insert(email($0)).inserted } }  // A note to myself.
        cc = cc.filter { !email($0).isEmpty && !mine.contains(email($0)) && seen.insert(email($0)).inserted }
        return (to, cc)
    }

    /// "Re: Subject", without stacking prefixes.
    public static func replySubject(_ subject: String) -> String {
        hasPrefix(subject, ["re:"]) ? subject : "Re: " + subject
    }

    public static func forwardSubject(_ subject: String) -> String {
        hasPrefix(subject, ["fwd:", "fw:"]) ? subject : "Fwd: " + subject
    }

    private static func hasPrefix(_ subject: String, _ prefixes: [String]) -> Bool {
        let s = subject.trimmingCharacters(in: .whitespaces).lowercased()
        return prefixes.contains { s.hasPrefix($0) }
    }

    /// "On 16 Oct 2026, at 9:12, Alice Liddell wrote:", as MailMate writes it (no leading zero on the hour).
    public static func attribution(_ original: Original, timeZone: TimeZone = .current) -> String {
        let who = original.from.first.map { a in a.name.flatMap { $0.isEmpty ? nil : $0 } ?? a.email ?? "" } ?? "Unknown"
        let date = formatter("d MMM yyyy", timeZone).string(from: original.date)
        let time = formatter("H:mm", timeZone).string(from: original.date)
        return "On \(date), at \(time), \(who) wrote:"
    }

    /// Prefixes every line with "> " (">" before an empty or already quoted line). An embedded picture's
    /// Markdown (`![](cid:…)`, from older MailMateJ messages) is quoted as `[ "name" ]`, as MailMate does.
    public static func quote(_ text: String) -> String {
        var lines = MarkdownMail.plainText(text).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.map { $0.isEmpty || $0.hasPrefix(">") ? ">" + $0 : "> " + $0 }.joined(separator: "\n")
    }

    /// References for a reply (RFC 5322 §3.6.4): the parent's References (else its In-Reply-To),
    /// then the parent's Message-ID.
    public static func references(messageId: [String], references: [String]?, inReplyTo: [String]?) -> [String] {
        var seen = Set<String>()
        return ((references ?? inReplyTo ?? []) + messageId).filter { seen.insert($0).inserted }
    }

    /// The identity to reply from: the one the message was sent to, else the account's first.
    public static func identity(
        replyingTo original: Original, accountId: String, identities: [IdentityRecord]
    ) -> IdentityRecord? {
        let mine = identities.filter { $0.accountId == accountId }
        let addressed = (original.to + original.cc + original.from).compactMap { $0.email?.lowercased() }
        return addressed.lazy.compactMap { email in mine.first { $0.email == email } }.first ?? mine.first
    }

    /// The readable text of an HTML body, to quote a message that has no plain-text part.
    public static func plainText(fromHTML html: String) -> String { JMAPAccountSync.plainText(fromHTML: html) }

    // MARK: Addresses

    /// "Name <a@b>, c@d" → addresses. Commas inside quotes or angle brackets don't split.
    public static func parseAddresses(_ text: String) -> [EmailAddress] {
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for ch in text {
            switch ch {
            case "\"": inQuotes.toggle()
            case "<" where !inQuotes: inAngle = true
            case ">" where !inQuotes: inAngle = false
            case ",", ";", "\n":
                if !inQuotes && !inAngle {
                    items.append(current)
                    current = ""
                    continue
                }
            default: break
            }
            current.append(ch)
        }
        items.append(current)
        return items.compactMap(parseAddress)
    }

    private static func parseAddress(_ item: String) -> EmailAddress? {
        let s = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let open = s.lastIndex(of: "<"), let close = s.lastIndex(of: ">"), open < close {
            let email = s[s.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            var name = s[..<open].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            return email.isEmpty ? nil : EmailAddress(name: name.isEmpty ? nil : name, email: email)
        }
        return EmailAddress(name: nil, email: s)
    }

    /// Whether this looks like a deliverable address (local@domain, no spaces).
    public static func isValid(_ address: EmailAddress) -> Bool {
        guard let email = address.email, !email.contains(where: \.isWhitespace) else { return false }
        let halves = email.split(separator: "@", omittingEmptySubsequences: false)
        return halves.count == 2 && !halves[0].isEmpty && !halves[1].isEmpty
    }

    /// Addresses completing what's typed in an address field, as MailMate offers them: those whose
    /// address or any word of whose name starts with it, formatted "Name <address>". Those that start
    /// with what's typed come first (only such a one can be completed inline); within each group, people
    /// written to most first, then the most seen. Addresses already in the field are left out.
    public static func completions(
        for typed: String, in known: [MailStore.KnownAddress], excluding: Set<String> = [], limit: Int = 10
    ) -> [String] {
        let query = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        let matches = known.filter { address in
            guard !excluding.contains(address.email) else { return false }
            if address.email.hasPrefix(query) { return true }
            guard let name = address.name?.lowercased() else { return false }
            return name.hasPrefix(query)
                || name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." }).contains { $0.hasPrefix(query) }
        }
        let ranked = matches
            .sorted { ($0.sentTo, $0.seen, $1.email) > ($1.sentTo, $1.seen, $0.email) }
            .map { format(EmailAddress(name: $0.name, email: $0.email)) }
        let leading = ranked.filter { $0.lowercased().hasPrefix(query) }
        return Array((leading + ranked.filter { !$0.lowercased().hasPrefix(query) }).prefix(limit))
    }

    /// "Name <a@b>, c@d", for an address field.
    public static func format(_ addresses: [EmailAddress]) -> String {
        addresses.map(format).joined(separator: ", ")
    }

    public static func format(_ address: EmailAddress) -> String {
        let email = address.email ?? ""
        guard let name = address.name, !name.isEmpty, name.lowercased() != email.lowercased() else { return email }
        let needsQuotes = name.contains { ",;<>@\"".contains($0) }
        let shown = needsQuotes ? "\"" + name.replacingOccurrences(of: "\"", with: "") + "\"" : name
        return "\(shown) <\(email)>"
    }

    private static func headerDate(_ date: Date, timeZone: TimeZone) -> String {
        formatter("d MMMM yyyy 'at' HH:mm:ss zzz", timeZone).string(from: date)
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }
}
