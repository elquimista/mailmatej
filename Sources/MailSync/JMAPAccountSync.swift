import Foundation
import JMAPKit
import MailStore

/// Keeps one JMAP account in sync with the local store, using state strings and `/changes`.
public actor JMAPAccountSync {
    public let account: AccountRecord
    private let client: JMAPClient
    private let store: MailStore

    public init(account: AccountRecord, credentials: Credentials, store: MailStore, urlSession: URLSession = .shared)
        throws
    {
        guard let url = URL(string: account.sessionURL) else { throw JMAPError.invalidResponse("bad session URL") }
        self.account = account
        self.client = JMAPClient(sessionURL: url, credentials: credentials, urlSession: urlSession)
        self.store = store
    }

    public struct Result: Sendable {
        public var mailboxes = 0
        public var created = 0
        public var updated = 0
        public var destroyed = 0
    }

    /// One full sync round: mailboxes, identities, then emails.
    @discardableResult
    public func sync() async throws -> Result {
        let session = try await client.currentSession()
        let accountId = try remoteAccountId(session)
        syncLog.notice(
            "Syncing \(self.account.name, privacy: .public): api \(session.apiUrl.absoluteString, privacy: .public), account \(accountId, privacy: .public)")
        var result = Result()
        result.mailboxes = try await syncMailboxes(accountId)
        if session.supports(Capability.submission) {
            try await syncIdentities(accountId)
        }
        try await syncEmails(accountId, session: session, into: &result)
        return result
    }

    /// Fetches and stores the body of one message (and its raw .eml). Called when a message is opened.
    public func fetchBody(messageId: Int64) async throws -> MessageBody {
        guard let detail = try store.detail(id: messageId) else { throw JMAPError.invalidResponse("unknown message") }
        let session = try await client.currentSession()
        let accountId = try remoteAccountId(session)

        var request = JMAPRequest()
        let get = request.call("Email/get", [
            "accountId": .string(accountId),
            "ids": .strings([detail.remoteId]),
            "properties": .strings(EmailBody.properties),
            "fetchTextBodyValues": true,
            "fetchHTMLBodyValues": true,
        ])
        async let raw = try? client.download(
            accountId: accountId, blobId: detail.blobId, type: "message/rfc822", name: "message.eml")
        let response = try await client.send(request)
        guard let email = try response.decode(GetResponse<EmailBody>.self, get).list.first else {
            throw JMAPError.invalidResponse("message no longer exists on the server")
        }
        let body = Self.render(email)
        try store.saveBody(messageId: messageId, body, parts: Self.parts(email))
        if let data = await raw {
            try? store.blobs.write(data, accountId: account.id, blobId: detail.blobId)
        }
        return body
    }

    /// Downloads one blob (e.g. an embedded image part).
    public func downloadBlob(blobId: String, type: String, name: String) async throws -> Data {
        let accountId = try remoteAccountId(try await client.currentSession())
        return try await client.download(accountId: accountId, blobId: blobId, type: type, name: name)
    }

    /// Push notifications. Yields whenever the server reports a change for this account.
    public func changeNotifications() async throws -> AsyncThrowingStream<Void, Error> {
        let session = try await client.currentSession()
        let accountId = try remoteAccountId(session)
        let changes = try await client.stateChanges()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await change in changes where change.changed[accountId] != nil {
                        continuation.yield()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Mailboxes

    private func syncMailboxes(_ accountId: String) async throws -> Int {
        if let since = try store.syncState(accountId: account.id, type: "Mailbox") {
            do {
                return try await syncMailboxChanges(accountId, since: since)
            } catch let error as JMAPMethodError where error.type == "cannotCalculateChanges" {
                // Fall through to a full refresh.
            }
        }
        var request = JMAPRequest()
        let get = request.call("Mailbox/get", ["accountId": .string(accountId), "ids": .null])
        let response = try await client.send(request)
        let result = try response.decode(GetResponse<Mailbox>.self, get)
        try store.applyMailboxes(
            accountId: account.id, upserts: result.list.map(Self.incoming), destroyed: [], replaceAll: true)
        try store.setSyncState(result.state, accountId: account.id, type: "Mailbox")
        return result.list.count
    }

    private func syncMailboxChanges(_ accountId: String, since: String) async throws -> Int {
        var state = since
        var count = 0
        while true {
            var request = JMAPRequest()
            let changes = request.call("Mailbox/changes", ["accountId": .string(accountId), "sinceState": .string(state)])
            let created = request.call("Mailbox/get", [
                "accountId": .string(accountId), "#ids": JMAPRequest.ref(changes, "/created"),
            ])
            let updated = request.call("Mailbox/get", [
                "accountId": .string(accountId), "#ids": JMAPRequest.ref(changes, "/updated"),
            ])
            let response = try await client.send(request)
            let delta = try response.decode(ChangesResponse.self, changes)
            let upserts =
                try response.decode(GetResponse<Mailbox>.self, created).list
                + response.decode(GetResponse<Mailbox>.self, updated).list
            try store.applyMailboxes(
                accountId: account.id, upserts: upserts.map(Self.incoming), destroyed: delta.destroyed,
                replaceAll: false)
            try store.setSyncState(delta.newState, accountId: account.id, type: "Mailbox")
            count += upserts.count + delta.destroyed.count
            state = delta.newState
            if !delta.hasMoreChanges { return count }
        }
    }

    // MARK: Identities

    private func syncIdentities(_ accountId: String) async throws {
        var request = JMAPRequest(using: [Capability.core, Capability.mail, Capability.submission])
        let get = request.call("Identity/get", ["accountId": .string(accountId), "ids": .null])
        let response = try await client.send(request)
        let identities = try response.decode(GetResponse<Identity>.self, get).list
        try store.replaceIdentities(accountId: account.id, identities.map { ($0.id, $0.name, $0.email) })
    }

    // MARK: Emails

    private func syncEmails(_ accountId: String, session: Session, into result: inout Result) async throws {
        let pageSize = min(session.maxObjectsInGet, 500)
        if let since = try store.syncState(accountId: account.id, type: "Email") {
            do {
                try await syncEmailChanges(accountId, since: since, pageSize: pageSize, into: &result)
                return
            } catch let error as JMAPMethodError where error.type == "cannotCalculateChanges" {
                // Server can't give a delta (state too old): fall back to a full sync.
            }
        }
        try await initialEmailSync(accountId, pageSize: pageSize, into: &result)
    }

    /// Pages through every email, newest first. The state captured on the first page is
    /// saved at the end; anything that changes meanwhile is picked up by the next `/changes`.
    private func initialEmailSync(_ accountId: String, pageSize: Int, into result: inout Result) async throws {
        var anchor: String?
        var position = 0
        var firstState: String?
        var seen = Set<String>()

        while true {
            var queryArgs: [String: JSONValue] = [
                "accountId": .string(accountId),
                "sort": [["property": "receivedAt", "isAscending": false]],
                "limit": .number(Double(pageSize)),
            ]
            if let anchor {
                queryArgs["anchor"] = .string(anchor)
                queryArgs["anchorOffset"] = 1
            } else {
                queryArgs["position"] = .number(Double(position))
            }
            var request = JMAPRequest()
            let query = request.call("Email/query", queryArgs)
            let get = request.call("Email/get", [
                "accountId": .string(accountId),
                "#ids": JMAPRequest.ref(query, "/ids"),
                "properties": .strings(Email.properties),
            ])

            let response: JMAPResponse
            let ids: [String]
            do {
                response = try await client.send(request)
                ids = try response.decode(QueryResponse.self, query).ids
            } catch let error as JMAPMethodError where error.type == "anchorNotFound" {
                // The anchor email was deleted mid-sync; continue by position instead.
                anchor = nil
                position = seen.count
                continue
            }
            let page = try response.decode(GetResponse<Email>.self, get)
            if firstState == nil { firstState = page.state }

            try store.upsertMessages(accountId: account.id, page.list.map(Self.incoming))
            for email in page.list where seen.insert(email.id).inserted { result.created += 1 }

            if ids.count < pageSize { break }
            anchor = ids.last
        }
        if let firstState {
            try store.setSyncState(firstState, accountId: account.id, type: "Email")
        }
    }

    private func syncEmailChanges(_ accountId: String, since: String, pageSize: Int, into result: inout Result)
        async throws
    {
        var state = since
        while true {
            var request = JMAPRequest()
            let changes = request.call("Email/changes", [
                "accountId": .string(accountId), "sinceState": .string(state), "maxChanges": .number(Double(pageSize)),
            ])
            let created = request.call("Email/get", [
                "accountId": .string(accountId), "#ids": JMAPRequest.ref(changes, "/created"),
                "properties": .strings(Email.properties),
            ])
            let updated = request.call("Email/get", [
                "accountId": .string(accountId), "#ids": JMAPRequest.ref(changes, "/updated"),
                "properties": .strings(Email.properties),
            ])
            let response = try await client.send(request)
            let delta = try response.decode(ChangesResponse.self, changes)
            let createdEmails = try response.decode(GetResponse<Email>.self, created).list
            let updatedEmails = try response.decode(GetResponse<Email>.self, updated).list

            try store.upsertMessages(accountId: account.id, (createdEmails + updatedEmails).map(Self.incoming))
            try store.deleteMessages(accountId: account.id, remoteIds: delta.destroyed)
            try store.setSyncState(delta.newState, accountId: account.id, type: "Email")

            result.created += createdEmails.count
            result.updated += updatedEmails.count
            result.destroyed += delta.destroyed.count
            state = delta.newState
            if !delta.hasMoreChanges { return }
        }
    }

    // MARK: Mapping

    private func remoteAccountId(_ session: Session) throws -> String {
        if let id = account.remoteAccountId { return id }
        guard let id = session.primaryMailAccountId else { throw JMAPError.missingCapability(Capability.mail) }
        return id
    }

    static func incoming(_ m: Mailbox) -> IncomingMailbox {
        IncomingMailbox(
            remoteId: m.id, parentRemoteId: m.parentId, name: m.name, role: m.role?.lowercased(),
            sortOrder: m.sortOrder ?? 0, totalEmails: m.totalEmails ?? 0, unreadEmails: m.unreadEmails ?? 0)
    }

    static func incoming(_ e: Email) -> IncomingMessage {
        var addresses: [IncomingMessage.Address] = []
        func add(_ role: AddressRole, _ list: [EmailAddress]?) {
            for a in list ?? [] {
                guard let email = a.email, !email.isEmpty else { continue }
                addresses.append(.init(role: role, name: a.name, email: email))
            }
        }
        add(.from, e.from)
        add(.sender, e.sender)
        add(.to, e.to)
        add(.cc, e.cc)
        add(.bcc, e.bcc)
        add(.replyTo, e.replyTo)

        return IncomingMessage(
            remoteId: e.id, threadId: e.threadId, blobId: e.blobId,
            mailboxRemoteIds: e.mailboxIds.filter(\.value).map(\.key),
            keywords: e.keywords.filter(\.value).map(\.key),
            size: e.size, receivedAt: e.receivedAt, sentAt: e.sentAt,
            messageIdHeader: e.messageId?.first, inReplyTo: e.inReplyTo?.first,
            subject: e.subject ?? "", preview: e.preview ?? "", hasAttachment: e.hasAttachment,
            addresses: addresses)
    }

    /// Parts worth keeping a reference to: anything with a Content-ID (embedded images) and attachments.
    static func parts(_ email: EmailBody) -> [MessagePart] {
        var seen = Set<String>()
        return (email.htmlBody + email.attachments).compactMap { part in
            guard let blobId = part.blobId, part.cid != nil || part.disposition == "attachment" || part.name != nil,
                seen.insert(blobId).inserted
            else { return nil }
            return MessagePart(blobId: blobId, cid: part.cid, type: part.type, name: part.name, size: part.size)
        }
    }

    /// Builds displayable HTML and plain text from the JMAP body structure.
    static func render(_ email: EmailBody) -> MessageBody {
        func value(_ part: EmailBodyPart) -> String? { part.partId.flatMap { email.bodyValues[$0]?.value } }

        let text = email.textBody.compactMap(value).joined(separator: "\n\n")
        let hasHTML = email.htmlBody.contains { $0.type.lowercased() == "text/html" }
        guard hasHTML else { return MessageBody(html: nil, text: text) }

        var html = ""
        for part in email.htmlBody {
            guard let v = value(part) else { continue }
            if part.type.lowercased() == "text/html" {
                html += v
            } else if part.type.lowercased().hasPrefix("text/") {
                html += "<pre style=\"white-space: pre-wrap\">" + escapeHTML(v) + "</pre>"
            }
        }
        return MessageBody(html: html, text: text)
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
